import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

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

    private let lock = NSLock()
    private var _launches: [LaunchConfiguration] = []
    private var _liveHandles: [LiveProcessHandle] = []
    private var _scriptedHandles: [ScriptedProcessHandle] = []
    private var _supervisors: [ChannelSupervisor] = []
    private var _published: [ObjectIdentifier: [ChannelState]] = [:]
    private var _scriptedTermination: TerminationReport?
    private var _useScripted = false
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
        let verbs = CLIVerbs(runner: runner, binary: FakeClaudeLaunch.binary, configHome: home.configHome,
                             environment: [:], diagnostics: diagnostics)
        reader = RecordingHolderReader(base: FileHolderReader(verbs: verbs, diagnostics: diagnostics))
        fleet = FleetCapCounter(diagnostics: diagnostics)

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
            var out: Set<Int32> = []
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

    /// Swaps the factory for one that hands out a fresh `ScriptedProcessHandle` per spawn.
    func useScriptedHandle(terminateReturns: TerminationReport) {
        lock.lock(); _useScripted = true; _scriptedTermination = terminateReturns; lock.unlock()
    }

    // MARK: - Building supervisors

    @discardableResult
    func supervisor(session: SessionID, fixture: String = "resume-no-replay", isRecent: Bool = true,
                    origin: ChannelOrigin = .archived, speed: Double = 50, dropFixture: Bool = false,
                    eligibility: EligibilityBox = EligibilityBox(), records: Bool = true) -> ChannelSupervisor {
        let environment: ResolvedEnvironment = {
            var e = FakeClaudeLaunch.environment(fixture: fixture, speed: speed)
            if dropFixture { e.variables["FAKE_CLAUDE_FIXTURE"] = nil }
            return e
        }()
        let template = FakeClaudeLaunch.launch(fixture: fixture, cwd: cwd, session: .resume(session, fork: false))
        let key = ChannelKey(configHome: home.url, session: session)
        let sink: any FleetDiagnosticsSink = records ? diagnostics : NullFleetDiagnostics()

        let supervisor = ChannelSupervisor(
            key: key, launchTemplate: template,
            factory: { [weak self] epoch, launch in
                guard let self else { fatalError("the rig went away while a supervisor was still spawning") }
                return self.makeHandle(epoch: epoch, launch: launch, environment: environment, session: session)
            },
            ownership: OwnershipCheck(observer: observer, clock: clock, diagnostics: sink),
            observer: observer, clock: clock,
            eligibilityInputs: { eligibility.input() },
            fleet: fleet, diagnostics: sink, isRecent: isRecent, initialOrigin: origin)

        lock.lock()
        _supervisors.append(supervisor)
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
        lock.unlock()

        if scripted {
            let handle = ScriptedProcessHandle(epoch: epoch, session: session,
                                               pid: 400_000 + Int32(epoch.rawValue),
                                               terminateReturns: termination)
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
        for supervisor in supervisors { await supervisor.reap() }
        await observer.stop()
        for task in tasks { task.cancel() }
        home.removeAll()
        try? FileManager.default.removeItem(at: cwd)
    }
}
