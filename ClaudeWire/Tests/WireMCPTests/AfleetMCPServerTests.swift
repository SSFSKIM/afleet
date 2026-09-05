import XCTest
import WireFrames
import WireMCP

/// A tool the cancellation cannot reach: it sleeps on a dispatch queue rather than with `Task.sleep`, which
/// would throw on cancellation and make the test pass without the fix it exists for.
private struct DeafTool: MCPTool {
    var name: String { "deaf" }
    var description: String { "ignores cancellation, then claims a delivery" }
    var inputSchema: JSONValue { .object(["type": .string("object"), "properties": .object([:])]) }
    func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { c.resume() }
        }
        return .text("done", invocation: .sentFile(paths: [context.cwd.appendingPathComponent("a.txt")],
                                                   caption: nil, status: "normal", display: nil))
    }
}

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
        let (r1, inv1, _) = await s.handle(req(1, "initialize", .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("claude-code")])])))
        guard case .response(.response(let resp)) = r1 else { return XCTFail("\(r1)") }
        XCTAssertEqual(resp.id, .number(1)); XCTAssertEqual(resp.result["serverInfo"]?["name"], .string("afleet"))
        XCTAssertEqual(resp.result["serverInfo"]?["version"], .string("0.1.0")); XCTAssertNotNil(resp.result["capabilities"]?["tools"]); XCTAssertNil(inv1)
        // A supported revision is agreed to as asked.
        XCTAssertEqual(resp.result["protocolVersion"], .string("2025-06-18"))
        // A revision outside our supported set is NOT echoed back. The engine's own list now leads
        // with 2025-11-25 (bundle 2.1.258:143537) and it sends its newest (679251), so echoing would
        // have afleet claim a surface it does not implement. We answer with what we do speak, which
        // is still inside the engine's list, so its `!r.includes(...)` check (679254) passes.
        let (newer, _, _) = await s.handle(req(11, "initialize", .object(["protocolVersion": .string("2025-11-25")])))
        guard case .response(.response(let negotiated)) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(negotiated.result["protocolVersion"], .string("2025-06-18"))
        // A supported revision that is NOT the preferred one. This is the only case that proves the
        // supported set is consulted at all: both assertions above expect preferredProtocolVersion,
        // so a body of `return .string(Self.preferredProtocolVersion)` would satisfy them both.
        let (older, _, _) = await s.handle(req(12, "initialize", .object(["protocolVersion": .string("2025-03-26")])))
        guard case .response(.response(let olderResp)) = older else { return XCTFail("\(older)") }
        XCTAssertEqual(olderResp.result["protocolVersion"], .string("2025-03-26"))
        let (r2, _, _) = await s.handle(.notification(.init(method: "notifications/initialized")))
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
        let (call, inv, _) = await s.handle(req(4, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt"), .string("b.txt")]), "caption": .string("two"), "status": .string("normal"), "display": .string("render")])])))
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
        let (r, inv, _) = await s.handle(req(6, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("nope.txt")]), "status": .string("normal")])])))
        guard case .response(.response(let resp)) = r else { return XCTFail() }
        XCTAssertEqual(resp.result["isError"], .bool(true)); XCTAssertNil(inv)
        XCTAssertTrue(resp.result["content"]?[0]?["text"]?.stringValue?.contains("nope.txt") ?? false)
        // A bare-string `files` is coerced to a one-element array, matching the built-in's Zod
        // preprocess (bundle 2.1.258:485919) rather than rejecting an unambiguous input. This amends
        // the plan's assertion; see "Fix round 1" in the task-6 report for the reasoning.
        let (r2, inv2, _) = await s.handle(req(7, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .string("a.txt"), "status": .string("normal")])])))
        guard case .response(.response(let coerced)) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(coerced.result["isError"], .bool(false))
        XCTAssertEqual(coerced.result["content"]?[0]?["text"], .string("Sent 1 file to the user: a.txt"))
        guard case .sentFile(let coercedPaths, _, _, _) = inv2 else { return XCTFail("\(String(describing: inv2))") }
        XCTAssertEqual(coercedPaths.map(\.lastPathComponent), ["a.txt"])
        // The assertion the bare-string case was standing in for: a `files` that is neither a string
        // nor a non-empty array of strings stays a protocol error.
        for bad: JSONValue in [.integer(5), .array([]), .array([.integer(1), .integer(2)]), .null] {
            let (badReply, _, _) = await s.handle(req(70, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": bad, "status": .string("normal")])])))
            guard case .response(.error(let badErr)) = badReply else { return XCTFail("files: \(bad) should be a protocol error, got \(badReply)") }
            XCTAssertEqual(badErr.error.code, -32602, "files: \(bad)")
        }
        // A bad `status` and a bad `display` are protocol errors too.
        let (badStatus, _, _) = await s.handle(req(71, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt")]), "status": .string("urgent")])])))
        guard case .response(.error(let statusErr)) = badStatus else { return XCTFail("\(badStatus)") }
        XCTAssertEqual(statusErr.error.code, -32602)
        let (badDisplay, _, _) = await s.handle(req(72, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt")]), "status": .string("normal"), "display": .string("popup")])])))
        guard case .response(.error(let displayErr)) = badDisplay else { return XCTFail("\(badDisplay)") }
        XCTAssertEqual(displayErr.error.code, -32602)
        // A directory is readable but not sendable: a runtime failure, not a protocol error, and it
        // must not carry a host invocation.
        let (dir, dirInv, _) = await s.handle(req(73, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string(".")]), "status": .string("normal")])])))
        guard case .response(.response(let dirResp)) = dir else { return XCTFail("\(dir)") }
        XCTAssertEqual(dirResp.result["isError"], .bool(true)); XCTAssertNil(dirInv)
        let (r3, _, _) = await s.handle(req(8, "tools/call", .object(["name": .string("no_such_tool"), "arguments": .object([:])])))
        guard case .response(.error(let e3)) = r3 else { return XCTFail() }
        XCTAssertEqual(e3.error.code, -32602)
    }
    /// Group 3i. `notifications/cancelled` called `cancel()` on the task and recorded nothing durable, and
    /// `Task.cancel()` is a request rather than an outcome: a tool that ignores it — or that finished a moment
    /// before the notification was handled — still returns, and the result went out as a success carrying a
    /// host invocation for work the client had already withdrawn.
    func testACancelledCallIsRefusedEvenWhenTheToolIgnoresCancellation() async throws {
        let s = AfleetMCPServer(serverVersion: "0.1.0", cwd: tmp, tools: [DeafTool()])
        let message = req(20, "tools/call", .object(["name": .string("deaf"), "arguments": .object([:])]))
        let call = Task { await s.handle(message) }
        try await Task.sleep(for: .milliseconds(100))       // the call is in flight; the tool is 400 ms long
        guard case .notificationAck = (await s.handle(.notification(.init(method: "notifications/cancelled", params: .object(["requestId": .integer(20)]))))).0 else {
            return XCTFail("the cancellation was not acknowledged")
        }
        let (reply, invocation, _) = await call.value
        guard case .response(.error(let e)) = reply else { return XCTFail("a cancelled call answered with \(reply)") }
        XCTAssertEqual(e.error.code, -32800)
        XCTAssertNil(invocation, "a cancelled call must not publish a host invocation")
        // The record is per-call, not sticky: the next call with the same id is answered normally.
        let (again, againInv, _) = await s.handle(req(20, "tools/call", .object(["name": .string("deaf"), "arguments": .object([:])])))
        guard case .response(.response(let ok)) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(ok.result["isError"], .bool(false))
        XCTAssertNotNil(againInv)
    }
    /// Group 4j. An optional argument read through `stringValue` returns nil for both "absent" and "present
    /// but not a string", so `display: 5` was silently accepted as `display: nil` instead of being refused.
    func testAPresentButWrongTypedOptionalIsAnArgumentError() async throws {
        let s = server()
        let wrong: [(String, JSONValue)] = [("display", .integer(5)), ("display", .bool(true)), ("display", .array([.string("render")])),
                                            ("caption", .integer(7)), ("caption", .object(["text": .string("x")]))]
        for (key, bad) in wrong {
            let args: JSONValue = .object(["files": .array([.string("a.txt")]), "status": .string("normal"), key: bad])
            let (reply, inv, _) = await s.handle(req(80, "tools/call", .object(["name": .string("send_user_file"), "arguments": args])))
            guard case .response(.error(let e)) = reply else { return XCTFail("\(key) = \(bad) was accepted: \(reply)") }
            XCTAssertEqual(e.error.code, -32602, "\(key) = \(bad)")
            XCTAssertNil(inv, "\(key) = \(bad)")
        }
        // Absence and an explicit null still mean omitted, so the rule above rejects wrong types rather than
        // optionality.
        let (ok, inv, _) = await s.handle(req(81, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object([
            "files": .array([.string("a.txt")]), "status": .string("normal"), "display": .null, "caption": .null])])))
        guard case .response(.response(let resp)) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(resp.result["isError"], .bool(false))
        guard case .sentFile(_, let caption, _, let display) = inv else { return XCTFail("\(String(describing: inv))") }
        XCTAssertNil(caption); XCTAssertNil(display)
    }
    /// Group 4k. The path check tested existence, non-directory and readability but never the object's TYPE.
    /// `access(R_OK)` answers about permissions, so a FIFO passes all three and produced a successful
    /// sent-file invocation for something that cannot be transferred.
    func testAFIFOIsNotATransferableFile() async throws {
        let fifo = tmp.appendingPathComponent("pipe.fifo")
        guard mkfifo(fifo.path, 0o644) == 0 else { throw XCTSkip("mkfifo failed with errno \(errno)") }
        // The premise: it passes every check the old rule made.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: fifo.path))

        let s = server()
        let (reply, inv, _) = await s.handle(req(82, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object([
            "files": .array([.string("pipe.fifo")]), "status": .string("normal")])])))
        guard case .response(.response(let resp)) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(resp.result["isError"], .bool(true), "a FIFO was reported as sent")
        XCTAssertNil(inv, "a FIFO produced a user-visible sent-file invocation")
    }
    func testAbsolutePathsAnywhereReadableAreAllowed() async throws {
        // The built-in SendUserFile accepts any file the model can read; afleet mirrors that domain (child spec, WireMCP).
        let s = server()
        let (r, inv, _) = await s.handle(req(9, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("/etc/hosts")]), "status": .string("proactive")])])))
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
        let (reply, invocation, _) = await s.handle(req(13, "tools/call", .object(["name": .string("lies"), "arguments": .object([:])])))
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
        let (r, _, _) = await call.value
        guard case .response(.error(let e)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.error.code, -32800)
    }
}

/// An unexpected throw is summarised for the model — an error's own description is frame-derived payload,
/// because an MCP tool's arguments come straight off engine frames. The metadata a host needs to diagnose it
/// leaves through `handle`'s return instead, so this module keeps its single dependency on `WireFrames`.
final class MCPToolFailureTests: XCTestCase {
    private struct ExplodingTool: MCPTool {
        struct Boom: Error { let modelNamedPath = "/Users/someone/private/ledger.csv" }
        var name: String { "explode" }
        var description: String { "throws" }
        var inputSchema: JSONValue { .object([:]) }
        func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult { throw Boom() }
    }
    func testUnexpectedToolErrorReturnsMetadataAndKeepsPayloadFromTheModel() async throws {
        let server = AfleetMCPServer(serverVersion: "0.1.0", cwd: URL(fileURLWithPath: "/tmp"), tools: [ExplodingTool()])
        let (reply, invocation, failure) = await server.handle(.request(.init(id: .number(1), method: "tools/call", params: .object(["name": .string("explode"), "arguments": .object([:])]))))
        XCTAssertNil(invocation)
        guard case .response(.response(let r)) = reply else { return XCTFail("expected a response, got \(reply)") }
        XCTAssertEqual(r.result["isError"], .bool(true))
        let modelText = r.result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertEqual(modelText, "Tool explode failed unexpectedly (Boom)")
        XCTAssertFalse(modelText.contains("ledger.csv"), "the model must not see the error's own description")
        let failed = try XCTUnwrap(failure)
        XCTAssertEqual(failed.tool, "explode")
        XCTAssertEqual(failed.errorType, "Boom")
        XCTAssertFalse(failed.domain.contains("ledger.csv"))
        XCTAssertTrue(failed.domain.contains("Boom"), "the bridged NSError domain names the error type: \(failed.domain)")
    }
    /// `domain` and `code` exist for exactly one job — diagnosing a Foundation failure — and a plain Swift
    /// struct cannot test them: its bridged domain is just the mangled type name and its code is always 1, so
    /// an assertion on those fields holds whatever the implementation does. This throws a real Cocoa error.
    func testACocoaErrorContributesItsDomainAndCode() async throws {
        struct CocoaThrower: MCPTool {
            var name: String { "cocoa" }
            var description: String { "throws a Foundation error" }
            var inputSchema: JSONValue { .object([:]) }
            func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                              userInfo: [NSFilePathErrorKey: "/Users/someone/private/ledger.csv"])
            }
        }
        let server = AfleetMCPServer(serverVersion: "0.1.0", cwd: URL(fileURLWithPath: "/tmp"), tools: [CocoaThrower()])
        let (reply, _, failure) = await server.handle(.request(.init(id: .number(1), method: "tools/call", params: .object(["name": .string("cocoa"), "arguments": .object([:])]))))
        let failed = try XCTUnwrap(failure)
        XCTAssertEqual(failed.tool, "cocoa")
        XCTAssertEqual(failed.domain, NSCocoaErrorDomain)
        XCTAssertEqual(failed.code, NSFileReadNoSuchFileError)
        XCTAssertFalse(failed.domain.contains("ledger.csv"))
        guard case .response(.response(let r)) = reply else { return XCTFail("expected a response, got \(reply)") }
        let modelText = r.result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertFalse(modelText.contains("ledger.csv"), "NSError's description carries NSFilePathErrorKey; the model must not get it")
    }
    /// A call that does not throw carries no failure, so the transport cannot record one for a healthy tool.
    func testASuccessfulCallCarriesNoFailure() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let server = AfleetMCPServer(serverVersion: "0.1.0", cwd: dir, tools: [SendUserFileTool()])
        let (_, invocation, failure) = await server.handle(.request(.init(id: .number(1), method: "tools/call", params: .object(["name": .string("send_user_file"), "arguments": .object(["files": .array([.string("a.txt")]), "status": .string("normal")])]))))
        XCTAssertNotNil(invocation)
        XCTAssertNil(failure)
    }
}
