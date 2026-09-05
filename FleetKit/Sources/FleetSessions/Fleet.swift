import Foundation
import AfleetCore
import ClaudeWire

/// The X5 lifecycle API, over everything below it: one `Fleet` per config home, owning the supervisors, the
/// observer, the cap counter, the store, the CLI verbs, the spawn preconditions, the router's refusal interceptor
/// and the one spawn barrier a `/logout` raises.
///
/// It holds no process and no stream of its own. Every wire frame, every control request and every transition
/// belongs to a `ChannelSupervisor`; what lives here is the fleet-wide part — which channel is which, which pids are
/// ours, which project a channel is in, and the merge of every supervisor's `updates` into one.
public actor Fleet: LifecycleAPI {

    /// What the fleet has to know about a channel before it can open it: where it runs, and whether C3's index
    /// calls it recently active. `perform(.open)` reads the recency from here.
    private struct Seed: Sendable {
        var cwd: URL
        var isRecent: Bool
    }

    private let configHome: ConfigHome
    private let environment: ResolvedEnvironment
    private let binary: URL
    private let store: any StateStore
    private let clock: any Clock<Duration>
    private let factory: ProcessFactory
    private let diagnostics: FileFleetDiagnostics
    private let verbs: CLIVerbs
    private let observer: FleetObserver
    private let counter: FleetCapCounter
    private let ownership: OwnershipCheck
    private let preconditionsGate: SpawnPreconditions
    /// The one barrier a `/logout` plan raises. Every supervisor this fleet builds consults it, and so does
    /// `perform` before it asks one of them to spawn.
    private let spawnBarrier = SpawnBarrier()
    /// Task 8's drift counter over the engine's bare refusals. The composer feeds it assistant text.
    public let refusals: RefusalInterceptor

    private var supervisors: [ChannelKey: ChannelSupervisor] = [:]
    /// The key each supervisor is filed under, so a fork that re-keys itself can be found and re-filed.
    private var filedAs: [ObjectIdentifier: ChannelKey] = [:]
    private var seeds: [ChannelKey: Seed] = [:]
    /// The line each channel was built from; the precondition gate reads its setting sources and its cwd.
    private var launches: [ChannelKey: LaunchConfiguration] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    /// The census a `/logout` built, held between the sheet and the user's answer.
    private var logoutPlan: LogoutPlan.Census?

    private let updatesContinuation: AsyncStream<ChannelState>.Continuation
    /// Every supervisor's transitions, merged. A supervisor built later joins the same stream.
    public nonisolated let updates: AsyncStream<ChannelState>

    // MARK: - Construction

    /// `factory` nil is production: a real `ClaudeProcess` per spawn, with the `CapturingDiagnostics` every factory
    /// must install so the wedged row has its escalation steps. `runner` is the CLI seam; `clock` drives every timer
    /// in the package.
    public init(configHome: ConfigHome, environment: ResolvedEnvironment, binary: URL, store: any StateStore,
                diagnosticsDirectory: URL, clock: any Clock<Duration> = ContinuousClock(),
                factory: ProcessFactory? = nil,
                runner: any DirectoryProcessRunner = FoundationDirectoryRunner()) {
        self.configHome = configHome
        self.environment = environment
        self.binary = binary
        self.store = store
        self.clock = clock

        let sink = FileFleetDiagnostics(directory: diagnosticsDirectory)
        self.diagnostics = sink
        // C2's own file, beside FleetKit's, so a child's wire diagnostics and the fleet's read as one recording.
        let wireSink = FileDiagnostics(directory: diagnosticsDirectory)

        // Composed once: every verb and every pane request of this fleet runs under the same scrubbed,
        // re-injected environment a child would, pinned to this config home.
        let template = LaunchConfiguration(binary: binary, cwd: configHome.root, session: .new(SessionID()))
        let childEnvironment = template.childEnvironment(over: environment, configHome: configHome)
        let verbs = CLIVerbs(runner: runner, binary: binary, configHome: configHome,
                             environment: childEnvironment, diagnostics: sink, clock: clock)
        self.verbs = verbs
        self.counter = FleetCapCounter(diagnostics: sink)
        self.preconditionsGate = SpawnPreconditions()
        self.refusals = RefusalInterceptor(diagnostics: sink)

        let reader = FileHolderReader(verbs: verbs, diagnostics: sink)
        let pids = OwnPIDs()
        self.observer = FleetObserver(configHome: configHome, reader: reader, clock: clock,
                                      ownPIDs: { await pids.value() })
        self.ownership = OwnershipCheck(observer: observer, clock: clock, diagnostics: sink)

        self.factory = factory ?? { epoch, launch in
            let capturing = CapturingDiagnostics(forwardingTo: wireSink)
            let process = ClaudeProcess(epoch: epoch, launch: launch, environment: environment,
                                        configHome: configHome,
                                        mcpServer: AfleetMCPServer(serverVersion: FleetVersion.server,
                                                                   cwd: launch.cwd, tools: [SendUserFileTool()]),
                                        diagnostics: capturing, capture: nil)
            return LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
        }
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        pids.fleet = self
    }

    /// The live child pids of every supervisor, for `Holder.isOwnChild`. A box because the observer needs the
    /// closure before the actor it reads from is fully initialised.
    private final class OwnPIDs: @unchecked Sendable {   // `fleet` is written once, at the end of `Fleet.init`
        weak var fleet: Fleet?
        func value() async -> Set<Int32> { await fleet?.livePIDs() ?? [] }
    }

    private func livePIDs() async -> Set<Int32> {
        var pids: Set<Int32> = []
        for supervisor in supervisors.values {
            if let pid = await supervisor.livePID() { pids.insert(pid) }
        }
        return pids
    }

    // MARK: - Lifetime

    /// Starts the observer and fans every published holder set to every supervisor. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        let stream = observer.updates
        tasks.append(Task { [weak self] in
            for await set in stream {
                guard let self else { return }
                await self.fanOut(set)
            }
        })
        await observer.start()
    }

    private func fanOut(_ set: HolderSet) async {
        for supervisor in supervisors.values { await supervisor.holdersChanged(set) }
    }

    /// Finishes every stream and cancels every timer. It terminates nothing: the user's channels keep running.
    public func shutdown() async {
        for supervisor in supervisors.values { await supervisor.shutdown() }
        await observer.stop()
        for task in tasks { task.cancel() }
        tasks = []
        updatesContinuation.finish()
        diagnostics.flush()
    }

    /// Every diagnostic line written so far is on disk when this returns.
    public func flushDiagnostics() { diagnostics.flush() }

    // MARK: - Registration

    /// Tells the fleet a channel exists, where it runs and whether C3's index calls it recently active. It spawns
    /// nothing: `perform(.open)` does that, and it reads the recency recorded here.
    public func register(_ key: ChannelKey, cwd: URL, recent: Bool) {
        seeds[key] = Seed(cwd: cwd, isRecent: recent)
        _ = supervisor(for: key)
    }

    /// Register and open in one call: the facade's own entry point, with the recency supplied by the caller.
    @discardableResult
    public func open(_ key: ChannelKey, cwd: URL, recent: Bool) async throws -> ChannelState {
        register(key, cwd: cwd, recent: recent)
        return try await perform(.open, on: key)
    }

    /// The supervisor for a key, built on first use. A key with no seed runs in the config home and is not recent,
    /// which every precondition then refuses: a channel nobody said where to run is not one this fleet can spawn.
    @discardableResult
    private func supervisor(for key: ChannelKey) -> ChannelSupervisor {
        if let existing = supervisors[key] { return existing }
        let seed = seeds[key] ?? Seed(cwd: configHome.root, isRecent: false)
        let launch = LaunchConfiguration(binary: binary, cwd: seed.cwd, session: .resume(key.session, fork: false))
        return build(key: key, launch: launch, isRecent: seed.isRecent)
    }

    private func build(key: ChannelKey, launch: LaunchConfiguration, isRecent: Bool) -> ChannelSupervisor {
        launches[key] = launch
        let supervisor = ChannelSupervisor(
            key: key, launchTemplate: launch, factory: factory, ownership: ownership, observer: observer,
            clock: clock,
            // C3's mirror has landed and `RegistryEntry` conforms to `TaskMirrorReading` (Task 11), but nothing
            // folds one per channel yet: `mirror` and `lastTaskFrameAge` are the two inputs still unwired, and both
            // the thirty-minute reap and `liveTaskIDs()` — `/logout`'s census and its *Stop* — read this closure.
            eligibilityInputs: { DormantEligibility.Input(turnRunning: false, pendingDecisions: 0, queuedInput: 0,
                                                          mirror: [], lastTaskFrameAge: nil,
                                                          heartbeatInterval: .seconds(30), wedged: false) },
            fleet: counter, diagnostics: diagnostics, isRecent: isRecent, spawnBarrier: spawnBarrier,
            environment: environment, configHome: configHome, verbs: verbs, store: store,
            evictVictim: { [weak self] victim in await self?.evict(victim) ?? .victimBecameIneligible },
            spawnSibling: { [weak self] source, provisional, start in
                await self?.buildSibling(provisional, start: start, from: source)
            },
            preconditions: preconditionsGate)

        supervisors[key] = supervisor
        filedAs[ObjectIdentifier(supervisor)] = key

        // Seed the new supervisor with the holders the observer has already read. `fanOut` runs only on a
        // *published* set and the observer publishes only what changed, so a channel registered after its holder
        // already existed would otherwise never hear about it — it would sit archived with a live job or a live
        // terminal against its session until something unrelated moved the fleet-wide set. G5's adoption scenario
        // found this: the job was in `jobs()` and the channel stayed archived, so `adopt` had nothing to adopt.
        // Detached rather than awaited because `build` is called from a synchronous path, and harmless when the
        // snapshot is empty: `holdersChanged` with no holders for this session publishes and changes nothing.
        tasks.append(Task { [weak self] in
            guard let self else { return }
            await supervisor.holdersChanged(await self.currentHolders())
        })

        let stream = supervisor.updates
        tasks.append(Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                await self.publish(state, from: supervisor)
            }
        })
        return supervisor
    }

    /// A fork is a *new channel* under the provisional key its source minted, with the fork's own `SessionStart` on
    /// its launch line and its source's working directory.
    private func buildSibling(_ provisional: ChannelKey, start: SessionStart,
                              from source: ChannelKey) async -> ChannelSupervisor {
        // The source's *runtime* directory, not its seed: a `/cd` moves the project the channel is in, and a fork
        // of a channel the user moved belongs where the user moved it. The seed is the fallback for a source this
        // fleet no longer holds a supervisor for, which is not a case a live fork can be in.
        let cwd = await supervisors[source]?.runtimeState().cwd ?? seeds[source]?.cwd ?? configHome.root
        seeds[provisional] = Seed(cwd: cwd, isRecent: true)
        return build(key: provisional, launch: LaunchConfiguration(binary: binary, cwd: cwd, session: start),
                     isRecent: true)
    }

    /// One published state, forwarded to the merged stream — and, when a fork has learned its own session id, the
    /// moment the map is re-keyed. The supervisor rewrites `state.key` only inside `resolveForkIdentity`, after its
    /// post-handshake check came back clean and the counter's slot moved, so reading it here is reading a decision
    /// that has already been taken and never a guess at one.
    private func publish(_ state: ChannelState, from supervisor: ChannelSupervisor) {
        let id = ObjectIdentifier(supervisor)
        if let filed = filedAs[id], filed != state.key {
            supervisors[filed] = nil
            supervisors[state.key] = supervisor
            filedAs[id] = state.key
            if let seed = seeds.removeValue(forKey: filed) { seeds[state.key] = seed }
            if let launch = launches.removeValue(forKey: filed) { launches[state.key] = launch }
        }
        updatesContinuation.yield(state)
    }

    /// The observer's most recent read, published or not.
    private func currentHolders() async -> HolderSet { await observer.snapshot() }

    private func evict(_ victim: ChannelKey) async -> EvictionOutcome {
        guard let supervisor = supervisors[victim] else { return .victimBecameIneligible }
        return await supervisor.evict()
    }

    // MARK: - LifecycleAPI: reading

    public func state(of key: ChannelKey) async -> ChannelState? {
        guard let supervisor = supervisors[key] else { return nil }
        return await supervisor.state
    }

    public func states() async -> [ChannelState] {
        var out: [ChannelState] = []
        for supervisor in supervisors.values { out.append(await supervisor.state) }
        return out.sorted { $0.key.session.description < $1.key.session.description }
    }

    public func preconditions(for key: ChannelKey) async -> SpawnPrecondition {
        let launch = launches[key] ?? LaunchConfiguration(binary: binary, cwd: seeds[key]?.cwd ?? configHome.root,
                                                          session: .resume(key.session, fork: false))
        let current = await state(of: key)
        let (verdict, _) = await preconditionsGate.evaluate(key: key, cwd: launch.cwd, launch: launch,
                                                            wedged: current?.wedged,
                                                            foreignHolders: current?.observed.foreign ?? [],
                                                            store: store)
        return verdict
    }

    public func isDormantEligible(_ key: ChannelKey) async -> Bool {
        guard let supervisor = supervisors[key] else { return false }
        return await supervisor.currentEligibility().isEligible
    }

    /// A fresh unbounded fan-out per call, straight from the supervisor; nil when this fleet owns no supervisor for
    /// the key. The facade keeps no stream of its own, so nothing is re-pumped and no frame is duplicated.
    public func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? {
        guard let supervisor = supervisors[key] else { return nil }
        return await supervisor.events()
    }

    // MARK: - LifecycleAPI: acting

    @discardableResult
    public func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        let supervisor = supervisor(for: key)
        // A channel must not come up into a fleet that is signing out, and the refusal must leave nothing behind:
        // asked here, before the supervisor applies the transition its spawn would have had to undo.
        if action.maySpawn { try spawnBarrier.check() }
        switch action {
        case .open:
            try await supervisor.open()
        case .send(let input):
            _ = try await supervisor.send(input)
        case .reap:
            // Gated here and not inside `reap()`: the reap the *user* asked for must not end a child with a
            // decision on screen or a background shell still working, while `ChannelSupervisor.reap()` is also the
            // unconditional teardown terminate a rig ends a test with.
            let verdict = await supervisor.currentEligibility()
            guard case .eligible = verdict else {
                if case .blocked(let blocker) = verdict { throw LifecycleError.notEligible(blocker) }
                return await supervisor.state
            }
            await supervisor.reap()
        case .adopt:
            try await supervisor.adopt()
        case .sendToBackground:
            _ = try await supervisor.sendToBackground()
        case .fork(let point):
            _ = try await supervisor.fork(at: point)
        case .quiescentRestart(let request):
            try await supervisor.quiescentRestart(request)
        case .stopEverything:
            // The turn first, then each task by id: a queued input would start the next turn the moment the running
            // one ended, which is the same order `/logout`'s *Stop* uses.
            _ = try? await supervisor.perform(Interrupt(cancelQueued: true))
            for task in await supervisor.liveTaskIDs() {
                _ = try? await supervisor.perform(StopTask(taskID: task))
            }
        case .backgroundAll:
            // One `background_tasks` with no `tool_use_id`: the engine puts every tool the current turn is running
            // into the background. It is not a handoff — a loop of `sendToBackground` would terminate every owned
            // child in the fleet and re-launch each as a `--bg` job, which is a different verb the *Stop* sheet
            // does not offer.
            _ = try await supervisor.perform(BackgroundTasks())
        case .logout:
            try await beginLogout()
        case .reopen:
            try await supervisor.reopen()
        case .answer(let id, let answer):
            try await supervisor.answer(id, answer)
        }
        return await supervisor.state
    }

    public func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest {
        try spawnBarrier.check()
        return try await supervisor(for: key).openInTerminal()
    }

    /// A pane exit belongs to whichever channel is waiting on that request `id`, and to no other: two requests with
    /// identical fields are two requests. An exit nobody is waiting on is recorded and discarded.
    public func paneExited(_ exit: PaneExit) async {
        for supervisor in supervisors.values {
            guard await supervisor.pendingPaneRequest?.id == exit.request.id else { continue }
            await supervisor.paneExited(exit)
            return
        }
        diagnostics.record(.staleExit(id: exit.request.id, purpose: String(describing: exit.request.purpose)))
    }

    // MARK: - Jobs

    /// Every roster job that has not gone terminal, reconciled with `agents --json` on the way in. A conversation
    /// job carries its session; an exec job carries none and is a `JobEntry` only.
    public func jobs() async -> [JobEntry] {
        _ = await observer.reconcileNow(label: OwnershipLabel.poll)
        let snapshot = await observer.detailedSnapshot()
        var entries: [JobEntry] = []
        for (short, record) in snapshot.jobs where !record.isTerminal {
            let holder = snapshot.holders.holders.first { $0.jobShort == short.rawValue }
            entries.append(JobEntry(short: short, state: record.state, kind: holder?.kind ?? "bg",
                                    sessionID: record.sessionId.flatMap(SessionID.init),
                                    cwd: record.cwd.map { URL(filePath: $0) },
                                    name: holder?.presence?.name))
        }
        return entries.sorted { $0.short.rawValue < $1.short.rawValue }
    }

    /// `claude stop|respawn|rm <short>` through the runner; no PTY. A job is keyed by its short and not by a
    /// session, which is why these are not `LifecycleAction`s.
    public func performJob(_ verb: JobVerb, _ short: JobShort) async throws {
        switch verb {
        case .stop: try await verbs.stop(short)
        case .respawn: try await verbs.respawn(short)
        case .remove: try await verbs.remove(short)
        }
    }

    public func attach(_ job: JobShort) async throws -> PaneRequest {
        try await jobPane(arguments: ["attach", job.rawValue], job: job, purpose: .attach(job), name: "attach")
    }

    public func logs(_ job: JobShort) async throws -> PaneRequest {
        try await jobPane(arguments: ["logs", job.rawValue], job: job, purpose: .logs(job), name: "logs")
    }

    /// A job's pane is composed here rather than on a channel: a job is keyed by short, an exec job has no session
    /// at all, and neither pane changes any ownership. The environment is the one every child of this fleet runs
    /// under, composed by ClaudeWire and never assembled by hand.
    private func jobPane(arguments: [String], job: JobShort, purpose: PanePurpose,
                         name: String) async throws -> PaneRequest {
        guard let entry = await jobs().first(where: { $0.short == job }) else { throw LifecycleError.notOwned }
        let cwd = entry.cwd ?? configHome.root
        let launch = LaunchConfiguration(binary: binary, cwd: cwd, session: .new(SessionID()))
        let request = PaneRequest(executable: binary, arguments: arguments, cwd: cwd,
                                  environment: launch.childEnvironment(over: environment, configHome: configHome),
                                  purpose: purpose)
        diagnostics.record(.paneRequest(id: request.id, purpose: name,
                                        session: entry.sessionID?.description))
        return request
    }

    // MARK: - Project servers (§6.12)

    /// The one Claude Code-owned file afleet writes.
    ///
    /// §6.12's precondition is about the *project*: the write runs only while no owned process for that project is
    /// running, because a live child has already loaded the server and an `mcp_toggle` after the fact arrives too
    /// late. The fleet is the only place that knows which channels are in a project, so it answers that question
    /// here and hands the answer to the channel that performs the write.
    public func declineProjectServers(_ names: [String], project: URL) async throws {
        let root = ProjectRoot.canonical(for: project).root
        let inProject = await channels(under: root)
        var live = false
        for supervisor in inProject where await supervisor.livePID() != nil { live = true }

        guard let writer = inProject.first else {
            // No channel of ours is in this project, so no owned process for it can be running either.
            do {
                _ = try preconditionsGate.decline(names: names, cwd: project, configHome: configHome.root,
                                                  processIsLive: false)
                diagnostics.record(.declineWrite(outcome: "written", servers: names.count))
            } catch let error as LifecycleError {
                guard case .declineRefused(let reason) = error else { throw error }
                diagnostics.record(.declineWrite(outcome: reason, servers: names.count))
                throw error
            }
            return
        }
        // The write is one write, so one channel performs it and banners its outcome: the project's consent state
        // is what the sheet is about, and every channel in the project is blocked on the same answer.
        try await writer.declineProjectServers(names, projectHasLiveProcess: live)
    }

    public func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {
        let root = ProjectRoot.canonical(for: project).root
        for server in servers { try? await preconditionsGate.accept(server, root: root, store: store) }
    }

    /// Every supervisor whose channel runs in this project root, in session order so the writer is the same channel
    /// twice.
    private func channels(under root: URL) async -> [ChannelSupervisor] {
        var matches: [ChannelSupervisor] = []
        for key in supervisors.keys.sorted(by: { $0.session.description < $1.session.description }) {
            guard let supervisor = supervisors[key] else { continue }
            // The runtime cwd, not the seed's: a `set_cwd` moves the project a channel is in.
            let cwd = await supervisor.runtimeState().cwd
            guard ProjectRoot.canonical(for: cwd).root == root else { continue }
            matches.append(supervisor)
        }
        return matches
    }

    // MARK: - The restart's unresolved settings

    /// The user picked a value for a setting a quiescent restart could not read back.
    ///
    /// The sequencing is the point, and it is the facade's because nothing below it can promise both halves: the
    /// value is applied through `ChannelSupervisor.perform`, which is what puts it into the channel's runtime
    /// record, and only if that succeeded does the banner advance to the next unresolved name. An advance without
    /// an apply would clear a banner over a setting the engine never received.
    ///
    /// `outputStyle` goes out as `update_settings`, the one key that request accepts (parent §7.7, §6.4 *F-7*),
    /// and not as a `/config` turn read back with `get_settings`.
    public func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        guard let supervisor = supervisors[key] else { throw LifecycleError.notOwned }
        if let request = Self.request(forSetting: name, value: value) {
            _ = try await StrategyExecutor.send(request, on: supervisor)
        }
        await supervisor.resolveSetting(name)
    }

    /// The request that puts one setting back, by the name `Readback.verify` reports it under. A name outside that
    /// closed set sends nothing: the banner only ever names one of these, so there is nothing to apply and nothing
    /// to guess at.
    private static func request(forSetting name: String, value: JSONValue) -> AnyControlRequest? {
        switch name {
        case "model":
            return value.stringValue.map { AnyControlRequest(SetModel(model: $0)) }
        case "permissionMode":
            return value.stringValue.flatMap(PermissionMode.init(rawValue:))
                .map { AnyControlRequest(SetPermissionMode(mode: $0)) }
        case "effort":
            return AnyControlRequest(ApplyFlagSettings(settings: .object(["effortLevel": value])))
        case "outputStyle":
            return AnyControlRequest(UpdateSettings(settings: .object(["outputStyle": value])))
        case "fastMode":
            return AnyControlRequest(ApplyFlagSettings(settings: .object(["fastMode": value])))
        default:
            guard name.hasPrefix("flagSettings.") else { return nil }
            let flag = String(name.dropFirst("flagSettings.".count))
            return AnyControlRequest(ApplyFlagSettings(settings: .object([flag: value])))
        }
    }

    // MARK: - `/logout`

    /// `/logout` is fleet-level, not a channel's: it raises the one spawn barrier, censuses every owned channel and
    /// every job afleet launched, and only then signs out. There is no channel banner and no header word for it —
    /// the facade hands the census, the refusal and the outcome to the shell, which renders them.
    private func beginLogout() async throws {
        guard logoutPlan == nil else { throw LifecycleError.logoutInProgress }
        logoutPlan = await LogoutPlan.build(fleet: await logoutContext())
    }

    /// The census `/logout` built, or nil when no plan is pending.
    public func logoutCensus() -> LogoutPlan.Census? { logoutPlan }

    /// Runs the pending plan. `nil` when there is none.
    public func runLogout(_ choice: LogoutChoice) async -> LogoutOutcome? {
        guard let census = logoutPlan else { return nil }
        let outcome = await LogoutPlan.execute(census, choice: choice, fleet: await logoutContext())
        // *Wait* is the plan still holding: the barrier stays up and so does the census.
        if case .waiting = outcome { return outcome }
        logoutPlan = nil
        return outcome
    }

    /// The user changed their mind: the barrier comes down and nothing was run.
    public func abandonLogout() async {
        guard logoutPlan != nil else { return }
        logoutPlan = nil
        LogoutPlan.abandon(fleet: await logoutContext())
    }

    /// The shorts afleet itself sent to the background are read from the store on every build: a job afleet did not
    /// launch is not afleet's to stop, and the record of which ones it did is the store's.
    private func logoutContext() async -> LogoutContext {
        let raw = (try? await store.read([String].self, namespace: .fleetKit,
                                         key: FleetKitKeys.ownJobShorts)) ?? []
        return LogoutContext(channels: Array(supervisors.values), observer: observer, verbs: verbs,
                             barrier: spawnBarrier, ownJobShorts: raw.map { JobShort(rawValue: $0) },
                             diagnostics: diagnostics, clock: clock)
    }
}

/// The version afleet's own MCP server reports to the engine.
enum FleetVersion {
    static let server = "0.1.0"
}

private extension LifecycleAction {
    /// Whether this action can start a process. Only these are held behind the `/logout` barrier; reading, reaping
    /// and answering are not.
    var maySpawn: Bool {
        switch self {
        case .open, .send, .adopt, .fork, .quiescentRestart, .reopen: true
        case .reap, .sendToBackground, .stopEverything, .backgroundAll, .logout, .answer: false
        }
    }
}
