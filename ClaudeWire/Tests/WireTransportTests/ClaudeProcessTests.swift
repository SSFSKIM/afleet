import XCTest
import AfleetCore
import WireFrames
import WireMCP
import WireDiagnostics
import WireTransport
import WireTestSupport

/// Collects events from a process in the background; tests await specific ones with a deadline.
actor EventLog {
    private(set) var events: [WireEvent] = []
    func append(_ e: WireEvent) { events.append(e) }
    func first(where pred: @escaping @Sendable (WireEvent) -> Bool, within: Duration = .seconds(5)) async throws -> WireEvent {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < within {
            if let e = events.first(where: pred) { return e }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("timeout waiting for event")   // replaced by XCTFail at the call site
    }
}

/// Keeps every diagnostic's canonical JSON so a test can assert on text the event stream deliberately does not carry.
final class RecordingDiagnostics: DiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ event: DiagnosticEvent) {
        let line = (try? event.jsonValue.canonicalData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        lock.lock(); stored.append(line); lock.unlock()
    }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class Harness {
    let cwd: URL; let env: ResolvedEnvironment; let log = EventLog()
    init() throws {
        cwd = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: cwd.appendingPathComponent("hello.txt"))
        var vars = ProcessInfo.processInfo.environment
        vars["SCRIPTED_CLAUDE_SCENARIO"] = ""
        env = ResolvedEnvironment(variables: vars, shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
    }
    func make(scenario: String, epoch: ProcessEpoch = .first, bufferCapacity: Int = 4096, capture: RawCapture? = nil,
              diagnostics: any DiagnosticsSink = NullDiagnostics(), extraTools: [any MCPTool] = []) -> ClaudeProcess {
        var e = env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = scenario
        let launch = LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: cwd, session: .new(SessionID()))
        let p = ClaudeProcess(epoch: epoch, launch: launch, environment: e, configHome: ConfigHome(root: cwd.appendingPathComponent("cfg"), source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: cwd, tools: [SendUserFileTool()] + extraTools),
                              diagnostics: diagnostics, capture: capture, eventBufferCapacity: bufferCapacity)
        let log = self.log      // capture the actor, not the non-Sendable Harness
        Task { for await ev in p.events { await log.append(ev) } }
        return p
    }
    func expect(_ pred: @escaping @Sendable (WireEvent) -> Bool, _ message: String, within: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line) async -> WireEvent? {
        do { return try await log.first(where: pred, within: within) } catch { XCTFail("missing event: \(message)", file: file, line: line); return nil }
    }
    func stderrLines() async -> [String] { await log.events.compactMap { if case .stderr(let s, _) = $0 { return s }; return nil } }
}

final class ClaudeProcessTests: XCTestCase {
    func testHandshakeAndEcho() async throws {
        let h = try Harness(); let p = h.make(scenario: "")
        let hs = try await p.spawn()
        XCTAssertEqual(hs.initialize.pid != nil, true)
        // The handshake carries no system/init, and — given time to arrive — none does: the engine opens each
        // *turn* with that frame, and the stand-in models the engine.
        //
        // The settle is load-bearing. Reading the log the instant `spawn()` returns proves nothing: the reader
        // pushes frames onto the channel and the collector drains it, both asynchronously, so the log is empty
        // at that moment whatever the child emitted. Half a second is several orders of magnitude more than the
        // stand-in needs to write the frame it used to write here.
        try await Task.sleep(for: .milliseconds(500))
        let systemFramesBeforeAnyTurn = await h.log.events.filter { if case .frame(.system, _) = $0 { return true }; return false }
        XCTAssertEqual(systemFramesBeforeAnyTurn.count, 0, "a system frame arrived before any user message: \(systemFramesBeforeAnyTurn)")
        let running = await p.status; XCTAssertEqual(running, .running)
        _ = await h.expect({ if case .handshakeCompleted(_, let e) = $0 { return e == .first }; return false }, "handshakeCompleted with epoch")
        let uuid = try await p.send(UserInput(text: "ping"))
        // The tool list, model and version reach a consumer here — off the event stream, with the turn.
        guard case .frame(.system(.initialize(let sysInit)), .first)? = await h.expect({
            if case .frame(.system(.initialize), _) = $0 { return true }; return false
        }, "system/init opening the first turn") else { return }
        XCTAssertEqual(sysInit.claudeCodeVersion, "2.1.259")
        XCTAssertTrue(sysInit.tools.contains("mcp__afleet__send_user_file"))
        let reply = await h.expect({ if case .frame(.assistant(let a), _) = $0 { return a.userMessageUUID == uuid.uuidString.lowercased() }; return false }, "assistant echo bound by user_message_uuid")
        XCTAssertNotNil(reply)
        _ = await h.expect({ if case .frame(.result, .first) = $0 { return true }; return false }, "result frame tagged with epoch")
        await p.terminate()
        guard case .exited(let status, .first)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exited") else { return }
        XCTAssertTrue(status.isClean)
        let final = await p.status; XCTAssertEqual(final, .exited(status))
    }
    func testRequestResponseCorrelationAndControlError() async throws {
        let h = try Harness(); let p = h.make(scenario: "")
        _ = try await p.spawn()
        let r: JSONValue = try await p.request(GetSettings())
        XCTAssertEqual(r, .object([:]))
        // Awaited rather than sampled: stdout and stderr are separate pipes read by separate tasks, so
        // the stand-in's log line is not ordered against the response the request already returned.
        _ = await h.expect({ if case .stderr("HOST get_settings", _) = $0 { return true }; return false }, "stand-in logged HOST get_settings")
        let raw = try await p.requestRaw(subtype: "future_thing", payload: .object(["k": .integer(1)]))
        XCTAssertEqual(raw, .object([:]))
        await p.terminate()
    }
    func testUnknownRequestAnsweredWithinOneSecondAndSurfacedAsPolicyEvent() async throws {
        let h = try Harness(); let p = h.make(scenario: "unknown_request")
        _ = try await p.spawn()
        let start = ContinuousClock.now
        guard case .policyAnswered(let req, let error)? = await h.expect({ if case .policyAnswered = $0 { return true }; return false }, "policyAnswered") else { return }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertEqual(req.subtype, "afleet_never_heard"); XCTAssertEqual(error, "subtype afleet_never_heard not supported by afleet 0.1.0")
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("ANSWER u1 ") && s.contains("\"subtype\":\"error\"") && s.contains("not supported by afleet") }; return false }, "stand-in saw the error response")
        let surfacedUnknown = await h.log.events.contains { if case .request(let r) = $0 { return r.subtype == "afleet_never_heard" }; return false }
        XCTAssertFalse(surfacedUnknown)
        await p.terminate()
    }
    func testMalformedKnownRequestNamesTheField() async throws {
        let h = try Harness(); let p = h.make(scenario: "malformed_can_use_tool")
        _ = try await p.spawn()
        guard case .policyAnswered(let req, let error)? = await h.expect({ if case .policyAnswered = $0 { return true }; return false }, "policyAnswered") else { return }
        guard case .malformed(_, let field, _) = req.payload else { return XCTFail() }
        XCTAssertEqual(field, "input"); XCTAssertEqual(error, "can_use_tool: cannot decode field input")
        await p.terminate()
    }
    func testDeclaredDialogSurfacesUndeclaredIsLeftUnanswered() async throws {
        let h = try Harness(); let p = h.make(scenario: "declared_dialog,undeclared_dialog")
        _ = try await p.spawn()
        guard case .request(let d1)? = await h.expect({ if case .request(let r) = $0 { return r.id.rawValue == "d1" }; return false }, "declared dialog surfaced") else { return }
        try await p.answer(d1.id, .dialog(.completed(result: .string("retry_fallback"))))
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("ANSWER d1 ") && s.contains("retry_fallback") }; return false }, "dialog answer delivered")
        _ = await h.expect({ if case .unansweredDialog(let r) = $0 { return r.id.rawValue == "d2" }; return false }, "undeclared dialog event")
        _ = await h.expect({ if case .requestCancelled(let id, _) = $0 { return id.rawValue == "d2" }; return false }, "CLI cancelled d2 after its deadline")
        let d2Answered = await h.stderrLines().contains { $0.hasPrefix("ANSWER d2") }
        XCTAssertFalse(d2Answered)
        await p.terminate()
    }
    func testCancelRemovesPendingAndLateAnswerThrows() async throws {
        let h = try Harness(); let p = h.make(scenario: "cancel_request")
        _ = try await p.spawn()
        guard case .request(let c1)? = await h.expect({ if case .request(let r) = $0 { return r.id.rawValue == "c1" }; return false }, "c1 surfaced") else { return }
        _ = await h.expect({ if case .requestCancelled(let id, _) = $0 { return id.rawValue == "c1" }; return false }, "requestCancelled")
        do { try await p.answer(c1.id, .permission(.deny(message: "late", interrupt: false, classification: nil))); XCTFail("late answer accepted") }
        catch let e as WireError { XCTAssertEqual(e, .unknownRequest(c1.id)) }
        await p.terminate()
    }
    func testHookCallbacksRegisteredSurfaceUnregisteredAutoContinue() async throws {
        let h = try Harness(); let p = h.make(scenario: "hook_unregistered,hook_registered")
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("ANSWER h1 ") && s.contains("\"response\":{}") }; return false }, "unregistered hook answered with empty continue")
        guard case .request(let h2)? = await h.expect({ if case .request(let r) = $0 { return r.id.rawValue == "h2" }; return false }, "registered hook surfaced") else { return }
        try await p.answer(h2.id, .hookContinue(.empty))
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("ANSWER h2 ") }; return false }, "registered hook answered by host")
        await p.terminate()
    }
    func testMCPSequenceIsAnsweredInsideTheTransport() async throws {
        let h = try Harness(); let p = h.make(scenario: "mcp_sequence")
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m1 ") && s.contains("\"serverInfo\"") }; return false }, "initialize answered")
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m1n ") && s.contains("\"mcp_response\":{\"id\":0,\"jsonrpc\":\"2.0\",\"result\":{}}") }; return false }, "notification acked with id 0 empty result")
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m3 ") && s.contains("send_user_file") }; return false }, "tools/list answered")
        guard case .hostToolInvoked(.sentFile(let paths, _, let status, _), .first)? = await h.expect({ if case .hostToolInvoked = $0 { return true }; return false }, "hostToolInvoked") else { return }
        XCTAssertEqual(paths.map(\.lastPathComponent), ["hello.txt"]); XCTAssertEqual(status, "normal")
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m5 ") && s.contains("-32601") }; return false }, "unknown method error")
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m6 ") }; return false }, "cancelled notification acked")
        let mcpSurfaced = await h.log.events.contains { if case .request(let r) = $0 { return r.subtype == "mcp_message" }; return false }
        XCTAssertFalse(mcpSurfaced, "mcp_message must never surface")
        await p.terminate()
    }
    func testPendingRequestsReArmedOnceAndDeduplicated() async throws {
        let h = try Harness(); let p = h.make(scenario: "pending")
        let hs = try await p.spawn()
        XCTAssertEqual(hs.pending.map(\.id.rawValue), ["p1"])
        try await Task.sleep(for: .milliseconds(300))
        let surfaced = await h.log.events.filter { if case .request(let r) = $0 { return r.id.rawValue == "p1" }; return false }
        XCTAssertEqual(surfaced.count, 1, "the live duplicate of p1 must not surface twice")
        try await p.answer(hs.pending[0].id, .permission(.allow(updatedInput: nil, updatedPermissions: nil, classification: .userTemporary)))
        await p.terminate()
    }
    /// Carried decision 3: `ControlSuccess.requestFrames` compact-maps with `try?`, so an element that does
    /// not decode as a control request is silently skipped and a pending prompt could go unsurfaced. The raw
    /// array is still re-encoded verbatim, so nothing is lost on the wire — but the gap must be recorded.
    func testHandshakePendingUnderReportIsRecorded() async throws {
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "pending_undecodable", diagnostics: sink)
        let hs = try await p.spawn()
        XCTAssertEqual(hs.pending.map(\.id.rawValue), ["q1"])
        XCTAssertTrue(sink.entries.contains { $0.contains("handshake pending under-reported") && $0.contains("pending_permission_requests") },
                      "the skipped element must be recorded; entries: \(sink.entries)")
        await p.terminate()
    }
    /// Carried decision 1: after honouring a cancel the engine still answers with an error response for a
    /// request id the pending map has already forgotten. That is ordinary traffic — a diagnostic at most,
    /// never a throw, never an event, never an opaque-census entry.
    func testLateControlResponseForAForgottenRequestIsOrdinaryTraffic() async throws {
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "side_question_late_error", diagnostics: sink)
        _ = try await p.spawn()
        let asked = Task { try await p.request(SideQuestion(question: "which one?")) }
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("HOST side_question WITHHELD") }; return false }, "stand-in withheld the answer")
        asked.cancel()
        do { _ = try await asked.value; XCTFail("a cancelled request returned a value") }
        catch is CancellationError {} catch { XCTFail("expected CancellationError, got \(error)") }
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("LATE ERROR ") }; return false }, "stand-in sent the late error response")
        try await Task.sleep(for: .milliseconds(300))
        let events = await h.log.events
        let surfaced = events.contains { if case .frame(.controlResponse, _) = $0 { return true }; if case .frame(.opaque, _) = $0 { return true }; return false }
        XCTAssertFalse(surfaced, "an uncorrelated control_response must not reach the event stream")
        XCTAssertTrue(sink.entries.contains { $0.contains("uncorrelated control_response") }, "it must still be recorded; entries: \(sink.entries)")
        let status = await p.status; XCTAssertEqual(status, .running)
        await p.terminate()
    }
    func testStderrExitCodeAndSendAfterExit() async throws {
        let h = try Harness(); let p = h.make(scenario: "stderr:boom,exit:3")
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr("boom", .first) = $0 { return true }; return false }, "stderr line with epoch")
        guard case .exited(.code(3, let tail), .first)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exit code 3") else { return }
        XCTAssertTrue(tail.contains("boom"))
        do { _ = try await p.send(UserInput(text: "x")); XCTFail() } catch let e as WireError { XCTAssertEqual(e, .processExited) }
    }
    func testHandshakeTimeoutCarriesStderrTail() async throws {
        let h = try Harness(); let p = h.make(scenario: "no_init,stderr:warming")
        do { _ = try await p.spawn(handshakeTimeout: .seconds(1)); XCTFail("spawn should time out") }
        catch let e as WireError { if case .handshakeTimeout(let tail) = e { XCTAssertTrue(tail.contains("warming")) } else { XCTFail("\(e)") } }
        let after = await p.status; XCTAssertNotEqual(after, .running)
    }
    func testLaunchFailure() async throws {
        let h = try Harness()
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = ""
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: URL(fileURLWithPath: "/nonexistent/claude"), cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []), diagnostics: NullDiagnostics(), capture: nil)
        do { _ = try await p.spawn(); XCTFail() } catch let err as WireError { if case .launchFailed = err {} else { XCTFail("\(err)") } }
    }
    /// Carried decision 4: the launch-failure path finishes the channel, and `BoundedChannel.push` drops
    /// anything pushed after that. The exit must therefore be published before the finish, not after it —
    /// FleetKit's ownership release is driven by `.exited`.
    func testLaunchFailurePublishesExitBeforeFinishingTheStream() async throws {
        let h = try Harness()
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = ""
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: URL(fileURLWithPath: "/nonexistent/claude"), cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []), diagnostics: NullDiagnostics(), capture: nil)
        let drain = Task { () -> [WireEvent] in var seen: [WireEvent] = []; for await ev in p.events { seen.append(ev) }; return seen }
        do { _ = try await p.spawn(); XCTFail() } catch let err as WireError { if case .launchFailed = err {} else { XCTFail("\(err)") } }
        let seen = await drain.value
        XCTAssertTrue(seen.contains { if case .exited = $0 { return true }; return false }, "the launch failure's exit never reached the stream: \(seen.count) events")
    }
    func testKeepAliveFramesFlowThrough() async throws {
        let h = try Harness(); let p = h.make(scenario: "keep_alive")
        _ = try await p.spawn()
        _ = await h.expect({ if case .frame(.keepAlive, _) = $0 { return true }; return false }, "keep_alive frame")
        await p.terminate()
    }
    /// The other half of the MCP failure path: the server hands the metadata back through `handle`, and this
    /// actor — the only place that knows the epoch — is what actually records it. The unit test in
    /// `WireMCPTests` covers the server's side; without this one the transport could ignore the descriptor
    /// entirely and nothing would notice.
    func testMCPToolFailureIsRecordedByTheTransportWithoutLeakingPayload() async throws {
        struct ExplodingTool: MCPTool {
            struct Boom: Error { let modelNamedPath: String }
            var name: String { "explode" }
            var description: String { "throws" }
            var inputSchema: JSONValue { .object([:]) }
            func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
                throw Boom(modelNamedPath: arguments["path"]?.stringValue ?? "")
            }
        }
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "mcp_tool_throws", diagnostics: sink, extraTools: [ExplodingTool()])
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr(let s, _) = $0 { return s.hasPrefix("MCP m7 ") }; return false }, "the tool call was answered")
        let answer = await h.stderrLines().first { $0.hasPrefix("MCP m7 ") } ?? ""
        XCTAssertTrue(answer.contains("failed unexpectedly (Boom)"), "model-visible text must be the summary: \(answer)")
        XCTAssertFalse(answer.contains("ledger.csv"), "the model must not be handed the error's own description")
        let recorded = sink.entries.filter { $0.contains("\"event\":\"mcp_tool_failure\"") }
        XCTAssertEqual(recorded.count, 1, "entries: \(sink.entries)")
        let entry = recorded[0]
        XCTAssertTrue(entry.contains("\"tool\":\"explode\""))
        XCTAssertTrue(entry.contains("\"error_type\":\"Boom\""))
        XCTAssertTrue(entry.contains("\"epoch\":1"), "the epoch is why this is recorded here and not in the server: \(entry)")
        XCTAssertFalse(entry.contains("ledger.csv"), "the metadata log stays metadata: \(entry)")
        await p.terminate()
    }
    /// Fix 3: `finish()` used to run on a fixed 50 ms timer after the exit, and everything the reader had not
    /// yet handed over was pushed into a finished channel, where `push` drops it.
    ///
    /// Getting this to discriminate took a second attempt. A fast consumer does not expose it: the child can
    /// only exit once it has written everything, so at most a pipe buffer plus one read chunk is ever in
    /// flight, and 50 ms drains that easily. The case a timer actually loses is a *slow* consumer — the reader
    /// parked in `push` when the child exits, with the whole backlog still on its side of the channel. The
    /// flood is sized to fit the pipe buffer so the child can exit without blocking, and the consumer paces
    /// itself well past the old window.
    func testEveryFrameWrittenBeforeExitIsDeliveredToASlowConsumer() async throws {
        let h = try Harness()
        let total = 100
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = "flood:\(total),exit:0"
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []),
                              diagnostics: NullDiagnostics(), capture: nil, eventBufferCapacity: 4)
        _ = try await p.spawn()
        var assistants = 0, sawResult = false, sawExit = false
        for await ev in p.events {
            switch ev {
            case .frame(.assistant, _): assistants += 1
            case .frame(.result, _): sawResult = true
            case .exited: sawExit = true
            default: break
            }
            if sawExit { break }
            try await Task.sleep(for: .milliseconds(2))     // ~200 ms of draining against a 50 ms window
        }
        XCTAssertEqual(assistants, total, "frames still held by the reader at exit must not be dropped by finish()")
        XCTAssertTrue(sawResult, "the result frame is the one that matters most")
        XCTAssertTrue(sawExit, "the exit must still be published after the drain")
    }
    /// Fix C. The child answers the request and exits in the same breath, so the response is sitting in the
    /// pipe when the termination handler fires. Failing outbound waiters before the drain — which is what an
    /// earlier revision did — turns a delivered answer into `processExited`. They settle after the bounded
    /// drain now, which is safe for exactly the reason the handshake waiter is: `Waiter.settle` is first-wins,
    /// so the arriving response gets there first, and callers keep their own `timeout:` for the case where
    /// nothing arrives at all.
    func testAResponseAlreadyInThePipeIsCorrelatedThoughTheChildHasExited() async throws {
        let h = try Harness()
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = "exit_after_answer"
        // A four-element channel and a consumer that paces itself: the reader is parked in `push` with the
        // answer still unread when the child dies. Without the back-pressure the reader simply wins the race
        // and the correlation is never exercised — an earlier version of this test passed against the break
        // for exactly that reason.
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []),
                              diagnostics: NullDiagnostics(), capture: nil, eventBufferCapacity: 4)
        let sawExit = Waiter<Void>()
        let consumer = Task {
            for await ev in p.events {
                if case .exited = ev { sawExit.settle(.success(())) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { consumer.cancel() }
        _ = try await p.spawn()
        let r: JSONValue = try await p.request(GetSettings())
        XCTAssertEqual(r, .object([:]), "the answer was on the wire before the exit and must be correlated")
        let timer = sawExit.timeout(after: .seconds(12)) { WireError.processExited }
        defer { timer.cancel() }
        do { try await sawExit.value() } catch { XCTFail("the exit was never published") }
    }
    /// Fix B. A child that answers the handshake *with a pending request* and exits in the same breath leaves
    /// `spawn` on its success path with events still to publish, while `processDidExit` is already publishing
    /// the terminal one. Nothing orders two continuations resuming on one actor, so this is a race; it is run
    /// repeatedly because a race observed once is luck, and the invariant it checks is absolute — `.exited` is
    /// the last event on the stream, always.
    func testNoEventIsPublishedAfterTheTerminalExit() async throws {
        for attempt in 0..<20 {
            let h = try Harness(); let p = h.make(scenario: "pending,exit:0")
            _ = try? await p.spawn()
            guard await h.expect({ if case .exited = $0 { return true }; return false }, "exited (attempt \(attempt))", within: .seconds(12)) != nil else { return }
            try await Task.sleep(for: .milliseconds(50))     // give a late publisher every chance to land
            let events = await h.log.events
            guard let terminal = events.firstIndex(where: { if case .exited = $0 { return true }; return false }) else {
                return XCTFail("no exit on attempt \(attempt)")
            }
            let after = events[(terminal + 1)...]
            XCTAssertTrue(after.isEmpty, "attempt \(attempt): \(after.count) event(s) published after the terminal exit: \(after.map { "\($0)" })")
        }
    }
    func testCaptureReceivesRedactedLinesForBothDirections() async throws {
        let h = try Harness()
        let root = h.cwd.appendingPathComponent("capture")
        let cap = RawCapture(root: root, configHome: ConfigHome(root: h.cwd.appendingPathComponent("cfg"), source: .environment), budgetBytes: 1_000_000)
        let p = h.make(scenario: "", capture: cap)
        _ = try await p.spawn(); _ = try await p.send(UserInput(text: "hello")); try await Task.sleep(for: .milliseconds(300)); await p.terminate()
        let dir = root.appendingPathComponent(RawCapture.configHomeHash(ConfigHome(root: h.cwd.appendingPathComponent("cfg"), source: .environment)))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("\"subtype\":\"initialize\"")); XCTAssertTrue(text.contains("\"type\":\"assistant\""))
    }
}

/// The engine's JSON-RPC handshake with the in-process MCP server, and the ordering constraint it places on
/// this transport.
///
/// Every recorded fixture opens the same way: the engine sends `mcp_message`/`initialize` toward the server and
/// **waits for the host's answer before answering `control_request/initialize`** (frame 2 before frame 4 in
/// `zero-cost`, `plain-two-turn`, `send-user-file` and `resume-no-replay`). The stand-in now reproduces that,
/// which turns a structural property of `ClaudeProcess` into something a test can hold: `spawn()` starts the
/// stdout reader before it writes the initialize request, so the inbound `mcp_message` is answered while
/// `spawn()` is still suspended. A transport that started reading after the handshake returned would deadlock
/// against this stand-in rather than pass quietly.
final class MCPStartupOrderingTests: XCTestCase {

    func testTheEngineSInitializeResponseFollowsTheHostAnsweringTheServerHandshake() async throws {
        let h = try Harness()
        let sink = RecordingDiagnostics()
        let p = h.make(scenario: "", diagnostics: sink)
        _ = try await p.spawn()
        await p.terminate()

        // Both directions are recorded, so the order is read off the log rather than inferred from timing.
        let mcpIn = sink.entries.firstIndex { $0.contains("\"direction\":\"inbound\"") && $0.contains("\"subtype\":\"mcp_message\"") }
        let answerOut = sink.entries.firstIndex { $0.contains("\"direction\":\"outbound\"") && $0.contains("\"subtype\":\"mcp_message\"") }
        let initResponseIn = sink.entries.firstIndex { $0.contains("\"direction\":\"inbound\"") && $0.contains("\"type\":\"control_response\"") && $0.contains("\"request_id\":\"init-1\"") }
        let inbound = try XCTUnwrap(mcpIn, "the engine never asked the in-process server to initialize")
        let answered = try XCTUnwrap(answerOut, "the host never answered the server handshake")
        let response = try XCTUnwrap(initResponseIn, "no initialize response was recorded")
        XCTAssertLessThan(inbound, answered, "the host answered before it was asked")
        XCTAssertLessThan(answered, response, "the initialize response arrived before the host answered the server handshake; the ordering the fixtures record was not exercised")
    }

    /// The window the corpus shows but never photographs: between the handshake completing and `tools/list`
    /// being answered, the server is not yet connected and its tool list is empty. A host that reads
    /// `mcp_status` the instant `spawn()` returns is inside it.
    func testTheServerIsNotConnectedTheMomentTheHandshakeCompletes() async throws {
        let h = try Harness()
        let p = h.make(scenario: "mcp_slow_connect:0.6")
        _ = try await p.spawn()

        let immediate = try await p.request(MCPStatus(), timeout: .seconds(5))
        let atOnce = try XCTUnwrap(immediate["mcpServers"]?.arrayValue?.first { $0["name"]?.stringValue == "afleet" })
        XCTAssertEqual(atOnce["status"]?.stringValue, "connecting")
        XCTAssertEqual(atOnce["tools"]?.arrayValue?.count, 0, "a tool list before tools/list was answered")

        var connected: JSONValue?
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, connected == nil {
            let reading = try await p.request(MCPStatus(), timeout: .seconds(5))
            connected = reading["mcpServers"]?.arrayValue?.first { $0["name"]?.stringValue == "afleet" && $0["status"]?.stringValue == "connected" }
            if connected == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let server = try XCTUnwrap(connected, "the server never reached connected")
        XCTAssertEqual(server["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["send_user_file"])
        await p.terminate()
    }
}
