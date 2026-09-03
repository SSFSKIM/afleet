import XCTest
import WireFrames
import WireMCP

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
        let (r2, _) = await s.handle(req(7, "tools/call", .object(["name": .string("send_user_file"), "arguments": .object(["files": .string("a.txt"), "status": .string("normal")])])))
        guard case .response(.error(let e)) = r2 else { return XCTFail() }
        XCTAssertEqual(e.error.code, -32602)
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
