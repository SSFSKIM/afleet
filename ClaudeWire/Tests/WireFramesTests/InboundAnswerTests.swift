import XCTest
import WireFrames

final class InboundAnswerTests: XCTestCase {
    private func json(_ a: InboundAnswer, id: String = "r") throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(a.controlResponse(for: RequestID(rawValue: id))))
    }
    func testAllowWithUpdatedInputAndPermissions() throws {
        let a = InboundAnswer.permission(.allow(updatedInput: .object(["file_path": .string("/tmp/x")]),
                                                updatedPermissions: [.setMode(mode: .acceptEdits, destination: .session)],
                                                classification: .userTemporary))
        let v = try json(a)
        XCTAssertEqual(v["type"], .string("control_response"))
        XCTAssertEqual(v["response"]?["subtype"], .string("success")); XCTAssertEqual(v["response"]?["request_id"], .string("r"))
        let r = v["response"]?["response"]
        XCTAssertEqual(r?["behavior"], .string("allow")); XCTAssertEqual(r?["updatedInput"]?["file_path"], .string("/tmp/x"))
        XCTAssertEqual(r?["updatedPermissions"]?[0]?["type"], .string("setMode")); XCTAssertEqual(r?["updatedPermissions"]?[0]?["mode"], .string("acceptEdits"))
        XCTAssertEqual(r?["updatedPermissions"]?[0]?["destination"], .string("session"))
        XCTAssertEqual(r?["decisionClassification"], .string("user_temporary"))
    }
    func testDenyDialogElicitationHookMCPAndError() throws {
        XCTAssertEqual(try json(.permission(.deny(message: "no", interrupt: false, classification: .userReject)))["response"]?["response"]?["message"], .string("no"))
        XCTAssertEqual(try json(.dialog(.completed(result: .string("retry_fallback"))))["response"]?["response"]?["result"], .string("retry_fallback"))
        XCTAssertEqual(try json(.dialog(.cancelled))["response"]?["response"]?["behavior"], .string("cancelled"))
        XCTAssertEqual(try json(.elicitation(.accept(content: .object(["repo": .string("a")]))))["response"]?["response"]?["action"], .string("accept"))
        XCTAssertEqual(try json(.elicitation(.decline))["response"]?["response"]?["action"], .string("decline"))
        XCTAssertEqual(try json(.elicitation(.cancel))["response"]?["response"]?["action"], .string("cancel"))
        XCTAssertEqual(try json(.hookContinue(.empty))["response"]?["response"], .object([:]))
        let mcp = try json(.mcpResponse(.response(.init(id: .number(0), result: .object([:])))))
        XCTAssertEqual(mcp["response"]?["response"]?["mcp_response"]?["id"], .integer(0))
        let err = try json(.error("subtype x not supported by afleet 0.1.0"))
        XCTAssertEqual(err["response"]?["subtype"], .string("error")); XCTAssertEqual(err["response"]?["error"], .string("subtype x not supported by afleet 0.1.0"))
    }
    func testPermissionModeAndDestinationRawValuesMatchTypings() {
        XCTAssertEqual(PermissionMode.allCases.map(\.rawValue), ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"])
        XCTAssertEqual(PermissionUpdateDestination.allCases.map(\.rawValue), ["userSettings", "projectSettings", "localSettings", "session", "cliArg"])
        XCTAssertEqual(PermissionBehavior.allCases.map(\.rawValue), ["allow", "deny", "ask"])
        // The engine's classification enum is exactly these three; anything else is dropped by its `.catch(void 0)`.
        XCTAssertEqual(PermissionDecisionClassification.allCases.map(\.rawValue), ["user_temporary", "user_permanent", "user_reject"])
    }
    func testPermissionUpdateRoundTrips() throws {
        let all: [PermissionUpdate] = [
            .addRules(rules: [PermissionRuleValue(toolName: "Write", ruleContent: "/tmp/**")], behavior: .allow, destination: .localSettings),
            .replaceRules(rules: [PermissionRuleValue(toolName: "Bash")], behavior: .deny, destination: .userSettings),
            .removeRules(rules: [PermissionRuleValue(toolName: "Read")], behavior: .ask, destination: .projectSettings),
            .setMode(mode: .plan, destination: .session),
            .addDirectories(directories: ["/a"], destination: .cliArg),
            .removeDirectories(directories: ["/b"], destination: .session),
        ]
        for update in all {
            let data = try JSONEncoder().encode(update)
            XCTAssertEqual(try JSONDecoder().decode(PermissionUpdate.self, from: data), update)
        }
        let encoded = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(all[0]))
        XCTAssertEqual(encoded["type"], .string("addRules"))
        XCTAssertEqual(encoded["rules"]?[0]?["toolName"], .string("Write"))
        XCTAssertEqual(encoded["rules"]?[0]?["ruleContent"], .string("/tmp/**"))
    }
}
