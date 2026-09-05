import Foundation

/// The parent's §7.4 table as data. `scenarios` enumerates every `(row, from, event, to)` the supervisor may take, one per
/// from-state a row admits and per outcome it can reach; it is what G1's coverage asserts over and what the supervisor
/// consults before every transition, so a transition not in the table is a diagnostic, never a silent change.
public enum LifecycleTable {
    public enum Row: String, CaseIterable, Hashable, Sendable {
        case archivedRecentOpened, archivedOlderOpened, archivedOlderSent
        case connectingClean, connectingFoundHolder
        case readyDormantEligible, readyExitedClean, dormantSent, dormantHolderAppeared
        case terminateExhausted, exitedNonZero, capReached, handoffPreempted
        case jobAdopt, ownedSendToBackground, ownedOpenInTerminal, ownTabExited
        case foreignRecordGone, foreignSendRefused, handoffTimedOut, desiredObservedDisagree, contendedSettled
    }
    /// Every path that calls `terminateOrWedge()`; the wedged row has one scenario per action so G1 injects the `nil`
    /// through each. `postHandshakeYield` is the yield the parent's "Owned, any" wedged row already covers — Owned-connecting
    /// is one of the states "any" admits — and which this enumeration used to omit.
    /// It also names a fork's identity-deadline expiry, which yields from the same state for the same reason: a
    /// handshake that cannot be finished, ended from Owned-connecting.
    public enum TerminatingAction: String, CaseIterable, Hashable, Sendable {
        case reap, sendToBackground, openInTerminal, restart, logout, capEviction, postHandshakeYield
    }
    public enum Event: Hashable, Sendable {
        case opened, userSent, handshakeClean, handshakeFoundHolder, dormantTimerFired, holderAppeared, exitedClean
        case terminateReturnedNil(during: TerminatingAction), exitedNonZero, seventhSpawnNeeded, adopt, sendToBackground, openInTerminal
        case paneExitedAndRecordGone, recordDisappeared, sendRefused, handoffTimedOut, desiredObservedDisagree, holdersSettled, holderAppearedBeforeLaunch
    }
    /// The names the table speaks in; `ChannelState.name` maps a state to one of these. No wildcard: every scenario is concrete.
    public enum StateName: String, Hashable, Sendable {
        case archivedRecent, archivedOlder, connecting, ready, dormant, wedged, backgroundJob, foreignUsersTerminal, foreignOwnTab, contended
    }
    public struct Transition: Hashable, Sendable {
        public let row: Row; public let from: StateName; public let event: Event; public let to: StateName
        public init(_ row: Row, _ from: StateName, _ event: Event, _ to: StateName) { self.row = row; self.from = from; self.event = event; self.to = to }
    }
    public static let scenarios: [Transition] = [
        .init(.archivedRecentOpened, .archivedRecent, .opened, .connecting),
        .init(.archivedOlderOpened, .archivedOlder, .opened, .archivedOlder),
        .init(.archivedOlderSent, .archivedOlder, .userSent, .connecting),
        .init(.connectingClean, .connecting, .handshakeClean, .ready),
        .init(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .foreignUsersTerminal),   // a foreign holder: yield, released notice
        .init(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .contended),              // one of our own pids: yield, contended
        .init(.readyDormantEligible, .ready, .dormantTimerFired, .dormant),
        // A child that ended on its own with a clean status is not a crash and carries no item: the channel simply
        // has no process any more, and dormant is where a processless owned channel rests.
        .init(.readyExitedClean, .ready, .exitedClean, .dormant),
        .init(.dormantSent, .dormant, .userSent, .connecting),
        // The row fires from every state in which afleet holds no process of its own, not from dormant alone: a
        // channel registered from C3's index has never been opened and is archived, and a holder appearing against
        // it is the same fact. The row keeps its name because `dormant` is where it was first enumerated; the three
        // from-states below are what it actually admits.
        .init(.dormantHolderAppeared, .dormant, .holderAppeared, .foreignUsersTerminal),
        .init(.dormantHolderAppeared, .dormant, .holderAppeared, .backgroundJob),
        .init(.dormantHolderAppeared, .archivedRecent, .holderAppeared, .foreignUsersTerminal),
        .init(.dormantHolderAppeared, .archivedRecent, .holderAppeared, .backgroundJob),
        .init(.dormantHolderAppeared, .archivedOlder, .holderAppeared, .foreignUsersTerminal),
        .init(.dormantHolderAppeared, .archivedOlder, .holderAppeared, .backgroundJob),
    ] + TerminatingAction.allCases.flatMap { action -> [Transition] in
        // A dormant channel holds no process, so the terminating actions run from ready; a restart or a logout can
        // also catch a handshake, and the post-handshake yield fires *only* from connecting — `handshakeFoundHolder`
        // exists nowhere else — so it is one scenario, before the contended/foreign branch, and never a ready one.
        let event = Event.terminateReturnedNil(during: action)
        switch action {
        case .postHandshakeYield:
            return [Transition(.terminateExhausted, .connecting, event, .wedged)]
        case .restart, .logout:
            return [Transition(.terminateExhausted, .ready, event, .wedged),
                    Transition(.terminateExhausted, .connecting, event, .wedged)]
        case .reap, .sendToBackground, .openInTerminal, .capEviction:
            return [Transition(.terminateExhausted, .ready, event, .wedged)]
        }
    } + [
        .init(.exitedNonZero, .ready, .exitedNonZero, .connecting),          // crash after ready: respawn with backoff
        .init(.exitedNonZero, .connecting, .exitedNonZero, .connecting),     // crash during the handshake: respawn with backoff
        // Crash exhaustion rests where a processless owned channel rests. A series that had reached ready owns the
        // session and rests dormant, from ready and from connecting alike; one that never did has nothing owned to
        // rest on and is archived. The crash item with *Reopen* rides on all three.
        .init(.exitedNonZero, .ready, .exitedNonZero, .dormant),             // fourth crash from ready: item with Reopen
        .init(.exitedNonZero, .connecting, .exitedNonZero, .dormant),        // fourth crash mid-handshake of a series that had been ready
        .init(.exitedNonZero, .connecting, .exitedNonZero, .archivedOlder),  // fourth crash of a channel never ready in this series
        .init(.capReached, .ready, .seventhSpawnNeeded, .dormant),           // the victim; a refusal is no transition (header note only)
        .init(.jobAdopt, .backgroundJob, .adopt, .connecting),
        .init(.ownedSendToBackground, .ready, .sendToBackground, .backgroundJob),
        .init(.ownedSendToBackground, .dormant, .sendToBackground, .backgroundJob),
        .init(.ownedOpenInTerminal, .ready, .openInTerminal, .foreignOwnTab),
        .init(.ownedOpenInTerminal, .dormant, .openInTerminal, .foreignOwnTab),
        .init(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .foreignUsersTerminal),   // a holder appeared between the release and the launch: no verb, no request
        .init(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .backgroundJob),
        .init(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .contended),               // the holder carries an own pid
        .init(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .foreignUsersTerminal), // from dormant there is no process and no wait: the recheck is the only check
        .init(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .backgroundJob),
        .init(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .contended),
        .init(.ownTabExited, .foreignOwnTab, .paneExitedAndRecordGone, .connecting),
        .init(.foreignRecordGone, .foreignUsersTerminal, .recordDisappeared, .archivedRecent),
        .init(.foreignSendRefused, .foreignUsersTerminal, .sendRefused, .foreignUsersTerminal),
        .init(.handoffTimedOut, .backgroundJob, .handoffTimedOut, .contended),        // adopt: the job did not leave
        .init(.handoffTimedOut, .ready, .handoffTimedOut, .contended),                // send to background / open in terminal: our record did not leave
        .init(.handoffTimedOut, .dormant, .handoffTimedOut, .contended),
        .init(.handoffTimedOut, .foreignOwnTab, .handoffTimedOut, .contended),        // pane exit: the tab's record did not leave
        .init(.desiredObservedDisagree, .connecting, .desiredObservedDisagree, .contended),
        .init(.desiredObservedDisagree, .ready, .desiredObservedDisagree, .contended),
        .init(.desiredObservedDisagree, .dormant, .desiredObservedDisagree, .contended),
        .init(.contendedSettled, .contended, .holdersSettled, .archivedRecent),
        // Archived-older is a matching origin too: the parent's row is "the matching origin", and a channel nobody
        // holds and afleet holds no process for is archived — recent or not, depending on the flag it already had.
        .init(.contendedSettled, .contended, .holdersSettled, .archivedOlder),
        .init(.contendedSettled, .contended, .holdersSettled, .ready),
        .init(.contendedSettled, .contended, .holdersSettled, .dormant),
        .init(.contendedSettled, .contended, .holdersSettled, .foreignUsersTerminal),
        .init(.contendedSettled, .contended, .holdersSettled, .backgroundJob),
    ]
    /// Every candidate for a from-state and event; the supervisor picks the one whose `to` is the outcome it resolved
    /// and records it, and an empty answer is `.transitionNotInTable`.
    public static func transitions(for event: Event, from state: StateName) -> [Transition] {
        scenarios.filter { $0.from == state && $0.event == event }
    }
}
