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
