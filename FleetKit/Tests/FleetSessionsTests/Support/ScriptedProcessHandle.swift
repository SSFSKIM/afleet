import Foundation
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The handle for the rows no real child can produce: a `terminate()` that answers no exit (wedged), an engine that
/// asks a decision on cue, and a fork whose id resolves onto a collision. Nothing outside ClaudeWire can construct or
/// feed a `WireEventStream`, which is why `ProcessHandle.events` is an existential and this stream is an
/// `AsyncStream` the test holds the continuation of.
final class ScriptedProcessHandle: ProcessHandle, @unchecked Sendable {   // `lock` serialises every field
    let epoch: ProcessEpoch

    private let stream: AsyncStream<WireEvent>
    private let continuation: AsyncStream<WireEvent>.Continuation
    private let lock = NSLock()
    private var _answers: [(id: RequestID, answer: InboundAnswer)] = []
    private var _consumed: [RequestID] = []
    private var _answerError: (any Error)?
    private var _terminateReturns: TerminationReport
    private var _pid: Int32
    private var _session: SessionID?
    private var _spawnCount = 0
    private var _terminateCount = 0
    private var _spawnError: (any Error)?
    private var _initialize: JSONValue = .object([:])
    private var _controlAnswers: [String: JSONValue] = [:]
    private var _controlRequests: [(subtype: String, payload: JSONValue)] = []
    private var _controlGate: (@Sendable (String) async -> Void)?
    private var _spawnGate: (@Sendable () async -> Void)?
    private var _sendGate: (@Sendable () async -> Void)?
    private var _terminateGate: (@Sendable () async -> Void)?
    private var _sent: [(input: UserInput, uuid: UUID)] = []
    private var _pidGate: (@Sendable () async -> Void)?

    init(epoch: ProcessEpoch, session: SessionID?, pid: Int32 = 424_242,
         terminateReturns: TerminationReport = TerminationReport(exit: .code(0, stderrTail: ""), steps: [])) {
        self.epoch = epoch
        self._session = session
        self._pid = pid
        self._terminateReturns = terminateReturns
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - What the test drives

    func push(_ event: WireEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var answers: [(id: RequestID, answer: InboundAnswer)] { locked { _answers } }
    /// Every id `answer` removed, whether the write then succeeded or threw: the contract of `ClaudeProcess.answer`,
    /// which removes `pendingInbound[id]` before it writes.
    var consumed: [RequestID] { lock.lock(); defer { lock.unlock() }; return _consumed }
    var spawnCount: Int { lock.lock(); defer { lock.unlock() }; return _spawnCount }
    /// How many times this handle was asked to terminate. "Nothing terminated" is an assertion several rows make and
    /// it is invisible in the state.
    var terminateCount: Int { lock.lock(); defer { lock.unlock() }; return _terminateCount }

    /// Makes `spawn` throw, which is how a test parks a channel in connecting with no process and no handshake.
    var spawnError: (any Error)? {
        get { lock.lock(); defer { lock.unlock() }; return _spawnError }
        set { lock.lock(); _spawnError = newValue; lock.unlock() }
    }
    var answerError: (any Error)? {
        get { lock.lock(); defer { lock.unlock() }; return _answerError }
        set { lock.lock(); _answerError = newValue; lock.unlock() }
    }
    var terminateReturns: TerminationReport {
        get { lock.lock(); defer { lock.unlock() }; return _terminateReturns }
        set { lock.lock(); _terminateReturns = newValue; lock.unlock() }
    }
    var pid: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _pid }
        set { lock.lock(); _pid = newValue; lock.unlock() }
    }
    var session: SessionID? {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; lock.unlock() }
    }
    /// The body of the initialize response `spawn` answers with, which is where the restart reads the permission
    /// mode, the output style and the fast-mode state back from.
    var initialize: JSONValue {
        get { lock.lock(); defer { lock.unlock() }; return _initialize }
        set { lock.lock(); _initialize = newValue; lock.unlock() }
    }
    /// Wire subtype -> the `response` body the engine answers with. A subtype with no entry answers a bare success,
    /// which is what the engine really sends for `apply_flag_settings` and the setters.
    var controlAnswers: [String: JSONValue] {
        get { lock.lock(); defer { lock.unlock() }; return _controlAnswers }
        set { lock.lock(); _controlAnswers = newValue; lock.unlock() }
    }
    /// Every control request this handle was asked for, in order, with the payload it carried.
    var controlRequests: [(subtype: String, payload: JSONValue)] {
        lock.lock(); defer { lock.unlock() }; return _controlRequests
    }
    /// Awaited inside `request`, before the answer: how a test holds one control answer open while it watches what
    /// the supervisor does — or does not — publish in the meantime.
    var controlGate: (@Sendable (String) async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _controlGate }
        set { lock.lock(); _controlGate = newValue; lock.unlock() }
    }
    /// Awaited inside `spawn`: how a test parks a channel in connecting *with* a live process, the one state a
    /// scripted spawn that throws cannot produce.
    var spawnGate: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _spawnGate }
        set { lock.lock(); _spawnGate = newValue; lock.unlock() }
    }
    /// Awaited inside `send`, before the uuid: how a test holds one turn's write open and asks what the reap and the
    /// eviction make of a channel whose send has started but not finished.
    var sendGate: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sendGate }
        set { lock.lock(); _sendGate = newValue; lock.unlock() }
    }
    /// Awaited inside `terminate`, before the report: how a test parks a reap between taking the channel and ending
    /// the child, which is the window a second action must be refused in.
    var terminateGate: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _terminateGate }
        set { lock.lock(); _terminateGate = newValue; lock.unlock() }
    }
    /// Every input this handle was asked to write, in order.
    var sent: [UserInput] { lock.lock(); defer { lock.unlock() }; return _sent.map(\.input) }
    /// The uuid each of those writes carried onto the wire, in the same order. The frame's own identifier: what
    /// `sendPrompt` answers its caller has to be what appears here, whether the write happened at once or came out
    /// of the queue a handshake later.
    var sentUUIDs: [UUID] { lock.lock(); defer { lock.unlock() }; return _sent.map(\.uuid) }
    /// Awaited inside `childProcessIdentifier`: how a test parks the supervisor on the *first* await after a
    /// handshake — the pid read every post-handshake check begins with — and feeds an exit into that window.
    var pidGate: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _pidGate }
        set { lock.lock(); _pidGate = newValue; lock.unlock() }
    }

    // MARK: - ProcessHandle

    var events: any AsyncSequence<WireEvent, Never> & Sendable { stream }
    var childProcessIdentifier: Int32 {
        get async {
            await locked { _pidGate }?()
            return locked { _pid }
        }
    }
    var sessionID: SessionID? { get async { locked { _session } } }

    func spawn(handshakeTimeout: Duration) async throws -> Handshake {
        let gate = locked { () -> (@Sendable () async -> Void)? in _spawnCount += 1; return _spawnGate }
        // The error is read *after* the gate, so a test that parks a spawn can unwind it deliberately rather than
        // having to resume it into a handshake the channel has already moved past.
        await gate?()
        if let failure = locked({ _spawnError }) { throw failure }
        return Handshake(initialize: InitializeResponse(raw: locked { _initialize }), pending: [])
    }

    func send(_ input: UserInput, uuid: UUID) async throws {
        let gate = locked { () -> (@Sendable () async -> Void)? in _sent.append((input, uuid)); return _sendGate }
        await gate?()
    }

    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response {
        let subtype = (spec as? RawControlRequest)?.wireSubtype ?? R.subtype
        let gate = locked { () -> (@Sendable (String) async -> Void)? in
            _controlRequests.append((subtype, spec.payload)); return _controlGate
        }
        await gate?(subtype)
        // The same decode `ClaudeProcess.request` runs, over the same bare-success default.
        if R.Response.self == EmptyResponse.self { return EmptyResponse() as! R.Response }
        let body = locked { _controlAnswers[subtype] } ?? .object([:])
        return try JSONDecoder().decode(R.Response.self, from: try body.canonicalData())
    }

    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue {
        try await request(RawControlRequest(subtype: subtype, payload: payload), timeout: timeout)
    }

    func answer(_ id: RequestID, _ answer: InboundAnswer) async throws {
        let failure = locked { () -> (any Error)? in
            _consumed.append(id)
            let failure = _answerError
            if failure == nil { _answers.append((id, answer)) }
            return failure
        }
        if let failure { throw failure }
    }

    func terminate() async -> TerminationReport {
        let gate = locked { () -> (@Sendable () async -> Void)? in _terminateCount += 1; return _terminateGate }
        await gate?()
        return locked { _terminateReturns }
    }
}

/// What a test scripts an answer write to fail with.
struct ScriptedWriteFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String = "scripted write failure") { self.description = description }
}
