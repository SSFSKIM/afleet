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
    private var _capDecisions: [String] = []
    private var _wireSteps: [String] = []

    init() {}

    var transitions: [Observed] { lock.lock(); defer { lock.unlock() }; return _transitions }
    var notInTable: [Observed] { lock.lock(); defer { lock.unlock() }; return _notInTable }
    var answerWriteFailures: [(id: String, reason: String)] { lock.lock(); defer { lock.unlock() }; return _answerWriteFailures }
    var wedged: [(session: String, steps: Int)] { lock.lock(); defer { lock.unlock() }; return _wedged }
    var capDecisions: [String] { lock.lock(); defer { lock.unlock() }; return _capDecisions }
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
        case let .capDecision(decision, _, _):
            _capDecisions.append(decision)
        default:
            break
        }
    }

    func record(_ event: DiagnosticEvent) {
        guard case let .terminateEscalated(step, _) = event else { return }
        lock.lock(); _wireSteps.append(step); lock.unlock()
    }
}
