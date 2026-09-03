import XCTest
import WireFrames

final class OutboundRequestTests: XCTestCase {
    private func request<R: ControlRequestSpec>(_ spec: R) throws -> JSONValue {
        let v = try JSONDecoder().decode(JSONValue.self, from: try OutboundEnvelope.encode(spec: spec, requestID: .init(rawValue: "r")))
        guard let inner = v["request"] else { throw XCTSkip("no request object") }
        return inner
    }
    func testEnvelopeShape() throws {
        let data = try OutboundEnvelope.encode(spec: SetPermissionMode(mode: .plan), requestID: RequestID(rawValue: "abc"))
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v, .object(["type": .string("control_request"), "request_id": .string("abc"),
                                   "request": .object(["subtype": .string("set_permission_mode"), "mode": .string("plan")])]))
    }
    func testEverySpecHasASubtypeAndDecodesItsResponse() throws {
        XCTAssertEqual(Interrupt.subtype, "interrupt"); XCTAssertEqual(SetModel.subtype, "set_model"); XCTAssertEqual(ListModels.subtype, "list_models")
        XCTAssertEqual(SetMaxThinkingTokens.subtype, "set_max_thinking_tokens"); XCTAssertEqual(ApplyFlagSettings.subtype, "apply_flag_settings")
        XCTAssertEqual(RenameSession.subtype, "rename_session"); XCTAssertEqual(SetCwd.subtype, "set_cwd"); XCTAssertEqual(GetSettings.subtype, "get_settings")
        XCTAssertEqual(ClaudeAuthenticate.subtype, "claude_authenticate"); XCTAssertEqual(ClaudeOAuthCallback.subtype, "claude_oauth_callback")
        XCTAssertEqual(ClaudeOAuthWaitForCompletion.subtype, "claude_oauth_wait_for_completion"); XCTAssertEqual(MCPAuthenticate.subtype, "mcp_authenticate")
        XCTAssertEqual(MCPOAuthCallbackURL.subtype, "mcp_oauth_callback_url"); XCTAssertEqual(MCPClearAuth.subtype, "mcp_clear_auth")
        XCTAssertEqual(RewindConversation.subtype, "rewind_conversation"); XCTAssertEqual(RewindFiles.subtype, "rewind_files")
        XCTAssertEqual(GetContextUsage.subtype, "get_context_usage"); XCTAssertEqual(GetSessionCost.subtype, "get_session_cost"); XCTAssertEqual(GetUsage.subtype, "get_usage")
        XCTAssertEqual(GetBinaryVersion.subtype, "get_binary_version"); XCTAssertEqual(StopTask.subtype, "stop_task"); XCTAssertEqual(BackgroundTasks.subtype, "background_tasks")
        XCTAssertEqual(SideQuestion.subtype, "side_question"); XCTAssertEqual(FileSuggestions.subtype, "file_suggestions"); XCTAssertEqual(MCPStatus.subtype, "mcp_status")
        XCTAssertEqual(MCPSetServers.subtype, "mcp_set_servers"); XCTAssertEqual(MCPReconnect.subtype, "mcp_reconnect"); XCTAssertEqual(MCPToggle.subtype, "mcp_toggle")
        XCTAssertEqual(ReloadSkills.subtype, "reload_skills"); XCTAssertEqual(ReloadPlugins.subtype, "reload_plugins"); XCTAssertEqual(EndSession.subtype, "end_session")
        XCTAssertEqual(GenerateSessionTitle.subtype, "generate_session_title"); XCTAssertEqual(UpdateSettings.subtype, "update_settings"); XCTAssertEqual(MCPCall.subtype, "mcp_call")
        let r = try JSONDecoder().decode(Interrupt.Response.self, from: Data(#"{"still_queued":["u1"],"cancelled":[]}"#.utf8))
        XCTAssertEqual(r.stillQueued, ["u1"])
        let empty = try JSONDecoder().decode(Interrupt.Response.self, from: Data("{}".utf8))
        XCTAssertNil(empty.stillQueued)
        let raw = RawControlRequest(subtype: "future_thing", payload: .object(["k": .integer(1)]))
        XCTAssertEqual(type(of: raw).subtype, "raw")
        XCTAssertEqual(raw.wireSubtype, "future_thing")
        XCTAssertEqual(try request(raw), .object(["subtype": .string("future_thing"), "k": .integer(1)]))
    }
    func testAbortableSubtypes() {
        XCTAssertEqual(OutboundEnvelope.abortableSubtypes, ["side_question", "mcp_call"])
    }
    /// Byte-level payloads for the requests whose keys the typings pin (a wrong key is a silently ignored request).
    func testPayloadsMatchTheTypings() throws {
        XCTAssertEqual(try request(MCPToggle(serverName: "github", enabled: false)), .object(["subtype": .string("mcp_toggle"), "serverName": .string("github"), "enabled": .bool(false)]))
        XCTAssertEqual(try request(MCPReconnect(serverName: "github")), .object(["subtype": .string("mcp_reconnect"), "serverName": .string("github")]))
        XCTAssertEqual(try request(UpdateSettings(settings: .object(["outputStyle": .string("x")]))), .object(["subtype": .string("update_settings"), "source": .string("localSettings"), "settings": .object(["outputStyle": .string("x")])]))
        XCTAssertEqual(try request(MCPCall(tool: "mcp__github__list_prs", arguments: .object(["repo": .string("a")]), timeoutMs: 5000)),
                       .object(["subtype": .string("mcp_call"), "tool": .string("mcp__github__list_prs"), "arguments": .object(["repo": .string("a")]), "timeout_ms": .integer(5000)]))
        XCTAssertEqual(try request(StopTask(taskID: "t1")), .object(["subtype": .string("stop_task"), "task_id": .string("t1")]))
        XCTAssertEqual(try request(BackgroundTasks()), .object(["subtype": .string("background_tasks")]))
        XCTAssertEqual(try request(RewindFiles(userMessageID: "u", dryRun: true)), .object(["subtype": .string("rewind_files"), "user_message_id": .string("u"), "dry_run": .bool(true)]))
        XCTAssertEqual(try request(SetMaxThinkingTokens(maxThinkingTokens: nil)), .object(["subtype": .string("set_max_thinking_tokens"), "max_thinking_tokens": .null]))
        XCTAssertEqual(try request(SetModel(model: "opus")), .object(["subtype": .string("set_model"), "model": .string("opus")]))
        XCTAssertEqual(try request(RenameSession(title: "t")), .object(["subtype": .string("rename_session"), "title": .string("t")]))
        XCTAssertEqual(try request(FileSuggestions(query: "src")), .object(["subtype": .string("file_suggestions"), "query": .string("src")]))
        XCTAssertEqual(try request(Interrupt(cancelQueued: true)), .object(["subtype": .string("interrupt"), "cancel_queued": .bool(true)]))
        XCTAssertEqual(try request(GetContextUsage(detail: "full")), .object(["subtype": .string("get_context_usage"), "detail": .string("full")]))
    }
    /// Keys the plan's table had wrong, re-derived from the bundle's own handlers (see the task report).
    func testPayloadsCorrectedAgainstTheBundleHandlers() throws {
        XCTAssertEqual(try request(SideQuestion(question: "why?")), .object(["subtype": .string("side_question"), "question": .string("why?")]))
        XCTAssertEqual(try request(SideQuestion(question: "why?", history: [.object(["question": .string("a"), "response": .string("b")])])),
                       .object(["subtype": .string("side_question"), "question": .string("why?"),
                                "history": .array([.object(["question": .string("a"), "response": .string("b")])])]))
        XCTAssertEqual(try request(MCPAuthenticate(serverName: "github")), .object(["subtype": .string("mcp_authenticate"), "serverName": .string("github")]))
        XCTAssertEqual(try request(MCPAuthenticate(serverName: "github", redirectUri: "http://localhost:9/cb")),
                       .object(["subtype": .string("mcp_authenticate"), "serverName": .string("github"), "redirectUri": .string("http://localhost:9/cb")]))
        XCTAssertEqual(try request(MCPOAuthCallbackURL(serverName: "github", callbackURL: "http://localhost:9/cb?code=1")),
                       .object(["subtype": .string("mcp_oauth_callback_url"), "serverName": .string("github"), "callbackUrl": .string("http://localhost:9/cb?code=1")]))
        XCTAssertEqual(try request(MCPClearAuth(serverName: "github")), .object(["subtype": .string("mcp_clear_auth"), "serverName": .string("github")]))
        XCTAssertEqual(try request(ClaudeAuthenticate()), .object(["subtype": .string("claude_authenticate")]))
        XCTAssertEqual(try request(ClaudeAuthenticate(loginWithClaudeAI: false)), .object(["subtype": .string("claude_authenticate"), "loginWithClaudeAi": .bool(false)]))
        XCTAssertEqual(try request(ClaudeOAuthCallback(authorizationCode: "c", state: "s")),
                       .object(["subtype": .string("claude_oauth_callback"), "authorizationCode": .string("c"), "state": .string("s")]))
        XCTAssertEqual(try request(ClaudeOAuthWaitForCompletion()), .object(["subtype": .string("claude_oauth_wait_for_completion")]))
        XCTAssertEqual(try request(SetCwd(path: "/tmp/a")), .object(["subtype": .string("set_cwd"), "path": .string("/tmp/a")]))
        XCTAssertEqual(try request(SetCwd(path: "/tmp/a", trustAccepted: true, trustedDirectory: "/tmp/a")),
                       .object(["subtype": .string("set_cwd"), "path": .string("/tmp/a"), "trust_accepted": .bool(true), "trusted_directory": .string("/tmp/a")]))
        XCTAssertEqual(try request(RewindConversation(targetMessageUUID: "u1")),
                       .object(["subtype": .string("rewind_conversation"), "target_message_uuid": .string("u1")]))
        XCTAssertEqual(try request(RewindConversation(targetMessageUUID: "u1", lastSeenUserMessageUUID: "u9", interruptIfRunning: true)),
                       .object(["subtype": .string("rewind_conversation"), "target_message_uuid": .string("u1"),
                                "last_seen_user_message_uuid": .string("u9"), "interrupt_if_running": .bool(true)]))
        XCTAssertEqual(try request(GenerateSessionTitle(description: "d", persist: true)),
                       .object(["subtype": .string("generate_session_title"), "description": .string("d"), "persist": .bool(true)]))
    }
}
