import XCTest
import WireFrames
import WireDiagnostics
import WireTestSupport

/// Parity between this redactor and C1's `Tools/probe/redact.py`, which parent §11 (spec commit `ed87a22`)
/// makes canonical. Both feed the same human review, so a byte one lets through is invisible to the other's
/// tests; this is the test that notices when they drift.
///
/// Skipped, not failed, when the sibling worktree or `python3` is absent — C2's suite has to pass standalone,
/// and `afleet-c1` will move or merge. Same pattern the plan uses for the typings drift test.
///
/// C1's rule 3 (home directory and hostname substitution) is switched off for the comparison rather than
/// mirrored: `home="/"` is skipped by its own guard and a two-character hostname fails its length guard.
/// That rule needs the recording machine's identity, which this redactor is not given; see `Redactor`'s
/// doc comment for why a capture does not carry it.
final class RedactorDifferentialTests: XCTestCase {
    /// `/Users/.../afleet-c1/Tools/probe/redact.py`, a sibling of this package's repository.
    private var referenceRedactor: URL? {
        let url = TestPaths.support                       // <repo>/ClaudeWire/Tests/Support
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                  // the directory holding the worktrees
            .appendingPathComponent("afleet-c1/Tools/probe/redact.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private static let python = "/usr/bin/python3"

    /// Vectors chosen one per rule, on top of the whole sample corpus.
    private static let vectors: [String] = [
        // identity: key set, normalisation, the email substring, whole values of every type, placeholders
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"accountUuid":"9f2","account_id":"7","organizationUuid":"o","organization_name":"Acme","userName":"m","user_id":"u","subscription_type":"max","fullName":"A E","emailAddress":"a@b.co","user":{"id":1},"organizationId":42,"account":null,"displayName":"Haiku","user_message_uuid":"x","hooks":{"UserPromptSubmit":["c"]},"pid":1}}}"#,
        // identity: the counter path, and the same leaf name off it
        #"{"type":"result","subagent_stats":{"killed":{"user":3,"parent":1,"system":0}},"killed":{"user":9},"userName":"m"}"#,
        // secrets: containers of every type, null, bearer, and the token-counter test
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"authorization":{"value":"Bearer x"},"cookies":[{"value":"c"}],"api_keys":{"primary":"p"},"bearer":"b","seven_day_oauth_apps":null,"usage":{"output_tokens_details":{"reasoning":3},"cacheReadInputTokens":9,"estimated_tokens_delta":1,"maxOutputTokens":4096,"progressToken":7,"input_tokens":1},"max_tokens":"8","rawmaxtokens":"1"}}}"#,
        // secrets: the structural exemptions and apiKeySource's own rule
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"projectKey":"-Users-x","hookCallbackIds":["h"],"apiKeySource":"none","oauth_token":"t"}}}"#,
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"apiKeySource":"ANTHROPIC_API_KEY"}}}"#,
        // secrets: the enum path, and a path that merely contains it
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"rate_limits":{"day":{"behaviors":[{"key":"cache_miss","used":1},{"key":"cron","used":2}]}},"behaviors":{"keyring":"sk-x"},"api_key":"sk-x"}}}"#,
        // content patterns: sk-ant, JWT, a long query run, the ls -l owner column, email in prose
        #"{"type":"result","note":"sk-ant-api03-XYZ and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk and https://x/cb?state=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&ok=1 and a@b.co","listing":"-rw-r--r--@  1 alice  staff  1024 Sep  5 10:00 notes.txt"}"#,
        // keys are data, and two of them collide onto one placeholder
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"contacts":{"a@b.co":1,"c@d.co":2,"plain":3}}}}"#,
        // rule 5: a get_settings answer reduced to setting names
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"effective":{"model":"haiku","apiKeyHelper":"/bin/x"},"sources":[{"source":"user","settings":{"theme":"dark","token":"t"}}]}}}"#,
        // rule 6: a callback URL, nested
        #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"nested":{"url":"https://claude.ai/oauth/cb?code=abc&state=def"},"plain":"https://example.com/docs"}}}"#,
        // the whole-frame drop
        #"{"type":"control_request","request_id":"e","request":{"subtype":"update_environment_variables","variables":{"A":"1"}}}"#,
        // rule 4: an over-limit MCP body, and one under the limit that must be left alone
        #"{"type":"control_request","request_id":"m","request":{"subtype":"mcp_message","server_name":"afleet","message":{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"blob":"\#(String(repeating: "x", count: 5000))"}}}}"#,
        #"{"type":"control_request","request_id":"m","request":{"subtype":"mcp_message","server_name":"afleet","message":{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"token":"t"}}}}"#,
        // arrays, nesting and a frame type neither side models
        #"{"type":"tool_progress","items":[{"user":"u"},[{"apiKey":"k"}],null,3],"nested":{"deep":{"deeper":{"token":"t"}}}}"#,
    ]

    func testMatchesC1sRedactorOverTheCorpusAndTheVectors() throws {
        guard let reference = referenceRedactor else {
            throw XCTSkip("afleet-c1/Tools/probe/redact.py is not present; parity is unverified in this checkout")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { throw XCTSkip("no python3 at \(Self.python)") }

        var inputs = Self.vectors
        for name in try TestPaths.sampleNames() { inputs.append(String(decoding: try TestPaths.sample(name), as: UTF8.self)) }
        let labels = Self.vectors.indices.map { "vector[\($0)]" } + (try TestPaths.sampleNames())

        let theirs = try runReference(reference, over: inputs)
        XCTAssertEqual(theirs.count, inputs.count)
        for (i, input) in inputs.enumerated() {
            let mine = Redactor.redact(line: Data(input.utf8))
            if theirs[i].isEmpty {
                XCTAssertNil(mine, "\(labels[i]): C1 drops this frame and we do not")
                continue
            }
            let mineValue = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(mine, labels[i]))
            let theirsValue = try JSONDecoder().decode(JSONValue.self, from: Data(theirs[i].utf8))
            // Canonicalised on both sides so a difference in how Python and Swift render a float cannot
            // masquerade as a difference in what was redacted.
            XCTAssertEqual(String(decoding: try normalised(mineValue).canonicalData(), as: UTF8.self),
                           String(decoding: try normalised(theirsValue).canonicalData(), as: UTF8.self),
                           labels[i])
        }
    }

    /// The one documented divergence: both redactors record the size of an over-limit MCP body, but C1
    /// measures it with `json.dumps` defaults (a space after every comma and colon) where this one measures
    /// canonical bytes. The counts therefore differ by the separator count. It is a diagnostic integer about
    /// a body both sides discarded, so it is normalised here rather than reimplemented — visibly, so that
    /// nothing else can drift behind it.
    private func normalised(_ v: JSONValue) throws -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, child) in o {
                if k == "truncated", let n = child.intValue {
                    XCTAssertGreaterThan(n, Int64(Redactor.mcpBodyLimit))
                    out[k] = .string("<over-limit>")
                } else {
                    out[k] = try normalised(child)
                }
            }
            return .object(out)
        case .array(let a): return .array(try a.map(normalised))
        default: return v
        }
    }

    /// One NDJSON line in, one line out; an empty line means C1 dropped the frame.
    private func runReference(_ redactPy: URL, over inputs: [String]) throws -> [String] {
        let driver = """
        import json, sys, os
        sys.path.insert(0, os.path.dirname(sys.argv[1]))
        import redact
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            frame = json.loads(line)
            out = redact.Redactor(home="/", hostname="zz").redact_frame(frame, "in", {})
            sys.stdout.write("" if out is None else json.dumps(out, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            sys.stdout.write("\\n")
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = ["-c", driver, redactPy.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Data(inputs.joined(separator: "\n").utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err, as: UTF8.self))
        var lines = String(decoding: out, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
