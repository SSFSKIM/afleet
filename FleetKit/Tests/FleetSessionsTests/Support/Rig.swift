import Foundation
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

struct HelperSpawnFailure: Error, CustomStringConvertible {
    let code: Int32
    var description: String { "posix_spawn of the helper process failed with \(code)" }
}

struct ScriptedSpawnFailure: Error, CustomStringConvertible {
    var description: String { "the scripted handle refused to spawn" }
}

/// The eligibility inputs a test can change while a channel runs: the mirror reading, the last task frame's age and
/// the heartbeat. Everything else in `DormantEligibility.Input` is the supervisor's own count and it overrides these.
final class EligibilityBox: @unchecked Sendable {   // `lock` serialises every field
    private let lock = NSLock()
    private var _mirror: [any TaskMirrorReading] = []
    private var _lastTaskFrameAge: Duration?
    private var _heartbeat: Duration = .seconds(30)

    init() {}

    var mirror: [any TaskMirrorReading] {
        get { lock.lock(); defer { lock.unlock() }; return _mirror }
        set { lock.lock(); _mirror = newValue; lock.unlock() }
    }
    var lastTaskFrameAge: Duration? {
        get { lock.lock(); defer { lock.unlock() }; return _lastTaskFrameAge }
        set { lock.lock(); _lastTaskFrameAge = newValue; lock.unlock() }
    }

    func input() -> DormantEligibility.Input {
        lock.lock(); defer { lock.unlock() }
        return DormantEligibility.Input(turnRunning: false, pendingDecisions: 0, queuedInput: 0, mirror: _mirror,
                                        lastTaskFrameAge: _lastTaskFrameAge, heartbeatInterval: _heartbeat,
                                        wedged: false)
    }
}

/// The harness every row test builds on: a scratch config home, scripted holder files, a manual clock, a recording
/// holder reader over the real `FileHolderReader`, a `FleetObserver`, a process factory that launches
/// `Tools/fake-claude/fake-claude` on a committed fixture through a real `ClaudeProcess`, and the cap counter and
/// diagnostics sink every supervisor it builds shares.
///
/// The rig plays the part Task 9's `Fleet` facade will: it owns the supervisors, it fans the observer's published
/// holder sets to each of them, and `shutdown()` shuts every one of them down.
final class Rig: @unchecked Sendable {   // `lock` serialises every recorded array
    let home: ScratchConfigHome
    let files: ScriptedHolderFiles
    let clock = TestClock()
    let diagnostics: RecordingDiagnostics
    let reader: RecordingHolderReader
    let observer: FleetObserver
    let fleet: FleetCapCounter
    let cwd: URL
    let runnerCalls: ScriptedProcessRunner.Recorder
    let verbs: CLIVerbs
    let store: FileStateStore
    private let storeDirectory: URL
    /// The `OwnershipCheck` seam every supervisor this rig builds shares: it runs once a release has been observed
    /// and before the caller's recheck, which is the window the preempt rows are about.
    var onReleased: (@Sendable () async -> Void)? {
        get { locked { _onReleased } }
        set { lock.lock(); _onReleased = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _onReleased: (@Sendable () async -> Void)?
    private var _byKey: [ChannelKey: ChannelSupervisor] = [:]
    private var _helpers: Set<Int32> = []
    private var _heldVictims: Set<ChannelKey> = []
    private var _heldEviction: [CheckedContinuation<Void, Never>] = []
    private var _extraOwnPIDs: Set<Int32> = []

    /// Pids the fleet counts as its own beside its live children. A holder that is ours is Contended rather than
    /// foreign live, and this is the one fact that decides it; a test that needs that branch claims a pid here.
    var extraOwnPIDs: Set<Int32> {
        get { locked { _extraOwnPIDs } }
        set { lock.lock(); _extraOwnPIDs = newValue; lock.unlock() }
    }
    private var _launches: [LaunchConfiguration] = []
    private var _liveHandles: [LiveProcessHandle] = []
    private var _scriptedHandles: [ScriptedProcessHandle] = []
    private var _supervisors: [ChannelSupervisor] = []
    private var _published: [ObjectIdentifier: [ChannelState]] = [:]
    private var _scriptedTermination: TerminationReport?
    private var _useScripted = false
    private var _scriptedSpawnError: (any Error)?
    private var _scriptedSpawnGate: (@Sendable () async -> Void)?
    private var _onScriptedHandle: (@Sendable (ScriptedProcessHandle) -> Void)?
    private var tasks: [Task<Void, Never>] = []

    /// A rig with its own diagnostics sink, or one sharing another rig's so a two-rig test still asserts one
    /// transition set.
    init(sharing shared: RecordingDiagnostics? = nil) throws {
        home = try ScratchConfigHome()
        files = ScriptedHolderFiles(home: home)
        diagnostics = shared ?? RecordingDiagnostics()
        cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let runner = ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files))
        runnerCalls = runner.calls
        verbs = CLIVerbs(runner: runner, binary: FakeClaudeLaunch.binary, configHome: home.configHome,
                         environment: [:], diagnostics: diagnostics)
        reader = RecordingHolderReader(base: FileHolderReader(verbs: verbs, diagnostics: diagnostics))
        fleet = FleetCapCounter(diagnostics: diagnostics)
        // Outside every config home, which is what the store's one validating initialiser insists on.
        storeDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-store-\(UUID().uuidString)")
        store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])

        let box = OwnPIDBox()
        observer = FleetObserver(configHome: home.configHome, reader: reader, clock: clock,
                                 ownPIDs: { await box.pids() })
        box.rig = self
    }

    /// Every supervisor's live child pid, which is what makes `Holder.isOwnChild` true for one of our own.
    private final class OwnPIDBox: @unchecked Sendable {
        weak var rig: Rig?
        func pids() async -> Set<Int32> {
            guard let rig else { return [] }
            var out = rig.extraOwnPIDs
            for supervisor in rig.supervisors { if let pid = await supervisor.livePID() { out.insert(pid) } }
            return out
        }
    }

    // MARK: - Reading what the rig recorded

    fileprivate func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var launches: [LaunchConfiguration] { locked { _launches } }
    var liveHandles: [LiveProcessHandle] { lock.lock(); defer { lock.unlock() }; return _liveHandles }
    var scriptedHandles: [ScriptedProcessHandle] { lock.lock(); defer { lock.unlock() }; return _scriptedHandles }
    var supervisors: [ChannelSupervisor] { lock.lock(); defer { lock.unlock() }; return _supervisors }
    /// How many processes the factory built, whatever kind.
    var spawnCount: Int { lock.lock(); defer { lock.unlock() }; return _launches.count }
    /// The backoff sleeps, keyed on the durations the backoff actually asks for rather than on a size threshold that
    /// later tasks' waits would slip under.
    var backoffSleeps: [Duration] {
        clock.requestedDurations.filter { ChannelSupervisor.backoffs.contains($0) }
    }

    func published(of supervisor: ChannelSupervisor) -> [ChannelState] {
        lock.lock(); defer { lock.unlock() }
        return _published[ObjectIdentifier(supervisor)] ?? []
    }

    /// Swaps the factory for one that hands out a fresh `ScriptedProcessHandle` per spawn. The report each handle
    /// starts with can be changed afterwards, per handle, which is how one channel of six wedges.
    func useScriptedHandle(terminateReturns: TerminationReport = TerminationReport(exit: .code(0, stderrTail: ""),
                                                                                   steps: [])) {
        lock.lock(); _useScripted = true; _scriptedTermination = terminateReturns; lock.unlock()
    }

    func supervisor(for key: ChannelKey) -> ChannelSupervisor? { locked { _byKey[key] } }

    /// Scripted handles built from now on spawn normally again.
    func clearScriptedSpawnFailure() { lock.lock(); _scriptedSpawnError = nil; lock.unlock() }

    /// Every scripted handle built from now on throws out of `spawn`, which parks a channel in connecting with no
    /// process — the state a channel is genuinely in between `open()` and a handshake.
    func failScriptedSpawns(with error: any Error = ScriptedSpawnFailure()) {
        lock.lock(); _scriptedSpawnError = error; lock.unlock()
    }

    /// Runs on every scripted handle the factory builds, at construction and before its `spawn`: how a test scripts
    /// the answers of a child that does not exist yet, such as the one a restart is about to launch.
    func configureScriptedHandles(_ body: @escaping @Sendable (ScriptedProcessHandle) -> Void) {
        lock.lock(); _onScriptedHandle = body; lock.unlock()
    }

    /// Every scripted handle built from now on parks inside `spawn` until `gate` returns: the channel is connecting
    /// *with* a live process of its own, which a spawn that throws cannot produce.
    func holdNextSpawn(_ gate: @escaping @Sendable () async -> Void) {
        lock.lock(); _scriptedSpawnGate = gate; lock.unlock()
    }

    // MARK: - Real processes the test started

    /// A real child of the test, standing in for a job worker or a terminal tab: a pid that can genuinely die,
    /// which is what `awaitRelease` waits for.
    ///
    /// `posix_spawn` rather than `Process`, so this rig owns the child outright and nothing else is waiting on it.
    /// Foundation reaps a `Process` asynchronously on machinery of its own, which is what made `killHelper` unable
    /// to promise the pid was gone by the time it returned.
    @discardableResult
    func startHelper() throws -> Int32 {
        let path = "/bin/sleep"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("3600"), nil]
        defer { for argument in argv where argument != nil { free(argument) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, nil, nil, &argv, environ)
        guard code == 0 else { throw HelperSpawnFailure(code: code) }
        lock.lock(); _helpers.insert(pid); lock.unlock()
        return pid
    }

    /// Kills the helper and **reaps it before returning**, so `kill(pid, 0)` stops answering the moment this call
    /// does. A release wait polls on the manual clock, which a test advances as fast as sleepers park, so the wait's
    /// whole budget can pass in a few milliseconds of wall time: a pid left as a zombie for even that long makes the
    /// wait run out and the channel go Contended instead of re-adopting. `SIGKILL` cannot be caught, so `waitpid`
    /// returns as soon as the kernel has torn the process down; no Swift concurrency has to make progress for it.
    func killHelper(_ pid: Int32) {
        guard locked({ _helpers.remove(pid) != nil }) else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            break   // ECHILD: already reaped, which is the same postcondition
        }
    }

    // MARK: - Holding an eviction open

    /// Parks the evicting supervisor between the victim's observed outcome and its report of it, so a test can run
    /// another decision while one eviction is still pending.
    /// Holds one victim's eviction open. Several may be held at once, which is how a test pins two concurrent
    /// acquisitions to the moment both have been decided and neither has completed.
    func holdEviction(of victim: ChannelKey) { lock.lock(); _heldVictims.insert(victim); lock.unlock() }

    func releaseEviction() {
        lock.lock()
        _heldVictims = []
        let waiting = _heldEviction
        _heldEviction = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// How many evicting supervisors are actually parked, so a test never races the barrier it means to hold.
    var heldEvictionCount: Int { locked { _heldEviction.count } }
    var evictionIsHeld: Bool { heldEvictionCount > 0 }

    private func barrier(for victim: ChannelKey) async {
        guard locked({ _heldVictims.contains(victim) }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard _heldVictims.contains(victim) else { lock.unlock(); continuation.resume(); return }
            _heldEviction.append(continuation)
            lock.unlock()
        }
    }

    // MARK: - Moving the manual clock while something waits on it

    /// Steps the manual clock in the release wait's own 500 ms poll interval while `body` runs, up to `limit` of test
    /// time, so a clock-driven wait makes progress. Nothing here sleeps on wall time to move the lifecycle: every
    /// step is the test moving the clock, and the wall-clock race is only a failure guard.
    ///
    /// The default limit is the handoff budget itself: a wait cannot outlast it, so a shorter default can only ever
    /// end a wait early and fail a test that was going to pass. A test that means to *reach* the timeout passes the
    /// budget explicitly, which is the same number and says so at the call site.
    func steppingClock<T: Sendable>(upTo limit: Duration = ChannelSupervisor.handoffBudget,
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let done = LockedFlag()
        let clock = self.clock
        let interval = OwnershipCheck.releasePollInterval
        let stepper = Task {
            var stepped = Duration.zero
            while !done.value && stepped < limit {
                // Only a parked sleeper is stepped past, so `limit` counts the wait's own polls and not the wall
                // time this loop happened to spend: ten seconds of limit is exactly the ten-second handoff budget,
                // and a budget any larger than that does not expire.
                guard clock.sleeperCount(due: interval) >= 1 else {
                    try? await Task.sleep(for: .milliseconds(1))
                    continue
                }
                await clock.advance(by: interval)
                stepped += interval
            }
        }
        let work = Task { try await body() }
        // A wall-clock guard, not a race: whatever `body` throws is what the caller sees, so a break shows up as the
        // error the code produced rather than as a timeout.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, !done.value else { return }
            XCTFail("the clock-stepped call never returned", file: file, line: line)
            work.cancel()
        }
        defer { done.set(); stepper.cancel(); watchdog.cancel() }
        return try await work.value
    }

    final class LockedFlag: @unchecked Sendable {   // `lock` serialises `flag`
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    // MARK: - Building supervisors

    @discardableResult
    func supervisor(session: SessionID, fixture: String = "resume-no-replay", isRecent: Bool = true,
                    origin: ChannelOrigin = .archived, desired: DesiredOwnership = .none, speed: Double = 50,
                    dropFixture: Bool = false, eligibility: EligibilityBox = EligibilityBox(),
                    records: Bool = true, template overrideTemplate: LaunchConfiguration? = nil,
                    script: URL? = nil, relaunchScript: URL? = nil, initOverride: URL? = nil,
                    forkFixture: String? = nil) -> ChannelSupervisor {
        func makeEnvironment(script: URL?) -> ResolvedEnvironment {
            var e = FakeClaudeLaunch.environment(fixture: fixture, script: script, initOverride: initOverride,
                                                 speed: speed)
            if dropFixture { e.variables["FAKE_CLAUDE_FIXTURE"] = nil }
            return e
        }
        let environment = makeEnvironment(script: script)
        // One `FAKE_CLAUDE_SCRIPT` file is read by every process the rig starts, and a restarted child's request
        // sequence is not the original's: the relaunch therefore replays under its own script. Nothing in production
        // has two environments; this is the rig standing in for two recordings of one channel.
        let relaunchEnvironment = relaunchScript.map { makeEnvironment(script: $0) } ?? environment
        let template = overrideTemplate
            ?? FakeClaudeLaunch.launch(fixture: fixture, cwd: cwd, session: .resume(session, fork: false))
        let key = ChannelKey(configHome: home.url, session: session)
        let sink: any FleetDiagnosticsSink = records ? diagnostics : NullFleetDiagnostics()

        let supervisor = ChannelSupervisor(
            key: key, launchTemplate: template,
            factory: { [weak self] epoch, launch in
                guard let self else { fatalError("the rig went away while a supervisor was still spawning") }
                let e = epoch.rawValue > 1 ? relaunchEnvironment : environment
                return self.makeHandle(epoch: epoch, launch: launch, environment: e, session: session)
            },
            ownership: OwnershipCheck(observer: observer, clock: clock, diagnostics: sink,
                                      onReleased: { [weak self] in await self?.onReleased?() }),
            observer: observer, clock: clock,
            eligibilityInputs: { eligibility.input() },
            fleet: fleet, diagnostics: sink, isRecent: isRecent,
            environment: environment, configHome: home.configHome, verbs: verbs, store: store,
            evictVictim: { [weak self] victim in
                guard let target = self?.supervisor(for: victim) else { return .victimBecameIneligible }
                return await target.evict()
            },
            evictionBarrier: { [weak self] victim in await self?.barrier(for: victim) },
            // The part Task 9's facade plays: a fork is a new channel, built here under the provisional key its
            // source minted and with the fork's own `SessionStart` on its launch line.
            spawnSibling: { [weak self] provisional, start in
                guard let self else { return nil }
                let siblingFixture = forkFixture ?? fixture
                return self.supervisor(
                    session: provisional.session, fixture: siblingFixture, isRecent: true, speed: speed,
                    eligibility: EligibilityBox(), records: records,
                    template: FakeClaudeLaunch.launch(fixture: siblingFixture, cwd: self.cwd, session: start),
                    script: script, relaunchScript: relaunchScript, initOverride: initOverride)
            },
            initialOrigin: origin, initialDesired: desired)

        lock.lock()
        _supervisors.append(supervisor)
        _byKey[key] = supervisor
        lock.unlock()

        let id = ObjectIdentifier(supervisor)
        let stream = supervisor.updates
        let task = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                self.locked { self._published[id, default: []].append(state) }
            }
        }
        locked { tasks.append(task) }
        return supervisor
    }

    /// Every factory, production and this one, installs a `CapturingDiagnostics` as `ClaudeProcess.init`'s
    /// `diagnostics:` argument and hands the same instance to `LiveProcessHandle`; the wedged row's trace exists
    /// nowhere else.
    private func makeHandle(epoch: ProcessEpoch, launch: LaunchConfiguration,
                            environment: ResolvedEnvironment, session: SessionID) -> any ProcessHandle {
        lock.lock()
        _launches.append(launch)
        let scripted = _useScripted
        let termination = _scriptedTermination ?? TerminationReport(exit: .code(0, stderrTail: ""), steps: [])
        let spawnError = _scriptedSpawnError
        let spawnGate = _scriptedSpawnGate
        let configure = _onScriptedHandle
        lock.unlock()

        if scripted {
            let handle = ScriptedProcessHandle(epoch: epoch, session: session,
                                               pid: 400_000 + Int32(epoch.rawValue),
                                               terminateReturns: termination)
            handle.spawnError = spawnError
            handle.spawnGate = spawnGate
            configure?(handle)
            lock.lock(); _scriptedHandles.append(handle); lock.unlock()
            return handle
        }
        let capturing = CapturingDiagnostics(forwardingTo: diagnostics)
        let process = ClaudeProcess(epoch: epoch, launch: launch, environment: environment,
                                    configHome: home.configHome,
                                    mcpServer: AfleetMCPServer(serverVersion: "0.0.0", cwd: cwd,
                                                               tools: [SendUserFileTool()]),
                                    diagnostics: capturing, capture: nil)
        let handle = LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
        lock.lock(); _liveHandles.append(handle); lock.unlock()
        return handle
    }

    // MARK: - Running

    /// Starts the observer's watcher and poll, and fans every published `HolderSet` to every supervisor — the part
    /// Task 9's facade plays in production.
    func startObserver() async {
        let task = Task { [weak self] in
            guard let self else { return }
            for await set in self.observer.updates {
                for supervisor in self.supervisors { await supervisor.holdersChanged(set) }
            }
        }
        locked { tasks.append(task) }
        await observer.start()
    }

    /// Waits for a real child to reach a state. The lifecycle's own timers never move on wall time — only the
    /// `TestClock` moves those — but a spawned process takes as long as it takes, and this is how a test waits for it.
    func waitUntil(_ supervisor: ChannelSupervisor, timeout: Duration = .seconds(30),
                   file: StaticString = #filePath, line: UInt = #line,
                   _ description: String = "the expected state",
                   _ predicate: @escaping @Sendable (ChannelState) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(await supervisor.state) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description); state was \(await supervisor.state.origin)",
                file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    /// Waits for any condition the test can read, on wall time. It moves no part of the lifecycle: only the manual
    /// clock does that, and this is how a test waits for work already in flight to reach a point it can observe.
    func waitFor(_ description: String, timeout: Duration = .seconds(30),
                 file: StaticString = #filePath, line: UInt = #line,
                 _ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    /// Waits until a sleeper is parked with exactly this much time left, so `advance` cannot race the arming of the
    /// timer it is meant to fire — and cannot be satisfied by a different timer that happens to exist.
    func waitForSleeper(due duration: Duration, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if clock.sleeperCount(due: duration) >= 1 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for a sleeper due in \(duration)", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    /// Waits for the detached collector draining `supervisor.updates` to have caught up with everything the actor has
    /// published. The actor's own count is the authority; without this, a count read from `published(of:)` can hold
    /// because an update has not been appended yet rather than because it was never made.
    func drainPublished(of supervisor: ChannelSupervisor,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let want = await supervisor.publishedCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if published(of: supervisor).count >= want { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the update collector never caught up: \(published(of: supervisor).count) of \(want)",
                file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    /// Waits for the supervisor to publish past a count the caller took earlier. `handleExit` publishes once on every
    /// branch, after the whole decision, so this is a synchronisation point on "the exit has been fully processed".
    func waitForPublish(_ supervisor: ChannelSupervisor, above count: Int,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if await supervisor.publishedCount > count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the supervisor never published past \(count)", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    func drainActivity() async {
        for supervisor in supervisors { await supervisor.drainActivity() }
    }

    /// Pushes one engine frame into a scripted channel and waits until the fleet's activity clock has stamped it.
    /// Recency is driven through the supervisor, never by assigning a value, and one frame at a time is what makes
    /// the order of the stamps the order of the frames rather than the order the pump happened to drain them in.
    func pushFrameAndAwaitStamp(_ handle: ScriptedProcessHandle, of supervisor: ChannelSupervisor,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = await fleet.recency(of: supervisor.key)
        handle.push(.frame(.keepAlive, handle.epoch))
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if await fleet.recency(of: supervisor.key) != before {
                await supervisor.drainActivity()
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the activity clock never stamped the frame", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }

    /// The environment the rig hands every child of this fixture, so a test can recompose a pane request's
    /// environment from the same inputs the supervisor used.
    func environment(fixture: String, speed: Double = 50) -> ResolvedEnvironment {
        FakeClaudeLaunch.environment(fixture: fixture, speed: speed)
    }

    /// The arrange/act boundary: everything the test had to build before it could drive its own row is forgotten,
    /// so `assertObserved` still compares exactly.
    func forgetTransitions() { diagnostics.forgetTransitions() }

    func assertObserved(_ expected: Set<LifecycleTable.Transition>,
                        file: StaticString = #filePath, line: UInt = #line) {
        let want = Set(expected.map(RecordingDiagnostics.Observed.init))
        let got = Set(diagnostics.transitions)
        XCTAssertEqual(got, want, "missing: \(want.subtracting(got)); unexpected: \(got.subtracting(want))",
                       file: file, line: line)
        XCTAssertEqual(diagnostics.notInTable, [], "a transition the table does not admit", file: file, line: line)
    }

    /// Finishes every subscriber stream and cancels every dormant timer, terminating nothing.
    func shutdown() async {
        for supervisor in supervisors { await supervisor.shutdown() }
    }

    func tearDown() async {
        releaseEviction()
        for supervisor in supervisors { await supervisor.reap() }
        await observer.stop()
        for task in tasks { task.cancel() }
        for pid in locked({ Array(_helpers) }) { killHelper(pid) }
        home.removeAll()
        try? FileManager.default.removeItem(at: cwd)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}
