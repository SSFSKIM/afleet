import XCTest
import WireFrames
import WireDiagnostics
import WireTestSupport

final class RedactorTests: XCTestCase {
    private func redacted(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(Redactor.redact(line: Data(s.utf8))))
    }
    func testStringSecretsReplacedNumbersUntouched() throws {
        let v = try redacted(#"{"type":"result","usage":{"input_tokens":12,"output_tokens":3,"thinking_tokens":1},"max_tokens":8,"tokens":5,"access_token":"sk-ant-abc","nested":{"apiKey":"k","oauthState":"s","secret_value":"v","count_tokens":7}}"#)
        XCTAssertEqual(v["usage"]?["input_tokens"], .integer(12)); XCTAssertEqual(v["usage"]?["thinking_tokens"], .integer(1))
        XCTAssertEqual(v["max_tokens"], .integer(8)); XCTAssertEqual(v["tokens"], .integer(5))
        XCTAssertEqual(v["access_token"], .string("<redacted>")); XCTAssertEqual(v["nested"]?["apiKey"], .string("<redacted>"))
        XCTAssertEqual(v["nested"]?["oauthState"], .string("<redacted>")); XCTAssertEqual(v["nested"]?["secret_value"], .string("<redacted>"))
        XCTAssertEqual(v["nested"]?["count_tokens"], .integer(7))          // a number, never redacted
    }
    func testAccountFieldsAndEnvironmentFramesDropped() throws {
        let v = try redacted(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"account":{"email":"a@b.c","uuid":"u"},"pid":1}}}"#)
        XCTAssertEqual(v["response"]?["response"]?["account"], .string("<redacted>")); XCTAssertEqual(v["response"]?["response"]?["pid"], .integer(1))
        XCTAssertNil(Redactor.redact(line: Data(#"{"type":"control_request","request_id":"e","request":{"subtype":"update_environment_variables","variables":{"A":"1"}}}"#.utf8)))
    }
    func testMCPBodiesTruncatedTo4KB() throws {
        let big = String(repeating: "x", count: 5000)
        let v = try redacted(#"{"type":"control_request","request_id":"m","request":{"subtype":"mcp_message","server_name":"afleet","message":{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"blob":""# + big + #""}}}}"#)
        let msg = v["request"]?["message"]
        XCTAssertEqual(msg?["truncated"]?.intValue.map { $0 > 4096 }, true)
        XCTAssertNil(msg?["params"])
    }
    func testUnparseableLineIsNotCaptured() {
        XCTAssertNil(Redactor.redact(line: Data("garbage".utf8)))
    }
    /// Parent §11 as revised at spec commit 22bc060: the identity rule is key-name based on
    /// string values (not object-only), over C1's `Tools/probe/redact.py` IDENTITY_KEYS compared
    /// after lowercase-and-separator normalisation, plus any email-shaped string anywhere, plus
    /// the whole-object replacement under an identity name.
    func testIdentityStringsAndEmailsRedacted() throws {
        let v = try redacted(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"accountUuid":"9f2","account_id":"7","organizationUuid":"org-1","organization_name":"Acme","userName":"alice","user_id":"u7","subscription_type":"max","fullName":"Alice Example","emailAddress":"a@b.co","note":"ping a@b.co or c@d.org","displayName":"Claude Haiku 4.5","user_message_uuid":"6d1d4b1e-0000-4000-8000-0000000000aa","tool_use_result":{"type":"text"},"hooks":{"UserPromptSubmit":["cmd"]},"user":{"id":1},"organizationId":42,"pid":1}}}"#)
        let r = try XCTUnwrap(v["response"]?["response"])
        for k in ["accountUuid", "account_id", "organizationUuid", "organization_name", "userName", "user_id", "subscription_type", "fullName", "emailAddress"] {
            XCTAssertEqual(r[k], .string("<redacted>"), k)   // normalisation folds case, _ and -
        }
        XCTAssertEqual(r["user"], .string("<redacted>"))     // an identity name over an object goes whole
        XCTAssertEqual(r["note"], .string("ping <email> or <email>"))   // email-shaped strings anywhere
        // Exact match on the normalised key, never substring. All four of these normalise to something
        // that *contains* an identity key, and all four are structural: `displayName` is a list_models row,
        // a plugin catalogue entry and a slash-command field; `user_message_uuid` links an assistant frame
        // to its user turn (Tests/Support/Samples/assistant.json); `tool_use_result` is the whole result
        // body of a user frame (user.json); `UserPromptSubmit` is a hook-event name used as a dictionary key.
        XCTAssertEqual(r["displayName"], .string("Claude Haiku 4.5"))
        XCTAssertEqual(r["user_message_uuid"], .string("6d1d4b1e-0000-4000-8000-0000000000aa"))
        XCTAssertEqual(r["tool_use_result"], .object(["type": .string("text")]))
        XCTAssertEqual(r["hooks"]?["UserPromptSubmit"], .array([.string("cmd")]))
        // A number under an identity name stays a number. §11 as revised scopes the rule to string
        // values and whole objects precisely so that a rewrite cannot change a declared Int into a
        // String and make the frame undecodable — the failure C1 hit at `subagent_stats.killed.user`.
        XCTAssertEqual(r["organizationId"], .integer(42))
        XCTAssertEqual(r["pid"], .integer(1))
    }
    /// Two exemptions that only a path can express, mirroring C1's IDENTITY_COUNTER_PATHS and
    /// SECRET_ENUM_PATHS. A name alone cannot tell `killed.user` (a count) from an account id,
    /// nor `behaviors[].key` (a behaviour enum) from a credential.
    func testPathScopedExemptions() throws {
        // On the wire `killed.user` is an integer, which the identity rule leaves alone anyway. The string
        // form is what binds the exemption: without it the rule would rewrite the count as "<redacted>".
        let i = try redacted(#"{"type":"result","subagent_stats":{"killed":{"user":3,"parent":1}},"userName":"alice"}"#)
        XCTAssertEqual(i["subagent_stats"]?["killed"]?["user"], .integer(3))
        XCTAssertEqual(i["subagent_stats"]?["killed"]?["parent"], .integer(1))
        XCTAssertEqual(i["userName"], .string("<redacted>"))   // same name, no exempting path
        let t = try redacted(#"{"type":"result","subagent_stats":{"killed":{"user":"3"}},"killed":{"user":"3"}}"#)
        XCTAssertEqual(t["subagent_stats"]?["killed"]?["user"], .string("3"))
        XCTAssertEqual(t["killed"]?["user"], .string("<redacted>"))   // the same leaf name off the exempt path
        let u = try redacted(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"rate_limits":{"day":{"behaviors":[{"key":"cache_miss","used":1},{"key":"cron","used":2}]}},"behaviors":{"keyring":"sk-ant-x"},"api_key":"sk-ant-x"}}}"#)
        let inner = try XCTUnwrap(u["response"]?["response"])
        let b = try XCTUnwrap(inner["rate_limits"]?["day"]?["behaviors"])
        XCTAssertEqual(b[0]?["key"], .string("cache_miss"))    // enum name, not a secret
        XCTAssertEqual(b[1]?["key"], .string("cron"))
        // The exemption is a trailing segment run, not a substring of the path: `behaviors.keyring`
        // contains "behaviors.key" and must still be redacted.
        XCTAssertEqual(inner["behaviors"]?["keyring"], .string("<redacted>"))
        XCTAssertEqual(inner["api_key"], .string("<redacted>"))
    }
    /// The counter exemption on a live path: a counter that arrives as a *string* is the one
    /// case where the secret rule would otherwise eat it, and the exemption is what stops that.
    func testUsageCountersExemptFromTheSecretRuleEvenAsStrings() throws {
        let v = try redacted(#"{"type":"result","max_tokens":"8","input_tokens":"12","cache_read_input_tokens":"0","access_token":"sk-ant-abc"}"#)
        XCTAssertEqual(v["max_tokens"], .string("8")); XCTAssertEqual(v["input_tokens"], .string("12"))
        XCTAssertEqual(v["cache_read_input_tokens"], .string("0"))
        XCTAssertEqual(v["access_token"], .string("<redacted>"))
    }
    func testTypedFramesStayTypedAfterRedaction() throws {
        for name in try TestPaths.sampleNames() {
            let raw = try TestPaths.sample(name)
            let before = FrameDecoder.decode(line: raw)
            guard let after = Redactor.redact(line: raw) else { XCTFail("\(name) dropped"); continue }
            let afterFrame = FrameDecoder.decode(line: after)
            XCTAssertEqual(before.typeName, afterFrame.typeName, name)
            if case .opaque = before { continue }
            if case .opaque(let o) = afterFrame { XCTFail("\(name) became opaque after redaction: \(o.reason)") }
        }
    }
}
