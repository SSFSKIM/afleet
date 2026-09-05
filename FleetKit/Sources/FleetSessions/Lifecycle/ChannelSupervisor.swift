import Foundation
import AfleetCore
import ClaudeWire

/// What `terminateOrWedge` observed. Every caller stops at `.wedged` without running what would have followed an exit.
public enum TerminateOutcome: Sendable {
    case exited(ExitStatus)
    case wedged(EscalationTrace)
}

/// Why a spawn is happening. `.restart` is the one reason that does not publish `.ready` from the handshake: Task 6
/// runs its readbacks first and applies the transition itself.
public enum SpawnReason: String, Hashable, Sendable {
    case open, userSent, respawn, restart, reopen, adopt, ownTabExited
}

extension LifecycleTable.Event {
    /// The name the diagnostics sink records. Payload-carrying cases spell their payload out, so a wedge during a
    /// reap and a wedge during a restart are two different observations rather than one.
    var diagnosticName: String {
        switch self {
        case .terminateReturnedNil(let action): "terminateReturnedNil(\(action.rawValue))"
        default: String(describing: self)
        }
    }
}

/// One actor per channel. It owns at most one process at a time, the channel's epoch progression, and every
/// transition, which goes through `LifecycleTable` and nowhere else.
public actor ChannelSupervisor {
    public nonisolated let key: ChannelKey

    private let launchTemplate: LaunchConfiguration
    private let factory: ProcessFactory
    private let ownership: OwnershipCheck
    private let observer: FleetObserver
    private let clock: any Clock<Duration>
    private let eligibilityInputs: @Sendable () async -> DormantEligibility.Input
    private let fleet: FleetCapCounter
    private let diagnostics: any FleetDiagnosticsSink
    private let handshakeTimeout: Duration
    /// The environment every child and every pane request is composed over, so a hatch resumes under exactly the
    /// environment the owned process ran in.
    private let environment: ResolvedEnvironment
    private let configHome: ConfigHome
    private let verbs: CLIVerbs
    /// Where the shorts afleet itself sent to the background are remembered (`FleetKitKeys.ownJobShorts`).
    private let store: (any StateStore)?
    /// Reaps the channel the cap counter named and answers what it observed. The facade routes it to that
    /// supervisor's `evict()`; the default frees nothing, which is the safe answer for a fleet with no router yet.
    private let evictVictim: @Sendable (ChannelKey) async -> EvictionOutcome
    /// Awaited between the victim's observed outcome and the report of it. Nothing in production; the rig parks here
    /// to hold an eviction open while another decision runs.
    private let evictionBarrier: @Sendable (ChannelKey) async -> Void

    /// Whether this channel counts as recently active, which is what tells `archivedRecent` from `archivedOlder`.
    /// It is held here rather than derived inside `ChannelState` because it is the supervisor's own fact: C3's index
    /// supplies it at construction and the reap refreshes it.
    private var isRecent: Bool

    public private(set) var state: ChannelState
    /// The hatch this channel is waiting on an exit for, matched by `id` and never by value.
    public var pendingPaneRequest: PaneRequest? { pendingHatch }
    /// Zero until the first spawn, which takes `ProcessEpoch.first`; every later spawn takes `.next()`. No event can
    /// carry epoch zero, so the pump's "discard anything older" filter is correct before there is a process.
    private var epoch = ProcessEpoch(rawValue: 0)
    private var process: (any ProcessHandle)?
    private var turnRunning = false
    private var queuedInput: [UserInput] = []
    private var pendingHatch: PaneRequest?
    /// Where the channel was when it became Contended, so a holder set that settles to nothing goes back there
    /// rather than to a state the table would refuse.
    private var contendedFrom: LifecycleTable.StateName?
    private var crashCount = 0
    private var wasReadyInThisSeries = false
    /// The epochs this supervisor deliberately ended. Keyed on the epoch and not on a flag held across one `await`,
    /// because `ClaudeProcess.terminate()` returns from the exit *waiter* (`ClaudeProcess.swift:431`) while the
    /// `.exited` **event** the pump sees is pushed after a bounded reader drain (`:450`): the event normally arrives
    /// after `terminate()` has already returned. A flag would be false by then and a SIGTERM or SIGKILL exit — which
    /// is never `.code(0)` — would be read as a crash and respawn a channel the user deliberately reaped.
    private var terminatedEpochs: Set<ProcessEpoch> = []
    private var dormantTimer: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var respawnTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var eligibilityTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<WireEvent>.Continuation] = [:]
    private var shuttingDown = false
    /// True from the moment a spawn takes its reservation until it has applied its own outcome. The holder updates
    /// that arrive in that window belong to the post-handshake check, not to the disagreement rule.
    private var spawning = false

    private let updatesContinuation: AsyncStream<ChannelState>.Continuation
    /// Every transition, published after the state has changed.
    public nonisolated let updates: AsyncStream<ChannelState>

    /// The thirty-minute reap.
    public static let dormantAfter = Duration.seconds(1800)
    /// Three attempts, then the system item.
    public static let backoffs: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// Rule 5's quiescent handoff budget: past it the channel is Contended.
    public static let handoffBudget = Duration.seconds(10)

    public init(key: ChannelKey, launchTemplate: LaunchConfiguration, factory: @escaping ProcessFactory,
                ownership: OwnershipCheck, observer: FleetObserver, clock: any Clock<Duration>,
                eligibilityInputs: @escaping @Sendable () async -> DormantEligibility.Input,
                fleet: FleetCapCounter, diagnostics: any FleetDiagnosticsSink, isRecent: Bool,
                environment: ResolvedEnvironment, configHome: ConfigHome, verbs: CLIVerbs,
                store: (any StateStore)? = nil,
                evictVictim: @escaping @Sendable (ChannelKey) async -> EvictionOutcome = { _ in .victimBecameIneligible },
                evictionBarrier: @escaping @Sendable (ChannelKey) async -> Void = { _ in },
                initialOrigin: ChannelOrigin = .archived, initialDesired: DesiredOwnership = .none,
                handshakeTimeout: Duration = .seconds(30)) {
        self.key = key; self.launchTemplate = launchTemplate; self.factory = factory
        self.ownership = ownership; self.observer = observer; self.clock = clock
        self.eligibilityInputs = eligibilityInputs; self.fleet = fleet; self.diagnostics = diagnostics
        self.isRecent = isRecent; self.handshakeTimeout = handshakeTimeout
        self.environment = environment; self.configHome = configHome; self.verbs = verbs; self.store = store
        self.evictVictim = evictVictim; self.evictionBarrier = evictionBarrier
        self.state = ChannelState(key: key, origin: initialOrigin, desired: initialDesired,
                                  observed: HolderSet(holders: [], observedAt: Date()),
                                  identity: .known(key.session), lastActivity: Date())
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - The state name the table speaks in

    /// `ChannelState` deliberately does not derive this: `archivedRecent` needs the recency flag only the supervisor
    /// holds, and the wedged row is an `.owned(.dormant)` carrying a trace.
    private var currentName: LifecycleTable.StateName {
        switch state.origin {
        case .owned(.connecting): return .connecting
        case .owned(.ready): return .ready
        case .owned(.dormant): return state.wedged == nil ? .dormant : .wedged
        case .owned(.contended): return .contended
        case .foreignLive(.usersTerminal): return .foreignUsersTerminal
        case .foreignLive(.ownTerminalTab): return .foreignOwnTab
        case .backgroundJob: return .backgroundJob
        case .archived: return isRecent ? .archivedRecent : .archivedOlder
        }
    }

    /// Every transition goes through here. The table is the authority: an event and an outcome with no candidate is
    /// a programming error surfaced as a diagnostic, never a silent state change.
    @discardableResult
    private func apply(_ event: LifecycleTable.Event, to target: LifecycleTable.StateName) -> Bool {
        let from = currentName
        guard let row = LifecycleTable.transitions(for: event, from: from).first(where: { $0.to == target }) else {
            diagnostics.record(.transitionNotInTable(event: event.diagnosticName, from: from.rawValue,
                                                     to: target.rawValue, session: key.session.description))
            return false
        }
        diagnostics.record(.transition(row: row.row.rawValue, from: from.rawValue, event: event.diagnosticName,
                                       to: target.rawValue, session: key.session.description,
                                       epoch: state.epoch?.rawValue))
        enter(target)
        publish()
        return true
    }

    private func enter(_ name: LifecycleTable.StateName) {
        switch name {
        case .archivedRecent: state.origin = .archived; isRecent = true
        case .archivedOlder: state.origin = .archived; isRecent = false
        case .connecting: state.origin = .owned(.connecting)
        case .ready: state.origin = .owned(.ready); wasReadyInThisSeries = true
        case .dormant: state.origin = .owned(.dormant)
        case .wedged: state.origin = .owned(.dormant)          // the trace on `state.wedged` is what makes it wedged
        case .backgroundJob: state.origin = .backgroundJob
        case .foreignUsersTerminal: state.origin = .foreignLive(.usersTerminal)
        case .foreignOwnTab: state.origin = .foreignLive(.ownTerminalTab)
        case .contended: state.origin = .owned(.contended)
        }
        state.presence = presenceNow()
    }

    /// An owned channel's presence is afleet's own turn state. Every other origin's presence is whatever the holder's
    /// record said, which `OriginResolver` resolved and the caller has already stored; recomputing it here would
    /// overwrite a fact with a guess.
    /// The table's name for an origin `OriginResolver` produced.
    private static func name(of origin: ChannelOrigin, isRecent: Bool) -> LifecycleTable.StateName {
        switch origin {
        case .owned(.connecting): return .connecting
        case .owned(.ready): return .ready
        case .owned(.dormant): return .dormant
        case .owned(.contended): return .contended
        case .foreignLive(.usersTerminal): return .foreignUsersTerminal
        case .foreignLive(.ownTerminalTab): return .foreignOwnTab
        case .backgroundJob: return .backgroundJob
        case .archived: return isRecent ? .archivedRecent : .archivedOlder
        }
    }

    private func presenceNow() -> Presence {
        guard case .owned(let owned) = state.origin, owned != .contended else { return state.presence }
        if !state.pendingDecisions.isEmpty { return .waiting(for: nil) }
        if turnRunning { return .busy }
        return .idle
    }

    /// How many states this supervisor has published. Read on the actor, so a caller that awaits it after an action
    /// sees every publish that action caused — which `updates`, drained from outside, cannot promise.
    public private(set) var publishedCount = 0

    private func publish() {
        publishedCount += 1
        updatesContinuation.yield(state)
    }

    // MARK: - Actions

    /// The §7.4 open rows. A recently active archived channel spawns eagerly; an older one renders history only.
    public func open() async throws {
        guard case .archived = state.origin else { return }
        if isRecent {
            state.desired = .owned
            apply(.opened, to: .connecting)
            try await spawn(reason: .open)
        } else {
            apply(.opened, to: .archivedOlder)
        }
    }

    /// Every send. A dormant or older-archived channel spawns first; a held one refuses.
    @discardableResult
    public func send(_ input: UserInput) async throws -> UUID {
        switch state.origin {
        case .foreignLive(.usersTerminal):
            // Rule 6: the send is refused where the user can see why, and *Fork* is what the banner offers.
            state.banner = .heldElsewhere(state.observed)
            apply(.sendRefused, to: .foreignUsersTerminal)
            throw LifecycleError.heldElsewhere(state.observed)
        case .foreignLive(.ownTerminalTab), .backgroundJob:
            throw LifecycleError.heldElsewhere(state.observed)
        case .owned(.ready):
            return try await deliver(input)
        case .owned(.dormant):
            if let trace = state.wedged { throw LifecycleError.wedged(trace) }
            state.desired = .owned
            apply(.userSent, to: .connecting)
            try await spawn(reason: .userSent)
            return try await deliver(input)
        case .archived:
            state.desired = .owned
            apply(.userSent, to: .connecting)
            try await spawn(reason: .userSent)
            return try await deliver(input)
        case .owned(.connecting):
            // A send while a spawn this supervisor did not start is still in flight. The input is queued and goes out
            // when the handshake lands; the uuid returned here is not the one the engine will echo, because
            // `ProcessHandle.send` mints its own. Task 9's facade serialises the actions of one channel, which is
            // where that gap closes; nothing in this task's rows reaches this case.
            queuedInput.append(input)
            pushEligibility()
            return UUID()
        case .owned(.contended):
            throw LifecycleError.heldElsewhere(state.observed)
        }
    }

    private func deliver(_ input: UserInput) async throws -> UUID {
        guard let handle = process else { throw LifecycleError.notOwned }
        let uuid = try await handle.send(input)
        turnRunning = true
        noteActivity()
        pushEligibility()
        publish()
        return uuid
    }

    /// The one path a decision is answered through. The id is consumed before the write, exactly as
    /// `ClaudeProcess.answer` removes `pendingInbound[id]` before it writes: after a failed write the id is gone in
    /// ClaudeWire and every retry would throw `unknownRequest`.
    public func answer(_ id: RequestID, _ answer: InboundAnswer) async throws {
        guard state.pendingDecisions.contains(where: { $0.id == id }) else {
            throw LifecycleError.decisionGone(id)
        }
        state.pendingDecisions.removeAll { $0.id == id }
        pushEligibility()
        publish()
        guard let handle = process else { throw LifecycleError.notOwned }
        do {
            try await handle.answer(id, answer)
            noteActivity()
        } catch {
            let reason = String(describing: error)
            diagnostics.record(.answerWriteFailed(id: id, reason: reason))
            throw LifecycleError.answerFailed(id, reason: reason)
        }
    }

    /// The thirty-minute reap, and `LifecycleAction.reap`.
    public func reap() async {
        guard process != nil, state.wedged == nil else { return }   // a ghost has nothing left to reap
        let outcome = await terminateOrWedge(during: .reap)
        guard case .exited = outcome else { return }   // wedged: no dormant mark, no released slot
        process = nil
        apply(.dormantTimerFired, to: .dormant)
        await fleet.release(key)
        pushEligibility()
    }

    /// The only call site of `ProcessHandle.terminate()`, and the only place a channel becomes wedged. Every
    /// terminating action names itself, the post-handshake yield included: the parent's wedged row is "Owned, any",
    /// and Owned-connecting is one of the states "any" admits.
    @discardableResult
    public func terminateOrWedge(during action: LifecycleTable.TerminatingAction) async -> TerminateOutcome {
        guard let handle = process else { return .exited(.code(0, stderrTail: "")) }
        let pid = await handle.childProcessIdentifier
        terminatedEpochs.insert(handle.epoch)
        let report = await handle.terminate()
        guard let exit = report.exit else {
            let trace = EscalationTrace(steps: report.steps, pid: pid, epoch: handle.epoch)
            state.wedged = trace
            state.systemItem = .wedged(trace, reopenOffered: true)
            diagnostics.record(.wedged(session: key.session.description, steps: report.steps.count))
            // `process` stays: the ghost is still out there and `livePID()` must keep naming its pid so the fleet's
            // own-pid set does not read it as a stranger.
            apply(.terminateReturnedNil(during: action), to: .wedged)
            await fleet.markWedged(key)
            pushEligibility()
            return .wedged(trace)
        }
        process = nil
        return .exited(exit)
    }

    // MARK: - Reopen

    /// The *Reopen* a wedged channel offers. It spawns only when the pre-spawn check finds no holder: the ghost may
    /// still be holding the transcript, and a second writer under one session id is the thing the checks exist to
    /// prevent. The table has no transition out of `wedged`, and none is invented: clearing the trace makes the
    /// channel the dormant channel it structurally is, and the user's request is then the ordinary dormant resume.
    public func reopen() async throws {
        guard state.wedged != nil else { return }
        let holders = await ownership.beforeSpawn(session: key.session)
        guard holders.isEmpty else {
            // Nothing changes state: the ghost is still the channel's situation and *Reopen* is still what is
            // offered. All the user learns is that somebody else has the session right now.
            let set = HolderSet(holders: holders, observedAt: Date())
            state.observed = set
            state.banner = .contended(set)
            publish()
            throw LifecycleError.heldElsewhere(set)
        }
        let ghost = state.wedged
        let item = state.systemItem
        state.wedged = nil
        state.systemItem = nil
        process = nil
        await fleet.clearWedged(key)
        state.desired = .owned
        guard apply(.userSent, to: .connecting) else {
            state.wedged = ghost
            state.systemItem = item
            return
        }
        try await spawn(reason: .reopen)
    }

    // MARK: - Adopt

    /// §7.4's job-adoption row: stop the job, wait for its worker to leave the roster and die, then resume it owned.
    public func adopt() async throws {
        let holders = await observer.holders(for: key.session)
        guard let job = holders.first(where: { $0.isJob }), let short = job.jobShort else {
            throw LifecycleError.notOwned
        }
        try await verbs.stop(JobShort(rawValue: short))
        switch await ownership.awaitRelease(previous: job, upTo: Self.handoffBudget) {
        case .timedOut:
            enterContended(holders, via: .handoffTimedOut)
            throw LifecycleError.handoffTimedOut(state.observed)
        case .released:
            state.desired = .owned
            guard apply(.adopt, to: .connecting) else { return }
            try await spawn(reason: .adopt)
        }
    }

    // MARK: - The two handoffs

    /// `terminate()`, wait for the release, run the pre-spawn check once more, then `claude --bg --resume <id>`.
    @discardableResult
    public func sendToBackground() async throws -> JobShort {
        try await handOff(during: .sendToBackground, event: .sendToBackground, to: .backgroundJob) {
            let short = try await verbs.backgroundResume(key.session, cwd: launchTemplate.cwd)
            try await rememberOwnJob(short)
            try await confirmListed(short)
            return short
        }
    }

    /// The terminal hatch. The window between the returned request and the panel's spawn is accepted (spec Decision
    /// Log, 2026-09-05); everything before it is not.
    public func openInTerminal() async throws -> PaneRequest {
        try await handOff(during: .openInTerminal, event: .openInTerminal, to: .foreignOwnTab) {
            let request = paneRequest(arguments: ["--resume", key.session.description],
                                      cwd: launchTemplate.cwd, purpose: .hatch(key.session))
            pendingHatch = request
            diagnostics.record(.paneRequest(id: request.id, purpose: "hatch", session: key.session.description))
            return request
        }
    }

    /// The shape both handoffs share: an owned channel lets go of its process, waits for the release, and only then
    /// — from ready and from dormant alike — asks once more whether anybody else has taken the session.
    ///
    /// A `nil` from `terminate()` stops here with nothing else run: no verb, no request, no replacement process.
    private func handOff<T>(during action: LifecycleTable.TerminatingAction, event: LifecycleTable.Event,
                            to target: LifecycleTable.StateName,
                            _ launch: () async throws -> T) async throws -> T {
        guard case .owned(let owned) = state.origin, owned == .ready || owned == .dormant else {
            throw LifecycleError.notOwned
        }
        if let trace = state.wedged { throw LifecycleError.wedged(trace) }

        var terminated = false
        if let handle = process {
            let ownPID = await handle.childProcessIdentifier
            if case .wedged(let trace) = await terminateOrWedge(during: action) {
                throw LifecycleError.wedged(trace)
            }
            process = nil
            terminated = true
            await fleet.release(key)
            // The record our own child wrote, waited out by pid: `awaitRelease` wants the record gone *and* the pid
            // dead, and a child with no record still has to be dead before anyone else may write the transcript.
            let own = Holder(pid: ownPID, sessionID: key.session, sources: [.registry], kind: "own",
                             isOwnChild: true)
            if case .timedOut = await ownership.awaitRelease(previous: own, upTo: Self.handoffBudget) {
                enterContended(await observer.holders(for: key.session), via: .handoffTimedOut)
                throw LifecycleError.handoffTimedOut(state.observed)
            }
        } else if let ours = (await observer.holders(for: key.session)).first(where: { $0.isOwnChild }) {
            // This channel has no process, but a *live child of the fleet's* still names the session — another
            // supervisor's, on the same session id. `isOwnChild` is computed from the set of live child pids, so an
            // older epoch's ghost is not one of these: a ghost is caught one step later, by the recheck. Rule 5
            // waits this one out before anybody else writes the transcript. With no such holder — the ordinary
            // dormant case — there is no process and no wait, and the recheck is the only check.
            if case .timedOut = await ownership.awaitRelease(previous: ours, upTo: Self.handoffBudget) {
                enterContended(await observer.holders(for: key.session), via: .handoffTimedOut)
                throw LifecycleError.handoffTimedOut(state.observed)
            }
        }

        // From dormant with nothing of ours left, this is the only check there is.
        let holders = await ownership.beforeSpawn(session: key.session)
        guard holders.isEmpty else { throw preempted(by: holders) }

        let result: T
        do {
            result = try await launch()
        } catch {
            // The child is already gone and its slot already released, so presenting the channel as owned would be
            // a lie: there is nothing behind it. What actually happened is a reap — terminate, then no replacement —
            // so that is the row it takes, and the caller still gets the failure.
            if terminated { apply(.dormantTimerFired, to: .dormant) }
            throw error
        }
        state.banner = nil
        apply(event, to: target)
        return result
    }

    /// A holder found in the window between the release and the launch: nothing launches, the channel takes the
    /// origin the holder implies, and the caller is told who has it.
    private func preempted(by holders: [Holder]) -> LifecycleError {
        let set = HolderSet(holders: holders, observedAt: Date())
        state.observed = set
        let (origin, presence) = OriginResolver.resolve(key: key, ownedState: nil, holders: holders,
                                                        pendingHatch: false)
        state.presence = presence
        if case .owned(.contended) = origin {
            state.banner = .contended(set)
            contendedFrom = currentName
        } else {
            state.banner = .heldElsewhere(set)
        }
        apply(.holderAppearedBeforeLaunch, to: Self.name(of: origin, isRecent: isRecent))
        return LifecycleError.heldElsewhere(set)
    }

    private func rememberOwnJob(_ short: JobShort) async throws {
        guard let store else { return }
        var shorts = (try? await store.read([String].self, namespace: .fleetKit,
                                            key: FleetKitKeys.ownJobShorts)) ?? []
        guard !shorts.contains(short.rawValue) else { return }
        shorts.append(short.rawValue)
        try await store.write(shorts, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
    }

    /// The CLI exiting zero is not the confirmation; the job being listed is. `backgroundResume` already waited for
    /// the roster, and this is the other half of item 16: the listing the sidebar will read names it too.
    private func confirmListed(_ short: JobShort) async throws {
        let rows = (try? await verbs.agentsJSON()) ?? []
        guard rows.contains(where: { $0.id == short.rawValue }) else {
            diagnostics.record(.jobNotListedAfterBackground(session: key.session.description))
            throw LifecycleError.verbFailed(verb: "--bg --resume", exitCode: 0)
        }
    }

    // MARK: - Panes

    /// `claude attach <short>` in a pane. It changes no ownership: the job keeps the session.
    public func attach(job: JobEntry) -> PaneRequest {
        paneRequest(arguments: ["attach", job.short.rawValue], cwd: job.cwd ?? launchTemplate.cwd,
                    purpose: .attach(job.short))
    }

    /// `claude logs <short>` in a pane. It changes no ownership.
    public func logs(job: JobEntry) -> PaneRequest {
        paneRequest(arguments: ["logs", job.short.rawValue], cwd: job.cwd ?? launchTemplate.cwd,
                    purpose: .logs(job.short))
    }

    /// Every pane this channel asks for runs the located binary under the same config home and the same scrubbed,
    /// re-injected environment the owned process ran under — composed by ClaudeWire, never assembled here.
    private func paneRequest(arguments: [String], cwd: URL, purpose: PanePurpose) -> PaneRequest {
        PaneRequest(executable: launchTemplate.binary, arguments: arguments, cwd: cwd,
                    environment: launchTemplate.childEnvironment(over: environment, configHome: configHome),
                    purpose: purpose)
    }

    // MARK: - Cap eviction

    /// The reap the cap counter asked for. Eligibility is re-evaluated *here*, at reap time, because the snapshot
    /// the counter decided from is as old as the last push; a channel that started a turn in between is not a victim.
    ///
    /// It never releases the slot: the counter is holding it as this eviction, and the evicting supervisor's report
    /// is what moves it. A release arriving from this channel's own lifecycle completes the same eviction.
    public func evict() async -> EvictionOutcome {
        guard process != nil, state.wedged == nil else { return .victimBecameIneligible }
        guard await currentVerdict().isEligible else { return .victimBecameIneligible }
        if case .wedged = await terminateOrWedge(during: .capEviction) { return .victimWedged }
        process = nil
        apply(.seventhSpawnNeeded, to: .dormant)
        pushEligibility()
        return .evicted
    }

    // MARK: - Contended

    private func enterContended(_ holders: [Holder], via event: LifecycleTable.Event) {
        let mine = holders.filter { $0.sessionID == key.session }
        let set = HolderSet(holders: mine, observedAt: Date())
        state.observed = set
        state.banner = .contended(set)
        contendedFrom = currentName
        apply(event, to: .contended)
    }

    /// The holder set settled. Zero holders means the session is nobody's — unless this channel still owns a process,
    /// or was dormant when the disagreement arrived, in which case it goes back to being that. One holder means the
    /// origin that holder implies. Two or more is still contended.
    private func resolveContended(_ mine: [Holder]) {
        let foreign = mine.filter { !$0.isOwnChild }
        if foreign.isEmpty {
            let target: LifecycleTable.StateName = {
                if process != nil { return .ready }
                if contendedFrom == .dormant { return .dormant }
                // `enter` reads a state name as a *statement* about recency, so naming `archivedRecent`
                // unconditionally would make a channel recent merely by passing through Contended. The name comes
                // from the flag the channel already has, and the table admits both.
                return Self.name(of: .archived, isRecent: isRecent)
            }()
            settle(to: target)
            return
        }
        guard foreign.count == 1 else { publish(); return }
        let (origin, presence) = OriginResolver.resolve(key: key, ownedState: nil, holders: foreign,
                                                        pendingHatch: false)
        state.presence = presence
        settle(to: Self.name(of: origin, isRecent: isRecent))
    }

    /// Leaves Contended, and leaves it *intact* if the table refuses. A transition that finds no candidate is a
    /// programming error and this actor stays in the state it was in — so the banner and the from-state it would
    /// need to try again must not have been thrown away first, or the channel is Contended with no way out and
    /// re-runs the refused transition on every later holder update.
    private func settle(to target: LifecycleTable.StateName) {
        let banner = state.banner
        let from = contendedFrom
        state.banner = nil
        contendedFrom = nil
        guard apply(.holdersSettled, to: target) else {
            state.banner = banner
            contendedFrom = from
            publish()
            return
        }
    }

    /// A fresh unbounded fan-out per call. This is the only way a wire frame leaves the supervisor.
    public func events() -> AsyncStream<WireEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    private func dropSubscriber(_ id: UUID) { subscribers[id] = nil }

    /// Finishes every subscriber stream and cancels the dormant timer. It terminates nothing: the facade calls this
    /// at app exit, and the user's channels keep running.
    public func shutdown() {
        shuttingDown = true
        dormantTimer?.cancel(); dormantTimer = nil
        respawnTask?.cancel(); respawnTask = nil
        pumpTask?.cancel(); pumpTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        updatesContinuation.finish()
    }

    /// The pid of the child this supervisor owns right now, for the fleet's `ownPIDs` set.
    public func livePID() async -> Int32? {
        guard let process else { return nil }
        let pid = await process.childProcessIdentifier
        return pid > 0 ? pid : nil
    }

    /// Awaits the tail of the fire-and-forget activity chain, so a caller can compare recency stamps.
    public func drainActivity() async { await activityTask?.value }

    /// Awaits the tail of the eligibility chain, so a caller can read the verdict the counter now holds.
    public func drainEligibility() async { await eligibilityTask?.value }

    /// The registry mirror is C3's, not this actor's, so a change in it can only arrive from outside. The facade
    /// calls this when a mirror entry for this channel arms, updates or completes; the verdict is re-evaluated and
    /// pushed to the counter, which never asks for it.
    public func mirrorChanged() async {
        pushEligibility()
        await eligibilityTask?.value
    }

    // MARK: - Spawning

    func spawn(reason: SpawnReason) async throws {
        spawning = true
        defer { spawning = false }
        // A respawn continues the crash series; anything the user asked for starts a new one, which is what makes
        // *Reopen* mean something after the fourth failure.
        if reason != .respawn { crashCount = 0; wasReadyInThisSeries = false }
        // The eviction loop. A victim that wedged or that turned out to be running frees nothing, so the counter
        // names the next one against the same reservation; the loop ends at a grant or a refusal, never at a slot
        // nobody vacated.
        var decision = await fleet.acquire(for: key)
        var granted: Reservation?
        while granted == nil {
            switch decision {
            case .refused(let live):
                state.headerNote = .capReached(live: live)
                state.liveCount = live
                publish()
                throw LifecycleError.capReached(live: live)
            case .granted(let r):
                granted = r
            case .evict(let victim, let r):
                let outcome = await evictVictim(victim)
                await evictionBarrier(victim)
                decision = await fleet.evictionOutcome(r, outcome)
            }
        }
        guard let reservation = granted else { return }

        let before = await ownership.beforeSpawn(session: key.session)
        if !before.isEmpty {
            await fleet.rollback(reservation)
            // The parent's table has no row for a pre-spawn refusal: nothing spawned and nothing was released, so
            // the channel simply takes the origin the holder implies (spec, `Ownership/`).
            adoptOrigin(from: before)
            throw LifecycleError.heldElsewhere(state.observed)
        }

        epoch = epoch.next()
        state.epoch = epoch
        let mine = epoch
        let handle = factory(epoch, launchTemplate)
        process = handle
        startPump(handle)

        do {
            _ = try await handle.spawn(handshakeTimeout: handshakeTimeout)
        } catch {
            await fleet.rollback(reservation)
            if epoch == mine { process = nil }
            throw error
        }
        guard epoch == mine else { return }   // an exit already respawned past this attempt

        let ownPID = await handle.childProcessIdentifier
        let after = await ownership.afterHandshake(session: key.session, ownPID: ownPID, epoch: mine)
        if !after.isEmpty {
            let holders = HolderSet(holders: after, observedAt: Date())
            if case .wedged = await terminateOrWedge(during: .postHandshakeYield) {
                // Our own child would not end, so nothing was released to anyone. Announcing `.releasedToTerminal`
                // here would tell the user afleet let go of a session its own ghost is still holding.
                await fleet.rollback(reservation)
                state.observed = holders
                state.desired = .owned
                publish()
                return
            }
            await fleet.rollback(reservation)
            state.observed = holders
            let (origin, presence) = OriginResolver.resolve(key: key, ownedState: nil, holders: after,
                                                             pendingHatch: false)
            state.presence = presence
            if case .owned(.contended) = origin {
                state.banner = .contended(holders)
                apply(.handshakeFoundHolder, to: .contended)
            } else {
                state.banner = .releasedToTerminal
                apply(.handshakeFoundHolder, to: .foreignUsersTerminal)
            }
            state.desired = .owned
            return
        }

        await fleet.confirm(reservation)
        state.banner = nil
        state.headerNote = nil
        if let resolved = await handle.sessionID { state.identity = .known(resolved) }
        guard reason != .restart else { return }   // Task 6 runs the readbacks and applies `.ready` itself
        apply(.handshakeClean, to: .ready)
        armDormantTimer()
        pushEligibility()
        await flushQueuedInput()
    }

    private func flushQueuedInput() async {
        guard !queuedInput.isEmpty, let handle = process else { return }
        let pending = queuedInput
        queuedInput = []
        for input in pending {
            guard let _ = try? await handle.send(input) else { continue }
            turnRunning = true
            noteActivity()
        }
        pushEligibility()
        publish()
    }

    /// The origin a set of observed holders implies, with no table transition: nothing of ours changed state, the
    /// world did.
    private func adoptOrigin(from holders: [Holder]) {
        let set = HolderSet(holders: holders, observedAt: Date())
        state.observed = set
        let (origin, presence) = OriginResolver.resolve(key: key, ownedState: nil, holders: holders,
                                                        pendingHatch: pendingHatch != nil)
        state.presence = presence
        enter(Self.name(of: origin, isRecent: isRecent))   // no table row: nothing of ours changed, the world did
        state.banner = { if case .owned(.contended) = origin { return .contended(set) } else { return nil } }()
        publish()
    }

    // MARK: - The event pump

    private func startPump(_ handle: any ProcessHandle) {
        pumpTask?.cancel()
        let stream = handle.events
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event: event)
            }
        }
    }

    /// Every engine event, epoch-filtered, fanned out and then acted on.
    public func handle(event: WireEvent) async {
        guard Self.epoch(of: event) >= epoch else { return }
        for continuation in subscribers.values { continuation.yield(event) }

        switch event {
        case .frame(let frame, _):
            noteActivity()
            switch frame {
            case .result:
                turnRunning = false
                pushEligibility()
                armDormantTimer()
                publish()
            case .user:
                turnRunning = true
                pushEligibility()
                publish()
            case .system(.initialize(let initFrame)):
                state.apiKeySource = initFrame.apiKeySource
                publish()
            default:
                break
            }
        case .request(let request):
            state.pendingDecisions.append(PendingDecision(id: request.id, subtype: request.subtype,
                                                          epoch: request.epoch, askedAt: Date()))
            noteActivity()
            pushEligibility()
            state.presence = presenceNow()
            publish()
        case .requestCancelled(let id, _):
            state.pendingDecisions.removeAll { $0.id == id }
            pushEligibility()
            state.presence = presenceNow()
            publish()
        case .exited(let status, let exitedEpoch):
            await handleExit(status, epoch: exitedEpoch)
        default:
            break
        }
    }

    private static func epoch(of event: WireEvent) -> ProcessEpoch {
        switch event {
        case .handshakeCompleted(_, let e), .sessionIdentityResolved(_, let e), .frame(_, let e),
             .requestCancelled(_, let e), .hostToolInvoked(_, let e), .stderr(_, let e), .exited(_, let e):
            return e
        case .request(let r), .policyAnswered(let r, _), .unansweredDialog(let r):
            return r.epoch
        }
    }

    /// A pane exit is matched to the pending hatch by `PaneRequest.id`, never by value equality: two requests with
    /// identical fields are two requests, and an exit from the older one must not re-adopt the newer one's channel.
    ///
    /// The tab closing is not the release. The record it wrote is, so the re-adoption waits for that record to go
    /// and for its pid to die, exactly as every other handoff does.
    public func paneExited(_ exit: PaneExit) async {
        guard let pending = pendingHatch, pending.id == exit.request.id else {
            diagnostics.record(.staleExit(id: exit.request.id, purpose: String(describing: exit.request.purpose)))
            return
        }
        pendingHatch = nil
        let holders = await observer.holders(for: key.session)
        // The tab wrote a registry record of its own: a foreign one, because the pane is not a child of ours and is
        // not a job. A job holder or one of our own children naming the same session is somebody else's business,
        // and waiting out its pid would be waiting for the wrong process to end.
        if let tab = holders.first(where: { !$0.isOwnChild && !$0.isJob }) {
            if case .timedOut = await ownership.awaitRelease(previous: tab, upTo: Self.handoffBudget) {
                enterContended(holders, via: .handoffTimedOut)
                return
            }
        }
        state.desired = .owned
        guard apply(.paneExitedAndRecordGone, to: .connecting) else { return }
        try? await spawn(reason: .ownTabExited)
    }

    // MARK: - Exits

    /// Every branch publishes exactly once — directly, or through the `apply` that succeeded — so a caller watching
    /// `publishedCount` has a synchronisation point that is after the whole decision and not in the middle of it.
    private func handleExit(_ status: ExitStatus, epoch exited: ProcessEpoch) async {
        state.pendingDecisions = []
        turnRunning = false
        process = nil
        pushEligibility()

        // Our own `terminateOrWedge()` ended this epoch. Whatever status the escalation produced is not a crash: a
        // SIGTERM or SIGKILL exit is never `.code(0)`, so a clean-exit test alone would respawn a reaped channel.
        if terminatedEpochs.remove(exited) != nil { publish(); return }
        if status.isClean { await fleet.release(key); publish(); return }
        guard !shuttingDown else { publish(); return }

        crashCount += 1
        await fleet.release(key)
        if crashCount <= Self.backoffs.count {
            let delay = Self.backoffs[crashCount - 1]
            // The table is the authority for the respawn as well: a from-state it admits no crash from gets the
            // `.transitionNotInTable` diagnostic and no replacement child.
            guard apply(.exitedNonZero, to: .connecting) else { publish(); return }
            respawnTask = Task { [weak self] in
                guard let self else { return }
                guard (try? await self.sleepOnClock(delay)) != nil else { return }
                try? await self.spawn(reason: .respawn)
            }
            return
        }
        let target: LifecycleTable.StateName = wasReadyInThisSeries ? .ready : .archivedOlder
        state.systemItem = .crashed(exit: status, reopenOffered: true)
        guard apply(.exitedNonZero, to: target) else { state.systemItem = nil; publish(); return }
    }

    private func sleepOnClock(_ duration: Duration) async throws { try await clock.sleep(for: duration) }

    // MARK: - Holders

    /// The fleet fans every published `HolderSet` to every supervisor; the supervisor narrows it to its own session.
    public func holdersChanged(_ set: HolderSet) async {
        let mine = set.holders.filter { $0.sessionID == key.session }
        state.observed = HolderSet(holders: mine, observedAt: set.observedAt)

        // A ghost stops costing a slot when its record is gone and its pid is dead — and only then.
        if let ghost = state.wedged, !mine.contains(where: { $0.pid == ghost.pid }),
           !ProcessLiveness.isRunning(pid: ghost.pid) {
            await fleet.clearWedged(key)
        }

        let here = currentName
        if here == .contended { resolveContended(mine); return }
        if here == .foreignUsersTerminal {
            guard mine.isEmpty else { publish(); return }
            apply(.recordDisappeared, to: .archivedRecent)
            return
        }
        guard !mine.isEmpty else { publish(); return }

        // Rule 1: afleet wants this channel and somebody else has it. Its own event, never a handoff timeout — the
        // two are raised from different places and G1 has to see both fire. A channel afleet does not want owned
        // takes the dormant `holderAppeared` row below instead.
        // Not while a spawn of ours is in flight: the post-handshake check is about to read the very same holders
        // and take `connectingFoundHolder`, the row that exists for a holder found during a spawn. Raising the
        // disagreement here instead would move the channel to Contended and leave that check's own transition with
        // no candidate — `transitionNotInTable`, which Task 12's gate reads as a programming error.
        if state.desired == .owned, !spawning, here == .connecting || here == .ready || here == .dormant,
           mine.contains(where: { !$0.isOwnChild }) {
            enterContended(mine, via: .desiredObservedDisagree)
            return
        }

        guard here == .dormant else { publish(); return }
        let (origin, presence) = OriginResolver.resolve(key: key, ownedState: nil, holders: mine, pendingHatch: false)
        state.presence = presence
        switch origin {
        case .backgroundJob:
            apply(.holderAppeared, to: .backgroundJob)
        default:
            state.banner = .heldElsewhere(state.observed)
            apply(.holderAppeared, to: .foreignUsersTerminal)
        }
    }

    // MARK: - The dormant timer

    private func armDormantTimer() {
        dormantTimer?.cancel()
        dormantTimer = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.sleepOnClock(Self.dormantAfter)) != nil else { return }
            await self.dormantTimerFired()
        }
    }

    private func dormantTimerFired() async {
        guard currentName == .ready else { return }
        if await currentVerdict().isEligible {
            await reap()
        } else {
            armDormantTimer()
        }
    }

    // MARK: - Eligibility, pushed and never pulled

    private func currentVerdict() async -> DormantEligibility.Verdict {
        var input = await eligibilityInputs()
        input.turnRunning = turnRunning
        input.pendingDecisions = state.pendingDecisions.count
        input.queuedInput = queuedInput.count
        input.wedged = state.wedged != nil
        return DormantEligibility.evaluate(input)
    }

    private func pushEligibility() {
        let previous = eligibilityTask
        let fleet = self.fleet, key = self.key
        eligibilityTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let verdict = await self.currentVerdict()
            await fleet.setEligibility(key, verdict)
        }
    }

    /// Ordered per supervisor, fire-and-forget for the pump: the counter's `activityClock` is fleet-wide, so the
    /// stamps have to land in the order the events did.
    private func noteActivity() {
        state.lastActivity = Date()
        let previous = activityTask
        let fleet = self.fleet, key = self.key
        activityTask = Task {
            await previous?.value
            await fleet.noteActivity(key)
        }
    }
}
