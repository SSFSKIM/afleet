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

/// Builds the supervisor a fork spawns beside this one. The facade injects it (Task 9): a fork is a *new channel*
/// under a provisional key, not a second process on this one. The key is the provisional one this supervisor minted
/// and the `SessionStart` is the fork's, so the sibling's launch template carries the fork on its command line.
/// The source key is a call-time argument and never a captured one: a fork re-keys itself the moment its identity
/// resolves, so a closure that captured the key its channel was built under would look its own source up under a key
/// the fleet no longer files it as — and a fork of a fork would find no project at all.
public typealias SiblingSpawner = @Sendable (_ source: ChannelKey, _ provisional: ChannelKey, _ start: SessionStart)
    async -> ChannelSupervisor?

/// The channel's key, readable without hopping onto the actor. A fork's is provisional until
/// `.sessionIdentityResolved` rewrites it; every other channel's never changes.
final class ChannelKeyBox: @unchecked Sendable {   // `lock` serialises `stored`
    private let lock = NSLock()
    private var stored: ChannelKey
    init(_ key: ChannelKey) { stored = key }
    var value: ChannelKey { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ key: ChannelKey) { lock.lock(); stored = key; lock.unlock() }
}

/// One actor per channel. It owns at most one process at a time, the channel's epoch progression, and every
/// transition, which goes through `LifecycleTable` and nowhere else.
public actor ChannelSupervisor {
    private let keyBox: ChannelKeyBox
    /// The channel's key. A fork's `session` is provisional until the identity event; nothing else ever rewrites it.
    public nonisolated var key: ChannelKey { keyBox.value }

    /// The line every spawn of this channel starts from. A quiescent restart *replaces* it with the line it
    /// composed, so the next respawn continues from the restarted channel rather than reverting to the one the
    /// channel was opened with — which would re-pass `--agent`, and re-passing it replays the agent's
    /// `initialPrompt` as a user turn (parent §7.4). Nothing else writes it.
    private var launchTemplate: LaunchConfiguration
    private let factory: ProcessFactory
    private let ownership: OwnershipCheck
    private let observer: FleetObserver
    private let clock: any Clock<Duration>
    private let eligibilityInputs: @Sendable () async -> DormantEligibility.Input
    /// This channel's fold of C3's task registry, which `eligibilityInputs` reads back. The supervisor writes it and
    /// never reads it: every eligibility decision goes through the one closure, so a rig that states a mirror
    /// outright and a fleet that folds one are the same code path.
    private let taskMirror: ChannelTaskMirror?
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
    /// Awaited at each finalisation site, on the far side of that spawn's last guard and immediately before the
    /// counter turn that takes its slot. Nothing in production; the rig parks here to deliver an exit into the one
    /// window `commitFinalisation` exists for — two actor hops wide, and the interleaving in which the exit's
    /// `release` runs *before* the `confirm` that would outlive it.
    private let finalisationBarrier: @Sendable () async -> Void

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
    /// The one lifecycle operation this channel is running. Taken synchronously after a public entry's pure guards
    /// and cleared by `defer`; a second entrant is refused with `LifecycleError.busy` rather than queued, and
    /// nothing ever waits on it, so nothing can deadlock on it. The two exceptions are documented where they are
    /// taken: a send while a spawn is in flight queues, and a restart asked for while one runs merges. The
    /// observer-driven entries read it and never take it.
    private var inFlight: LifecycleOperation?
    /// The resting state this channel was in when it last entered `.connecting`, so a spawn that does not complete
    /// can put it back there. No table row: nothing of ours changed, the attempt did not happen.
    private var restingOrigin: LifecycleTable.StateName = .dormant

    /// What the channel is *running*: every value here arrived from an engine answer or an engine frame, and the
    /// quiescent restart relaunches from a copy of it rather than from the launch template.
    private var runtime: SessionRuntimeState
    /// The first `system/init` seeds; later ones only report fast mode.
    private var seededFromInit = false
    /// The newest handshake's initialize response, which is the source for the permission-mode and output-style
    /// readbacks.
    private var lastHandshake: InitializeResponse?
    /// The newest `system/init`, kept for the same reason `lastHandshake` is: the router reads
    /// `terminal_slash_commands` off it to refuse a command that belongs to the engine's terminal interface rather
    /// than sending it for the engine to refuse (parent §7.7, contract X10). The seeding the frame also does is
    /// `RuntimeStateUpdater`'s and happens once; this is the report itself, which every later frame replaces.
    private var lastSystemInit: SystemInitFields?
    /// The names a restart's readbacks rejected, in `Readback.verify`'s order. The banner names the first; the user
    /// picking a value for it moves on to the next, and an empty list is what lets the channel become ready.
    private var unresolvedSettings: [String] = []
    /// A fork's reservation, held from the handshake until `.sessionIdentityResolved` says which key it belongs to.
    private var forkReservation: Reservation?
    /// An identity that resolved before the spawn had finished taking its reservation. The engine emits
    /// `auth_status` immediately after the initialize response, so the pump can reach the event while `spawn` is
    /// still suspended inside `handle.spawn`; dropping it would leave the fork connecting forever.
    ///
    /// The epoch travels with the id, because an id belongs to the child that announced it: a spawn parked past its
    /// own exit and a respawn behind it are two engines with two sessions, and consuming the first one's id in the
    /// second one's finalisation re-keys the channel onto a session nothing is running under.
    private var forkIdentityPending: (id: SessionID, epoch: ProcessEpoch)?
    /// The fork's identity deadline. `ClaudeProcess.spawn` returns at the initialize response and cancels its own
    /// handshake timer there, while a fork's id arrives much later off the frame reader, so the spawn's timeout
    /// cannot cover it: without this a fork whose engine never announces an id sits connecting forever, holding a
    /// live child and a cap slot the counter can never reclaim.
    private var forkIdentityTimer: Task<Void, Never>?
    private let spawnSibling: SiblingSpawner
    /// The §6.12 gate every spawn passes first. nil in a rig that is driving a lifecycle row rather than a project.
    private let preconditions: SpawnPreconditions?
    /// The fleet's one spawn barrier, raised while a `LogoutPlan` runs. A supervisor built without one holds its
    /// own, permanently lowered, which is the right answer for a fleet with no router yet.
    private let spawnBarrier: SpawnBarrier
    /// The launch's sources exclude `local` and the project declares `.mcp.json` servers, so `--strict-mcp-config`
    /// is on and the header says the project's servers are off. Re-applied wherever the header note is cleared.
    private var projectServersOff = false

    private let updatesContinuation: AsyncStream<ChannelState>.Continuation
    /// Every transition, published after the state has changed.
    public nonisolated let updates: AsyncStream<ChannelState>

    /// The thirty-minute reap.
    public static let dormantAfter = Duration.seconds(1800)
    /// Three attempts, then the system item.
    public static let backoffs: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// Rule 5's quiescent handoff budget: past it the channel is Contended.
    public static let handoffBudget = Duration.seconds(10)
    /// How long `perform` waits for a control answer before it gives up, on the injected clock.
    public static let controlTimeout = Duration.seconds(30)

    public init(key: ChannelKey, launchTemplate: LaunchConfiguration, factory: @escaping ProcessFactory,
                ownership: OwnershipCheck, observer: FleetObserver, clock: any Clock<Duration>,
                eligibilityInputs: @escaping @Sendable () async -> DormantEligibility.Input,
                taskMirror: ChannelTaskMirror? = nil,
                fleet: FleetCapCounter, diagnostics: any FleetDiagnosticsSink, isRecent: Bool,
                spawnBarrier: SpawnBarrier = SpawnBarrier(),
                environment: ResolvedEnvironment, configHome: ConfigHome, verbs: CLIVerbs,
                store: (any StateStore)? = nil,
                evictVictim: @escaping @Sendable (ChannelKey) async -> EvictionOutcome = { _ in .victimBecameIneligible },
                evictionBarrier: @escaping @Sendable (ChannelKey) async -> Void = { _ in },
                finalisationBarrier: @escaping @Sendable () async -> Void = {},
                spawnSibling: @escaping SiblingSpawner = { _, _, _ in nil },
                preconditions: SpawnPreconditions? = nil,
                initialOrigin: ChannelOrigin = .archived, initialDesired: DesiredOwnership = .none,
                handshakeTimeout: Duration = .seconds(30)) {
        self.keyBox = ChannelKeyBox(key); self.launchTemplate = launchTemplate; self.factory = factory
        self.spawnSibling = spawnSibling; self.preconditions = preconditions
        self.ownership = ownership; self.observer = observer; self.clock = clock
        self.eligibilityInputs = eligibilityInputs; self.taskMirror = taskMirror
        self.fleet = fleet; self.diagnostics = diagnostics
        self.isRecent = isRecent; self.handshakeTimeout = handshakeTimeout; self.spawnBarrier = spawnBarrier
        self.environment = environment; self.configHome = configHome; self.verbs = verbs; self.store = store
        self.evictVictim = evictVictim; self.evictionBarrier = evictionBarrier
        self.finalisationBarrier = finalisationBarrier
        // A fork's own id is minted by the engine and announced on `auth_status`, so the template's `--fork-session`
        // is what says this channel's key is provisional. Nothing else in the launch can tell us.
        let identity: SessionIdentity = {
            switch launchTemplate.session {
            case .resume(let source, true), .forkFrom(let source, _):
                return .awaitingFork(from: source, provisional: key.session)
            case .new, .resume: return .known(key.session)
            }
        }()
        self.state = ChannelState(key: key, origin: initialOrigin, desired: initialDesired,
                                  observed: HolderSet(holders: [], observedAt: Date()),
                                  identity: identity, lastActivity: Date())
        self.runtime = SessionRuntimeState(permissionMode: launchTemplate.permissionMode, model: launchTemplate.model,
                                           effort: launchTemplate.effort, cwd: launchTemplate.cwd,
                                           agent: launchTemplate.agent,
                                           addDirectories: launchTemplate.addDirectories,
                                           environment: launchTemplate.environment)
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// The record a restart relaunches from.
    public func runtimeState() -> SessionRuntimeState { runtime }

    /// Everything `CommandRouter.route` reads off a channel, in one hop: the engine's own report of what it offers
    /// and what the channel is currently running. Nothing here is derived; each value is the newest one the engine
    /// sent, kept where it arrived.
    public func routingContext() -> (handshake: InitializeResponse?, systemInit: SystemInitFields?,
                                     runtime: SessionRuntimeState) {
        (lastHandshake, lastSystemInit, runtime)
    }

    /// The tasks this channel has running or armed, by id. `/logout`'s census lists a channel that is not eligible
    /// together with the tasks that make it so, and *Stop* sends one `stop_task` per id.
    public func liveTaskIDs() async -> [String] {
        let input = await eligibilityInputs()
        return input.mirror.filter { $0.isRunning || $0.isArmed }.map(\.taskID)
    }

    /// This channel's dormant eligibility right now, over the same inputs the reap consults.
    public func currentEligibility() async -> DormantEligibility.Verdict { await currentVerdict() }

    /// True while this channel is a fork whose own session id has not arrived.
    private var isAwaitingFork: Bool { if case .awaitingFork = state.identity { return true }; return false }

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
        // A channel that has archived owns no process, and `events()` hands out an unbounded fan-out per call: a
        // consumer looping over one would wait forever on frames that can never come. `shutdown()` finishes them at
        // app exit, which is far too late — archiving happens on ordinary transitions.
        case .archivedRecent: finishSubscribers(); state.origin = .archived; isRecent = true
        case .archivedOlder: finishSubscribers(); state.origin = .archived; isRecent = false
        case .connecting:
            // Read before the origin moves: `currentName` is still the state this channel is leaving.
            restingOrigin = restingName(leaving: currentName)
            state.origin = .owned(.connecting)
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

    /// The resting state a channel entering `.connecting` is leaving. An owned channel with no process of its own
    /// rests in dormant, so ready and both handoff origins map there; dormant and the two archived names are
    /// already resting states and map to themselves. A respawn inside a crash series — connecting to connecting —
    /// takes the answer that series' own exhaustion row takes: dormant when it had owned the session, and
    /// archived-older when it never reached ready at all.
    private func restingName(leaving from: LifecycleTable.StateName) -> LifecycleTable.StateName {
        switch from {
        case .dormant, .archivedRecent, .archivedOlder: from
        case .connecting: wasReadyInThisSeries ? .dormant : .archivedOlder
        default: .dormant
        }
    }

    /// Puts the channel back in the resting state it left, and answers whether it did. This is `adoptOrigin`'s
    /// idiom and not a transition: the attempt did not happen, so no row describes it. The guard keeps it out of a
    /// crash series `handleExit` has already continued, out of an attempt a newer epoch has replaced, and out of a
    /// channel that is not connecting in the first place.
    @discardableResult
    private func restoreResting(ifEpochIs mine: ProcessEpoch) -> Bool {
        guard epoch == mine, currentName == .connecting, respawnTask == nil else { return false }
        enter(restingOrigin)
        publish()
        return true
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
            // Asked here, before the transition, and not only inside the spawn: a channel refused because the fleet
            // is signing out has to be left exactly as it was, and the `apply` below would already have moved it to
            // connecting with no process behind it. Nothing else in this method can fail, so nothing is half done.
            try spawnBarrier.check()
            if let inFlight { throw LifecycleError.busy(inFlight) }
            self.inFlight = .spawn
            defer { self.inFlight = nil }
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
        // The one operation a send is admitted behind is a spawn: the channel is connecting and the input queues
        // until the handshake lands. Behind anything else — a reap, a handoff, a restart — the channel has already
        // been taken, and writing into a child on its way out is what the marker exists to stop.
        if let inFlight, inFlight != .spawn { throw LifecycleError.busy(inFlight) }
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
            return try await resume(input)
        case .archived:
            return try await resume(input)
        case .owned(.connecting):
            // A send while a spawn is in flight. The input is queued and goes out when the handshake lands; the
            // uuid returned here is not the one the engine will echo, because `ProcessHandle.send` mints its own.
            // This supervisor serialises its own operations and the facade adds nothing on top of that: this is the
            // one place a second caller is admitted rather than refused, because queueing is what the user means.
            queuedInput.append(input)
            pushEligibility()
            return UUID()
        case .owned(.contended):
            throw LifecycleError.heldElsewhere(state.observed)
        }
    }

    /// The dormant and archived resume: one spawn and then the input, under one marker, so nothing may reap the
    /// channel or hand it off in between.
    private func resume(_ input: UserInput) async throws -> UUID {
        inFlight = .spawn
        defer { inFlight = nil }
        state.desired = .owned
        apply(.userSent, to: .connecting)
        try await spawn(reason: .userSent)
        return try await deliver(input)
    }

    /// The turn is marked running *before* the write, not after it. The reap, the eviction and the restart each
    /// re-evaluate eligibility at the moment they act, and a turn that has started but not returned has to be
    /// visible to them; marking it afterwards leaves a window in which the channel looks idle while the user's
    /// input is already on its way to the engine.
    private func deliver(_ input: UserInput) async throws -> UUID {
        guard let handle = process else { throw LifecycleError.notOwned }
        let wasRunning = turnRunning
        turnRunning = true
        pushEligibility()
        let uuid: UUID
        do {
            uuid = try await handle.send(input)
        } catch {
            turnRunning = wasRunning
            pushEligibility()
            throw error
        }
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

    /// The thirty-minute reap, and `LifecycleAction.reap`. A channel already running an operation of its own is
    /// left alone: the reap has nothing to report, so the refusal is silence rather than an error.
    public func reap() async {
        guard inFlight == nil else { return }
        inFlight = .reap
        defer { inFlight = nil }
        _ = await endProcess(during: .reap)
    }

    /// `/logout`'s terminate. A terminate with no replacement is a reap, and the plan invents no transition of its
    /// own; what makes it a logout is the action name the wedged row records, so a ghost left by a logout and one
    /// left by a reap are two different observations.
    @discardableResult
    public func terminateForLogout() async -> TerminateOutcome {
        await endProcess(during: .logout)
    }

    /// §7.4 *Quit*'s terminate. Modelled on `terminateForLogout()` and separate from it for the same reason: what
    /// makes it a quit is the action name the wedged row records, so a ghost the quit left behind is not read as a
    /// reap's. Ungated and unguarded by `inFlight`: the confirmed quit must end a channel whose spawn or restart is
    /// mid-flight too, and a channel it could not end is a ghost the trace names rather than a channel it skipped.
    @discardableResult
    public func terminateForQuit() async -> TerminateOutcome {
        await endProcess(during: .quit)
    }

    /// Ends this channel's process and, when it really exited, marks the channel dormant and gives its slot back.
    /// A `nil` exit stops here: no dormant mark and no released slot, because the ghost is still out there.
    private func endProcess(during action: LifecycleTable.TerminatingAction) async -> TerminateOutcome {
        // A channel that is *already* wedged is not a channel that has gone: `terminateOrWedge` deliberately keeps
        // `process` non-nil because the ghost is still out there. The two early exits must not answer the same way,
        // or a caller that reads this outcome — `/logout` does — would take a live ghost for an exited channel and
        // do what only an exit permits.
        if let trace = state.wedged { return .wedged(trace) }
        // A channel whose only claim to a process is a respawn parked on its backoff. Cancelling that task is what
        // ends the attempt, and an attempt that did not happen leaves the channel in the state it left — the same
        // non-row a refused spawn takes, seen from the other side.
        if process == nil, respawnTask != nil, currentName == .connecting {
            respawnTask?.cancel(); respawnTask = nil
            enter(restingOrigin)
            publish()
            pushEligibility()
            return .exited(.code(0, stderrTail: ""))
        }
        guard process != nil else { return .exited(.code(0, stderrTail: "")) }
        let outcome = await terminateOrWedge(during: action)
        guard case .exited = outcome else { return outcome }
        process = nil
        // A restart takes the same step only from ready: the table has no `dormantTimerFired` out of connecting,
        // and a handshake ended mid-flight leaves the channel where it was rather than in a state invented here.
        if currentName == .ready { apply(.dormantTimerFired, to: .dormant) }
        await fleet.release(key)
        pushEligibility()
        return outcome
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

    /// The *Reopen* every offered item carries — a crash series' item, a fork whose identity never arrived, and the
    /// ghost of a wedged channel. It spawns only when the pre-spawn check finds no holder: the ghost may still be
    /// holding the transcript, and a second writer under one session id is the thing the checks exist to prevent.
    ///
    /// No new event and no new row. Clearing the item makes the channel the resting channel it structurally is, and
    /// the user's request is then that state's own ordinary resume: the dormant send row, the archived-older send
    /// row, or the archived-recent open row.
    public func reopen() async throws {
        guard let item = state.systemItem, Self.offersReopen(item) else { return }
        // A wedged channel is the dormant channel it structurally is once the trace goes.
        let resting = state.wedged == nil ? currentName : LifecycleTable.StateName.dormant
        guard let event = Self.resumeEvent(from: resting) else { return }
        if let inFlight { throw LifecycleError.busy(inFlight) }
        self.inFlight = .reopen
        defer { self.inFlight = nil }
        let holders = await ownership.beforeSpawn(session: key.session)
        if let trace = state.wedged, holders.isEmpty, ProcessLiveness.isRunning(pid: trace.pid) {
            // A ghost stops mattering when its record is gone *and* its pid is dead — `holdersChanged` frees the
            // slot on exactly those two facts. A child that will not die but whose record the CLI has already
            // removed is invisible to the holder check, and spawning behind it puts two writers on one transcript.
            throw LifecycleError.wedged(trace)
        }
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
        state.wedged = nil
        state.systemItem = nil
        if ghost != nil {
            // Only the wedged row keeps a `process` behind a channel that has none; every other offered item is on
            // a channel whose process is already gone.
            process = nil
            await fleet.clearWedged(key)
        }
        state.desired = .owned
        guard apply(event, to: .connecting) else {
            state.wedged = ghost
            state.systemItem = item
            return
        }
        try await spawn(reason: .reopen)
    }

    /// Whether an item offers *Reopen*. All three carry the flag, because what the user needs from each is the same.
    private static func offersReopen(_ item: SystemItem) -> Bool {
        switch item {
        case .crashed(_, let offered), .wedged(_, let offered), .forkIdentityTimedOut(_, let offered): offered
        }
    }

    /// The row a resting state comes back through. Anything else is a channel that is not resting, and *Reopen* has
    /// nothing to do on one.
    private static func resumeEvent(from resting: LifecycleTable.StateName) -> LifecycleTable.Event? {
        switch resting {
        case .dormant, .archivedOlder: .userSent
        case .archivedRecent: .opened
        default: nil
        }
    }

    // MARK: - Adopt

    /// §7.4's job-adoption row: stop the job, wait for its worker to leave the roster and die, then resume it owned.
    public func adopt() async throws {
        if let inFlight { throw LifecycleError.busy(inFlight) }
        self.inFlight = .adopt
        defer { self.inFlight = nil }
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
            let short = try await verbs.backgroundResume(key.session, cwd: runtime.cwd)
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
                                      cwd: runtime.cwd, purpose: .hatch(key.session))
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
        // Before the origin is even read, and for the same reason `openInTerminal` is gated at the facade: a handoff
        // admitted after `/logout`'s census — or suspended across it — terminates this child and launches work the
        // census cannot see. `ownJobShorts` was read before that job existed, so nothing stops it; the channel is
        // processless by then, so the plan's terminate answers a clean exit and `claude auth logout` runs over a
        // `--bg` worker afleet started seconds earlier. Nothing has changed yet, so the refusal leaves nothing behind.
        try spawnBarrier.check()
        guard case .owned(let owned) = state.origin, owned == .ready || owned == .dormant else {
            throw LifecycleError.notOwned
        }
        if let trace = state.wedged { throw LifecycleError.wedged(trace) }
        if let inFlight { throw LifecycleError.busy(inFlight) }
        self.inFlight = .handOff
        defer { self.inFlight = nil }

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

    /// One append, not a read and a write. Two supervisors handing off at once are two actors over one store, and
    /// a read-then-write across two hops loses whichever short landed in between: the shorts are how afleet knows
    /// which jobs are its own, and a lost one is a job the sidebar never claims.
    private func rememberOwnJob(_ short: JobShort) async throws {
        guard let store else { return }
        try await store.appendUnique(short.rawValue, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
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
        paneRequest(arguments: ["attach", job.short.rawValue], cwd: job.cwd ?? runtime.cwd,
                    purpose: .attach(job.short))
    }

    /// `claude logs <short>` in a pane. It changes no ownership.
    public func logs(job: JobEntry) -> PaneRequest {
        paneRequest(arguments: ["logs", job.short.rawValue], cwd: job.cwd ?? runtime.cwd,
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
        // The marker before the eligibility check, and held across the terminate: a channel already running an
        // operation of its own is not a victim, and taking it here is what keeps a send from starting between the
        // verdict and the child ending.
        guard inFlight == nil else { return .victimBecameIneligible }
        inFlight = .evict
        defer { inFlight = nil }
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

    private func finishSubscribers() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    /// Finishes every subscriber stream and cancels the dormant timer. It terminates nothing: the facade calls this
    /// at app exit, and the user's channels keep running.
    public func shutdown() {
        shuttingDown = true
        dormantTimer?.cancel(); dormantTimer = nil
        forkIdentityTimer?.cancel(); forkIdentityTimer = nil
        respawnTask?.cancel(); respawnTask = nil
        pumpTask?.cancel(); pumpTask = nil
        finishSubscribers()
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

    /// `launch` overrides the template for this spawn only: the quiescent restart composes its line from the runtime
    /// snapshot, and nothing else does.
    func spawn(reason: SpawnReason, launch launchOverride: LaunchConfiguration? = nil) async throws {
        // Before anything: a channel must not come up into a fleet that is signing out from under it. Nothing has
        // changed yet, so the refusal leaves no state behind.
        let entry = epoch
        do { try spawnBarrier.check() } catch { restoreResting(ifEpochIs: entry); throw error }
        // `spawn` is internal, and is reached either with the marker already held by the public entry that led here
        // or with nothing in flight at all — a respawn, a pane exit, a rig driving a row. It therefore adopts the
        // marker when it is free and clears only what it took.
        let ownsMarker = inFlight == nil
        if ownsMarker { inFlight = .spawn }
        defer { if ownsMarker { inFlight = nil } }
        unresolvedSettings = []   // whatever an earlier restart could not read back died with its process

        // The §6.12 gate, before the cap and before the pre-spawn check: a project afleet may not spawn into must
        // not take a slot on the way to being refused, and nothing here changes a state a transition could refuse.
        // Group D: what this channel is *running*, not what it was opened with. `--resume` restores the
        // conversation and nothing else, so a `/model`, a `/permissions`, an `/effort`, a `/cd` or an `/add-dir`
        // lives in `runtime` and has to be put back on the command line of every child — the dormant resume, the
        // crash respawn, the reopen, the adopt and the pane re-adoption alike. The quiescent restart composes its
        // own line and passes it as `launch`, which is the one override there is.
        //
        // `agent` is deliberately not composed. The restart clears it because re-passing `--agent` replays the
        // agent's `initialPrompt` as a user turn (parent §7.4); the runtime still remembers the name for the
        // header, and taking it from there would put the flag back.
        var template = launchOverride ?? composedFromRuntime()
        if let preconditions {
            let (verdict, resolved) = await preconditions.evaluate(
                key: key, cwd: template.cwd, launch: template, configHome: configHome, wedged: state.wedged,
                foreignHolders: state.observed.foreign, store: store)
            diagnostics.record(.precondition(verdict: Self.name(of: verdict), session: key.session.description))
            guard verdict == .ready else {
                // A consent sheet is not a banner, and a decline that was just refused has already set one that
                // says more than "consent needed" would; the other verdicts each have their own.
                switch verdict {
                case .untrusted: state.banner = .untrusted
                case .managedSettingsPending: state.banner = .managedSettingsPending
                case .contended(let holders): state.banner = .contended(holders)
                case .ready, .consentNeeded, .wedged: break
                }
                if !restoreResting(ifEpochIs: entry) { publish() }
                throw LifecycleError.precondition(verdict)
            }
            template = resolved
            projectServersOff = resolved.strictMCPConfig
        }
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
                if !restoreResting(ifEpochIs: entry) { publish() }
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

        // The barrier again, after the last await and before the epoch this line advances. Three awaits stand
        // between the check at the top of this method and here, and `/logout`'s census runs in exactly that window:
        // it reports the channel as processless, `claude auth logout` runs, and a child launched behind it loses
        // its credentials mid-handshake. The reservation goes back on the refusal.
        do { try spawnBarrier.check() } catch {
            await fleet.rollback(reservation)
            restoreResting(ifEpochIs: entry)
            throw error
        }

        epoch = epoch.next()
        state.epoch = epoch
        let mine = epoch
        let handle = factory(epoch, template)
        process = handle
        startPump(handle)

        do {
            let handshake = try await handle.spawn(handshakeTimeout: handshakeTimeout)
            if epoch == mine {
                lastHandshake = handshake.initialize
                RuntimeStateUpdater.apply(handshake: handshake.initialize, to: &runtime)
            }
        } catch {
            await fleet.rollback(reservation)
            if epoch == mine {
                process = nil
                forkIdentityPending = nil
                // The channel is put back only when this supervisor ended the epoch itself — a `/logout` terminate
                // caught the handshake — because that is the one case in which nothing else will act. Every other
                // failure here has an exit on its way: `ClaudeProcess` settles the handshake waiter from its exit
                // path and pushes `.exited` immediately after, and `handleExit` owns that outcome. It continues the
                // crash series and rests the channel when the series is exhausted, and restoring here as well would
                // take the from-state that exit's own row needs out from under it.
                if terminatedEpochs.contains(mine) { restoreResting(ifEpochIs: mine) }
            }
            throw error
        }
        // An exit already respawned past this attempt, or ended the child this one was finalising. Either way the
        // finalisation below is about a process that is not this channel's any more, and the one thing this attempt
        // still owes the fleet is its slot: returning with the reservation held costs one of the six permanently,
        // per race. `ProcessHandle` is `Sendable` and not `AnyObject`, so the handle cannot be compared by identity
        // — epoch equality plus non-nil is sufficient, because only a new spawn replaces the handle and that
        // advances the epoch.
        //
        // And it rests the channel. A child that ends *cleanly* in this window is nobody's crash — `handleExit`
        // takes `.exitedClean` only from ready, so it leaves a connecting channel alone — and returning here without
        // the restore leaves an owned channel connecting with no process, which ruling 1 says never happens.
        // `restoreResting` refuses when a crash series' respawn is parked or a newer epoch owns the channel, so the
        // paths that do have an exit on their way are untouched.
        guard epoch == mine, process != nil else {
            await fleet.rollback(reservation)
            restoreResting(ifEpochIs: mine)
            return
        }

        // A fork's key is a random provisional id, so the post-handshake check has nothing to ask about: it runs on
        // the *resolved* id when `.sessionIdentityResolved` arrives, and until then the channel stays connecting.
        // The reservation is held rather than confirmed, because which key it belongs to is not known yet.
        if isAwaitingFork {
            state.banner = nil
            state.headerNote = projectServersOff ? .projectServersOff : nil
            forkReservation = reservation
            if let pending = forkIdentityPending, pending.epoch == mine {
                forkIdentityPending = nil
                await resolveForkIdentity(pending.id, epoch: mine)
                return
            }
            forkIdentityPending = nil
            armForkIdentityDeadline(epoch: mine)
            return
        }

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

        // Two more awaits have run since the guard above, and the child can die in either of them.
        guard epoch == mine, process != nil else {
            await fleet.rollback(reservation)
            restoreResting(ifEpochIs: mine)
            return
        }
        // Read before the counter turn rather than after it, so `confirm` is the only hop left between this guard
        // and the one below.
        let announced = await handle.sessionID
        await finalisationBarrier()
        await fleet.confirm(reservation)
        guard await commitFinalisation(epoch: mine, confirmedAs: key) else { return }
        state.banner = nil
        state.headerNote = projectServersOff ? .projectServersOff : nil
        if let announced { state.identity = .known(announced) }
        guard reason != .restart else { return }   // Task 6 runs the readbacks and applies `.ready` itself
        apply(.handshakeClean, to: .ready)
        armDormantTimer()
        pushEligibility()
        await flushQueuedInput()
    }

    /// The last guard of both spawn paths, run after their last await rather than before it.
    ///
    /// Every guard earlier in a spawn is an *entry* check, and the marker keeps other entrants out. This one is
    /// about an observer: `handleExit` clears `process` from the pump without advancing the epoch, so it can land
    /// inside the counter turn that takes the slot, and the epoch alone would still read as this attempt's. What
    /// follows a confirmed slot — `.ready`, the identity, the key, the queued input — belongs to a live child only.
    ///
    /// On a no, the undo is a *release* and not a rollback: the reservation has already become a live entry, and
    /// `FleetCapCounter.release` is the only thing that removes one. `handleExit`'s own release ran while this
    /// attempt was suspended, against a `live` set the confirm had not written yet, so without this the entry
    /// outlives the channel — one of six slots, for the life of the process. Then the channel rests, because an
    /// owned channel left connecting with no process is ruling 1's flat prohibition and has no way back:
    /// `send` throws, `reap` returns early on `process == nil`, and with no `systemItem` *Reopen* refuses.
    private func commitFinalisation(epoch mine: ProcessEpoch, confirmedAs confirmed: ChannelKey) async -> Bool {
        guard epoch == mine, process != nil else {
            await fleet.release(confirmed)
            restoreResting(ifEpochIs: mine)
            return false
        }
        return true
    }

    /// The launch template with every field the channel has since changed taken from the runtime record. The
    /// template keeps what only it knows — the binary, the session start, the invariants a restart request set, and
    /// the agent.
    private func composedFromRuntime() -> LaunchConfiguration {
        var launch = launchTemplate
        launch.cwd = runtime.cwd
        launch.model = runtime.model
        launch.permissionMode = runtime.permissionMode
        launch.effort = runtime.effort
        launch.addDirectories = runtime.addDirectories
        launch.environment = runtime.environment
        return launch
    }

    /// The verdict's own word, with no payload: a precondition diagnostic names a shape, never a path or a record.
    private static func name(of verdict: SpawnPrecondition) -> String {
        switch verdict {
        case .ready: "ready"
        case .untrusted: "untrusted"
        case .consentNeeded(let servers): "consentNeeded(\(servers.count))"
        case .managedSettingsPending: "managedSettingsPending"
        case .contended(let holders): "contended(\(holders.holders.count))"
        case .wedged: "wedged"
        }
    }

    /// *Decline*: the one Claude Code-owned file afleet writes, through §6.12's resolver and write policy. A refusal
    /// banners the reason word and changes nothing else — the channel is still consent-blocked and the sheet is
    /// still the way out.
    ///
    /// §6.12's precondition is about the *project*, not about this channel: two channels in one project — ordinary
    /// for this app — must not let the idle one write while the other's child is live. Only the facade holds the
    /// project-to-channel index, so it answers `projectHasLiveProcess` and this supervisor ors its own process in.
    public func declineProjectServers(_ names: [String], projectHasLiveProcess: Bool) async throws {
        guard let preconditions else { throw LifecycleError.notOwned }
        do {
            // The runtime cwd, not the template's: a `set_cwd` moves the project the channel is in, and the store
            // resolves from where the channel actually is.
            try preconditions.decline(names: names, cwd: runtime.cwd, configHome: key.configHome,
                                      processIsLive: projectHasLiveProcess || process != nil)
            diagnostics.record(.declineWrite(outcome: "written", servers: names.count))
        } catch let error as LifecycleError {
            guard case .declineRefused(let reason) = error else { throw error }
            diagnostics.record(.declineWrite(outcome: reason, servers: names.count))
            state.banner = .mcpDeclineRefused(reason)
            publish()
            throw error
        }
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

    // MARK: - Control requests

    /// The one door for a control request. Task 8's strategy executor and the app both come through here, and every
    /// answer passes through `RuntimeStateUpdater` on the way out — which is what makes the runtime record the
    /// channel's own account of itself rather than a second guess maintained beside it.
    @discardableResult
    public func perform<R: ControlRequestSpec>(_ request: R) async throws -> R.Response {
        guard let handle = process else { throw LifecycleError.notOwned }
        let answer = try await bounded(request, on: handle)
        RuntimeStateUpdater.apply(answer: answer, for: request, to: &runtime)
        noteActivity()
        return answer
    }

    /// The wait is bounded on the *injected* clock rather than on `ProcessHandle.request`'s own timeout, which runs
    /// on real time inside ClaudeWire: an engine that never answers must not be able to hang a restart in
    /// `.connecting` with no banner and no way out, and a test must be able to reach that case without sleeping.
    private func bounded<R: ControlRequestSpec>(_ request: R, on handle: any ProcessHandle) async throws -> R.Response {
        let subtype = RuntimeStateUpdater.subtype(of: request)
        let clock = self.clock, budget = Self.controlTimeout
        return try await withThrowingTaskGroup(of: R.Response.self) { group in
            group.addTask { try await handle.request(request, timeout: nil) }
            group.addTask {
                try await clock.sleep(for: budget)
                throw WireError.controlError("timeout after \(budget) waiting for \(subtype)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw WireError.controlError("no answer for \(subtype)")
            }
            return first
        }
    }

    // MARK: - Fork

    /// Spawns a fork of this channel as a new channel under a provisional key, and returns that key.
    ///
    /// The key is provisional because `--fork-session` makes the engine mint a fresh session id and announce it on
    /// `auth_status`: the `--resume` target names the session forked *from* and never the fork's own. The sibling
    /// therefore stays `.connecting` until `.sessionIdentityResolved`, when the ownership check runs against the id
    /// that actually arrived and the counter's slot is rekeyed onto it.
    ///
    /// `--resume-session-at` and `--resume-drops-turn` are the line composer's: this appends no argument of its own.
    @discardableResult
    public func fork(at point: ForkPoint?) async throws -> ChannelKey {
        guard let source = state.identity.resolved else { throw LifecycleError.notOwned }
        let start: SessionStart = point.map { .forkFrom(source, at: $0) } ?? .resume(source, fork: true)
        let provisional = ChannelKey(configHome: key.configHome, session: SessionID())
        guard let sibling = await spawnSibling(key, provisional, start) else { throw LifecycleError.notOwned }
        try await sibling.open()
        return provisional
    }

    /// The fork's own id has arrived. In order: the post-handshake check against the *resolved* id, where a holder
    /// takes the `connectingFoundHolder` rows exactly as a post-handshake holder does; then, clean, one counter turn
    /// moving the slot onto the resolved key, the key itself, the identity, and only now `.ready`.
    private func resolveForkIdentity(_ resolved: SessionID, epoch resolvedEpoch: ProcessEpoch) async {
        guard case .awaitingFork = state.identity, resolvedEpoch == epoch,
              let handle = process, let reservation = forkReservation else { return }
        // This is the rest of the fork's spawn, and ruling 2's marker belongs on it wherever it is reached from:
        // inline from `spawn`, where the marker is already held, or — the ordinary case — from the pump, minutes
        // after `open()` returned, with nothing in flight. Four awaits follow, and without the marker the
        // thirty-minute reap, the cap eviction, `/logout`'s terminate and the quiescent restart each pass their own
        // `inFlight == nil` guard and end the child this method is about to publish ready.
        let ownsMarker = inFlight == nil
        if ownsMarker { inFlight = .spawn }
        defer { if ownsMarker { inFlight = nil } }
        forkIdentityTimer?.cancel(); forkIdentityTimer = nil
        forkReservation = nil

        // Every question from here on is about the *resolved* session, the provisional key included: a holder set is
        // narrowed by session id, and narrowing it by the random provisional would find nobody.
        let resolvedKey = ChannelKey(configHome: key.configHome, session: resolved)
        let ownPID = await handle.childProcessIdentifier
        let after = await ownership.afterHandshake(session: resolved, ownPID: ownPID, epoch: resolvedEpoch)
        if !after.isEmpty {
            let holders = HolderSet(holders: after, observedAt: Date())
            if case .wedged = await terminateOrWedge(during: .postHandshakeYield) {
                await fleet.rollback(reservation)
                state.observed = holders
                state.desired = .owned
                publish()
                return
            }
            await fleet.rollback(reservation)
            state.observed = holders
            let (origin, presence) = OriginResolver.resolve(key: resolvedKey, ownedState: nil, holders: after,
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

        // Two awaits have run since this method took the reservation out of `forkReservation`, so `handleExit`
        // cannot give it back: an exit in that window leaves the checks below asking about a process that is gone,
        // and the rollback is this method's own.
        guard resolvedEpoch == epoch, process != nil else {
            await fleet.rollback(reservation)
            return
        }
        await finalisationBarrier()
        await fleet.rekey(key, to: resolvedKey)
        await fleet.confirm(reservation)
        guard await commitFinalisation(epoch: resolvedEpoch, confirmedAs: resolvedKey) else {
            // The counter was told to use the resolved key and this channel never will: it is keyed provisionally
            // until the line below, and a respawn or a reap would release a key nothing holds. The slot itself is
            // already back; this is the recency stamp and the eligibility verdict following it home.
            await fleet.rekey(resolvedKey, to: key)
            return
        }
        keyBox.set(resolvedKey)
        state.key = resolvedKey
        state.identity = .known(resolved)
        // Every later launch of this channel resumes the fork's *own* session. The template it was built from names
        // the session it forked from and carries `--fork-session`; relaunching from that would mint a third session
        // and leave this fork's transcript behind. `relaunch` already forces the same value for a restart.
        launchTemplate.session = .resume(resolved, fork: false)
        apply(.handshakeClean, to: .ready)
        armDormantTimer()
        pushEligibility()
        await flushQueuedInput()
    }

    /// The fork's identity deadline, on the injected clock. It is not the spawn's timeout — that one has already
    /// returned — so this is the supervisor's own, armed when the fork's handshake lands and cancelled the moment the
    /// identity arrives.
    private func armForkIdentityDeadline(epoch deadlineEpoch: ProcessEpoch) {
        forkIdentityTimer?.cancel()
        let budget = handshakeTimeout
        forkIdentityTimer = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.sleepOnClock(budget)) != nil else { return }
            await self.forkIdentityDeadlineExpired(epoch: deadlineEpoch)
        }
    }

    /// No id within the budget. The channel is failed the way a spawn error fails it: the child is ended, the
    /// reservation goes back, nothing is published ready, and the channel is left connecting with no process.
    private func forkIdentityDeadlineExpired(epoch deadlineEpoch: ProcessEpoch) async {
        forkIdentityTimer = nil
        guard isAwaitingFork, deadlineEpoch == epoch, let reservation = forkReservation else { return }
        forkReservation = nil
        forkIdentityPending = nil
        diagnostics.record(.forkIdentityDeadlineExpired(session: key.session.description,
                                                        epoch: deadlineEpoch.rawValue))
        // The parent's wedged row is "Owned, any", and the yield of a spawn that cannot finish is the action this
        // one is: `postHandshakeYield` fires only from connecting, which is where a fork without an id sits.
        let outcome = await terminateOrWedge(during: .postHandshakeYield)
        guard case .exited(let status) = outcome else {
            await fleet.rollback(reservation)
            return
        }
        process = nil
        await fleet.rollback(reservation)
        // Something the user can see. Its own case, because this is not a crash: afleet ended a child whose engine
        // would not say which session it was. The channel goes back to the resting state the spawn left, exactly as
        // a refused spawn leaves it — nothing rests in connecting with no process — and the item is what offers the
        // way forward from there.
        state.systemItem = .forkIdentityTimedOut(exit: status, reopenOffered: true)
        if !restoreResting(ifEpochIs: deadlineEpoch) { publish() }
    }

    // MARK: - The quiescent restart

    /// §7.4's quiescent restart. It carries the channel's runtime state and never the launch template: `--resume`
    /// restores the conversation and nothing else, so the permission mode, the model, the effort and every
    /// `apply_flag_settings` value have to be put back by hand and then read back.
    ///
    /// The channel is not eligible yet: the change is queued and the composer says so, and the dormant timer runs it
    /// when the current work finishes. Eligible: snapshot, terminate (a `nil` wedges and stops here), wait for the
    /// release, relaunch every launch field from the snapshot with no `--agent`, re-send the whole flag union, ask
    /// `get_settings`, and publish `.ready` only once every readback matches.
    public func quiescentRestart(_ request: RestartRequest) async throws {
        // The same door `handOff` and `reap` stand behind. Without it a wedged channel would take the queueing
        // branch and be told the change "applies when the current work finishes" — a wedged channel is never
        // eligible, so it never would — and a channel that owns nothing would terminate nothing and spawn anyway,
        // leaving a live child on an origin that says the session is somebody else's.
        guard case .owned(let owned) = state.origin,
              owned == .ready || owned == .dormant || owned == .connecting else {
            throw LifecycleError.notOwned
        }
        if let trace = state.wedged { throw LifecycleError.wedged(trace) }
        // The second exception to the marker: two restart-required changes are one restart, so a change asked for
        // while one runs merges into the pending change rather than terminating the channel a second time.
        if inFlight == .restart {
            state.pendingChange = Self.merge(state.pendingChange, request)
            publish()
            return
        }
        if let inFlight { throw LifecycleError.busy(inFlight) }
        self.inFlight = .restart
        defer { self.inFlight = nil }
        try await restartNow(request)
    }

    /// The restart itself, with the marker already held. The dormant timer takes the marker before the eligibility
    /// check it shares with the eviction and then comes in here, so the check and the terminate it authorises are
    /// one window rather than two.
    private func restartNow(_ request: RestartRequest) async throws {
        guard await currentVerdict().isEligible else {
            state.pendingChange = Self.merge(state.pendingChange, request)
            publish()
            return
        }
        let snapshot = runtime
        let ownPID = await process?.childProcessIdentifier ?? 0
        if case .wedged(let trace) = await terminateOrWedge(during: .restart) {
            state.pendingChange = nil          // nothing is queued behind a ghost
            throw LifecycleError.wedged(trace)
        }
        state.pendingChange = nil
        process = nil
        await fleet.release(key)
        if ownPID > 0 {
            let own = Holder(pid: ownPID, sessionID: key.session, sources: [.registry], kind: "own", isOwnChild: true)
            // A wait that runs out leaves the holder in place for the pre-spawn check inside `spawn`, which refuses
            // every live holder: the restart never writes the transcript behind somebody still holding it.
            _ = await ownership.awaitRelease(previous: own, upTo: Self.handoffBudget)
        }

        // Terminate with no replacement yet is a reap, and a resume under the same session id is the dormant-send
        // row: the restart is those two, in that order, and invents no transition of its own.
        if currentName == .ready {
            guard apply(.dormantTimerFired, to: .dormant) else { return }
        }
        state.desired = .owned
        if currentName == .dormant {
            guard apply(.userSent, to: .connecting) else { return }
        }

        launchTemplate = relaunch(from: snapshot, applying: request)
        try await spawn(reason: .restart, launch: launchTemplate)
        guard currentName == .connecting, process != nil else { return }   // the spawn yielded or wedged

        if !snapshot.flagSettings.isEmpty {
            _ = try await perform(ApplyFlagSettings(settings: .object(snapshot.flagSettings)))
        }
        let settings = try await perform(GetSettings())
        let handshake = lastHandshake ?? InitializeResponse(raw: .object([:]))
        unresolvedSettings = Readback.verify(
            snapshot: snapshot, handshake: handshake,
            settingsApplied: settings["applied"] ?? .object([:]),
            // `effective` is an *object* of the settings the engine has applied, keyed by name; the readback wants
            // the names and never the values, which a fixture redacts anyway.
            effectiveKeys: settings["effective"]?.objectValue.map { Array($0.keys) } ?? [])
        await becomeReadyOrBanner()
    }

    /// Two restart-required changes, folded into one. Directories accumulate — a second `/add-dir` must not lose
    /// the first — and every other field is a value the later request replaces.
    private static func merge(_ existing: RestartRequest?, _ incoming: RestartRequest) -> RestartRequest {
        guard var merged = existing else { return incoming }
        if let directories = incoming.addDirectories {
            var union = merged.addDirectories ?? []
            for directory in directories where !union.contains(directory) { union.append(directory) }
            merged.addDirectories = union
        }
        if let sources = incoming.settingSources { merged.settingSources = sources }
        if let allowBypass = incoming.allowBypass { merged.allowBypass = allowBypass }
        if let suggestions = incoming.promptSuggestions { merged.promptSuggestions = suggestions }
        if let worktree = incoming.worktree { merged.worktree = worktree }
        if let environment = incoming.environment { merged.environment = environment }
        return merged
    }

    /// The user picked a value for a setting that did not survive. The next unresolved one takes the banner; with
    /// none left the channel is finally ready.
    public func resolveSetting(_ name: String) async {
        guard unresolvedSettings.first == name else { return }
        unresolvedSettings.removeFirst()
        await becomeReadyOrBanner()
    }

    private func becomeReadyOrBanner() async {
        guard unresolvedSettings.isEmpty else {
            state.banner = .settingDidNotSurvive(unresolvedSettings[0])
            publish()
            return
        }
        state.banner = nil
        guard apply(.handshakeClean, to: .ready) else { return }
        armDormantTimer()
        pushEligibility()
        await flushQueuedInput()
    }

    /// Every launch field from the snapshot, the template's invariants, and never `--agent`: re-passing it replays
    /// the agent's `initialPrompt` as a user turn behind the connecting glyph (parent §7.4).
    private func relaunch(from snapshot: RestartSnapshot, applying request: RestartRequest) -> LaunchConfiguration {
        var launch = launchTemplate
        launch.session = .resume(key.session, fork: false)
        launch.cwd = snapshot.cwd
        launch.model = snapshot.model
        launch.permissionMode = snapshot.permissionMode
        launch.effort = snapshot.effort
        launch.addDirectories = request.addDirectories ?? snapshot.addDirectories
        launch.environment = request.environment ?? snapshot.environment
        launch.agent = nil
        // Each invariant the request names is overridden; an outer nil keeps the template's, an inner nil clears it.
        if let settingSources = request.settingSources { launch.settingSources = settingSources }
        if let worktree = request.worktree { launch.worktree = worktree }
        if let allowBypass = request.allowBypass { launch.allowBypass = allowBypass }
        if let promptSuggestions = request.promptSuggestions { launch.promptSuggestions = promptSuggestions }
        runtime.addDirectories = launch.addDirectories
        runtime.environment = launch.environment
        return launch
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
        case .sessionIdentityResolved(let resolved, let resolvedEpoch):
            guard isAwaitingFork, resolvedEpoch == epoch else { return }
            // The spawn may still be inside `handle.spawn`: the engine emits `auth_status` right after the initialize
            // response, so the reservation this event has to move may not have been recorded yet.
            guard forkReservation != nil else { forkIdentityPending = (resolved, resolvedEpoch); return }
            await resolveForkIdentity(resolved, epoch: resolvedEpoch)
        case .frame(let frame, let frameEpoch):
            noteActivity()
            RuntimeStateUpdater.apply(frame: frame, to: &runtime, seededFromInit: &seededFromInit)
            // The channel's own task mirror, folded from the channel's own pump. A frame that touched a task row is
            // the only frame that can have changed the answer to "may this channel be reaped", so it is also the
            // only one that pushes: an armed background shell has to be visible to the thirty-minute reap, to the
            // cap eviction and to `/logout` before any of them acts.
            if taskMirror?.note(frame, epoch: frameEpoch) == true { pushEligibility() }
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
                lastSystemInit = initFrame.fields
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
        // A fork's reservation is confirmed nowhere but `resolveForkIdentity`, and an exit before the identity
        // arrives reaches neither that nor the deadline: leaving it here would keep a claim in the counter's
        // `reserved` map for the life of the process, one of six slots, permanently, per such crash. `release` on an
        // unconfirmed provisional key is a no-op, so there is nothing to double-free.
        forkIdentityTimer?.cancel(); forkIdentityTimer = nil
        if let reservation = forkReservation {
            forkReservation = nil
            await fleet.rollback(reservation)
        }
        // The id this child announced dies with it. The stash exists only for the window in which the spawn has not
        // recorded its reservation yet, and nothing beyond this epoch may read it.
        if forkIdentityPending?.epoch == exited { forkIdentityPending = nil }
        state.pendingDecisions = []
        turnRunning = false
        process = nil
        unresolvedSettings = []   // the process whose readbacks they were is gone
        taskMirror?.reset()       // and so are the background tasks: they were children of that process
        pushEligibility()

        // Our own `terminateOrWedge()` ended this epoch. Whatever status the escalation produced is not a crash: a
        // SIGTERM or SIGKILL exit is never `.code(0)`, so a clean-exit test alone would respawn a reaped channel.
        if terminatedEpochs.remove(exited) != nil { publish(); return }
        // A child that ended on its own with a clean status is not a crash: no item and no *Reopen*, the slot goes
        // back, and the channel is left where a processless owned channel rests. Leaving it in ready would name a
        // process that has gone, and the next send would throw `notOwned`.
        if status.isClean {
            await fleet.release(key)
            if currentName == .ready, apply(.exitedClean, to: .dormant) { return }
            publish(); return
        }
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
                // The channel stops being "connecting on the strength of a parked respawn" here: from now on the
                // attempt is the spawn itself, and the spawn's own failure paths are what rest the channel.
                await self.beginRespawn()
                try? await self.spawn(reason: .respawn)
            }
            return
        }
        // Exhaustion rests where a processless owned channel rests: a series that reached ready owns the session
        // and is dormant, one that never did is archived. Both carry the item that offers *Reopen*.
        let target: LifecycleTable.StateName = wasReadyInThisSeries ? .dormant : .archivedOlder
        state.systemItem = .crashed(exit: status, reopenOffered: true)
        guard apply(.exitedNonZero, to: target) else { state.systemItem = nil; publish(); return }
    }

    /// Clears the respawn handle as the backoff ends. A `Task` keeps itself alive while it runs, so dropping the
    /// reference here cancels nothing; what it changes is the answer to "is a respawn still waiting".
    private func beginRespawn() { respawnTask = nil }

    private func sleepOnClock(_ duration: Duration) async throws { try await clock.sleep(for: duration) }

    // MARK: - Holders

    /// The fleet fans every published `HolderSet` to every supervisor; the supervisor narrows it to its own session.
    public func holdersChanged(_ set: HolderSet) async {
        let mine = set.holders.filter { $0.sessionID == key.session }
        // Every fan-out reaches every supervisor, and almost none of them are about this channel. A state whose only
        // difference is a fresh `observedAt` is not a transition, and `updates` promises transitions: publishing one
        // per fan-out costs one published `ChannelState` per registered channel for every holder change anywhere in
        // the fleet, which every subscriber then has to coalesce again. So the no-transition publishes below are
        // taken only when this channel's *own* narrowed view moved. The stamp is still written on every call — it is
        // read elsewhere — and every evaluation below still runs on every call, because a suppressed archive depends
        // on the next tick re-evaluating.
        let viewChanged = Set(mine) != Set(state.observed.holders)
        state.observed = HolderSet(holders: mine, observedAt: set.observedAt)

        // A ghost stops costing a slot when its record is gone and its pid is dead — and only then.
        if let ghost = state.wedged, !mine.contains(where: { $0.pid == ghost.pid }),
           !ProcessLiveness.isRunning(pid: ghost.pid) {
            await fleet.clearWedged(key)
        }

        let here = currentName
        if here == .contended { resolveContended(mine); return }
        // The holder's record went away, so the session is nobody's. The rule is about the *holder*, not about
        // which kind of holder it was: a background job whose roster worker leaves is the same fact as a terminal
        // whose registry record vanishes, and the channel is archived from both.
        if here == .foreignUsersTerminal || here == .backgroundJob {
            guard mine.isEmpty else { if viewChanged { publish() }; return }
            // Not while an operation of ours is in flight, for the same reason rule 1 below is not. `adopt()` runs
            // `claude stop <short>` and then waits for exactly this disappearance — the job's roster worker leaving
            // and its pid dying *is* the release it is waiting for — and `.adopt` has one row, out of
            // `.backgroundJob`. Archiving on the release therefore takes adopt's only from-state away between its
            // wait and its transition, and adopt returns having spawned nothing and thrown nothing: §7.4's round
            // trip silently does not happen. The observer re-reads every `pollInterval`, so a suppressed archive is
            // taken by the next tick once the operation has finished and the channel really is nobody's.
            guard inFlight == nil else { if viewChanged { publish() }; return }
            apply(.recordDisappeared, to: .archivedRecent)
            return
        }
        guard !mine.isEmpty else { if viewChanged { publish() }; return }

        // Rule 1: afleet wants this channel and somebody else has it. Its own event, never a handoff timeout — the
        // two are raised from different places and G1 has to see both fire. A channel afleet does not want owned
        // takes the dormant `holderAppeared` row below instead.
        // Not while an operation of ours is in flight. A spawn is about to read the very same holders in its
        // post-handshake check and take `connectingFoundHolder`, the row that exists for a holder found during a
        // spawn; raising the disagreement here instead would move the channel to Contended and leave that check's
        // own transition with no candidate — `transitionNotInTable`, which Task 12's gate reads as a programming
        // error. A handoff between its terminate and its launch is excluded for the same reason. Our own child's
        // registry record outlives its process — the CLI removes it, and the release wait exists precisely to wait
        // for that — and once `process` is nil the fleet's own-pid set no longer claims it, so a poll landing in
        // that window reads our own dying child as a stranger. The handoff runs its own recheck a moment later and
        // takes `holderAppearedBeforeLaunch` if a holder is genuinely there. G5's adoption scenario found this:
        // send-to-background ran, the job was on the roster, and the channel read `owned(contended)`.
        if state.desired == .owned, inFlight == nil,
           here == .connecting || here == .ready || here == .dormant,
           mine.contains(where: { !$0.isOwnChild }) {
            enterContended(mine, via: .desiredObservedDisagree)
            return
        }

        // Every state in which this channel holds no process of its own: dormant, and both archived names. The
        // origin rule is about the holder, not about whether afleet has ever owned the session — a channel a shell
        // registered from C3's index has never been opened and is archived, and the user's terminal taking that
        // session is the same fact as it taking a dormant one. Restricting this to dormant left an archived channel
        // archived forever with a live foreign holder against its name, which is what G5's foreign-session scenario
        // found.
        guard here == .dormant || here == .archivedRecent || here == .archivedOlder else {
            if viewChanged { publish() }
            return
        }
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
        // The marker before the eligibility check, and held across what the check authorises: a send arriving in
        // between would otherwise start a turn on a channel already decided against.
        guard inFlight == nil else { armDormantTimer(); return }
        // A change the user asked for while work was running is what "applies when the current work finishes"
        // means: the channel restarts into it rather than being reaped out from under it.
        let queued = state.pendingChange
        inFlight = queued == nil ? .reap : .restart
        defer { inFlight = nil }
        guard await currentVerdict().isEligible else { armDormantTimer(); return }
        if let queued {
            try? await restartNow(queued)
            return
        }
        _ = await endProcess(during: .reap)
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
