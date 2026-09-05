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

    /// Whether this channel counts as recently active, which is what tells `archivedRecent` from `archivedOlder`.
    /// It is held here rather than derived inside `ChannelState` because it is the supervisor's own fact: C3's index
    /// supplies it at construction and the reap refreshes it.
    private var isRecent: Bool

    public private(set) var state: ChannelState
    /// Zero until the first spawn, which takes `ProcessEpoch.first`; every later spawn takes `.next()`. No event can
    /// carry epoch zero, so the pump's "discard anything older" filter is correct before there is a process.
    private var epoch = ProcessEpoch(rawValue: 0)
    private var process: (any ProcessHandle)?
    private var turnRunning = false
    private var queuedInput: [UserInput] = []
    private var pendingHatch: PaneRequest?
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

    private let updatesContinuation: AsyncStream<ChannelState>.Continuation
    /// Every transition, published after the state has changed.
    public nonisolated let updates: AsyncStream<ChannelState>

    /// The thirty-minute reap.
    public static let dormantAfter = Duration.seconds(1800)
    /// Three attempts, then the system item.
    public static let backoffs: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    public init(key: ChannelKey, launchTemplate: LaunchConfiguration, factory: @escaping ProcessFactory,
                ownership: OwnershipCheck, observer: FleetObserver, clock: any Clock<Duration>,
                eligibilityInputs: @escaping @Sendable () async -> DormantEligibility.Input,
                fleet: FleetCapCounter, diagnostics: any FleetDiagnosticsSink, isRecent: Bool,
                initialOrigin: ChannelOrigin = .archived, handshakeTimeout: Duration = .seconds(30)) {
        self.key = key; self.launchTemplate = launchTemplate; self.factory = factory
        self.ownership = ownership; self.observer = observer; self.clock = clock
        self.eligibilityInputs = eligibilityInputs; self.fleet = fleet; self.diagnostics = diagnostics
        self.isRecent = isRecent; self.handshakeTimeout = handshakeTimeout
        self.state = ChannelState(key: key, origin: initialOrigin, desired: .none,
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
        case .foreignLive, .backgroundJob:
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
        guard process != nil else { return }
        let outcome = await terminateOrWedge(during: .reap)
        guard case .exited = outcome else { return }   // wedged: Task 5 fills the wedged state
        process = nil
        apply(.dormantTimerFired, to: .dormant)
        await fleet.release(key)
        pushEligibility()
    }

    /// The only call site of `ProcessHandle.terminate()`. `action` is nil on the one terminating path the parent's
    /// table does not model — the post-handshake yield — where a wedge is recorded and the caller still stops.
    @discardableResult
    public func terminateOrWedge(during action: LifecycleTable.TerminatingAction? = nil) async -> TerminateOutcome {
        guard let handle = process else { return .exited(.code(0, stderrTail: "")) }
        let pid = await handle.childProcessIdentifier
        terminatedEpochs.insert(handle.epoch)
        let report = await handle.terminate()
        guard let exit = report.exit else {
            let trace = EscalationTrace(steps: report.steps, pid: pid, epoch: handle.epoch)
            state.wedged = trace
            diagnostics.record(.wedged(session: key.session.description, steps: report.steps.count))
            if let action {
                apply(.terminateReturnedNil(during: action), to: .wedged)
            } else {
                // The one terminating path the parent's table does not model. The trace still has to be *findable*:
                // `currentName` reads `state.wedged` only under `.owned(.dormant)`, so the state name is entered
                // directly — through `enter`, which stays the only writer of `state.origin` — and no table
                // transition is applied.
                enter(.wedged)
                publish()
            }
            await fleet.markWedged(key)
            pushEligibility()
            return .wedged(trace)
        }
        process = nil
        return .exited(exit)
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

    // MARK: - Spawning

    func spawn(reason: SpawnReason) async throws {
        // A respawn continues the crash series; anything the user asked for starts a new one, which is what makes
        // *Reopen* mean something after the fourth failure.
        if reason != .respawn { crashCount = 0; wasReadyInThisSeries = false }
        let decision = await fleet.acquire(for: key)
        let reservation: Reservation
        switch decision {
        case .refused(let live):
            state.headerNote = .capReached(live: live)
            publish()
            throw LifecycleError.capReached(live: live)
        case .evict(_, let r):
            // Task 5 owns the eviction path: it terminates the victim and reports what it observed. Until then a
            // spawn that would evict gives the slot straight back rather than spawning on a slot nobody freed.
            await fleet.rollback(r)
            let live = await fleet.liveCount
            state.headerNote = .capReached(live: live)
            publish()
            throw LifecycleError.capReached(live: live)
        case .granted(let r):
            reservation = r
        }

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
            if case .wedged = await terminateOrWedge() {
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

    /// A pane exit is matched to the pending hatch by `PaneRequest.id`, never by value equality (Task 5 exercises it).
    public func paneExited(_ exit: PaneExit) async {
        guard let pending = pendingHatch, pending.id == exit.request.id else {
            diagnostics.record(.staleExit(id: exit.request.id, purpose: String(describing: exit.request.purpose)))
            return
        }
        pendingHatch = nil   // Task 5 runs the re-adoption
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
        guard !mine.isEmpty else { publish(); return }
        guard currentName == .dormant else { publish(); return }
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
