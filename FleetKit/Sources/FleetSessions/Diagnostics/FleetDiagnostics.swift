import Foundation
import WireFrames

/// FleetKit's own diagnostics vocabulary, one JSON line per event in the app's diagnostics directory beside C2's file.
/// Structural fields only: names, counts, ids, epochs, durations. Never a path under a config home, an environment,
/// a record or stdout (parent §6.3). `WireDiagnostics.DiagnosticEvent` is closed and owned by C2, so FleetKit keeps
/// its own closed enumeration here and writes the same one-line JSON shape.
public enum FleetDiagnosticEvent: Sendable {
    /// The (row, from, event, to) the rig's RecordingDiagnostics collects.
    case transition(row: String, from: String, event: String, to: String, session: String, epoch: UInt64?)
    case transitionNotInTable(event: String, from: String, to: String, session: String)
    case ownershipCheck(label: String, foreignHolders: Int, session: String)
    case handoffWait(outcome: String, waitedMs: Int, session: String)
    case verb(name: String, exitCode: Int32, durationMs: Int)
    case precondition(verdict: String, session: String)
    case declineWrite(outcome: String, servers: Int)
    case paneRequest(id: UUID, purpose: String, session: String?)
    case staleExit(id: UUID, purpose: String)
    case jobNotListedAfterBackground(session: String)
    case wedged(session: String, steps: Int)
    /// A fork's engine never announced an id within the supervisor's deadline. The child is ended and the slot goes
    /// back; without this the failure had no record, no banner and no item, and the user was left on the connecting
    /// glyph with nothing said.
    case forkIdentityDeadlineExpired(session: String, epoch: UInt64)
    /// Liveness fell back to the `startedAt` window because the record carried no `procStart`.
    case procStartAbsent(pid: Int32)
    /// Liveness fell back to the `startedAt` window because the record's `procStart` did not parse.
    case procStartUnparseable(pid: Int32)
    /// `kill(pid, 0)` said live but `proc_pidinfo` refused, so the pid counts as a holder with nothing compared.
    case startTimeUnreadable(pid: Int32)
    /// `live` is every slot holding a process — a live channel, a ghost, or a victim whose eviction has not
    /// completed. `pendingEvictions` is how many of those are victims, and each of those is the slot one of the
    /// `reserved` claims is waiting for: the incoming process replaces the victim's rather than joining it. So the
    /// occupancy a decision was taken against is `live + reserved - pendingEvictions`, and that is what the cap
    /// bounds. Three numbers rather than two, because the invariant cannot be stated from any two of them.
    case capDecision(decision: String, live: Int, reserved: Int, pendingEvictions: Int)
    case evictionOutcome(outcome: String, victim: String)
    case logout(step: String, count: Int)
    case driftRefusalIntercepted(command: String)
    /// The engine write behind an answer failed; the id is consumed.
    case answerWriteFailed(id: RequestID, reason: String)

    /// The event's name and its structural fields, keys in snake_case. Nothing here may carry a payload.
    public var jsonValue: JSONValue {
        switch self {
        case let .transition(row, from, event, to, session, epoch):
            var o: [String: JSONValue] = ["event": .string("transition"), "row": .string(row), "from": .string(from),
                                          "transition_event": .string(event), "to": .string(to), "session": .string(session)]
            if let epoch { o["epoch"] = .integer(Int64(epoch)) }
            return .object(o)
        case let .transitionNotInTable(event, from, to, session):
            return .object(["event": .string("transition_not_in_table"), "transition_event": .string(event),
                            "from": .string(from), "to": .string(to), "session": .string(session)])
        case let .ownershipCheck(label, foreignHolders, session):
            return .object(["event": .string("ownership_check"), "label": .string(label),
                            "foreign_holders": .integer(Int64(foreignHolders)), "session": .string(session)])
        case let .handoffWait(outcome, waitedMs, session):
            return .object(["event": .string("handoff_wait"), "outcome": .string(outcome),
                            "waited_ms": .integer(Int64(waitedMs)), "session": .string(session)])
        case let .verb(name, exitCode, durationMs):
            return .object(["event": .string("cli_verb"), "verb": .string(name),
                            "exit_code": .integer(Int64(exitCode)), "duration_ms": .integer(Int64(durationMs))])
        case let .precondition(verdict, session):
            return .object(["event": .string("precondition"), "verdict": .string(verdict), "session": .string(session)])
        case let .declineWrite(outcome, servers):
            return .object(["event": .string("decline_write"), "outcome": .string(outcome),
                            "servers": .integer(Int64(servers))])
        case let .paneRequest(id, purpose, session):
            var o: [String: JSONValue] = ["event": .string("pane_request"), "id": .string(id.uuidString),
                                          "purpose": .string(purpose)]
            if let session { o["session"] = .string(session) }
            return .object(o)
        case let .staleExit(id, purpose):
            return .object(["event": .string("stale_exit"), "id": .string(id.uuidString), "purpose": .string(purpose)])
        case let .jobNotListedAfterBackground(session):
            return .object(["event": .string("job_not_listed_after_background"), "session": .string(session)])
        case let .wedged(session, steps):
            return .object(["event": .string("wedged"), "session": .string(session), "steps": .integer(Int64(steps))])
        case let .forkIdentityDeadlineExpired(session, epoch):
            return .object(["event": .string("fork_identity_deadline_expired"), "session": .string(session),
                            "epoch": .integer(Int64(epoch))])
        case let .procStartAbsent(pid):
            return .object(["event": .string("proc_start_absent"), "pid": .integer(Int64(pid))])
        case let .procStartUnparseable(pid):
            return .object(["event": .string("proc_start_unparseable"), "pid": .integer(Int64(pid))])
        case let .startTimeUnreadable(pid):
            return .object(["event": .string("start_time_unreadable"), "pid": .integer(Int64(pid))])
        case let .capDecision(decision, live, reserved, pendingEvictions):
            return .object(["event": .string("cap_decision"), "decision": .string(decision),
                            "live": .integer(Int64(live)), "reserved": .integer(Int64(reserved)),
                            "pending_evictions": .integer(Int64(pendingEvictions))])
        case let .evictionOutcome(outcome, victim):
            return .object(["event": .string("eviction_outcome"), "outcome": .string(outcome), "victim": .string(victim)])
        case let .logout(step, count):
            return .object(["event": .string("logout"), "step": .string(step), "count": .integer(Int64(count))])
        case let .driftRefusalIntercepted(command):
            return .object(["event": .string("drift_refusal_intercepted"), "command": .string(command)])
        case let .answerWriteFailed(id, reason):
            return .object(["event": .string("answer_write_failed"), "id": .string(id.rawValue), "reason": .string(reason)])
        }
    }
}

public protocol FleetDiagnosticsSink: Sendable {
    func record(_ event: FleetDiagnosticEvent)
}

/// The sink for every caller that does not want the events. Task 9 adds the file sink.
public struct NullFleetDiagnostics: FleetDiagnosticsSink {
    public init() {}
    public func record(_ event: FleetDiagnosticEvent) {}
}
