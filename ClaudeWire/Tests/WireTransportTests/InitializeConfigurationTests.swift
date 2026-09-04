import XCTest
import WireFrames
import WireTransport

final class InitializeConfigurationTests: XCTestCase {
    func testDefaultPayloadIsByteEqualToParentSection62() throws {
        let expected = Data(#"{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize","supportedDialogKinds":["refusal_fallback_prompt","fable_overage_consent_prompt"],"perTaskStopAffordance":true,"agentProgressSummaries":true,"sdkMcpServers":["afleet"],"sdkMcpServerConfigs":{"afleet":{}},"hooks":{"Notification":[{"hookCallbackIds":["afleet.notification"]}],"ConfigChange":[{"hookCallbackIds":["afleet.config-change"]}]}}}"#.utf8)
        let canonicalExpected = try JSONDecoder().decode(JSONValue.self, from: expected).canonicalData()
        let line = try InitializeConfiguration().requestLine(requestID: RequestID(rawValue: "init-1"))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: line).canonicalData(), canonicalExpected)
    }
    func testHookMatcherEncodesOptionalFields() throws {
        let cfg = InitializeConfiguration(hooks: [.preToolUse: [HookCallbackMatcher(matcher: "Bash", hookCallbackIds: ["a"], timeout: 30)]])
        let v = cfg.payload()
        XCTAssertEqual(v["hooks"]?["PreToolUse"]?[0], .object(["matcher": .string("Bash"), "hookCallbackIds": .array([.string("a")]), "timeout": .integer(30)]))
    }
}
