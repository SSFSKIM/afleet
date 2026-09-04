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
