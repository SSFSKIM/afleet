import XCTest
import AfleetCore
import WireFrames
import WireDiagnostics

final class RawCaptureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-cap-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var home: ConfigHome { ConfigHome(root: URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home"), source: .environment) }

    func testWritesRedactedLinesUnderHashedDirWithModes() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 1_000_000)
        let s = SessionID()
        await cap.write(line: Data(#"{"type":"keep_alive","access_token":"t"}"#.utf8), session: s)
        let dir = root.appendingPathComponent(RawCapture.configHomeHash(home))
        let file = dir.appendingPathComponent("\(s.description).ndjson")
        XCTAssertEqual(RawCapture.configHomeHash(home).count, 12)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("<redacted>")); XCTAssertFalse(text.contains("\"t\"")); XCTAssertTrue(text.hasSuffix("\n"))
        let dirPerm = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        let filePerm = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerm, 0o700); XCTAssertEqual(filePerm, 0o600)
    }
    /// The budget skips *past* the session currently being written rather than stopping at it, and it
    /// counts and deletes only the `.ndjson` files this type owns — `prune` always did, and the two
    /// disagreeing meant a foreign file in the directory could be deleted to satisfy a budget it was never
    /// counted against.
    ///
    /// The protected session is forced to be the oldest entry by pushing the other files' modification
    /// times into the future; a write refreshes its own file's timestamp, so it is otherwise always newest.
    func testBudgetSkipsPastTheProtectedSessionAndLeavesForeignFilesAlone() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 300)
        let a = SessionID(), b = SessionID(), c = SessionID()
        let line = { (n: Int) in Data((#"{"type":"keep_alive","pad":""# + String(repeating: "x", count: 100 + n) + #""}"#).utf8) }
        for (s, n) in [(a, 0), (b, 1), (c, 2)] { await cap.write(line: line(n), session: s) }
        let dir = root.appendingPathComponent(RawCapture.configHomeHash(home))
        let stray = dir.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 500).write(to: stray)
        // Distinct future timestamps, not one shared value: equal timestamps leave the sort order between
        // the two undefined and the assertion below could not name which of them is evicted.
        for (s, offset) in [(b, 3600.0), (c, 7200.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)],
                                                  ofItemAtPath: dir.appendingPathComponent("\(s.description).ndjson").path)
        }
        await cap.write(line: line(0), session: a)          // `a` is now both the oldest file and the protected one
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertTrue(files.contains("\(a.description).ndjson"), "the session being written is never evicted")
        XCTAssertTrue(files.contains("notes.txt"), "a file this type does not own is not deleted")
        XCTAssertFalse(files.contains("\(b.description).ndjson"), "eviction continues past the protected session")
        XCTAssertTrue(files.contains("\(c.description).ndjson"), "and stops once the budget holds")
        let owned = files.filter { $0.hasSuffix(".ndjson") }
            .compactMap { try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? Int }
        XCTAssertLessThanOrEqual(owned.reduce(0, +), 300, "the budget holds over the files the type owns")
    }

    /// End to end: the grant must not be on disk. The capture is where a redaction miss actually costs
    /// something, so this asserts against the file rather than against the redactor's return value.
    func testAnOAuthCallbackGrantNeverReachesTheCapture() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 1_000_000)
        let s = SessionID()
        await cap.write(line: Data(#"{"type":"control_request","request_id":"o1","request":{"subtype":"mcp_oauth_callback_url","serverName":"github","callbackUrl":"http://localhost:51337/cb?code=abc123&state=xyz789"}}"#.utf8), session: s)
        let file = root.appendingPathComponent(RawCapture.configHomeHash(home)).appendingPathComponent("\(s.description).ndjson")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("abc123"), text)
        XCTAssertFalse(text.contains("xyz789"), text)
        XCTAssertTrue(text.contains("<redacted>"), text)
        XCTAssertTrue(text.contains("mcp_oauth_callback_url"), "the frame is still captured; only the grant is gone")
    }

    // MARK: - on-disk safety

    private func line(_ pad: Int = 100) -> Data {
        Data((#"{"type":"keep_alive","pad":""# + String(repeating: "x", count: pad) + #""}"#).utf8)
    }
    private var captureDirectory: URL { root.appendingPathComponent(RawCapture.configHomeHash(home)) }
    /// The bytes actually on disk in the files the capture owns.
    private func ownedBytes() throws -> Int {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(atPath: captureDirectory.path)
            .filter { $0.hasSuffix(".ndjson") }
            .compactMap { try? fm.attributesOfItem(atPath: captureDirectory.appendingPathComponent($0).path) }
            .filter { ($0[.type] as? FileAttributeType) == .typeRegular }
            .reduce(0) { $0 + (($1[.size] as? Int) ?? 0) }
    }

    /// The modes used to be applied only at creation, so a directory or a file that was already there kept
    /// whatever it had — and capture data sat in it world-readable. They are now enforced on the descriptor
    /// that was actually opened, whether it was created or found.
    func testExistingPermissiveDirectoryAndFileAreTightened() async throws {
        let s = SessionID()
        let fm = FileManager.default
        try fm.createDirectory(at: captureDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let file = captureDirectory.appendingPathComponent("\(s.description).ndjson")
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o666])
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 1_000_000)
        await cap.write(line: line(), session: s)
        XCTAssertEqual(try fm.attributesOfItem(atPath: captureDirectory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 0, "the write still happened")
    }

    /// A session file that is really a symlink must not be written through: the target is somewhere the
    /// capture system does not own, and redirecting a session's frames there is how captured data leaves the
    /// directory it was budgeted, permissioned and pruned in.
    func testASymlinkedSessionFileIsRefusedAndItsTargetIsNeverWritten() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.txt")
        try Data("original".utf8).write(to: target)
        let s = SessionID()
        try fm.createSymbolicLink(at: captureDirectory.appendingPathComponent("\(s.description).ndjson"), withDestinationURL: target)
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 1_000_000)
        await cap.write(line: line(), session: s)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    /// The same for the directory itself, which the path-based `fileExists` check could not see.
    func testASymlinkedCaptureDirectoryIsRefused() async throws {
        let fm = FileManager.default
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: captureDirectory, withDestinationURL: elsewhere)
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 1_000_000)
        await cap.write(line: line(), session: SessionID())
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// The budget is a statement about what is on disk. It used to append first and enforce second, and then
    /// refuse to evict the file it had just appended to — so a single long-lived session, which is the
    /// ordinary case, grew without limit and the 200 MB budget never applied to it at all.
    func testASingleLongLivedSessionStaysInsideTheBudget() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 400)
        let s = SessionID()
        for i in 0..<20 {
            await cap.write(line: line(), session: s)
            XCTAssertLessThanOrEqual(try ownedBytes(), 400, "over budget after write \(i)")
        }
        XCTAssertGreaterThan(try ownedBytes(), 0, "and it is still capturing, not merely empty")
    }

    /// The other end of the same rule: a line that cannot fit in the budget at all is dropped rather than
    /// written and left there.
    func testALineLargerThanTheWholeBudgetIsNeverWritten() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 50)
        await cap.write(line: line(), session: SessionID())
        XCTAssertEqual(try ownedBytes(), 0)
    }

    /// Eviction counted every name ending in `.ndjson` and then handed it to `removeItem`, which on a
    /// directory deletes the whole tree. Ownership is proven now, so a directory wearing the suffix is
    /// neither counted against the budget nor deleted by it, nor by `prune`.
    func testADirectoryWearingTheSuffixIsNeitherCountedNorDeleted() async throws {
        let fm = FileManager.default
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 300)
        let s = SessionID()
        await cap.write(line: line(), session: s)
        let impostor = captureDirectory.appendingPathComponent("\(SessionID().description).ndjson")
        try fm.createDirectory(at: impostor, withIntermediateDirectories: true)
        let inside = impostor.appendingPathComponent("payload.txt")
        try Data("precious".utf8).write(to: inside)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: impostor.path)
        for _ in 0..<4 { await cap.write(line: line(), session: s) }
        await cap.prune(keeping: [])
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "precious")
    }

    /// A failed eviction used to be accounted as if it had succeeded, so enforcement concluded the budget
    /// held while the bytes were still on disk and stopped before evicting anything that would have helped.
    /// `UF_IMMUTABLE` makes `removeItem` fail for real rather than through a stub.
    func testAFailedEvictionDoesNotStopEnforcement() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let stuck = SessionID(), evictable = SessionID()
        let stuckURL = captureDirectory.appendingPathComponent("\(stuck.description).ndjson")
        let evictableURL = captureDirectory.appendingPathComponent("\(evictable.description).ndjson")
        try Data(repeating: 0x41, count: 200).write(to: stuckURL)
        try Data(repeating: 0x42, count: 150).write(to: evictableURL)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stuckURL.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: evictableURL.path)
        XCTAssertEqual(chflags(stuckURL.path, UInt32(UF_IMMUTABLE)), 0, "the test needs a removal that really fails")
        defer { _ = chflags(stuckURL.path, 0) }
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 300)
        await cap.write(line: line(), session: SessionID())
        XCTAssertTrue(fm.fileExists(atPath: stuckURL.path), "its removal failed, so it is still there")
        XCTAssertFalse(fm.fileExists(atPath: evictableURL.path),
                       "enforcement must go on to the next candidate rather than conclude on bytes it failed to remove")
    }

    func testBudgetEvictsOldestAndPruneRemovesUnknownSessions() async throws {
        let cap = RawCapture(root: root, configHome: home, budgetBytes: 300)
        let a = SessionID(), b = SessionID(), c = SessionID()
        for (s, n) in [(a, 0), (b, 1), (c, 2)] {
            try await Task.sleep(for: .milliseconds(20))
            await cap.write(line: Data((#"{"type":"keep_alive","pad":""# + String(repeating: "x", count: 100 + n) + #""}"#).utf8), session: s)
        }
        let dir = root.appendingPathComponent(RawCapture.configHomeHash(home))
        var files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains("\(a.description).ndjson"), "oldest should be evicted")
        XCTAssertTrue(files.contains("\(c.description).ndjson"))
        await cap.prune(keeping: [c])
        files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files, ["\(c.description).ndjson"])
    }
}
