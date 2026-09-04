import XCTest
import WireFrames
import WireMCP
import WireDiagnostics

final class AfleetMCPServerTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: tmp.appendingPathComponent("b.txt"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }
    private func server() -> AfleetMCPServer { AfleetMCPServer(serverVersion: "0.1.0", cwd: tmp, tools: [SendUserFileTool()]) }
    private func req(_ id: Int64, _ method: String, _ params: JSONValue? = nil) -> JSONRPCMessage { .request(.init(id: .number(id), method: method, params: params)) }

    func testInitializeThenInitializedNotification() async throws {
        let s = server()
        let (r1, inv1) = await s.handle(req(1, "initialize", .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("claude-code")])])))
        guard case .response(.response(let resp)) = r1 else { return XCTFail("\(r1)") }
        XCTAssertEqual(resp.id, .number(1)); XCTAssertEqual(resp.result["serverInfo"]?["name"], .string("afleet"))
        XCTAssertEqual(resp.result["serverInfo"]?["version"], .string("0.1.0")); XCTAssertNotNil(resp.result["capabilities"]?["tools"]); XCTAssertNil(inv1)
        // A supported revision is agreed to as asked.
        XCTAssertEqual(resp.result["protocolVersion"], .string("2025-06-18"))
        // A revision outside our supported set is NOT echoed back. The engine's own list now leads
        // with 2025-11-25 (bundle 2.1.258:143537) and it sends its newest (679251), so echoing would
        // have afleet claim a surface it does not implement. We answer with what we do speak, which
        // is still inside the engine's list, so its `!r.includes(...)` check (679254) passes.
        let (newer, _) = await s.handle(req(11, "initialize", .object(["protocolVersion": .string("2025-11-25")])))
        guard case .response(.response(let negotiated)) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(negotiated.result["protocolVersion"], .string("2025-06-18"))
        // A supported revision that is NOT the preferred one. This is the only case that proves the
        // supported set is consulted at all: both assertions above expect preferredProtocolVersion,
        // so a body of `return .string(Self.preferredProtocolVersion)` would satisfy them both.
        let (older, _) = await s.handle(req(12, "initialize", .object(["protocolVersion": .string("2025-03-26")])))
        guard case .response(.response(let olderResp)) = older else { return XCTFail("\(older)") }
        XCTAssertEqual(olderResp.result["protocolVersion"], .string("2025-03-26"))
        let (r2, _) = await s.handle(.notification(.init(method: "notifications/initialized")))
        guard case .notificationAck = r2 else { return XCTFail("\(r2)") }
    }
    func testPingListCallUnknownAndCancel() async throws {
        let s = server()
        guard case .response(.response(let ping)) = (await s.handle(req(2, "ping"))).0 else { return XCTFail() }
        XCTAssertEqual(ping.result, .object([:]))
        guard case .response(.response(let list)) = (await s.handle(req(3, "tools/list"))).0 else { return XCTFail() }
        let tools = list.result["tools"]?.arrayValue
        XCTAssertEqual(tools?.count, 1); XCTAssertEqual(tools?[0]["name"], .string("send_user_file"))
        XCTAssertEqual(tools?[0]["inputSchema"]?["required"], .array([.string("files"), .string("status")]))
        let (call, inv) = await s.handle(req(4, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt"), .string("b.txt")]), "caption": .string("two"), "status": .string("normal"), "display": .string("render")])])))
        guard case .response(.response(let callResp)) = call else { return XCTFail() }
        XCTAssertEqual(callResp.result["isError"], .bool(false))
        XCTAssertEqual(callResp.result["content"]?[0]?["text"], .string("Sent 2 files to the user: a.txt, b.txt"))
        guard case .sentFile(let paths, let caption, let status, let display) = inv else { return XCTFail("\(String(describing: inv))") }
        XCTAssertEqual(paths.map(\.lastPathComponent), ["a.txt", "b.txt"]); XCTAssertEqual(caption, "two"); XCTAssertEqual(status, "normal"); XCTAssertEqual(display, "render")
        guard case .response(.error(let unknown)) = (await s.handle(req(5, "resources/list"))).0 else { return XCTFail() }
        XCTAssertEqual(unknown.error.code, -32601)
        guard case .notificationAck = (await s.handle(.notification(.init(method: "notifications/cancelled", params: .object(["requestId": .integer(4)]))))).0 else { return XCTFail() }
    }
    func testMissingFileAndBadArgumentsAreToolErrorsNotProtocolErrors() async throws {
        let s = server()
        let (r, inv) = await s.handle(req(6, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("nope.txt")]), "status": .string("normal")])])))
        guard case .response(.response(let resp)) = r else { return XCTFail() }
        XCTAssertEqual(resp.result["isError"], .bool(true)); XCTAssertNil(inv)
        XCTAssertTrue(resp.result["content"]?[0]?["text"]?.stringValue?.contains("nope.txt") ?? false)
        // A bare-string `files` is coerced to a one-element array, matching the built-in's Zod
        // preprocess (bundle 2.1.258:485919) rather than rejecting an unambiguous input. This amends
        // the plan's assertion; see "Fix round 1" in the task-6 report for the reasoning.
        let (r2, inv2) = await s.handle(req(7, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .string("a.txt"), "status": .string("normal")])])))
        guard case .response(.response(let coerced)) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(coerced.result["isError"], .bool(false))
        XCTAssertEqual(coerced.result["content"]?[0]?["text"], .string("Sent 1 file to the user: a.txt"))
        guard case .sentFile(let coercedPaths, _, _, _) = inv2 else { return XCTFail("\(String(describing: inv2))") }
        XCTAssertEqual(coercedPaths.map(\.lastPathComponent), ["a.txt"])
        // The assertion the bare-string case was standing in for: a `files` that is neither a string
        // nor a non-empty array of strings stays a protocol error.
        for bad: JSONValue in [.integer(5), .array([]), .array([.integer(1), .integer(2)]), .null] {
            let (badReply, _) = await s.handle(req(70, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": bad, "status": .string("normal")])])))
            guard case .response(.error(let badErr)) = badReply else { return XCTFail("files: \(bad) should be a protocol error, got \(badReply)") }
            XCTAssertEqual(badErr.error.code, -32602, "files: \(bad)")
        }
        // A bad `status` and a bad `display` are protocol errors too.
        let (badStatus, _) = await s.handle(req(71, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt")]), "status": .string("urgent")])])))
        guard case .response(.error(let statusErr)) = badStatus else { return XCTFail("\(badStatus)") }
        XCTAssertEqual(statusErr.error.code, -32602)
        let (badDisplay, _) = await s.handle(req(72, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt")]), "status": .string("normal"), "display": .string("popup")])])))
        guard case .response(.error(let displayErr)) = badDisplay else { return XCTFail("\(badDisplay)") }
        XCTAssertEqual(displayErr.error.code, -32602)
        // A directory is readable but not sendable: a runtime failure, not a protocol error, and it
        // must not carry a host invocation.
        let (dir, dirInv) = await s.handle(req(73, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string(".")]), "status": .string("normal")])])))
        guard case .response(.response(let dirResp)) = dir else { return XCTFail("\(dir)") }
        XCTAssertEqual(dirResp.result["isError"], .bool(true)); XCTAssertNil(dirInv)
        let (r3, _) = await s.handle(req(8, "tools/call", .object(["name": .string("no_such_tool"), "arguments": .object([:])])))
        guard case .response(.error(let e3)) = r3 else { return XCTFail() }
        XCTAssertEqual(e3.error.code, -32602)
    }
    func testAbsolutePathsAnywhereReadableAreAllowed() async throws {
        // The built-in SendUserFile accepts any file the model can read; afleet mirrors that domain (child spec, WireMCP).
        let s = server()
        let (r, inv) = await s.handle(req(9, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("/etc/hosts")]), "status": .string("proactive")])])))
        guard case .response(.response(let resp)) = r else { return XCTFail() }
        XCTAssertEqual(resp.result["isError"], .bool(false))
        guard case .sentFile(let paths, _, let status, _) = inv else { return XCTFail() }
        XCTAssertEqual(paths.first?.path, "/etc/hosts"); XCTAssertEqual(status, "proactive")
    }
    /// `SendUserFileTool.resolve` is the tool's path policy with the I/O taken out, so all three
    /// rules are decidable without a file existing anywhere. This is what lets the tilde rule be
    /// asserted at all: welded to the readability check, expansion and non-expansion both end at a
    /// missing file and the assertion cannot discriminate them.
    func testPathResolutionPolicy() throws {
        let cwd = URL(fileURLWithPath: "/private/tmp/afleet-cwd")

        // A leading `~` expands to the home directory, and does so BEFORE the absolute test, so it
        // never lands under the cwd.
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let tilde = SendUserFileTool.resolve("~/report.pdf", against: cwd)
        XCTAssertEqual(tilde, home.appendingPathComponent("report.pdf").standardizedFileURL)
        XCTAssertFalse(tilde.path.hasPrefix(cwd.path), "~ must not resolve under the cwd")

        // An absolute path is taken as given, whatever the cwd is.
        XCTAssertEqual(SendUserFileTool.resolve("/etc/hosts", against: cwd).path, "/etc/hosts")
        XCTAssertEqual(SendUserFileTool.resolve("/etc/hosts", against: URL(fileURLWithPath: "/var")).path, "/etc/hosts")

        // A relative path resolves against the cwd.
        XCTAssertEqual(SendUserFileTool.resolve("a.txt", against: cwd).path, "/private/tmp/afleet-cwd/a.txt")
        XCTAssertEqual(SendUserFileTool.resolve("sub/a.txt", against: cwd).path, "/private/tmp/afleet-cwd/sub/a.txt")

        // A `..` walks out of the cwd. Pinned as intentional: this tool accepts any absolute path
        // the model can read, so confining the relative form would be an inconsistency rather than
        // a boundary. If this assertion ever fails, that is a deliberate policy change, not a bug fix.
        // The escape itself is what this pins. The exact resulting string is deliberately not
        // asserted: the walk lands on /private/etc/hosts and standardizedFileURL then rewrites it to
        // /etc/hosts, which is Darwin resolving its /private symlink rather than anything this
        // policy decides.
        let escaped = SendUserFileTool.resolve("../../etc/hosts", against: cwd)
        XCTAssertFalse(escaped.path.hasPrefix(cwd.path))
        XCTAssertTrue(escaped.path.hasSuffix("etc/hosts"), escaped.path)
    }
    /// The server, not the tool, drops a host invocation from a failure result. `SendUserFileTool`
    /// cannot exercise this: its failures go out through `.text(isError: true)`, whose invocation is
    /// already nil, so an assertion against it holds with the guard present, absent or inverted.
    /// Only a tool that sets both can tell the difference — which is exactly the future tool the
    /// guard exists for.
    func testAFailureResultNeverCarriesAHostInvocation() async throws {
        struct LyingTool: MCPTool {
            var name: String { "lies" }; var description: String { "fails while claiming it sent a file" }
            var inputSchema: JSONValue { .object(["type": .string("object")]) }
            func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
                MCPToolResult(content: [.object(["type": .string("text"), "text": .string("upload failed")])],
                              isError: true,
                              hostInvocation: .sentFile(paths: [URL(fileURLWithPath: "/tmp/never-sent.pdf")],
                                                        caption: nil, status: "normal", display: nil))
            }
        }
        let s = AfleetMCPServer(serverVersion: "0.1.0", cwd: tmp, tools: [LyingTool()])
        let (reply, invocation) = await s.handle(req(13, "tools/call", .object(["name": .string("lies"), "arguments": .object([:])])))
        guard case .response(.response(let resp)) = reply else { return XCTFail("\(reply)") }
        // The failure still reaches the model as a successful response carrying isError...
        XCTAssertEqual(resp.result["isError"], .bool(true))
        XCTAssertEqual(resp.result["content"]?[0]?["text"], .string("upload failed"))
        // ...but the host is never told a file was sent, because it was not.
        XCTAssertNil(invocation)
    }
    func testCancelledNotificationCancelsAnInFlightCall() async throws {
        struct SleepingTool: MCPTool {
            var name: String { "sleep" }; var description: String { "sleeps until cancelled" }
            var inputSchema: JSONValue { .object(["type": .string("object")]) }
            func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
                try await Task.sleep(for: .seconds(30)); return .text("woke")
            }
        }
        let s = AfleetMCPServer(serverVersion: "0.1.0", cwd: tmp, tools: [SleepingTool()])
        // The message is built outside the Task: `req` is a method on this XCTestCase, and under language
        // mode 6 capturing the non-Sendable `self` in a `sending` closure is a data-race error.
        let sleepCall = req(10, "tools/call", .object(["name": .string("sleep"), "arguments": .object([:])]))
        let call = Task { await s.handle(sleepCall) }
        try await Task.sleep(for: .milliseconds(100))
        _ = await s.handle(.notification(.init(method: "notifications/cancelled", params: .object(["requestId": .integer(10)]))))
        let (r, _) = await call.value
        guard case .response(.error(let e)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.error.code, -32800)
    }
}

/// An unexpected throw is summarised for the model — a Foundation error's description carries the path it
/// failed on — but the text used to be lost entirely, because this actor had nowhere to write it. It goes to
/// the diagnostics sink now: the local metadata log is where an operator can diagnose the failure.
final class MCPToolFailureDiagnosticsTests: XCTestCase {
    private final class Sink: DiagnosticsSink, @unchecked Sendable {
        private let lock = NSLock(); private var stored: [DiagnosticEvent] = []
        func record(_ event: DiagnosticEvent) { lock.lock(); stored.append(event); lock.unlock() }
        var events: [DiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private struct ExplodingTool: MCPTool {
        struct Boom: Error { let secretPath = "/Users/someone/private/ledger.csv" }
        var name: String { "explode" }
        var description: String { "throws" }
        var inputSchema: JSONValue { .object([:]) }
        func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult { throw Boom() }
    }
    func testUnexpectedToolErrorTextReachesDiagnosticsAndNotTheModel() async throws {
        let sink = Sink()
        let server = AfleetMCPServer(serverVersion: "0.1.0", cwd: URL(fileURLWithPath: "/tmp"), tools: [ExplodingTool()], diagnostics: sink)
        let (reply, invocation) = await server.handle(.request(.init(id: .number(1), method: "tools/call", params: .object(["name": .string("explode"), "arguments": .object([:])]))))
        XCTAssertNil(invocation)
        guard case .response(.response(let r)) = reply else { return XCTFail("expected a response, got \(reply)") }
        XCTAssertEqual(r.result["isError"], .bool(true))
        let modelText = r.result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertEqual(modelText, "Tool explode failed unexpectedly (Boom)")
        XCTAssertFalse(modelText.contains("ledger.csv"), "the model must not see the error's own description")
        let recorded = sink.events.compactMap { e -> (String, String)? in if case .mcpToolFailure(let t, let m) = e { return (t, m) }; return nil }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, "explode")
        XCTAssertTrue(recorded.first?.1.contains("ledger.csv") == true, "the full error text must survive in diagnostics: \(recorded)")
    }
}
