import Foundation
import AfleetCore
import ClaudeWire

/// What the supervisor needs from a process. The live conformance is `LiveProcessHandle`, a thin wrapper over
/// `ClaudeProcess`; the seam exists so the one row no real child can produce (wedged: a `TerminationReport` whose
/// `exit` is `nil`), the decision tests and the fork collision run against a scripted handle. `events` is an
/// existential because ClaudeWire's `WireEventStream` has an internal initialiser and can be neither constructed nor
/// fed outside its module (`BoundedChannel.swift:108-118`); its failure type is `Never` because the stream's `next()`
/// does not throw.
public protocol ProcessHandle: Sendable {
    var epoch: ProcessEpoch { get }
    var events: any AsyncSequence<WireEvent, Never> & Sendable { get }
    var childProcessIdentifier: Int32 { get async }
    var sessionID: SessionID? { get async }
    func spawn(handshakeTimeout: Duration) async throws -> Handshake
    func send(_ input: UserInput) async throws -> UUID
    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response
    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue
    func answer(_ id: RequestID, _ answer: InboundAnswer) async throws
    /// The exit plus this epoch's escalation steps. A `nil` exit is the wedged row.
    func terminate() async -> TerminationReport
}

/// The live conformance. A retroactive `extension ClaudeProcess: ProcessHandle {}` cannot witness the existential
/// `events` with the actor's concrete `WireEventStream<WireEvent>`, so this wrapper forwards every member and exposes
/// the very same stream value as the existential: ClaudeWire's bounded channel and its backpressure are untouched,
/// nothing is re-pumped.
public final class LiveProcessHandle: ProcessHandle {
    public let process: ClaudeProcess
    /// The sink the factory passed as `ClaudeProcess.init(diagnostics:)`; the only place the escalation steps exist.
    public let diagnostics: CapturingDiagnostics
    /// The same value the factory handed `ClaudeProcess.init`. Held here because an actor's stored `let` is still
    /// isolated, and the supervisor reads the epoch synchronously on every event.
    public let epoch: ProcessEpoch

    public init(_ process: ClaudeProcess, epoch: ProcessEpoch, diagnostics: CapturingDiagnostics) {
        self.process = process; self.epoch = epoch; self.diagnostics = diagnostics
    }
    public var events: any AsyncSequence<WireEvent, Never> & Sendable { process.events }
    public var childProcessIdentifier: Int32 { get async { await process.childProcessIdentifier } }
    public var sessionID: SessionID? { get async { await process.sessionID } }

    public func spawn(handshakeTimeout: Duration) async throws -> Handshake {
        try await process.spawn(handshakeTimeout: handshakeTimeout)
    }
    public func send(_ input: UserInput) async throws -> UUID { try await process.send(input) }
    public func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response {
        try await process.request(spec, timeout: timeout)
    }
    public func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue {
        try await process.requestRaw(subtype: subtype, payload: payload, timeout: timeout)
    }
    public func answer(_ id: RequestID, _ answer: InboundAnswer) async throws {
        try await process.answer(id, answer)
    }
    public func terminate() async -> TerminationReport {
        TerminationReport(exit: await process.terminate(), steps: diagnostics.steps(for: epoch))
    }
}

/// Installed by every `ProcessFactory` — production and the test rig's — as `ClaudeProcess.init`'s `diagnostics:`
/// argument. Forwards every event to the fleet's ClaudeWire sink and keeps the `step` of each
/// `.terminateEscalated(step:epoch:)` under its epoch. `ClaudeProcess.terminate()` returns only `ExitStatus?`, so the
/// steps exist nowhere else; a factory that passes `NullDiagnostics` or the fleet's sink straight to `ClaudeProcess`
/// leaves the wedged row's trace empty.
public final class CapturingDiagnostics: DiagnosticsSink, @unchecked Sendable {   // `lock` serialises `captured`
    private let forward: any DiagnosticsSink
    private let lock = NSLock()
    private var captured: [ProcessEpoch: [String]] = [:]

    public init(forwardingTo sink: any DiagnosticsSink) { self.forward = sink }

    public func record(_ event: DiagnosticEvent) {
        if case let .terminateEscalated(step, epoch) = event {
            lock.lock(); captured[epoch, default: []].append(step); lock.unlock()
        }
        forward.record(event)
    }

    /// The steps recorded for one epoch, in the order they were recorded.
    public func steps(for epoch: ProcessEpoch) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return captured[epoch] ?? []
    }
}

public typealias ProcessFactory = @Sendable (ProcessEpoch, LaunchConfiguration) -> any ProcessHandle
