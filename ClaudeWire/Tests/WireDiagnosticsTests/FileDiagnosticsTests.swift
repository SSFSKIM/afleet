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
    }
}
