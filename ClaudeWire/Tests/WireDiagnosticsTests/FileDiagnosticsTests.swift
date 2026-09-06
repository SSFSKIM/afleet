import XCTest
import WireFrames
import WireDiagnostics

final class FileDiagnosticsTests: XCTestCase {
    func testAppendsJSONLinesAndRotatesOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileDiagnostics(directory: dir, rotateAt: 2_000)
        for i in 0..<100 { sink.record(.frame(direction: .inbound, type: "assistant", subtype: nil, bytes: i, epoch: .first, requestID: nil)) }
        sink.flush()
        let log = dir.appendingPathComponent("diagnostics.log"), old = dir.appendingPathComponent("diagnostics.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let first = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first["event"], .string("frame")); XCTAssertEqual(first["type"], .string("assistant")); XCTAssertNotNil(first["at"])
        XCTAssertNil(first["payload"])
        // The log holds metadata about every frame on the machine, so its modes are asserted here for the
        // same reason the capture tests assert theirs.
        let dirPerm = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        let logPerm = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int
        let oldPerm = try FileManager.default.attributesOfItem(atPath: old.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerm, 0o700); XCTAssertEqual(logPerm, 0o600); XCTAssertEqual(oldPerm, 0o600)
    }
    /// The app's *Delete diagnostics* unlinks the log while the sink lives on. A sink that held one handle open for
    /// its whole life kept writing into the unlinked inode and the user's next diagnostics were lost to a file with
    /// no name; opening per write means the next record recreates the file.
    func testRecordsAfterTheLogIsDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileDiagnostics(directory: dir)
        sink.record(.frame(direction: .inbound, type: "assistant", subtype: nil, bytes: 11, epoch: .first, requestID: nil))
        sink.flush()
        let log = dir.appendingPathComponent("diagnostics.log")
        try FileManager.default.removeItem(at: log)

        sink.record(.frame(direction: .outbound, type: "user", subtype: nil, bytes: 22, epoch: .first, requestID: nil))
        sink.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "the deleted log was never recreated")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "the recreated log holds exactly the record made after the deletion")
        let only = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
        XCTAssertEqual(only["type"], .string("user"))
        XCTAssertEqual(only["bytes"], .integer(22))
        let perm = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int
        XCTAssertEqual(perm, 0o600)
    }
}
