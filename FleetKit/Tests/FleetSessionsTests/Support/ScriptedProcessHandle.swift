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

    // MARK: - ProcessHandle

    var events: any AsyncSequence<WireEvent, Never> & Sendable { stream }
    var childProcessIdentifier: Int32 { get async { locked { _pid } } }
    var sessionID: SessionID? { get async { locked { _session } } }

    func spawn(handshakeTimeout: Duration) async throws -> Handshake {
        let failure = locked { () -> (any Error)? in _spawnCount += 1; return _spawnError }
        if let failure { throw failure }
        return Handshake(initialize: InitializeResponse(raw: .object([:])), pending: [])
    }

    func send(_ input: UserInput) async throws -> UUID { UUID() }

    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response {
        throw WireError.controlError("the scripted handle answers no control requests")
    }

    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue {
        throw WireError.controlError("the scripted handle answers no control requests")
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

    func terminate() async -> TerminationReport { locked { _terminateCount += 1; return _terminateReturns } }
}

/// What a test scripts an answer write to fail with.
struct ScriptedWriteFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String = "scripted write failure") { self.description = description }
}
