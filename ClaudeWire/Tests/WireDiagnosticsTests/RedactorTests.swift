import XCTest
import WireFrames
import WireDiagnostics
import WireTestSupport

final class RedactorTests: XCTestCase {
    private func redacted(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(Redactor.redact(line: Data(s.utf8))))
    }
    /// The body of a control_response, which is where most of the interesting rules land.
    private func responseBody(_ body: String) throws -> JSONValue {
        let v = try redacted(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":"# + body + #"}}"#)
        return try XCTUnwrap(v["response"]?["response"])
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
        XCTAssertEqual(v["response"]?["response"]?["account"], .string("<account>")); XCTAssertEqual(v["response"]?["response"]?["pid"], .integer(1))
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

    // MARK: - Identity, parent §11 as revised at spec commits 22bc060 and ed87a22

    /// The identity rule is key-name based, normalised and case-insensitive, over C1's IDENTITY_KEYS, plus
    /// any email-shaped string anywhere. It replaces the value whatever its type, and names its placeholder
    /// after the key so a reviewer reads a capture and a fixture with one checklist.
    func testIdentityFieldsRedactedWithKeyDerivedPlaceholders() throws {
        let r = try responseBody(#"{"accountUuid":"9f2","account_id":"7","organizationUuid":"org-1","organization_name":"Acme","userName":"alice","user_id":"u7","subscription_type":"max","fullName":"Alice Example","emailAddress":"a@b.co","note":"ping a@b.co or c@d.org","displayName":"Claude Haiku 4.5","user_message_uuid":"6d1d4b1e-0000-4000-8000-0000000000aa","tool_use_result":{"type":"text"},"hooks":{"UserPromptSubmit":["cmd"]},"user":{"id":1},"organizationId":42,"pid":1}"#)
        for k in ["accountUuid", "account_id", "organizationUuid", "organization_name", "userName", "user_id", "subscription_type", "fullName"] {
            XCTAssertEqual(r[k], .string("<\(k)>"), k)      // normalisation folds case, _ and -; the placeholder keeps the key
        }
        XCTAssertEqual(r["emailAddress"], .string("<email>"))   // the one substring match, and its own placeholder
        XCTAssertEqual(r["user"], .string("<user>"))            // whatever the type: an object goes whole
        XCTAssertEqual(r["organizationId"], .string("<organizationId>"))   // and so does a number
        XCTAssertEqual(r["note"], .string("ping <email> or <email>"))      // email-shaped strings anywhere
        // Exact match on the normalised key, never substring. All four normalise to something that
        // *contains* an identity key and all four are structural: `displayName` is a list_models row, a
        // plugin catalogue entry and a slash-command field; `user_message_uuid` links an assistant frame to
        // its user turn (Tests/Support/Samples/assistant.json); `tool_use_result` is the whole result body
        // of a user frame (user.json); `UserPromptSubmit` is a hook-event name used as a dictionary key.
        XCTAssertEqual(r["displayName"], .string("Claude Haiku 4.5"))
        XCTAssertEqual(r["user_message_uuid"], .string("6d1d4b1e-0000-4000-8000-0000000000aa"))
        XCTAssertEqual(r["tool_use_result"], .object(["type": .string("text")]))
        XCTAssertEqual(r["hooks"]?["UserPromptSubmit"], .array([.string("cmd")]))
        XCTAssertEqual(r["pid"], .integer(1))
    }
    /// Two exemptions that only a path can express, mirroring C1's IDENTITY_COUNTER_PATHS and
    /// SECRET_ENUM_PATHS. A name alone cannot tell `killed.user` — a count of subagents the user killed,
    /// present on every result frame — from an account id, nor `behaviors[].key` from a credential.
    func testPathScopedExemptions() throws {
        let i = try redacted(#"{"type":"result","subagent_stats":{"killed":{"user":3,"parent":1}},"userName":"alice","killed":{"user":9}}"#)
        XCTAssertEqual(i["subagent_stats"]?["killed"]?["user"], .integer(3))
        XCTAssertEqual(i["subagent_stats"]?["killed"]?["parent"], .integer(1))
        XCTAssertEqual(i["killed"]?["user"], .string("<user>"))   // the same leaf name off the exempt path
        XCTAssertEqual(i["userName"], .string("<userName>"))
        let b = try responseBody(#"{"rate_limits":{"day":{"behaviors":[{"key":"cache_miss","used":1},{"key":"cron","used":2}]}},"behaviors":{"keyring":"sk-x"},"api_key":"sk-x"}"#)
        XCTAssertEqual(b["rate_limits"]?["day"]?["behaviors"]?[0]?["key"], .string("cache_miss"))
        XCTAssertEqual(b["rate_limits"]?["day"]?["behaviors"]?[1]?["key"], .string("cron"))
        // The exemption is a trailing segment run, not a substring of the path: `behaviors.keyring`
        // contains "behaviors.key" and must still be redacted.
        XCTAssertEqual(b["behaviors"]?["keyring"], .string("<redacted>"))
        XCTAssertEqual(b["api_key"], .string("<redacted>"))
    }

    // MARK: - Secrets, mirroring redact.py rule 2 in full

    /// The secret rule fires on any secret-named field whatever its type. Reading it as "any secret-named
    /// *string*" is what left `{"authorization": {"value": "Bearer .."}}` on disk. `bearer` is a secret
    /// word. `null` is never redacted — nothing there to leak, and a placeholder changes the field's type.
    func testSecretRuleFiresOnContainersAndSkipsNull() throws {
        let r = try responseBody(#"{"authorization":{"value":"Bearer x"},"cookies":[{"value":"c"}],"api_keys":{"primary":"p"},"bearer":"b","seven_day_oauth_apps":null,"usage":{"output_tokens_details":{"reasoning":3},"cacheReadInputTokens":9,"estimated_tokens_delta":1,"maxOutputTokens":4096,"progressToken":7}}"#)
        for k in ["authorization", "cookies", "api_keys", "bearer"] { XCTAssertEqual(r[k], .string("<redacted>"), k) }
        XCTAssertEqual(r["seven_day_oauth_apps"], .null)
        // The token-counter test: `token` is the only secret word present and nothing under the value is a
        // string, so each of these stays — including a whole dict of counters, without being listed anywhere.
        XCTAssertEqual(r["usage"]?["output_tokens_details"], .object(["reasoning": .integer(3)]))
        XCTAssertEqual(r["usage"]?["cacheReadInputTokens"], .integer(9))
        XCTAssertEqual(r["usage"]?["estimated_tokens_delta"], .integer(1))
        XCTAssertEqual(r["usage"]?["maxOutputTokens"], .integer(4096))
        XCTAssertEqual(r["usage"]?["progressToken"], .integer(7))
    }
    /// C1's SECRET_EXEMPT: three structural names that happen to contain a secret word. `apiKeySource` has
    /// its own rule on top — the literal value `none` is kept, anything else becomes a placeholder.
    func testStructuralNamesExemptFromTheSecretRule() throws {
        let r = try responseBody(#"{"projectKey":"-Users-alice-Developer","hookCallbackIds":["h1","h2"],"apiKeySource":"none","oauth_token":"t"}"#)
        XCTAssertEqual(r["projectKey"], .string("-Users-alice-Developer"))   // names the directory a GUI reads to replay history
        XCTAssertEqual(r["hookCallbackIds"], .array([.string("h1"), .string("h2")]))
        XCTAssertEqual(r["apiKeySource"], .string("none"))
        XCTAssertEqual(r["oauth_token"], .string("<redacted>"))            // `token` is not the only secret word here
        let other = try responseBody(#"{"apiKeySource":"ANTHROPIC_API_KEY"}"#)
        XCTAssertEqual(other["apiKeySource"], .string("<apiKeySource>"))
    }
    /// Usage counters are exempt by exact lowercased name whatever the value's type — the string form is
    /// the one case where the secret rule would otherwise eat them.
    func testUsageCountersExemptEvenAsStrings() throws {
        let v = try redacted(#"{"type":"result","max_tokens":"8","input_tokens":"12","cache_read_input_tokens":"0","rawmaxtokens":"1","access_token":"x"}"#)
        XCTAssertEqual(v["max_tokens"], .string("8")); XCTAssertEqual(v["input_tokens"], .string("12"))
        XCTAssertEqual(v["cache_read_input_tokens"], .string("0")); XCTAssertEqual(v["rawmaxtokens"], .string("1"))
        XCTAssertEqual(v["access_token"], .string("<redacted>"))
    }
    /// Content patterns, which fire on a string wherever it sits and whatever its key is called. The
    /// `ls -l` owner and group columns are matched by *position*: a directory listing carries the recording
    /// machine's account name where no name-keyed rule looks.
    func testContentPatternsInAnyString() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let long = String(repeating: "a", count: 40)
        let r = try responseBody(#"{"text":"here is sk-ant-api03-XYZ and a jwt "# + jwt + #"","listing":"-rw-r--r--@  1 alice  staff  1024 Sep  5 10:00 notes.txt"}"#)
        let text = try XCTUnwrap(r["text"]?.stringValue)
        XCTAssertFalse(text.contains("sk-ant-api03")); XCTAssertFalse(text.contains("eyJhbGci"))
        XCTAssertEqual(text, "here is <redacted> and a jwt <redacted>")
        XCTAssertEqual(r["listing"], .string("-rw-r--r--@  1 <user>  <group>  1024 Sep  5 10:00 notes.txt"))
        // A long random-looking query run is redacted wherever it sits, independently of rule 6, which only
        // walks a control_response body.
        let elsewhere = try redacted(#"{"type":"result","note":"see https://x/cb?state="# + long + #"&ok=1"}"#)
        XCTAssertEqual(elsewhere["note"], .string("see https://x/cb?state=<redacted>&ok=1"))
    }

    // MARK: - Frame-scoped rules 5 and 6

    /// A `get_settings` answer has its values dropped and replaced by the setting *names*. The keys that
    /// produces all contain "key" and all carry lists of strings — exactly the shape the secret rule eats —
    /// so C1 exempts them by path, and so does this.
    func testGetSettingsBodyReducedToNamesWhichSurviveTheSecretRule() throws {
        let r = try responseBody(#"{"effective":{"model":"haiku","apiKeyHelper":"/bin/x"},"sources":[{"source":"user","settings":{"theme":"dark","token":"t"}}]}"#)
        XCTAssertNil(r["effective"]); XCTAssertNil(r["sources"])
        XCTAssertEqual(r["effective_keys"], .array([.string("apiKeyHelper"), .string("model")]))
        XCTAssertEqual(r["sources_keys"], .array([.object(["source": .string("user"), "keys": .array([.string("theme"), .string("token")])])]))
    }
    /// Rule 6 strips a URL query wholesale, and a callback URL is not always top-level.
    func testOAuthCallbackURLQueriesStripped() throws {
        let r = try responseBody(#"{"nested":{"url":"https://claude.ai/oauth/cb?code=abc&state=def"},"plain":"https://example.com/docs"}"#)
        XCTAssertEqual(r["nested"]?["url"], .string("https://claude.ai/oauth/cb?<redacted>"))
        XCTAssertEqual(r["plain"], .string("https://example.com/docs"))
    }

    /// Rule 6 on the **request** side. C1 runs it only over a control_response body, so an OAuth request's
    /// own payload was the one place it could not reach: `mcp_oauth_callback_url` carries the whole grant in
    /// `request.callbackUrl`, which is not a secret-named key, and a short `code`/`state` is far under the
    /// query-run pattern's 32-character floor. Both went to disk verbatim.
    ///
    /// Gated on the subtype, from C1's own `OAUTH_SUBTYPES`, and not on scanning every string — which the
    /// second half asserts: a `can_use_tool` request carrying a URL is untouched here, exactly as C1 has it.
    func testOAuthCallbackRequestHasItsQueryStripped() throws {
        let v = try redacted(#"{"type":"control_request","request_id":"o1","request":{"subtype":"mcp_oauth_callback_url","serverName":"github","callbackUrl":"http://localhost:51337/cb?code=abc123&state=xyz789"}}"#)
        XCTAssertEqual(v["request"]?["callbackUrl"], .string("http://localhost:51337/cb?<redacted>"))
        XCTAssertEqual(v["request"]?["serverName"], .string("github"))
        let redirect = try redacted(#"{"type":"control_request","request_id":"o2","request":{"subtype":"mcp_authenticate","serverName":"github","redirectUri":"http://localhost:51337/cb?state=xyz789"}}"#)
        XCTAssertEqual(redirect["request"]?["redirectUri"], .string("http://localhost:51337/cb?<redacted>"))
        let other = try redacted(#"{"type":"control_request","request_id":"o3","request":{"subtype":"can_use_tool","tool_name":"WebFetch","input":{"url":"https://example.com/x?q=1"}}}"#)
        XCTAssertEqual(other["request"]?["input"]?["url"], .string("https://example.com/x?q=1"))
    }

    /// Rule 6's other half, request-side and subtype-gated like the first. `claude_oauth_callback` returns
    /// the grant as two bare strings; `authorizationCode` is caught by the `authorization` secret word and
    /// `state` by nothing at all. A generic key name is exactly what a secret-word scanner cannot see, which
    /// is why the gate is the subtype and not the name.
    ///
    /// The values are deliberately short. A grant long enough to trip the 32-character query-run pattern
    /// would be redacted by that older rule whatever this one does, and the assertion would hold with the
    /// rule removed — which is no assertion at all.
    func testBareOAuthStateIsRedactedUnderTheOAuthSubtypesAndNowhereElse() throws {
        let v = try redacted(#"{"type":"control_request","request_id":"o4","request":{"subtype":"claude_oauth_callback","authorizationCode":"grant-1","state":"nonce-1"}}"#)
        XCTAssertEqual(v["request"]?["state"], .string("<redacted>"))
        XCTAssertEqual(v["request"]?["authorizationCode"], .string("<redacted>"))
        // Nested, and under every OAuth subtype rather than only the one that motivated the rule.
        let nested = try redacted(#"{"type":"control_request","request_id":"o5","request":{"subtype":"mcp_authenticate","serverName":"github","callback":{"state":"nonce-2"}}}"#)
        XCTAssertEqual(nested["request"]?["callback"]?["state"], .string("<redacted>"))
        // An ordinary `state` outside the gate keeps its value; so does one on a frame that is not a request.
        let ordinary = try redacted(#"{"type":"control_request","request_id":"o6","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"state":"expanded"}}}"#)
        XCTAssertEqual(ordinary["request"]?["input"]?["state"], .string("expanded"))
        let body = try responseBody(#"{"session_state":{"state":"idle"}}"#)
        XCTAssertEqual(body["session_state"]?["state"], .string("idle"))
    }

    // MARK: - Keys, idempotence, and the corpus

    /// A key is data too: project maps are keyed by absolute path and contact maps by address. Two keys can
    /// map onto one placeholder, and the second is disambiguated rather than silently overwriting the first.
    func testKeysAreRedactedAndCollisionsDisambiguated() throws {
        let r = try responseBody(#"{"contacts":{"a@b.co":1,"c@d.co":2,"plain":3}}"#)
        let contacts = try XCTUnwrap(r["contacts"]?.objectValue)
        XCTAssertEqual(contacts.count, 3)
        XCTAssertEqual(Set(contacts.keys), ["<email>", "<email>#2", "plain"])
        XCTAssertEqual(contacts["plain"], .integer(3))
    }
    /// Redaction is a fixed point: running it over its own output changes nothing. Every placeholder this
    /// type emits has to be inert to the rule that produced it, which is what PLACEHOLDER_KEY_RE and the
    /// "already a placeholder" checks exist for.
    func testRedactionIsIdempotentOverTheCorpusAndTheVectors() throws {
        for name in try TestPaths.sampleNames() { try assertIdempotent(try TestPaths.sample(name), name) }
        let vector = #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"account":{"e":1},"emailAddress":"a@b.co","apiKeySource":"ANTHROPIC_API_KEY","token":"t","contacts":{"a@b.co":1,"c@d.co":2},"listing":"-rw-r--r--@  1 alice  staff  1 Sep  5 10:00 f","effective":{"m":1}}}}"#
        try assertIdempotent(Data(vector.utf8), "vector")
    }
    private func assertIdempotent(_ raw: Data, _ label: String) throws {
        // Explicitly, not silently: a regression that made `redact` return nil broadly would otherwise
        // leave this test passing because there was nothing left to compare.
        guard let once = Redactor.redact(line: raw) else { return XCTFail("\(label) was dropped; nothing was compared") }
        let twice = try XCTUnwrap(Redactor.redact(line: once), label)
        XCTAssertEqual(String(decoding: twice, as: UTF8.self), String(decoding: once, as: UTF8.self), label)
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
