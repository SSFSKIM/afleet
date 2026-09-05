import Foundation
import AfleetCore
import ClaudeWire

/// Which check a `HolderReader.read` is serving. It travels as a task-local rather than as a parameter because
/// `HolderReader.read` is C4's published protocol and a Swift protocol requirement may carry no default argument:
/// adding a label to the requirement would have rewritten every conformance and every call site of Task 3's reader
/// for a value only the recording reader in the tests ever looks at.
public enum OwnershipLabel {
    @TaskLocal public static var current: String?
    /// The label a read carries when no check set one: the observer's own poll or reconciliation.
    public static let poll = "poll"
}

/// What the release wait observed.
public enum ReleaseOutcome: Hashable, Sendable { case released, timedOut }

/// The two checks that bracket every spawn, and the quiescent handoff's wait.
///
/// Neither check reads `Holder.isOwnChild` to excuse a holder: that flag is informational for the sidebar. The
/// pre-spawn check refuses every live holder, our own children included, because before a spawn this supervisor
/// holds no process and so has no pid to excuse. The post-handshake check excludes exactly one pid — the child this
/// spawn started — and treats any other pid, foreign or ours, as a holder.
public struct OwnershipCheck: Sendable {
    private let observer: FleetObserver
    private let clock: any Clock<Duration>
    private let diagnostics: any FleetDiagnosticsSink

    public init(observer: FleetObserver, clock: any Clock<Duration>,
                diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()) {
        self.observer = observer; self.clock = clock; self.diagnostics = diagnostics
    }

    /// Every live holder naming the session, foreign or ours. A holder that is one of our own children — a second
    /// supervisor's, or an older epoch's ghost — is returned too, and the caller reads it as Contended rather than
    /// as a foreign live channel.
    public func beforeSpawn(session: SessionID) async -> [Holder] {
        let holders = await reconcile(label: "beforeSpawn").filter { $0.sessionID == session }
        record("beforeSpawn", holders, session)
        return holders
    }

    /// Every live holder naming the session except the one pid this spawn started.
    public func afterHandshake(session: SessionID, ownPID: Int32, epoch: ProcessEpoch) async -> [Holder] {
        _ = epoch
        let holders = await reconcile(label: "afterHandshake")
            .filter { $0.sessionID == session && $0.pid != ownPID }
            // Re-validated here as well as in the read: the record may name a pid that died between the two.
            .filter { ProcessLiveness.startTime(of: $0.pid) != nil }
        record("afterHandshake", holders, session)
        return holders
    }

    /// Rule 5's quiescent handoff. `.released` only when the pid is dead *and* the record that named it is gone;
    /// `.timedOut` after `upTo`, on which the channel becomes Contended.
    public func awaitRelease(previous: Holder, upTo budget: Duration) async -> ReleaseOutcome {
        let interval = Duration.milliseconds(500)
        var waited = Duration.zero
        while true {
            let holders = await reconcile(label: "release")
            let recordGone = !holders.contains { $0.pid == previous.pid && $0.sessionID == previous.sessionID }
            if recordGone && ProcessLiveness.startTime(of: previous.pid) == nil {
                diagnostics.record(.handoffWait(outcome: "released", waitedMs: milliseconds(waited),
                                                session: previous.sessionID.description))
                return .released
            }
            if waited >= budget {
                diagnostics.record(.handoffWait(outcome: "timedOut", waitedMs: milliseconds(waited),
                                                session: previous.sessionID.description))
                return .timedOut
            }
            guard (try? await clock.sleep(for: interval)) != nil else { return .timedOut }
            waited += interval
        }
    }

    // MARK: - Internals

    private func reconcile(label: String) async -> [Holder] {
        await OwnershipLabel.$current.withValue(label) {
            await observer.reconcileNow().holders
        }
    }

    /// The count is every holder the check is about to hand back, not only the foreign ones: the pre-spawn check
    /// refuses our own children too, so "how many holders did this check find" is the number worth recording.
    private func record(_ label: String, _ holders: [Holder], _ session: SessionID) {
        diagnostics.record(.ownershipCheck(label: label, foreignHolders: holders.count,
                                           session: session.description))
    }

    private func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
