import XCTest
import WireFrames
import WireTestSupport

final class SystemFrameTests: XCTestCase {
    private func system(_ name: String) throws -> SystemFrame {
        guard case .system(let s) = FrameDecoder.decode(line: try TestPaths.sample(name)) else { XCTFail("\(name) not system"); throw XCTSkip() }
        return s
    }
    func testInitCarriesToolsCapabilitiesAndVersion() throws {
        guard case .initialize(let i) = try system("system_init") else { return XCTFail() }
        XCTAssertEqual(i.claudeCodeVersion, "2.1.259")
        XCTAssertTrue(i.tools.count >= 5)
        XCTAssertEqual(i.mcpServers.first?.name, "afleet")
        XCTAssertNotNil(i.capabilities)
        XCTAssertEqual(i.permissionMode, "default")
    }
    func testTaskFramesAreTyped() throws {
        guard case .taskStarted(let t) = try system("system_task_started") else { return XCTFail() }
        XCTAssertEqual(t.taskID, "a1b2c3d4e5f6a7b8c"); XCTAssertEqual(t.spawnDepth, 1); XCTAssertEqual(t.subagentType, "Explore")
        guard case .taskNotification(let n) = try system("system_task_notification") else { return XCTFail() }
        XCTAssertEqual(n.status, "completed"); XCTAssertTrue(n.outputFile.hasSuffix(".output"))
    }
    func testUnknownSubtypeIsSystemOpaqueAndReEncodes() throws {
        let raw = try TestPaths.sample("system_unknown_subtype")
        guard case .system(.opaque(let subtype, let value)) = FrameDecoder.decode(line: raw) else { return XCTFail() }
        XCTAssertEqual(subtype, "afleet_future_subtype"); XCTAssertEqual(value["payload"]?["x"], .integer(1))
        let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(.system(.opaque(subtype: subtype, value))))
        XCTAssertEqual(again, try JSONDecoder().decode(JSONValue.self, from: raw))
    }
    /// A modelled subtype whose payload does not decode must be the TOP-LEVEL opaque with a
    /// decodeFailure reason, not `.system(.opaque)`: that is what lets the drift counter tell
    /// "new subtype" apart from "known subtype, new shape".
    func testKnownSubtypeWithBadPayloadIsTopLevelOpaque() throws {
        let broken = Data(#"{"type":"system","subtype":"api_retry","attempt":"two","max_retries":4,"retry_delay_ms":1000,"error_status":null,"error":"Connection error.","uuid":"u","session_id":"s"}"#.utf8)
        guard case .opaque(let o) = FrameDecoder.decode(line: broken) else { return XCTFail("must not be .system(.opaque)") }
        XCTAssertEqual(o.type, "system"); XCTAssertEqual(o.subtype, "api_retry")
        guard case .decodeFailure(let field, _) = o.reason else { return XCTFail("\(o.reason)") }
        XCTAssertEqual(field, "attempt")
    }
    func testSubtypeAccessorMatchesWire() throws {
        XCTAssertEqual(try system("system_mirror_error").subtype, "mirror_error")
        XCTAssertEqual(try system("system_model_consent_fallback").subtype, "model_consent_fallback")
        XCTAssertEqual(try system("system_unknown_subtype").subtype, "afleet_future_subtype")
    }
    func testOtherOneWayFrames() throws {
        guard case .transcriptMirror(let m) = FrameDecoder.decode(line: try TestPaths.sample("transcript_mirror")) else { return XCTFail() }
        XCTAssertTrue(m.filePath.hasSuffix(".jsonl")); XCTAssertEqual(m.entries.count, 1)
        guard case .toolUseSummary(let s) = FrameDecoder.decode(line: try TestPaths.sample("tool_use_summary")) else { return XCTFail() }
        XCTAssertEqual(s.precedingToolUseIDs, ["toolu_01"])
        guard case .authStatus(let a) = FrameDecoder.decode(line: try TestPaths.sample("auth_status")) else { return XCTFail() }
        XCTAssertEqual(a.isAuthenticating, false)
    }
}
