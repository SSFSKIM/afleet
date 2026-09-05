import Foundation
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The rig's sink. It is both FleetKit's `FleetDiagnosticsSink` — where the `(row, from, event, to)` transitions land —
/// and ClaudeWire's `DiagnosticsSink`, which is what a `CapturingDiagnostics` forwards to in production.
final class RecordingDiagnostics: FleetDiagnosticsSink, DiagnosticsSink, @unchecked Sendable {   // `lock` serialises every array
    /// One transition as the supervisor recorded it, in the vocabulary the sink speaks: strings, never enum values,
    /// so what a test declares is compared against what was written rather than against what it meant.
    struct Observed: Hashable, Sendable {
        let row: String, from: String, event: String, to: String
        init(row: String, from: String, event: String, to: String) {
            self.row = row; self.from = from; self.event = event; self.to = to
        }
        init(_ t: LifecycleTable.Transition) {
            self.init(row: t.row.rawValue, from: t.from.rawValue, event: t.event.diagnosticName, to: t.to.rawValue)
        }
    }

    private let lock = NSLock()
    private var _transitions: [Observed] = []
    private var _notInTable: [Observed] = []
    private var _answerWriteFailures: [(id: String, reason: String)] = []
    private var _wedged: [(session: String, steps: Int)] = []
    private var _capDecisions: [(decision: String, live: Int, reserved: Int, pendingEvictions: Int)] = []
    private var _evictions: [(outcome: String, victim: String)] = []
    private var _paneRequests: [(id: UUID, purpose: String)] = []
    private var _staleExits: [UUID] = []
    private var _jobNotListed: [String] = []
    private var _handoffWaits: [(outcome: String, waitedMs: Int)] = []
    private var _wireSteps: [String] = []
    private var _forkIdentityDeadlines: [String] = []

    init() {}

    var transitions: [Observed] { lock.lock(); defer { lock.unlock() }; return _transitions }
    var notInTable: [Observed] { lock.lock(); defer { lock.unlock() }; return _notInTable }
    var answerWriteFailures: [(id: String, reason: String)] { lock.lock(); defer { lock.unlock() }; return _answerWriteFailures }
    var wedged: [(session: String, steps: Int)] { lock.lock(); defer { lock.unlock() }; return _wedged }
    var capDecisions: [(decision: String, live: Int, reserved: Int, pendingEvictions: Int)] {
        lock.lock(); defer { lock.unlock() }; return _capDecisions
    }
    var evictions: [(outcome: String, victim: String)] { lock.lock(); defer { lock.unlock() }; return _evictions }
    var paneRequests: [(id: UUID, purpose: String)] { lock.lock(); defer { lock.unlock() }; return _paneRequests }
    var staleExits: [UUID] { lock.lock(); defer { lock.unlock() }; return _staleExits }
    var jobNotListed: [String] { lock.lock(); defer { lock.unlock() }; return _jobNotListed }
    var handoffWaits: [(outcome: String, waitedMs: Int)] { lock.lock(); defer { lock.unlock() }; return _handoffWaits }
    /// Every fork whose identity deadline expired, by session.
    var forkIdentityDeadlines: [String] { lock.lock(); defer { lock.unlock() }; return _forkIdentityDeadlines }
    /// Every `terminate_escalated` step ClaudeWire reported through the capturing sink.
    var wireEscalationSteps: [String] { lock.lock(); defer { lock.unlock() }; return _wireSteps }

    /// The arrange/act boundary. A row test that has to build a ready or dormant channel before it can drive its own
    /// row forgets the arranging transitions here, so `assertObserved` still compares exactly.
    func forgetTransitions() { lock.lock(); _transitions = []; _notInTable = []; lock.unlock() }

    func record(_ event: FleetDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .transition(row, from, transitionEvent, to, _, _):
            _transitions.append(Observed(row: row, from: from, event: transitionEvent, to: to))
        case let .transitionNotInTable(transitionEvent, from, to, _):
            _notInTable.append(Observed(row: "-", from: from, event: transitionEvent, to: to))
        case let .answerWriteFailed(id, reason):
            _answerWriteFailures.append((id.rawValue, reason))
        case let .wedged(session, steps):
            _wedged.append((session, steps))
        case let .capDecision(decision, live, reserved, pendingEvictions):
            _capDecisions.append((decision, live, reserved, pendingEvictions))
        case let .evictionOutcome(outcome, victim):
            _evictions.append((outcome, victim))
        case let .paneRequest(id, purpose, _):
            _paneRequests.append((id, purpose))
        case let .staleExit(id, _):
            _staleExits.append(id)
        case let .jobNotListedAfterBackground(session):
            _jobNotListed.append(session)
        case let .handoffWait(outcome, waitedMs, _):
            _handoffWaits.append((outcome, waitedMs))
        case let .forkIdentityDeadlineExpired(session, _):
            _forkIdentityDeadlines.append(session)
        default:
            break
        }
    }

    func record(_ event: DiagnosticEvent) {
        guard case let .terminateEscalated(step, _) = event else { return }
        lock.lock(); _wireSteps.append(step); lock.unlock()
    }
}
