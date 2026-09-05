import Foundation
import AfleetCore

/// What the supervisor knows about a channel it owns. The resolver cannot see inside a `ChannelSupervisor`, so the
/// supervisor hands it this much and no more.
public struct OwnedView: Hashable, Sendable {
    /// Which owned state the supervisor is in; `.contended` is X2's Contended.
    public var state: ChannelOrigin.OwnedState
    /// A send is outstanding and its `result` has not arrived.
    public var turnRunning: Bool
    /// The count of `ChannelState.pendingDecisions`.
    public var pendingDecisions: Int
    /// A `session_state_changed` frame carried `requires_action`.
    public var sessionStateRequiresAction: Bool

    public init(state: ChannelOrigin.OwnedState, turnRunning: Bool = false, pendingDecisions: Int = 0,
                sessionStateRequiresAction: Bool = false) {
        self.state = state; self.turnRunning = turnRunning; self.pendingDecisions = pendingDecisions
        self.sessionStateRequiresAction = sessionStateRequiresAction
    }
}

/// Holders plus what the supervisor knows, in the parent's precedence: owned, foreign, job, archived.
public enum OriginResolver {
    /// `holders` are the live holders of `key.session`, already filtered by `HolderReader`. Every holder is
    /// classified by its own evidence — `Holder.isJob` — and never by which branch happens to run first, so a
    /// conversation job's worker, present in both the registry and the roster, is a job and not a foreign terminal.
    public static func resolve(key: ChannelKey, ownedState: OwnedView?, holders: [Holder],
                               pendingHatch: Bool) -> (ChannelOrigin, Presence) {
        if let owned = ownedState { return (.owned(owned.state), presence(of: owned)) }

        let live = holders.filter { $0.sessionID == key.session }
        // A holder that is ours while no supervisor owns the channel is Contended, not foreign live.
        if let ours = live.first(where: { $0.isOwnChild }) {
            return (.owned(.contended), presence(of: ours.presence))
        }
        if let foreign = live.first(where: { !$0.isJob }) {
            return (.foreignLive(pendingHatch ? .ownTerminalTab : .usersTerminal), presence(of: foreign.presence))
        }
        if let job = live.first(where: { $0.isJob }) {
            return (.backgroundJob, presence(of: job.presence))
        }
        return (.archived, .unknown)
    }

    /// A pending decision is the more specific fact than a running turn: the turn is stalled on the user, and that
    /// is what the sidebar has to show.
    private static func presence(of owned: OwnedView) -> Presence {
        if owned.pendingDecisions > 0 || owned.sessionStateRequiresAction { return .waiting(for: nil) }
        if owned.turnRunning { return .busy }
        return .idle
    }

    /// A foreign holder's presence is whatever its own record says, and `.unknown` when it says nothing — which is
    /// every headless holder.
    ///
    /// The registry's `status` vocabulary is `busy` / `shell` / `idle` / `waiting` (parity
    /// `docs/tui-parity/areas/50-36-39-38-notifications-remote-teams-daemon.md:407`, SPEC §38.18.1); a TUI running
    /// a shell command is busy. The job states (`working`, `blocked`, …) are not in it: they live in `state`, and
    /// nothing builds a `ForeignPresence` from `state`.
    private static func presence(of foreign: ForeignPresence?) -> Presence {
        guard let foreign else { return .unknown }
        switch foreign.status {
        case "busy", "shell": return .busy
        case "idle": return .idle
        case "waiting": return .waiting(for: foreign.waitingFor)
        default: return .unknown
        }
    }
}
