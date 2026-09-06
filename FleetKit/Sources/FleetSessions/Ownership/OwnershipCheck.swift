import Foundation
import AfleetCore
import ClaudeWire

/// Which check a `HolderReader.read` is serving. The label is an explicit argument threaded from the check through
/// `FleetObserver` to the reader: G1's proof that the ownership checks ran around every spawn is the label sequence,
/// and ambient context that can silently go blank is not good enough for that.
public enum OwnershipLabel {
    public static let beforeSpawn = "beforeSpawn"
    public static let afterHandshake = "afterHandshake"
    public static let release = "release"
    /// The label a read carries when no check asked for it: the observer's own poll or reconciliation.
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
    /// Runs once, on the actor of the caller, at the moment `awaitRelease` has observed `.released` and before the
    /// caller's recheck. nil in production; the preempt rows use it to make a holder appear in exactly that window.
    private let onReleased: (@Sendable () async -> Void)?

    public init(observer: FleetObserver, clock: any Clock<Duration>,
                diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics(),
                onReleased: (@Sendable () async -> Void)? = nil) {
        self.observer = observer; self.clock = clock; self.diagnostics = diagnostics
        self.onReleased = onReleased
    }

    /// Every live holder naming the session, foreign or ours. A holder that is one of our own children — a second
    /// supervisor's, or an older epoch's ghost — is returned too, and the caller reads it as Contended rather than
    /// as a foreign live channel.
    public func beforeSpawn(session: SessionID) async -> [Holder] {
        let holders = await reconcile(label: OwnershipLabel.beforeSpawn).filter { $0.sessionID == session }
        record(OwnershipLabel.beforeSpawn, holders, session)
        return holders
    }

    /// Every live holder naming the session except the one pid this spawn started.
    public func afterHandshake(session: SessionID, ownPID: Int32, epoch: ProcessEpoch) async -> [Holder] {
        _ = epoch
        let holders = await reconcile(label: OwnershipLabel.afterHandshake)
            .filter { $0.sessionID == session && $0.pid != ownPID }
            // Re-validated here as well as in the read: the record may name a pid that died between the two. The
            // question is liveness alone, so it is `kill(pid, 0)`: a live pid the kernel will not describe is still
            // a holder, and dropping it here would be the unsafe direction.
            .filter { ProcessLiveness.isRunning(pid: $0.pid) }
        record(OwnershipLabel.afterHandshake, holders, session)
        return holders
    }

    /// Rule 5's quiescent handoff. `.released` only when the pid is dead *and* the record that named it is gone;
    /// `.timedOut` after `upTo`, on which the channel becomes Contended.
    /// How often the wait re-reads. Public so a test that drives the manual clock steps by the wait's own interval
    /// rather than by a number it invented.
    public static let releasePollInterval = Duration.milliseconds(500)

    public func awaitRelease(previous: Holder, upTo budget: Duration) async -> ReleaseOutcome {
        let interval = Self.releasePollInterval
        var waited = Duration.zero
        while true {
            let holders = await reconcile(label: OwnershipLabel.release)
            let recordGone = !holders.contains { $0.pid == previous.pid && $0.sessionID == previous.sessionID }
            if recordGone && !ProcessLiveness.isRunning(pid: previous.pid) {
                diagnostics.record(.handoffWait(outcome: "released", waitedMs: milliseconds(waited),
                                                session: previous.sessionID.description))
                await onReleased?()
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
        await observer.reconcileNow(label: label).holders
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
