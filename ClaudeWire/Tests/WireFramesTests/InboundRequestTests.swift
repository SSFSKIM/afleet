import XCTest
import WireFrames
import WireTestSupport

final class InboundRequestTests: XCTestCase {
    private func parse(_ name: String) throws -> InboundRequest {
        guard case .controlRequest(let f) = FrameDecoder.decode(line: try TestPaths.sample(name)) else { XCTFail("\(name) is not a control_request"); throw XCTSkip("not a control_request") }
        return InboundRequest.parse(frame: f, epoch: .first, receivedAt: .now)
    }
    func testCanUseTool() throws {
        let r = try parse("control_request_can_use_tool")
        XCTAssertEqual(r.id.rawValue, "req-001"); XCTAssertEqual(r.epoch, .first)
        guard case .canUseTool(let p) = r.payload else { return XCTFail() }
        XCTAssertEqual(p.toolName, "Write"); XCTAssertEqual(p.toolUseID, "toolu_02")
        XCTAssertEqual(p.permissionSuggestions?.count, 1)
        guard case .addRules(let rules, let behavior, let dest) = p.permissionSuggestions?[0] else { return XCTFail() }
        XCTAssertEqual(rules[0].toolName, "Write"); XCTAssertEqual(behavior, .allow); XCTAssertEqual(dest, .localSettings)
        guard case .write(let w) = p.typedInput else { return XCTFail() }
        XCTAssertEqual(w.filePath, "/tmp/scratch/out.txt")
        XCTAssertEqual(r.subtype, "can_use_tool")
    }
    func testHookMCPElicitationDialog() throws {
        guard case .hookCallback(let h) = try parse("control_request_hook_callback").payload else { return XCTFail() }
        XCTAssertEqual(h.callbackID, "afleet.notification"); XCTAssertEqual(h.input["hook_event_name"], .string("Notification"))
        guard case .mcpMessage(let m) = try parse("control_request_mcp_message").payload, case .request(let rpc) = m.message else { return XCTFail() }
        XCTAssertEqual(m.serverName, "afleet"); XCTAssertEqual(rpc.method, "tools/list")
        guard case .elicitation(let e) = try parse("control_request_elicitation").payload else { return XCTFail() }
        XCTAssertEqual(e.mcpServerName, "github"); XCTAssertEqual(e.mode, "form")
        guard case .requestUserDialog(let d) = try parse("control_request_request_user_dialog").payload else { return XCTFail() }
        XCTAssertEqual(d.dialogKind, "refusal_fallback_prompt"); XCTAssertEqual(d.payload["fallbackModel"], .string("claude-opus-5"))
    }
    func testUnknownAndMalformed() throws {
        guard case .unknown(let subtype, let v) = try parse("control_request_unknown").payload else { return XCTFail() }
        XCTAssertEqual(subtype, "afleet_never_heard"); XCTAssertEqual(v["anything"], .integer(1))
        let bad = try parse("control_request_malformed_can_use_tool")
        guard case .malformed(let subtype2, let field, let raw) = bad.payload else { return XCTFail() }
        XCTAssertEqual(subtype2, "can_use_tool"); XCTAssertEqual(field, "input")
        XCTAssertEqual(raw["tool_name"], .string("Write"))
        XCTAssertEqual(bad.subtype, "can_use_tool")
    }
    /// The engine's `issued_at` / `deadline_ms` on hook_callback are @internal and unmodelled; they must survive in `additional`.
    func testUnmodelledKeysSurviveInAdditional() throws {
        let line = Data(#"{"type":"control_request","request_id":"req-h2","request":{"subtype":"hook_callback","callback_id":"c","input":{},"issued_at":17}}"#.utf8)
        guard case .controlRequest(let f) = FrameDecoder.decode(line: line) else { return XCTFail() }
        guard case .hookCallback(let h) = InboundRequest.parse(frame: f, epoch: .first, receivedAt: .now).payload else { return XCTFail() }
        XCTAssertEqual(h.additional["issued_at"], .integer(17))
    }
}
