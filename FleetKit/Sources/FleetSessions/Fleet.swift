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

    private let jobUpdatesContinuation: AsyncStream<[JobEntry]>.Continuation
    /// The roster, republished in full whenever the observer's read of it changes. Derived from the read the
    /// observer had already taken, so a surface that listens here costs no `agents --json` run of its own.
    public nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    /// The task carrying the observer's roster reads onto `jobUpdates`. Held apart from `tasks` because `shutdown`
    /// awaits it rather than cancelling it: the observer finishes its stream first, so awaiting drains whatever it
    /// published last instead of dropping it.
    private var rosterForwarding: Task<Void, Never>?

    // MARK: - Construction

    /// `factory` nil is production: a real `ClaudeProcess` per spawn, with the `CapturingDiagnostics` every factory
    /// must install so the wedged row has its escalation steps. `runner` is the CLI seam; `clock` drives every timer
    /// in the package.
    ///
    /// `capture` is parent §11's opt-in raw frame capture, asked once per spawn rather than read once here: the
    /// setting behind it is a live toggle, so a channel opened after it is switched on captures and one opened
    /// before it does not. It defaults to off, and an explicit `factory` wins outright — a caller that builds its
    /// own processes decides their capture too.
    public init(configHome: ConfigHome, environment: ResolvedEnvironment, binary: URL, store: any StateStore,
                diagnosticsDirectory: URL, clock: any Clock<Duration> = ContinuousClock(),
                factory: ProcessFactory? = nil,
                capture: @escaping @Sendable () -> RawCapture? = { nil },
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

        self.factory = factory ?? Self.liveFactory(environment: environment, configHome: configHome,
                                                   wireSink: wireSink, capture: capture)
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobUpdatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        pids.fleet = self
    }

    /// Production's `ProcessFactory`: one real `ClaudeProcess` per spawn, under this fleet's environment and config
    /// home, with the in-process MCP server and the `CapturingDiagnostics` that holds the wedged row's escalation
    /// steps.
    ///
    /// It is a member rather than a closure inside `init` because it is the only thing that decides what a spawned
    /// process is given, `FleetVersion` and the tool list it names are internal to this package, and a caller outside
    /// it — the app's composition root — therefore cannot rebuild it to change one argument. Naming it here is also
    /// what lets a test watch that argument arrive without spawning anything.
    static func liveFactory(environment: ResolvedEnvironment, configHome: ConfigHome,
                            wireSink: any DiagnosticsSink,
                            capture: @escaping @Sendable () -> RawCapture?) -> ProcessFactory {
        { epoch, launch in
            let capturing = CapturingDiagnostics(forwardingTo: wireSink)
            let process = ClaudeProcess(epoch: epoch, launch: launch, environment: environment,
                                        configHome: configHome,
                                        mcpServer: AfleetMCPServer(serverVersion: FleetVersion.server,
                                                                   cwd: launch.cwd, tools: [SendUserFileTool()]),
                                        diagnostics: capturing, capture: capture())
            return LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
        }
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
        let rosters = observer.jobUpdates
        let continuation = jobUpdatesContinuation
        rosterForwarding = Task {
            for await snapshot in rosters { continuation.yield(snapshot.roster) }
        }
        await observer.start()
    }

    private func fanOut(_ set: HolderSet) async {
        for supervisor in supervisors.values { await supervisor.holdersChanged(set) }
    }

    /// Finishes every stream and cancels every timer. It terminates nothing: the user's channels keep running.
    public func shutdown() async {
        for supervisor in supervisors.values { await supervisor.shutdown() }
        await observer.stop()
        // `observer.stop()` finished the roster stream, so this ends of its own accord once it has forwarded
        // everything the last read published. Awaiting it is what makes "the roster the fleet published" the whole
        // roster and not whatever happened to arrive before the cancel.
        await rosterForwarding?.value
        rosterForwarding = nil
        for task in tasks { task.cancel() }
        tasks = []
        updatesContinuation.finish()
        jobUpdatesContinuation.finish()
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

    /// How long a running task's last frame may be, before the host stops believing it is still running: the
    /// engine's own task heartbeat, and the boundary parent §7.4's uncertainty rule is stated over.
    static let taskHeartbeat = Duration.seconds(30)

    private func build(key: ChannelKey, launch: LaunchConfiguration, isRecent: Bool) -> ChannelSupervisor {
        launches[key] = launch
        // This channel's own fold of C3's task registry: written by the supervisor's pump, read back here. The
        // thirty-minute reap, the cap eviction, `perform(.reap)` and `/logout`'s census and *Stop* all decide
        // through this one closure, so all of them see the same tasks, as of the moment each of them asks.
        let taskMirror = ChannelTaskMirror(clock: clock)
        let supervisor = ChannelSupervisor(
            key: key, launchTemplate: launch, factory: factory, ownership: ownership, observer: observer,
            clock: clock,
            eligibilityInputs: { DormantEligibility.Input(turnRunning: false, pendingDecisions: 0, queuedInput: 0,
                                                          mirror: taskMirror.liveEntries,
                                                          lastTaskFrameAge: taskMirror.lastFrameAge,
                                                          heartbeatInterval: Self.taskHeartbeat, wedged: false) },
            taskMirror: taskMirror,
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
                                                            configHome: configHome, wedged: current?.wedged,
                                                            foreignHolders: current?.observed.foreign ?? [],
                                                            store: store)
        return verdict
    }

    /// The supervisor a key is filed under, or nil. Internal, and the one way into a channel from outside the
    /// facade: a test that asserts on what the fleet-wide counter holds has to drain that channel's own
    /// fire-and-forget eligibility chain first, and nothing public does that for one key.
    func channel(_ key: ChannelKey) -> ChannelSupervisor? { supervisors[key] }

    public func isDormantEligible(_ key: ChannelKey) async -> Bool {
        guard let supervisor = supervisors[key] else { return false }
        return await supervisor.currentEligibility().isEligible
    }

    public func liveTaskIDs(of key: ChannelKey) async -> [String] {
        guard let supervisor = supervisors[key] else { return [] }
        return await supervisor.liveTaskIDs()
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
        case .quit:
            // Ungated, where `.reap` is gated. The reap's gate protects the reap the *user* asks for from the
            // header: it must not end a child with a decision on screen or a background shell still working. §7.4's
            // quit is the opposite case — the user has been warned about exactly those channels and has confirmed —
            // and running the quit through the reap's gate would terminate none of them. The warning is X9's rule
            // and it is what licenses this teardown; the name it terminates under is its own, so a ghost the quit
            // leaves behind is recorded as a quit's.
            await supervisor.terminateForQuit()
        case .reopen:
            try await supervisor.reopen()
        case .answer(let id, let answer):
            try await supervisor.answer(id, answer)
        }
        return await supervisor.state
    }

    /// `perform(.send(input), on:)`'s path, answering the uuid the supervisor minted instead of the state.
    ///
    /// The supervisor mints the uuid the engine will echo for the user message and `perform` throws it away, so a
    /// host had no way to know it before the echo arrived — and reaching below the facade for it is contract Y5's
    /// refusal. With it in hand the composer raises `HostSignal.promptSent(uuid:at:)` the moment the send returns,
    /// which is the pre-echo preview C3's `StreamIngestion.signal(_:)` exists to receive.
    ///
    /// Same preconditions, same refusals: the barrier is checked because a send may spawn, and everything else is
    /// the supervisor's own — `busy` behind a lifecycle operation, `heldElsewhere` on a channel held elsewhere.
    @discardableResult
    public func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID {
        let supervisor = supervisor(for: key)
        try spawnBarrier.check()
        return try await supervisor.send(input)
    }

    /// `perform(.fork(at:), on:)`'s path, answering the sibling's provisional key instead of the source's state.
    ///
    /// The supervisor mints that key — a fork is a *new channel*, filed under a provisional id until the engine
    /// announces its own — and `perform` throws it away, so a host that forked had no way to name the channel it had
    /// just opened. Without it the fork's own composer cannot be prefilled and the window cannot select it; with it
    /// neither has to guess, and reaching below the facade for the fleet's supervisor table is contract Y5's refusal.
    @discardableResult
    public func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey {
        let supervisor = supervisor(for: key)
        try spawnBarrier.check()
        return try await supervisor.fork(at: point)
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
        return await observer.detailedSnapshot().roster
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

    // MARK: - The composer's line

    /// Routes one composer line for a channel, over that channel's own engine report.
    ///
    /// The three operations below are the router's, reached on a `ChannelKey`: the conversation surface holds a key
    /// and nothing under it, and `CommandRouter` and `StrategyExecutor` both speak in supervisors, which the facade
    /// owns and never hands out. Each resolves the key and delegates; no line is parsed here and no state the
    /// supervisor already keeps is kept a second time.
    ///
    /// A key this fleet owns no supervisor for has no engine report to route against, so the local table alone
    /// decides — which is what a line typed into a channel that has not opened yet must still do. Sending and
    /// running are different: both act on a child, and a key with no child is refused.
    public func route(_ text: String, on key: ChannelKey) async -> Routed {
        guard let supervisor = supervisors[key] else { return CommandRouter.route(text) }
        let context = await supervisor.routingContext()
        return CommandRouter.route(text, handshake: context.handshake, systemInit: context.systemInit,
                                   runtime: context.runtime)
    }

    /// One routed control request, on a channel.
    @discardableResult
    public func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        guard let supervisor = supervisors[key] else { throw LifecycleError.notOwned }
        return try await StrategyExecutor.send(request, on: supervisor)
    }

    /// One routed strategy, on a channel. `ui` is the app's browser tab and confirmation sheet, which the
    /// multi-step strategies need and the facade has no opinion about.
    @discardableResult
    public func run(_ strategy: RouteStrategy, arguments: [String] = [], on key: ChannelKey,
                    ui: any StrategyUI) async throws -> StrategyOutcome {
        guard let supervisor = supervisors[key] else { throw LifecycleError.notOwned }
        return try await StrategyExecutor.run(strategy, arguments: arguments, on: supervisor, ui: ui)
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
    /// Whether this action can put work where `/logout`'s census cannot see it, which is what the barrier holds
    /// back: a process of our own, or a job or background shell started after the census was taken. Reading,
    /// reaping, stopping and answering are not held — the plan's own *Stop* runs through them.
    ///
    /// The two handoffs are here for the reason `Fleet.openInTerminal` checks the barrier directly: `--bg --resume`
    /// launches a worker whose short is not in `census.ownJobs`, and `background_tasks` moves the current turn's
    /// tools into background shells the same list was read without.
    var maySpawn: Bool {
        switch self {
        case .open, .send, .adopt, .fork, .quiescentRestart, .reopen, .sendToBackground, .backgroundAll: true
        case .reap, .stopEverything, .logout, .quit, .answer: false
        }
    }
}
