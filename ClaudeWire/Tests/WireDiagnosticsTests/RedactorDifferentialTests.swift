import XCTest
import WireFrames
import WireDiagnostics
import WireTestSupport

/// Parity between this redactor and `Tools/probe/redact.py`, which parent §11 (spec commit `ed87a22`)
/// makes canonical. Both feed the same human review, so a byte one lets through is invisible to the other's
/// tests; this is the test that notices when they drift.
///
/// Skipped, not failed, when the reference or `python3` is absent, so the package stands alone.
///
/// C1's rule 3 (home directory and hostname substitution) is switched off for the comparison rather than
/// mirrored: `home="/"` is skipped by its own guard and a two-character hostname fails its length guard.
/// That rule needs the recording machine's identity, which this redactor is not given; see `Redactor`'s
/// doc comment for why a capture does not carry it.
final class RedactorDifferentialTests: XCTestCase {
    /// `Tools/probe/redact.py`, in this repository since C1 merged.
    private var referenceRedactor: URL? {
        let url = TestPaths.support                       // <repo>/ClaudeWire/Tests/Support
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/probe/redact.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private static let python = "/usr/bin/python3"

    /// An MCP message sized to sit inside the band where the two size measurements disagree: under the
    /// 4 KB limit as canonical bytes, over it once `json.dumps` puts a space after every comma and colon.
    /// Written already canonical — keys sorted, no whitespace — so its own byte count is its canonical one.
    private static func mcpMessage(canonicalBytes target: Int) -> String {
        let fixed = #"{"id":1,"jsonrpc":"2.0","method":"tools/call""#
        func assemble(_ last: String) -> String {
            let fillers = (0..<29).map { #""p\#(String(format: "%02d", $0))":"v""# } + [last]
            return fixed + "," + fillers.joined(separator: ",") + "}"
        }
        let pad = target - assemble(#""p29":"v""#).utf8.count
        precondition(pad >= 0, "target too small for the fixed part")
        return assemble(#""p29":"v\#(String(repeating: "x", count: pad))""#)
    }
    private static func mcpFrame(_ message: String) -> String {
        #"{"type":"control_request","request_id":"m","request":{"subtype":"mcp_message","server_name":"afleet","message":\#(message)}}"#
    }

    /// Vectors chosen one per rule, on top of the whole sample corpus.
    private static let vectors: [String] = [
        // identity: key set, normalisation, the email substring, whole values of every type, placeholders
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"accountUuid":"9f2","account_id":"7","organizationUuid":"o","organization_name":"Acme","userName":"m","user_id":"u","subscription_type":"max","fullName":"Alice Example","emailAddress":"a@b.co","user":{"id":1},"organizationId":42,"account":null,"displayName":"Haiku","user_message_uuid":"x","hooks":{"UserPromptSubmit":["c"]},"pid":1}}}"#,
        // identity: the counter path, and the same leaf name off it
        #"{"type":"result","subagent_stats":{"killed":{"user":3,"parent":1,"system":0}},"killed":{"user":9},"userName":"m"}"#,
        // secrets: containers of every type, null, bearer, and the token-counter test
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"authorization":{"value":"Bearer x"},"cookies":[{"value":"c"}],"api_keys":{"primary":"p"},"bearer":"b","seven_day_oauth_apps":null,"usage":{"output_tokens_details":{"reasoning":3},"cacheReadInputTokens":9,"estimated_tokens_delta":1,"maxOutputTokens":4096,"progressToken":7,"input_tokens":1},"max_tokens":"8","rawmaxtokens":"1"}}}"#,
        // secrets: the structural exemptions and apiKeySource's own rule
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"projectKey":"-Users-x","hookCallbackIds":["h"],"apiKeySource":"none","oauth_token":"t"}}}"#,
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"apiKeySource":"ANTHROPIC_API_KEY"}}}"#,
        // secrets: the enum path, a path that merely contains it, and keys carrying brackets of their own
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"rate_limits":{"day":{"behaviors":[{"key":"cache_miss","used":1},{"key":"cron","used":2}]}},"behaviors":{"keyring":"sk-x"},"api_key":"sk-x","beh[aviors":{"key":"k"},"behaviors[x]":{"key":"k"}}}}"#,
        // content patterns: sk-ant, JWT, a long query run, the ls -l owner column, email in prose
        #"{"type":"result","note":"sk-ant-api03-XYZ and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk and https://x/cb?state=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&ok=1 and a@b.co","listing":"-rw-r--r--@  1 alice  staff  1024 Sep  5 10:00 notes.txt"}"#,
        // keys are data, and two of them collide onto one placeholder
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"contacts":{"a@b.co":1,"c@d.co":2,"plain":3}}}}"#,
        // rule 5: a get_settings answer reduced to setting names
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"effective":{"model":"haiku","apiKeyHelper":"/bin/x"},"sources":[{"source":"user","settings":{"theme":"dark","token":"t"}}]}}}"#,
        // rule 6: a callback URL nested, one with an embedded newline that the reference's non-DOTALL
        // pattern leaves alone, one with a trailing newline that its `$` still matches, one with no query
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"nested":{"url":"https://claude.ai/oauth/cb?code=abc&state=def"},"embedded":"http://x/cb?code=abc\nmore text","trailing":"http://x/cb?code=abc\n","plain":"https://example.com/docs"}}}"#,
        // the whole-frame drop
        #"{"type":"control_request","request_id":"e","request":{"subtype":"update_environment_variables","variables":{"A":"1"}}}"#,
        // rule 4: comfortably over the limit, comfortably under it, and both edges of the band where the
        // canonical size and the `json.dumps` size disagree about which side of the limit a body is on
        mcpFrame(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"blob":"\#(String(repeating: "x", count: 5000))"}}"#),
        mcpFrame(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"token":"t"}}"#),
        mcpFrame(mcpMessage(canonicalBytes: 4090)),
        mcpFrame(mcpMessage(canonicalBytes: 4000)),
        // arrays, nesting, non-ASCII including an astral scalar, and a frame type neither side models
        #"{"type":"tool_progress","items":[{"user":"u"},[{"apiKey":"k"}],null,3],"nested":{"deep":{"deeper":{"token":"t"}}},"text":"ünïcødé and 𝄞 and \u0007"}"#,
        // Rule 6 on the **request** side, both halves. The grant values are short on purpose: the
        // pre-existing query-run pattern strips any run of 32 characters or more, so a long value would be
        // redacted whatever the subtype gate does and the vector would agree across a change to it.
        #"{"type":"control_request","request_id":"r4","request":{"subtype":"mcp_oauth_callback_url","server_name":"afleet","callbackUrl":"http://localhost:1455/callback?code=grant-1&state=nonce-1"}}"#,
        #"{"type":"control_request","request_id":"r5","request":{"subtype":"mcp_authenticate","server_name":"afleet","nested":{"redirectUri":"https://claude.ai/oauth/cb?code=grant-2&state=nonce-2"}}}"#,
        #"{"type":"control_request","request_id":"r6","request":{"subtype":"claude_oauth_callback","authorizationCode":"grant-3","state":"nonce-3"}}"#,
        // ...and the subtype gate's other side: an ordinary request carrying both shapes, untouched.
        #"{"type":"control_request","request_id":"r7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"state":"expanded","url":"https://docs.test/page?section=intro"}}}"#,
    ] + correlationVectors

    /// Correlation, which is the whole reason these are ordered. Each pair is a `control_request` naming a
    /// subtype followed by the `control_response` that answers it, over one body carrying all four shapes
    /// rules 4, 5 and 6 look for. Gating changes the outcome of every pair, and differently in each: one
    /// truncates only the MCP body, one reduces only the settings, one strips only the URL, and one — a
    /// subtype none of the rules belong to — leaves all four alone. A redactor without correlation applies
    /// all three to all four and cannot pass this.
    ///
    /// One body, reused, so the only variable is the subtype it is correlated to.
    private static let gatedBody = #"{"mcp_response":{"jsonrpc":"2.0","id":9,"result":{"blob":"\#(String(repeating: "x", count: 5000))"}},"effective":{"model":"haiku","apiKeyHelper":"/bin/x"},"sources":[{"source":"user","settings":{"theme":"dark"}}],"link":"https://claude.ai/oauth/cb?code=grant-4&state=nonce-4"}"#
    private static func gatedPair(_ id: String, _ subtype: String) -> [String] {
        [#"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"\#(subtype)"}}"#,
         #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":\#(gatedBody)}}"#]
    }
    private static let correlationVectors: [String] =
        gatedPair("g1", "get_usage") + gatedPair("g2", "get_settings")
        + gatedPair("g3", "mcp_message") + gatedPair("g4", "claude_authenticate")
        // The unknown case, last: a response whose request this stream never saw. Both sides apply all three
        // rules to it rather than none, which is the fail-closed direction for anything reaching disk.
        + [#"{"type":"control_response","response":{"subtype":"success","request_id":"never-seen","response":\#(gatedBody)}}"#]

    private func allInputs() throws -> (inputs: [String], labels: [String]) {
        let names = try TestPaths.sampleNames()
        var inputs = Self.vectors
        for name in names { inputs.append(String(decoding: try TestPaths.sample(name), as: UTF8.self)) }
        return (inputs, Self.vectors.indices.map { "vector[\($0)]" } + names)
    }

    /// The boundary vector is only worth anything if it really sits in the band, so that is asserted rather
    /// than assumed: under the limit measured as canonical bytes, over it measured as `json.dumps`.
    func testBoundaryVectorSitsInsideTheDisagreementBand() throws {
        let msg = try JSONDecoder().decode(JSONValue.self, from: Data(Self.mcpMessage(canonicalBytes: 4090).utf8))
        XCTAssertLessThanOrEqual(try msg.canonicalData().count, Redactor.mcpBodyLimit)
        XCTAssertGreaterThan(Redactor.pythonDumpsLength(msg), Redactor.mcpBodyLimit)
        let under = try JSONDecoder().decode(JSONValue.self, from: Data(Self.mcpMessage(canonicalBytes: 4000).utf8))
        XCTAssertLessThanOrEqual(Redactor.pythonDumpsLength(under), Redactor.mcpBodyLimit)
    }

    func testMatchesTheReferenceRedactorOverTheCorpusAndTheVectors() throws {
        let reference = try requireReference()
        let (inputs, labels) = try allInputs()
        // The reference's correlation map, accumulated line by line exactly as `harness.py` does while it
        // records. Passing `{}` here — as this test used to — put every response in the unknown case on the
        // reference side as well, so the two agreed no matter what either did about gating: the test that
        // exists to catch drift in these three rules could not observe it.
        let driver = """
        import json, sys, os
        sys.path.insert(0, os.path.dirname(sys.argv[1]))
        import redact
        rs = {}
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            frame = json.loads(line)
            if frame.get("type") == "control_request":
                rid, sub = frame.get("request_id"), (frame.get("request") or {}).get("subtype")
                if rid and sub:
                    rs[rid] = sub
            out = redact.Redactor(home="/", hostname="zz").redact_frame(frame, "in", rs)
            sys.stdout.write("" if out is None else json.dumps(out, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            sys.stdout.write("\\n")
        """
        let theirs = try runPython(driver, reference, inputs)
        guard theirs.count == inputs.count else {
            return XCTFail("reference produced \(theirs.count) lines for \(inputs.count) inputs")
        }
        var correlation = Redactor.Correlation()
        for (i, input) in inputs.enumerated() {
            let mine = Redactor.redact(line: Data(input.utf8), correlation: &correlation)
            if theirs[i].isEmpty {
                XCTAssertNil(mine, "\(labels[i]): the reference drops this frame and we do not")
                continue
            }
            let mineValue = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(mine, labels[i]))
            let theirsValue = try JSONDecoder().decode(JSONValue.self, from: Data(theirs[i].utf8))
            // Canonicalised on both sides so a difference in how Python and Swift render a float cannot
            // masquerade as a difference in what was redacted.
            XCTAssertEqual(String(decoding: try mineValue.canonicalData(), as: UTF8.self),
                           String(decoding: try theirsValue.canonicalData(), as: UTF8.self),
                           labels[i])
        }
    }

    /// `Redactor.pythonDumpsLength` decides where an MCP body is truncated, so it is checked against the
    /// real `json.dumps` rather than against the reasoning in its own doc comment.
    func testPythonDumpsLengthMatchesTheRealEncoder() throws {
        let reference = try requireReference()
        let (inputs, labels) = try allInputs()
        let driver = """
        import json, sys
        for line in sys.stdin:
            line = line.strip()
            if line:
                sys.stdout.write(str(len(json.dumps(json.loads(line)))) + "\\n")
        """
        let theirs = try runPython(driver, reference, inputs)
        guard theirs.count == inputs.count else {
            return XCTFail("reference produced \(theirs.count) lines for \(inputs.count) inputs")
        }
        for (i, input) in inputs.enumerated() {
            let v = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
            XCTAssertEqual(String(Redactor.pythonDumpsLength(v)), theirs[i], labels[i])
        }
    }

    // MARK: - Harness

    private func requireReference() throws -> URL {
        guard let reference = referenceRedactor else {
            throw XCTSkip("Tools/probe/redact.py is not present; parity is unverified in this checkout")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { throw XCTSkip("no python3 at \(Self.python)") }
        return reference
    }

    /// One NDJSON line in, one line out. Stdin is written from a background queue: a foreground write of an
    /// input larger than the pipe buffer would block while the child blocks writing its own output, and the
    /// test would hang rather than fail.
    private func runPython(_ driver: String, _ redactPy: URL, _ inputs: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = ["-c", driver, redactPy.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        let payload = Data(inputs.joined(separator: "\n").utf8)
        DispatchQueue.global().async {
            stdin.fileHandleForWriting.write(payload)
            try? stdin.fileHandleForWriting.close()
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err, as: UTF8.self))
        var lines = String(decoding: out, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
