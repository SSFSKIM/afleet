import Foundation
import AfleetCore
import WireFrames
import WireMCP
import WireEnvironment
import WireDiagnostics

/// One instance, one process, one epoch. Never respawned in place.
public actor ClaudeProcess {
    public let epoch: ProcessEpoch
    public let launch: LaunchConfiguration
    public let environment: ResolvedEnvironment
    public let configHome: ConfigHome
    public let initialize: InitializeConfiguration
    public let policy: InboundPolicy
    public let mcpServer: AfleetMCPServer
    public let diagnostics: any DiagnosticsSink
    public let capture: RawCapture?
    public let sessionID: SessionID

    public nonisolated let events: WireEventStream<WireEvent>
    private let channel: BoundedChannel<WireEvent>

    /// Foundation.Process is not Sendable; this box is the one place it lives and only the actor (and its termination
    /// handler, which hops back onto the actor) touches it.
    private final class ProcessBox: @unchecked Sendable { let process = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe() }
    private let box = ProcessBox()
    private var writer: StdinWriter?
    private var readers: [Task<Void, Never>] = []
    private var mcpTasks: [RequestID: Task<Void, Never>] = [:]
    private var stderrRing: [String] = []
    private var pendingOutbound: [RequestID: Waiter<ControlResponseBody>] = [:]
    private var pendingInbound: [RequestID: InboundRequest] = [:]
    private var seenInboundIDs: Set<RequestID> = []
    private var exitWaiters: [Waiter<ExitStatus>] = []
    private let handshakeWaiter = Waiter<HandshakePair>()
    private var handshakeInit: ControlSuccess?
    private var handshakeSystemInit: SystemInit?
    private var handshakePending: [InboundRequest] = []
    private var terminating = false
    public private(set) var status: ProcessStatus = .launching
    private struct HandshakePair: Sendable { let initialize: ControlSuccess; let systemInit: SystemInit }

    public init(epoch: ProcessEpoch, launch: LaunchConfiguration, environment: ResolvedEnvironment, configHome: ConfigHome,
                initialize: InitializeConfiguration = .init(), policy: InboundPolicy? = nil, mcpServer: AfleetMCPServer,
                diagnostics: any DiagnosticsSink, capture: RawCapture?, eventBufferCapacity: Int = 4096) {
        self.epoch = epoch; self.launch = launch; self.environment = environment; self.configHome = configHome; self.initialize = initialize
        self.policy = policy ?? .default(declaredDialogKinds: Set(initialize.supportedDialogKinds), registeredHookCallbackIDs: initialize.registeredHookCallbackIDs)
        self.mcpServer = mcpServer; self.diagnostics = diagnostics; self.capture = capture
        switch launch.session { case .new(let id), .resume(let id, _): sessionID = id }
        channel = BoundedChannel(capacity: eventBufferCapacity)
        events = WireEventStream(channel: channel)
        signal(SIGPIPE, SIG_IGN)
    }

    public var bufferedEventCount: Int { get async { await channel.count } }
    private var isExited: Bool { if case .exited = status { return true }; return false }

    // MARK: spawn and handshake

    public func spawn(handshakeTimeout: Duration = .seconds(30)) async throws -> Handshake {
        guard status == .launching else { throw WireError.notInRunningState(status) }
        let p = box.process
        p.executableURL = launch.binary; p.arguments = launch.arguments(); p.currentDirectoryURL = launch.cwd
        p.environment = launch.childEnvironment(over: environment)
        p.standardInput = box.stdin; p.standardOutput = box.stdout; p.standardError = box.stderr
        p.terminationHandler = { [weak self] proc in
            let raw: ExitStatus = proc.terminationReason == .uncaughtSignal ? .signal(proc.terminationStatus, stderrTail: "") : .code(proc.terminationStatus, stderrTail: "")
            Task { await self?.processDidExit(raw) }
        }
        do { try p.run() } catch {
            let failure = ExitStatus.code(-1, stderrTail: String(describing: error))
            status = .exited(failure)
            // The exit goes out *before* the finish: `BoundedChannel.push` drops anything pushed after
            // finish(), and FleetKit releases ownership of a channel on `.exited`, not on stream end.
            await channel.push(.exited(failure, epoch))
            await channel.finish()
            throw WireError.launchFailed(String(describing: error))
        }
        status = .handshaking
        diagnostics.record(.lifecycle("spawned pid \(p.processIdentifier)", epoch: epoch))
        writer = StdinWriter(handle: box.stdin.fileHandleForWriting)
        startReaders()
        let started = ContinuousClock.now
        let timer = handshakeWaiter.timeout(after: handshakeTimeout) { WireError.handshakeTimeout(stderrTail: "") }
        defer { timer.cancel() }
        let pair: HandshakePair
        do {
            let line = try initialize.requestLine(requestID: RequestID(rawValue: "init-1"))
            try await writeLine(line, type: "control_request", subtype: "initialize", requestID: RequestID(rawValue: "init-1"))
            pair = try await handshakeWaiter.value()
        } catch {
            let tail = stderrTail()
            await terminate()
            if let wire = error as? WireError, case .handshakeTimeout = wire { throw WireError.handshakeTimeout(stderrTail: tail) }
            throw error
        }
        // A child that exits between the handshake frames and here must not be reported as running: the
        // termination handler waits 50 ms for the stderr reader, so this window is real if narrow.
        if isExited { throw WireError.processExited }
        status = .running
        diagnostics.record(.handshake(durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)), epoch: epoch))
        let pending = handshakePending
        let handshake = Handshake(initialize: InitializeResponse(raw: pair.initialize.response ?? .object([:])), systemInit: pair.systemInit, pending: pending)
        await channel.push(.handshakeCompleted(handshake, epoch))
        for r in pending { await channel.push(.request(r)) }
        return handshake
    }
    private func handshakeProgress() {
        if let i = handshakeInit, let s = handshakeSystemInit { handshakeWaiter.settle(.success(HandshakePair(initialize: i, systemInit: s))) }
    }
    /// Runs on the reader, synchronously, the moment the initialize response is decoded — before any suspension.
    /// The engine re-sends every pending request as a live `control_request` right after the handshake, so the
    /// ids must already be in `seenInboundIDs` when those arrive; doing this in `spawn` instead would leave the
    /// order to the scheduler and let the duplicate surface twice.
    ///
    /// `ControlSuccess`'s typed views compact-map with `try?`: an element that does not decode as a control
    /// request is skipped, and a skipped element could be a permission prompt that never reaches the user. It
    /// is still re-encoded verbatim, so nothing is lost on the wire, but the gap is recorded here.
    private func registerPending(_ s: ControlSuccess) {
        func take(_ raw: JSONValue?, _ typed: [ControlRequestFrame], _ key: String) {
            let onWire = raw?.arrayValue?.count ?? 0
            if typed.count < onWire {
                diagnostics.record(.lifecycle("handshake pending under-reported: \(typed.count) of \(onWire) \(key) decoded as control requests", epoch: epoch))
            }
            for frame in typed {
                let request = InboundRequest.parse(frame: frame, epoch: epoch, receivedAt: .now)
                guard !seenInboundIDs.contains(request.id) else { continue }
                seenInboundIDs.insert(request.id)
                pendingInbound[request.id] = request
                handshakePending.append(request)
            }
        }
        take(s.rawPendingPermissionRequests, s.pendingPermissionRequests, "pending_permission_requests")
        take(s.rawPendingUserDialogRequests, s.pendingUserDialogRequests, "pending_user_dialog_requests")
    }

    // MARK: readers

    /// The plan called for `FileHandle.bytes.lines`. Measured against the stand-in it issues roughly one read
    /// syscall per byte: a 314-byte control response arrived at once while the 5 KB `system/init` frame behind
    /// it took four seconds, so every handshake timed out and the flood never finished. `LineReader` below does
    /// the same job with one blocking chunked read per 64 KB on a dedicated queue, and keeps the back-pressure
    /// the plan depends on — it only reads again once `receive` has returned, so a full event channel stalls the
    /// pipe and the child blocks on its own write.
    private func startReaders() {
        let out = LineReader(handle: box.stdout.fileHandleForReading, label: "afleet.stdout-reader")
        let err = LineReader(handle: box.stderr.fileHandleForReading, label: "afleet.stderr-reader")
        readers.append(Task { [weak self] in
            while let line = await out.next() {
                guard let self else { return }
                await self.receive(line: line)
            }
        })
        readers.append(Task { [weak self] in
            while let line = await err.next() {
                guard let self else { return }
                await self.receiveStderr(String(decoding: line, as: UTF8.self))
            }
        })
    }
    private func record(_ e: DiagnosticEvent) { diagnostics.record(e) }
    private func receiveStderr(_ line: String) async {
        stderrRing.append(line); if stderrRing.count > 200 { stderrRing.removeFirst(stderrRing.count - 200) }
        await channel.push(.stderr(line, epoch))
    }
    private func stderrTail() -> String { stderrRing.suffix(50).joined(separator: "\n") }

    private func receive(line: Data) async {
        let frame = FrameDecoder.decode(line: line)
        diagnostics.record(.frame(direction: .inbound, type: frame.typeName, subtype: subtype(of: frame), bytes: line.count, epoch: epoch, requestID: requestID(of: frame)))
        await capture?.write(line: line, session: sessionID)
        switch frame {
        case .controlResponse(let resp):
            if resp.requestID.rawValue == "init-1" {
                switch resp.body {
                case .success(let s): handshakeInit = s; registerPending(s); handshakeProgress()
                case .error(let e): handshakeWaiter.settle(.failure(WireError.handshakeRejected(e.error)))
                }
                return
            }
            guard let waiter = pendingOutbound.removeValue(forKey: resp.requestID) else {
                // Ordinary traffic, not drift. After honouring a `control_cancel_request` the engine still
                // emits an error response for the cancelled id ("mcp_call cancelled by client: <server>",
                // "Side question cancelled"), and its own schema says a requester ignores responses for ids
                // it is not waiting on. Dropped with a diagnostic: never an error, never an event, never an
                // opaque-census entry.
                diagnostics.record(.lifecycle("uncorrelated control_response for \(resp.requestID) dropped", epoch: epoch))
                return
            }
            waiter.settle(.success(resp.body))
            await channel.push(.frame(frame, epoch))
        case .controlRequest(let req):
            await handleInbound(req)
        case .controlCancelRequest(let cancel):
            if pendingInbound.removeValue(forKey: cancel.requestID) != nil { await channel.push(.requestCancelled(cancel.requestID, epoch)) }
            if let running = mcpTasks.removeValue(forKey: cancel.requestID) { running.cancel() }
            await channel.push(.frame(frame, epoch))
        case .system(.initialize(let sysInit)):
            if handshakeSystemInit == nil { handshakeSystemInit = sysInit; handshakeProgress() }
            await channel.push(.frame(frame, epoch))
        default:
            await channel.push(.frame(frame, epoch))
        }
    }
    private func handleInbound(_ req: ControlRequestFrame) async {
        let request = InboundRequest.parse(frame: req, epoch: epoch, receivedAt: .now)
        if seenInboundIDs.contains(request.id) { return }              // a live duplicate of a pending request re-armed at handshake
        seenInboundIDs.insert(request.id)
        switch policy.decide(request) {
        case .surface:
            pendingInbound[request.id] = request
            await channel.push(.request(request))
        case .answer(let answer):
            try? await writeAnswer(request.id, answer, subtype: request.subtype)
            if case .error(let message) = answer { await channel.push(.policyAnswered(request, error: message)) }
            else { diagnostics.record(.answer(requestID: request.id, subtype: request.subtype, behavior: "policy", classification: nil, epoch: epoch)) }
        case .leaveUnanswered:
            pendingInbound[request.id] = request
            await channel.push(.unansweredDialog(request))
        case .routeToMCP:
            guard case .mcpMessage(let m) = request.payload else { return }
            switch m.message {
            case .request:
                // Off the reader: a long tools/call must not stall stdout, and notifications/cancelled must reach the server while it runs.
                let id = request.id
                mcpTasks[id] = Task { [mcpServer] in
                    let (reply, invocation) = await mcpServer.handle(m.message)
                    await self.deliverMCP(id, reply: reply, invocation: invocation)
                }
            default:
                let (reply, invocation) = await mcpServer.handle(m.message)
                await deliverMCP(request.id, reply: reply, invocation: invocation)
            }
        }
    }
    private func deliverMCP(_ id: RequestID, reply: MCPReply, invocation: HostToolInvocation?) async {
        mcpTasks[id] = nil
        let rpc: JSONRPCMessage = { if case .response(let r) = reply { return r }; return .response(.init(id: .number(0), result: .object([:]))) }()
        try? await writeAnswer(id, .mcpResponse(rpc), subtype: "mcp_message")
        if let invocation { await channel.push(.hostToolInvoked(invocation, epoch)) }
    }
    private func subtype(of frame: Frame) -> String? {
        switch frame { case .system(let s): s.subtype; case .controlRequest(let r): r.subtype; case .result(let r): r.subtype; case .opaque(let o): o.subtype; default: nil }
    }
    private func requestID(of frame: Frame) -> RequestID? {
        switch frame { case .controlRequest(let r): r.requestID; case .controlResponse(let r): r.requestID; case .controlCancelRequest(let c): c.requestID; default: nil }
    }

    // MARK: writes

    private func writeLine(_ data: Data, type: String, subtype: String?, requestID: RequestID?) async throws {
        guard let writer, !terminating, !isExited else { throw WireError.processExited }
        diagnostics.record(.frame(direction: .outbound, type: type, subtype: subtype, bytes: data.count, epoch: epoch, requestID: requestID))
        await capture?.write(line: data, session: sessionID)
        do { try await writer.write(data) } catch { throw WireError.processExited }
    }
    private func writeAnswer(_ id: RequestID, _ answer: InboundAnswer, subtype: String) async throws {
        let frame = answer.controlResponse(for: id)
        let behavior: String = { if case .error = answer { return "error" }; return "success" }()
        diagnostics.record(.answer(requestID: id, subtype: subtype, behavior: behavior, classification: nil, epoch: epoch))
        try await writeLine(try frame.jsonValue.canonicalData(), type: "control_response", subtype: subtype, requestID: id)
    }

    public func send(_ input: UserInput) async throws -> UUID {
        guard status == .running else { throw isExited ? WireError.processExited : WireError.notInRunningState(status) }
        let uuid = UUID()
        try await writeLine(try input.frame(uuid: uuid).canonicalData(), type: "user", subtype: nil, requestID: nil)
        return uuid
    }
    public func send(raw frame: JSONValue) async throws {
        guard status == .running else { throw isExited ? WireError.processExited : WireError.notInRunningState(status) }
        try await writeLine(try frame.canonicalData(), type: frame["type"]?.stringValue ?? "raw", subtype: frame["subtype"]?.stringValue, requestID: nil)
    }
    public func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration? = nil) async throws -> R.Response {
        let body = try await performRequest(spec, timeout: timeout)
        switch body {
        case .error(let e): throw WireError.controlError(e.error)
        case .success(let s):
            if R.Response.self == EmptyResponse.self { return EmptyResponse() as! R.Response }
            return try JSONDecoder().decode(R.Response.self, from: try (s.response ?? .object([:])).canonicalData())
        }
    }
    public func requestRaw(subtype: String, payload: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        try await request(RawControlRequest(subtype: subtype, payload: payload), timeout: timeout)
    }
    /// The waiter is registered BEFORE the request is written, so a response that arrives during the write's suspension
    /// always finds it; every settlement path (response, exit, timeout, cancellation) removes the entry.
    private func performRequest<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> ControlResponseBody {
        guard status == .running else { throw isExited ? WireError.processExited : WireError.notInRunningState(status) }
        let id = RequestID(rawValue: UUID().uuidString.lowercased())
        let wireSubtype = (spec as? RawControlRequest)?.wireSubtype ?? R.subtype
        let waiter = Waiter<ControlResponseBody>()
        pendingOutbound[id] = waiter
        defer { pendingOutbound[id] = nil }
        do { try await writeLine(try OutboundEnvelope.encode(spec: spec, requestID: id), type: "control_request", subtype: wireSubtype, requestID: id) }
        catch { waiter.settle(.failure(error)); throw error }
        let timer = timeout.map { t in waiter.timeout(after: t) { WireError.controlError("timeout after \(t) waiting for \(wireSubtype)") } }
        defer { timer?.cancel() }
        do { return try await waiter.value() }
        catch is CancellationError {
            if OutboundEnvelope.abortableSubtypes.contains(wireSubtype) { await cancel(id) }
            throw CancellationError()
        }
    }
    /// Asks the engine to abort an outbound request. **The engine ignores this frame for every subtype but
    /// `mcp_call` and `side_question`** (`OutboundEnvelope.abortableSubtypes`): only those two register an abort
    /// handler in its stdin loop. For anything else it logs `control_cancel_request for unknown request <id> —
    /// nothing pending, ignoring` and the request runs on to its normal answer, so a caller must not treat this
    /// as a way to stop it. An honoured cancel is itself answered — with an error response for an id this actor
    /// has already forgotten, which `receive(line:)` drops as ordinary traffic.
    public func cancel(_ id: RequestID) async {
        if let line = try? ControlCancelFrame(requestID: id).jsonValueData() {
            try? await writeLine(line, type: "control_cancel_request", subtype: nil, requestID: id)
        }
    }
    public func answer(_ id: RequestID, _ answer: InboundAnswer) async throws {
        guard let request = pendingInbound.removeValue(forKey: id) else { throw WireError.unknownRequest(id) }
        try await writeAnswer(id, answer, subtype: request.subtype)
    }

    // MARK: exit and terminate

    private func processDidExit(_ raw: ExitStatus) async {
        try? await Task.sleep(for: .milliseconds(50))      // let the stderr reader drain the last lines
        let tail = stderrTail()
        let status: ExitStatus = { switch raw { case .code(let c, _): .code(c, stderrTail: tail); case .signal(let sig, _): .signal(sig, stderrTail: tail) } }()
        self.status = .exited(status)
        for (_, w) in pendingOutbound { w.settle(.failure(WireError.processExited)) }; pendingOutbound.removeAll()
        pendingInbound.removeAll()
        for (_, t) in mcpTasks { t.cancel() }; mcpTasks.removeAll()
        handshakeWaiter.settle(.failure(WireError.processExited))
        diagnostics.record(.lifecycle("exited \(status)", epoch: epoch))
        // Read the result rather than trusting ordering: nothing enforces that this push precedes the
        // finish below in some other path, and a dropped `.exited` is a channel FleetKit never releases.
        if await channel.push(.exited(status, epoch)) == false {
            diagnostics.record(.lifecycle("exit event dropped: channel already finished", epoch: epoch))
        }
        await channel.finish()
        for w in exitWaiters { w.settle(.success(status)) }; exitWaiters.removeAll()
        await writer?.close()
    }
    /// nil on timeout; the caller escalates. Never deadlocks: the timeout settles the waiter itself.
    private func waitForExit(upTo timeout: Duration) async -> ExitStatus? {
        if case .exited(let s) = status { return s }
        let w = Waiter<ExitStatus>(); exitWaiters.append(w)
        struct ExitTimeout: Error {}
        let timer = w.timeout(after: timeout) { ExitTimeout() }
        defer { timer.cancel() }
        return try? await w.value()
    }
    /// §6.7 as amended: end_session, close stdin, wait 5 s, SIGTERM, wait 5 s, SIGKILL; returns only after the exit is observed.
    public func terminate() async {
        if isExited { return }
        if terminating { _ = await waitForExit(upTo: .seconds(60)); return }
        terminating = true
        let wasRunning = status == .running
        status = .terminating
        if wasRunning, let writer, let line = try? OutboundEnvelope.encode(spec: EndSession(), requestID: RequestID(rawValue: "end-\(UUID().uuidString.lowercased())")) {
            try? await writer.write(line)
            diagnostics.record(.terminateEscalated(step: "end_session", epoch: epoch))
        }
        await writer?.close()
        diagnostics.record(.terminateEscalated(step: "stdin_closed", epoch: epoch))
        if await waitForExit(upTo: .seconds(5)) != nil { return }
        diagnostics.record(.terminateEscalated(step: "SIGTERM", epoch: epoch))
        box.process.terminate()
        if await waitForExit(upTo: .seconds(5)) != nil { return }
        diagnostics.record(.terminateEscalated(step: "SIGKILL", epoch: epoch))
        kill(box.process.processIdentifier, SIGKILL)
        _ = await waitForExit(upTo: .seconds(30))
    }
}

private extension ControlCancelFrame {
    func jsonValueData() throws -> Data { try JSONValue.object(["type": .string("control_cancel_request"), "request_id": .string(requestID.rawValue)]).canonicalData() }
}

/// One NDJSON line at a time off a pipe. `@unchecked Sendable` is sound because every field is touched only
/// inside `queue`, a serial queue that is the single owner of the handle and the buffer — the same discipline
/// `StdinWriter` uses on the other direction. A caller that stops asking stops reading, which is what turns a
/// full event channel into back-pressure on the child.
private final class LineReader: @unchecked Sendable {
    /// The handle is retained, not just its descriptor: the fd stays valid for the life of this reader even
    /// if the actor that opened the pipe goes away first, so a blocking read can never land on a reused fd.
    private let handle: FileHandle
    private let fd: Int32
    private let queue: DispatchQueue
    private var buffer = Data()
    private var scratch = [UInt8](repeating: 0, count: 65_536)
    private var offset = 0
    private var eof = false
    init(handle: FileHandle, label: String) { self.handle = handle; self.fd = handle.fileDescriptor; self.queue = DispatchQueue(label: label) }

    func next() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            queue.async { [self] in c.resume(returning: readLine()) }
        }
    }
    /// nil only at end of stream. A final line without a trailing newline is still returned.
    private func readLine() -> Data? {
        while true {
            if let i = buffer[offset...].firstIndex(of: 0x0A) {
                let line = Data(buffer[offset..<i])
                offset = i + 1
                if offset == buffer.count { buffer.removeAll(keepingCapacity: true); offset = 0 }
                return line
            }
            if eof {
                guard offset < buffer.count else { return nil }
                let rest = Data(buffer[offset...]); offset = buffer.count
                return rest
            }
            // A direct read(2), not `FileHandle.read(upToCount:)`: on a pipe that call blocks until it has
            // the whole requested count or the writer closes, so a 5 KB handshake frame sat unread until the
            // child exited. read(2) returns as soon as any bytes are there, which is the contract this needs.
            let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if offset > 0 { buffer.removeSubrange(0..<offset); offset = 0 }
                buffer.append(contentsOf: scratch[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                eof = true
            }
        }
    }
}
