import Foundation
import AfleetCore
import ClaudeWire

/// The one spawn barrier a fleet holds. It is up from the moment a `/logout` plan is built until that plan has
/// finished or been abandoned, and every `ChannelSupervisor.spawn` consults it: a channel opened into a fleet that
/// is signing out would come up authenticated, lose its token a moment later, and have no way to say why.
public final class SpawnBarrier: @unchecked Sendable {   // `lock` serialises `raised`
    private let lock = NSLock()
    private var raised = false

    public init() {}

    public var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    public func raise() { lock.lock(); raised = true; lock.unlock() }
    public func lower() { lock.lock(); raised = false; lock.unlock() }

    /// Called at the top of every spawn, before anything the spawn would have to undo.
    public func check() throws {
        if isRaised { throw LifecycleError.logoutInProgress }
    }
}

/// Everything `/logout` has to see and to act through. Task 9's facade builds one from what it owns; a test builds
/// one directly.
public struct LogoutContext: Sendable {
    /// Every channel afleet supervises under this config home.
    public var channels: [ChannelSupervisor]
    public var observer: FleetObserver
    public var verbs: CLIVerbs
    public var barrier: SpawnBarrier
    /// The shorts afleet itself sent to the background, remembered in the store under
    /// `FleetKitKeys.ownJobShorts`. A job afleet did not launch is not afleet's to stop.
    public var ownJobShorts: [JobShort]
    public var diagnostics: any FleetDiagnosticsSink
    public var clock: any Clock<Duration>

    public init(channels: [ChannelSupervisor], observer: FleetObserver, verbs: CLIVerbs, barrier: SpawnBarrier,
                ownJobShorts: [JobShort], diagnostics: any FleetDiagnosticsSink, clock: any Clock<Duration>) {
        self.channels = channels; self.observer = observer; self.verbs = verbs; self.barrier = barrier
        self.ownJobShorts = ownJobShorts; self.diagnostics = diagnostics; self.clock = clock
    }
}

public enum LogoutChoice: Sendable { case wait, stop }

/// What the plan did. `success` is reported only when every listed process and job has gone.
public enum LogoutOutcome: Hashable, Sendable {
    /// *Wait*: the plan is holding, and these are the task ids it is holding on.
    case waiting(on: [String])
    case success(exited: [ChannelKey], foreignLeftRunning: [SessionID])
    /// Something afleet started is still alive: a channel whose `terminate()` answered no exit, or a job whose
    /// worker never left the roster. `claude auth logout` did not run in either case — taking the token out from
    /// under a live process is the one thing this plan exists to prevent, and a job's worker is as live as a
    /// channel's child.
    case blocked(wedged: [ChannelKey], jobsStillListed: [JobShort])
    /// Every channel and job went, and the CLI then refused to sign out. The terminations stand; the sign-out did
    /// not happen, and the surface must not be told it did.
    case signOutFailed(exited: [ChannelKey], reason: String)
}

/// The parent's `/logout`: raise the barrier, census, *Wait* or *Stop*, stop the jobs, terminate the channels, and
/// only then `claude auth logout`.
public enum LogoutPlan {

    /// The census, and the barrier raised with it.
    public struct Census: Sendable {
        /// Every channel afleet owns a process for, in session order so the plan and its report read the same twice.
        public var owned: [ChannelKey]
        /// The channels that are not eligible, each with the tasks that make them so.
        public var nonEligible: [(key: ChannelKey, tasks: [String])]
        public var ownJobs: [JobShort]
        /// Live holders that are neither a channel of ours nor a job of ours: somebody else's session, which keeps
        /// its token because afleet may not stop it.
        public var foreign: [Holder]
        /// Channels already wedged when the census was taken. Each is a ghost afleet cannot end, so the plan cannot
        /// finish, and the user is told which ones before being offered *Stop* rather than after.
        public var wedged: [ChannelKey]

        public init(owned: [ChannelKey], nonEligible: [(key: ChannelKey, tasks: [String])],
                    ownJobs: [JobShort], foreign: [Holder], wedged: [ChannelKey] = []) {
            self.owned = owned; self.nonEligible = nonEligible; self.ownJobs = ownJobs; self.foreign = foreign
            self.wedged = wedged
        }
    }

    /// How long the roster has to drop a stopped job's worker, and how often it is re-read; the same cadence
    /// `OwnershipCheck` polls a release at, so one clock drives both waits.
    public static let rosterInterval = OwnershipCheck.releasePollInterval
    public static let rosterBudget = Duration.seconds(10)

    /// Raises the barrier and reads the world.
    public static func build(fleet: LogoutContext) async -> Census {
        fleet.barrier.raise()
        _ = await fleet.observer.reconcileNow(label: "logout")
        let snapshot = await fleet.observer.detailedSnapshot()

        var owned: [ChannelKey] = []
        var nonEligible: [(key: ChannelKey, tasks: [String])] = []
        var wedged: [ChannelKey] = []
        for channel in fleet.channels {
            let state = await channel.state
            guard case .owned = state.origin else { continue }
            owned.append(channel.key)
            // A wedged channel is `.owned(.dormant)` with a trace, so origin alone does not tell it from a channel
            // that can be ended. It is listed as owned *and* named here.
            if state.wedged != nil { wedged.append(channel.key) }
            let tasks = await channel.liveTaskIDs()
            if await !channel.currentEligibility().isEligible { nonEligible.append((channel.key, tasks)) }
        }
        owned.sort { $0.session.description < $1.session.description }
        nonEligible.sort { $0.key.session.description < $1.key.session.description }
        wedged.sort { $0.session.description < $1.session.description }

        let ourSessions = Set(fleet.channels.map(\.key.session))
        let ourShorts = Set(fleet.ownJobShorts.map(\.rawValue))
        let ownJobs = fleet.ownJobShorts.filter { snapshot.jobs[$0]?.isTerminal == false }
            .sorted { $0.rawValue < $1.rawValue }
        let foreign = snapshot.holders.holders
            .filter { !$0.isOwnChild && !ourSessions.contains($0.sessionID) }
            .filter { holder in holder.jobShort.map { !ourShorts.contains($0) } ?? true }
            .sorted { $0.pid < $1.pid }

        fleet.diagnostics.record(.logout(step: "census", count: owned.count))
        return Census(owned: owned, nonEligible: nonEligible, ownJobs: ownJobs, foreign: foreign, wedged: wedged)
    }

    /// Lowers the barrier without running anything: the user changed their mind.
    public static func abandon(fleet: LogoutContext) {
        fleet.barrier.lower()
        fleet.diagnostics.record(.logout(step: "abandoned", count: 0))
    }

    /// Runs the plan in the parent's order. The barrier stays up for a `.waiting` — the plan has not finished, and
    /// a channel opened in the meantime would be caught by the same logout — and is lowered on every other outcome.
    public static func execute(_ census: Census, choice: LogoutChoice, fleet: LogoutContext) async -> LogoutOutcome {
        // A ghost the census already found is a plan that cannot finish. Stopping first and discovering it after
        // would tear the user's other channels and jobs down for a sign-out that was never going to run.
        guard census.wedged.isEmpty else {
            fleet.diagnostics.record(.logout(step: "blocked", count: census.wedged.count))
            fleet.barrier.lower()
            return .blocked(wedged: census.wedged, jobsStillListed: [])
        }
        let blocking = census.nonEligible.flatMap(\.tasks)
        if choice == .wait, !blocking.isEmpty {
            fleet.diagnostics.record(.logout(step: "waiting", count: blocking.count))
            return .waiting(on: blocking)
        }

        // Stop: the turn first, then each task by id. `interrupt {cancel_queued: true}` before `stop_task` because a
        // queued input would start the next turn the moment the running one ends.
        if choice == .stop, !census.nonEligible.isEmpty {
            for entry in census.nonEligible {
                guard let channel = fleet.channels.first(where: { $0.key == entry.key }) else { continue }
                _ = try? await channel.perform(Interrupt(cancelQueued: true))
                for task in entry.tasks { _ = try? await channel.perform(StopTask(taskID: task)) }
            }
            fleet.diagnostics.record(.logout(step: "tasksStopped", count: blocking.count))
        }

        // The jobs afleet launched, stopped through the CLI and confirmed gone from the roster: the verb exiting
        // zero is not the job having left, and a logout that ran on the verb alone would sign out a live worker.
        for short in census.ownJobs {
            try? await fleet.verbs.stop(short)
        }
        if !census.ownJobs.isEmpty {
            let stillListed = await awaitRosterRemoval(of: census.ownJobs, fleet: fleet)
            // The same invariant as the wedge, and the same answer: a worker still named in the roster is a live
            // process, and `auth logout` behind it would sign a running job out mid-turn. The plan stops here
            // rather than terminating the channels for a sign-out it cannot run.
            guard stillListed.isEmpty else {
                fleet.diagnostics.record(.logout(step: "blocked", count: stillListed.count))
                fleet.barrier.lower()
                return .blocked(wedged: [], jobsStillListed: stillListed)
            }
            fleet.diagnostics.record(.logout(step: "jobsStopped", count: census.ownJobs.count))
        }

        // Every owned channel. A `nil` exit stops the plan here: `terminateOrWedge` is the only caller of
        // `terminate()`, and nothing that would have followed an exit happens behind one.
        var exited: [ChannelKey] = []
        var wedged: [ChannelKey] = []
        for key in census.owned {
            guard let channel = fleet.channels.first(where: { $0.key == key }) else { continue }
            switch await channel.terminateForLogout() {
            case .exited: exited.append(key)
            case .wedged: wedged.append(key)
            }
        }
        guard wedged.isEmpty else {
            fleet.diagnostics.record(.logout(step: "blocked", count: wedged.count))
            fleet.barrier.lower()
            return .blocked(wedged: wedged, jobsStillListed: [])
        }

        do {
            try await fleet.verbs.authLogout()
        } catch {
            // The channels went; the sign-out did not. Reporting success here would be the one value the surface
            // renders saying the opposite of what happened.
            fleet.diagnostics.record(.logout(step: "signOutFailed", count: exited.count))
            fleet.barrier.lower()
            return .signOutFailed(exited: exited, reason: String(describing: error))
        }
        fleet.diagnostics.record(.logout(step: "loggedOut", count: exited.count))
        fleet.barrier.lower()

        // Read the world once more: a foreign session still on the machine keeps its own token, and the report
        // names it so the user is not told everything signed out when it did not.
        _ = await fleet.observer.reconcileNow(label: "logout")
        let after = await fleet.observer.snapshot()
        let stillThere = Set(after.holders.map(\.pid))
        let left = census.foreign.filter { stillThere.contains($0.pid) }.map(\.sessionID)
        return .success(exited: exited, foreignLeftRunning: left)
    }

    /// Re-reads the roster until none of these shorts names a worker, bounded on the injected clock, and answers
    /// with the ones still listed when it gave up — empty on the path where every worker left.
    private static func awaitRosterRemoval(of shorts: [JobShort], fleet: LogoutContext) async -> [JobShort] {
        var waited = Duration.zero
        var announced = false
        var remaining = shorts
        while waited <= rosterBudget {
            let snapshot = await fleet.observer.reconcileNow(label: "logout")
            let live = Set(snapshot.holders.compactMap(\.jobShort))
            remaining = shorts.filter { live.contains($0.rawValue) }
            if remaining.isEmpty { return [] }
            if !announced {
                announced = true
                fleet.diagnostics.record(.logout(step: "jobRosterWait", count: shorts.count))
            }
            guard (try? await fleet.clock.sleep(for: rosterInterval)) != nil else { return remaining }
            waited += rosterInterval
        }
        fleet.diagnostics.record(.logout(step: "jobRosterTimedOut", count: remaining.count))
        return remaining
    }
}
