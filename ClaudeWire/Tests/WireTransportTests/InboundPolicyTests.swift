import XCTest
import WireFrames
import WireTransport

final class InboundPolicyTests: XCTestCase {
    private func req(_ p: InboundRequest.Payload) -> InboundRequest { .init(id: .init(rawValue: "r"), epoch: .first, receivedAt: .now, payload: p, raw: .object([:])) }
    func testDecisions() throws {
        let policy = InboundPolicy.default(declaredDialogKinds: ["refusal_fallback_prompt"], registeredHookCallbackIDs: ["afleet.notification"])
        XCTAssertEqual(policy.decide(req(.unknown(subtype: "x", .null))), .answer(.error("subtype x not supported by afleet 0.1.0")))
        XCTAssertEqual(policy.decide(req(.malformed(subtype: "can_use_tool", field: "input", .null))), .answer(.error("can_use_tool: cannot decode field input")))
        let undeclared = try JSONDecoder().decode(UserDialogRequest.self, from: Data(#"{"subtype":"request_user_dialog","dialog_kind":"weird","payload":{}}"#.utf8))
        XCTAssertEqual(policy.decide(req(.requestUserDialog(undeclared))), .leaveUnanswered)
        let declared = try JSONDecoder().decode(UserDialogRequest.self, from: Data(#"{"subtype":"request_user_dialog","dialog_kind":"refusal_fallback_prompt","payload":{}}"#.utf8))
        XCTAssertEqual(policy.decide(req(.requestUserDialog(declared))), .surface)
        let unregistered = try JSONDecoder().decode(HookCallbackRequest.self, from: Data(#"{"subtype":"hook_callback","callback_id":"nope","input":{}}"#.utf8))
        XCTAssertEqual(policy.decide(req(.hookCallback(unregistered))), .answer(.hookContinue(.empty)))
        let registered = try JSONDecoder().decode(HookCallbackRequest.self, from: Data(#"{"subtype":"hook_callback","callback_id":"afleet.notification","input":{}}"#.utf8))
        XCTAssertEqual(policy.decide(req(.hookCallback(registered))), .surface)
        let mcp = try JSONDecoder().decode(MCPMessageRequest.self, from: Data(#"{"subtype":"mcp_message","server_name":"afleet","message":{"jsonrpc":"2.0","id":1,"method":"ping"}}"#.utf8))
        XCTAssertEqual(policy.decide(req(.mcpMessage(mcp))), .routeToMCP)
    }
}
