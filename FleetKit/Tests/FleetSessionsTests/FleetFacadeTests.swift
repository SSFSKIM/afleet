import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The facade over everything Tasks 1 through 8 landed: one `Fleet` per config home, built the way production
/// builds it — its own diagnostics sink, its own holder reader, its own observer, cap counter, preconditions and
/// verbs — with only the clock and the CLI runner swapped for scripted ones. The processes are real children of
/// `fake-claude` replaying a committed fixture.
final class FleetFacadeTests: XCTestCase {

    private static let fixture = "resume-no-replay"

    // MARK: - The harness

    /// A `Fleet` over a scratch config home, its scripted holder files, a manual clock and a scripted CLI runner.
    private final class Harness: @unchecked Sendable {   // every stored value is set once, in `init`
        let home: ScratchConfigHome
        let files: ScriptedHolderFiles
        let clock = TestClock()
        let runner: ScriptedProcessRunner
        let calls: ScriptedProcessRunner.Recorder
        let store: FileStateStore
        let fleet: Fleet
        let cwd: URL
        let diagnosticsDirectory: URL
        /// The handles the scripted factory built, in spawn order; empty unless the harness was asked for them.
        let handles = ScriptedHandles()
        /// Parent §11's opt-in raw frame capture, when the test asked for one: the only place a frame afleet
        /// *wrote* to a child is written down whole, which is what a claim about the bytes on the wire needs.
        let capture: RawCapture?
        private let storeDirectory: URL
        private let scriptDirectory: URL
        private let captureRoot: URL

        /// `scriptedHandles` swaps the production factory for one that hands out a `ScriptedProcessHandle` per
        /// spawn, which is how a test reads back the control requests the facade sent.
        ///
        /// `replaying` are `FAKE_CLAUDE_SCRIPT` steps: the exchanges the replayed child answers the facade's own
        /// control requests with. `RouterTests` builds them the same way, against a supervisor; a facade test needs
        /// them here because the environment a `Fleet` launches its children with is fixed at construction.
        init(scriptedHandles: Bool = false, replaying steps: [[String: Any]] = [],
             capturing: Bool = false) throws {
            home = try ScratchConfigHome()
            files = ScriptedHolderFiles(home: home)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            cwd = temporary.appending(path: "afleet-c4-facade-cwd-\(UUID().uuidString)")
            storeDirectory = temporary.appending(path: "afleet-c4-facade-store-\(UUID().uuidString)")
            diagnosticsDirectory = temporary.appending(path: "afleet-c4-facade-diag-\(UUID().uuidString)")
            scriptDirectory = temporary.appending(path: "afleet-c4-facade-script-\(UUID().uuidString)")
            captureRoot = temporary.appending(path: "afleet-c4-facade-capture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try home.trust(root: cwd)

            let recorder = ScriptedProcessRunner.Recorder()
            calls = recorder
            runner = ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files) + Harness.jobRules(),
                                           calls: recorder)
            store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])
            let factory: ProcessFactory? = scriptedHandles ? Harness.scriptedFactory(into: handles) : nil
            let script = steps.isEmpty
                ? nil
                : try ReplayScript.write(steps, fixture: FleetFacadeTests.fixture, into: scriptDirectory)
            let capture = capturing ? RawCapture(root: captureRoot, configHome: home.configHome) : nil
            self.capture = capture
            fleet = Fleet(configHome: home.configHome,
                              environment: FakeClaudeLaunch.environment(fixture: FleetFacadeTests.fixture,
                                                                        script: script),
                              binary: FakeClaudeLaunch.binary, store: store,
                              diagnosticsDirectory: diagnosticsDirectory, clock: clock, factory: factory,
                              capture: { capture }, runner: runner)
        }

        /// A factory handing out one `ScriptedProcessHandle` per spawn, collected in order.
        static func scriptedFactory(into built: ScriptedHandles) -> ProcessFactory {
            { epoch, launch in
                let session: SessionID
                switch launch.session {
                case .new(let id): session = id
                case .resume(let id, _): session = id
                case .forkFrom(let id, _): session = id
                }
                let handle = ScriptedProcessHandle(epoch: epoch, session: session,
                                                   pid: 500_000 + Int32(epoch.rawValue))
                built.append(handle, launch)
                return handle
            }
        }

        /// `respawn` and `rm`, which the shared default script does not answer: `jfail` is the short whose respawn
        /// the CLI refuses, which is the only way to reach the non-zero-exit arm.
        static func jobRules() -> [ScriptedProcessRunner.Rule] {
            [.init(match: { $0.count == 2 && $0[0] == "respawn" },
                   respond: { argv in .exit(argv[1] == "jfail" ? 3 : 0) }),
             .init(match: { $0.count == 2 && $0[0] == "rm" }, respond: { _ in .exit(0) })]
        }

        func tearDown() async {
            await fleet.shutdown()
            home.removeAll()
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnosticsDirectory)
            try? FileManager.default.removeItem(at: scriptDirectory)
            try? FileManager.default.removeItem(at: captureRoot)
        }

        /// Every `user` frame this harness's capture recorded for a session: the frames afleet wrote into the
        /// child, read back from the one file that holds them whole. Empty when nothing has been captured yet,
        /// so a wait can poll it.
        func capturedUserFrames(of session: SessionID) -> [[String: Any]] {
            guard capture != nil else { return [] }
            let url = captureRoot.appending(path: RawCapture.configHomeHash(home.configHome))
                .appending(path: "\(session.description).ndjson")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "user" else { return nil }
                return object
            }
        }

        /// The suite's clock stepper and wall-clock wait, over this harness's manual clock. Both bodies live in
        /// `TestTiming`, so this harness and `Rig` cannot drift apart.
        func steppingClock<T: Sendable>(upTo limit: Duration = ChannelSupervisor.handoffBudget,
                                        file: StaticString = #filePath, line: UInt = #line,
                                        _ body: @escaping @Sendable () async throws -> T) async throws -> T {
            try await TestTiming.steppingClock(clock, upTo: limit, file: file, line: line, body)
        }

        func waitFor(_ description: String, timeout: Duration = .seconds(30),
                     file: StaticString = #filePath, line: UInt = #line,
                     _ predicate: @Sendable () async -> Bool) async throws {
            try await TestTiming.waitFor(description, timeout: timeout, file: file, line: line, predicate)
        }

        /// Every line the fleet's own diagnostics file holds, as decoded objects.
        func diagnosticLines() async throws -> [[String: Any]] {
            await fleet.flushDiagnostics()
            let url = diagnosticsDirectory.appending(path: "fleet.log")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { line in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    struct NotAnObject: Error {}
                    throw NotAnObject()
                }
                return object
            }
        }
    }

    private var harness: Harness!
    /// Harnesses a single test built for itself — a scripted-handle fleet, say — torn down with the shared one.
    private var extraHarnesses: [Harness] = []

    /// A second fleet of this suite's shape whose children are `ScriptedProcessHandle`s, so a test can read the
    /// control requests the facade sent and the launch lines it composed.
    private func scriptedHarness() throws -> Harness {
        let harness = try Harness(scriptedHandles: true)
        extraHarnesses.append(harness)
        return harness
    }

    override func setUp() async throws {
        try await super.setUp()
        harness = try Harness()
    }

    override func tearDown() async throws {
        for extra in extraHarnesses { await extra.tearDown() }
        extraHarnesses = []
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func key(_ session: SessionID) -> ChannelKey {
        ChannelKey(configHome: harness.home.url, session: session)
    }

    /// Starts observing before the stimulus. The expectation is fulfilled by the matching delivery itself.
    private func expectStateDelivery(in fleet: Fleet, description: String,
                                     where predicate: @escaping @Sendable (ChannelState) -> Bool)
        -> (expectation: XCTestExpectation, observer: Task<Void, Never>) {
        let delivered = expectation(description: description)
        let observer = Task {
            for await state in fleet.updates where predicate(state) {
                delivered.fulfill()
                return
            }
        }
        return (delivered, observer)
    }

    /// `events(of:)` registers the subscriber before returning, so a push immediately after this call cannot be lost.
    private func expectEventDelivery(in fleet: Fleet, on key: ChannelKey, description: String,
                                     where predicate: @escaping @Sendable (WireEvent) -> Bool) async throws
        -> (expectation: XCTestExpectation, observer: Task<Void, Never>) {
        let available = await fleet.events(of: key)
        let stream = try XCTUnwrap(available, "no event stream for the scripted channel")
        let delivered = expectation(description: description)
        let observer = Task {
            for await event in stream where predicate(event) {
                delivered.fulfill()
                return
            }
        }
        return (delivered, observer)
    }

    private func fixtureSession() throws -> SessionID { try FakeClaudeLaunch.sessionID(of: Self.fixture) }

    // MARK: - Actions the facade owns

    /// *Background all* is one request to the engine, not a handoff of every channel. `background_tasks` with no
    /// `tool_use_id` asks the engine to put every tool the current turn is running into the background; a loop of
    /// `sendToBackground` instead terminates every owned child in the fleet and re-launches each as a `--bg` job,
    /// which is a different verb with a different meaning and nothing the *Stop* sheet offers.
    ///
    /// Scripted handles: what the test reads is the control request the facade sent.
    ///
    /// Deliberate break: loop `sendToBackground` over every owned channel again.
    func testBackgroundAllSendsOneBackgroundTasksRequestAndTerminatesNothing() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let first = ChannelKey(configHome: harness.home.url, session: SessionID())
        let second = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(first, cwd: harness.cwd, recent: true)
        _ = try await fleet.open(second, cwd: harness.cwd, recent: true)

        _ = try await fleet.perform(.backgroundAll, on: first)

        let handles = harness.handles.all
        XCTAssertEqual(handles.count, 2, "two channels, two children, and no relaunch")
        XCTAssertEqual(handles[0].controlRequests.map(\.subtype), ["background_tasks"])
        XCTAssertEqual(handles[0].controlRequests.first?.payload, .object([:]),
                       "no tool_use_id: every tool of the current turn, not one named tool")
        XCTAssertEqual(handles[1].controlRequests.map(\.subtype), [],
                       "the request goes to the channel the sheet was opened on")
        XCTAssertEqual(handles.map(\.terminateCount), [0, 0], "nothing was terminated")
        let states = await [fleet.state(of: first)?.origin, fleet.state(of: second)?.origin]
        XCTAssertEqual(states, [.owned(.ready), .owned(.ready)], "and no channel became a job")
    }

    /// The thirty-minute reap and the cap eviction both re-evaluate eligibility at the moment they act. The
    /// facade's own `.reap` did not: *Reap* on a channel with a decision on screen killed the child under the
    /// question. The gate is on the facade and not on `ChannelSupervisor.reap()`, which the rig uses as an
    /// unconditional teardown terminate.
    ///
    /// Deliberate break: call `supervisor.reap()` from `perform(.reap)` without consulting the verdict.
    func testAFacadeReapIsRefusedWhileTheChannelIsNotEligible() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)

        let decision = try await expectEventDelivery(in: fleet, on: k,
                                                     description: "the decision request was delivered") {
            if case .request = $0 { true } else { false }
        }
        defer { decision.observer.cancel() }
        handle.push(.request(Self.decisionRequest(epoch: handle.epoch)))
        try await TestTiming.awaitDelivery([decision.expectation])

        do {
            _ = try await fleet.perform(.reap, on: k)
            XCTFail("the reap ended a child with a decision still on screen")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notEligible(.pendingDecision),
                           "the refusal names the blocker")
        }
        XCTAssertEqual(handle.terminateCount, 0, "the process survived")
        let origin = await fleet.state(of: k)?.origin
        XCTAssertEqual(origin, .owned(.ready))
    }

    /// **Group H, the wired mirror.** A channel with a background task armed on its own pump is not eligible, and
    /// the two places that end a child on eligibility both see it: the facade's *Reap* refuses and names the task,
    /// and the cap eviction never picks the channel as its victim. Before the mirror was wired every supervisor read
    /// an empty one, so a channel whose background shell had just been announced was the fleet's most inviting
    /// victim — and terminating it kills the shell, which is the loss parent §7.4's dormant-eligibility paragraph
    /// exists to prevent.
    ///
    /// Six channels fill the cap. Five are held by a decision on screen and the sixth by the armed task, so the
    /// seventh open must be refused rather than evicting anybody: with the mirror unwired the armed channel is the
    /// one eligible candidate and is reaped instead.
    ///
    /// Deliberate break: hand `Fleet.build`'s `eligibilityInputs` an empty mirror again.
    func testAChannelWithAnArmedTaskRefusesAReapAndIsNeverTheEvictionVictim() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        await fleet.start()
        var keys: [ChannelKey] = []
        for _ in 0..<FleetCapCounter.capacity {
            let k = ChannelKey(configHome: harness.home.url, session: SessionID())
            keys.append(k)
            _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        }
        let handles = harness.handles.all
        XCTAssertEqual(handles.count, FleetCapCounter.capacity)

        // The channel the engine has announced a background shell on, and nothing else about it.
        let armed = keys[0]
        let taskID = "task-invented-armed-shell-1"
        let armedFrame = try await expectEventDelivery(in: fleet, on: armed,
                                                       description: "the armed task frame was delivered") {
            if case .frame = $0 { true } else { false }
        }
        defer { armedFrame.observer.cancel() }
        handles[0].push(.frame(try Self.backgroundTasksChanged(taskIDs: [taskID], session: armed.session),
                               handles[0].epoch))
        try await TestTiming.awaitDelivery([armedFrame.expectation])
        await fleet.channel(armed)?.drainEligibility()

        do {
            _ = try await fleet.perform(.reap, on: armed)
            XCTFail("the reap ended a child with a background task armed")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notEligible(.taskArmed(taskID)),
                           "the refusal names the task that is holding the channel")
        }

        // Everybody else is held by a decision, so the armed channel is the only channel an eviction could pick.
        for (index, k) in keys.enumerated().dropFirst() {
            let decision = try await expectEventDelivery(in: fleet, on: k,
                                                         description: "channel \(index)'s decision was delivered") {
                if case .request = $0 { true } else { false }
            }
            handles[index].push(.request(Self.decisionRequest(epoch: handles[index].epoch)))
            try await TestTiming.awaitDelivery([decision.expectation])
            decision.observer.cancel()
            await fleet.channel(k)?.drainEligibility()
        }

        let seventh = ChannelKey(configHome: harness.home.url, session: SessionID())
        var refusal: (any Error)?
        do { _ = try await fleet.open(seventh, cwd: harness.cwd, recent: true) } catch { refusal = error }
        XCTAssertEqual(refusal as? LifecycleError, .capReached(live: FleetCapCounter.capacity),
                       "with nobody eligible the cap refuses rather than evicting the armed channel")
        XCTAssertEqual(handles.map(\.terminateCount), Array(repeating: 0, count: FleetCapCounter.capacity),
                       "no channel was terminated, least of all the one with a task armed")
        XCTAssertEqual(harness.handles.all.count, FleetCapCounter.capacity, "the refused spawn built no child")
        let origin = await fleet.state(of: armed)?.origin
        XCTAssertEqual(origin, .owned(.ready))
    }

    /// **Group H, the clock.** The age of the last task frame is measured on the *injected* clock. C3's mirror
    /// stamps `lastFrameAt` as a wall-clock `Date`; an age derived from `Date()` is a quantity no manual clock can
    /// move, and the uncertainty rule — a running task whose last frame is older than its heartbeat may have
    /// completed unseen — would then be untestable without sleeping on wall time, which this package forbids.
    ///
    /// One `task_started` and no frame after it: the task is running and fresh, and the same task is uncertain once
    /// the clock has moved past the thirty-second heartbeat. Nothing sleeps; only `TestClock.advance` moves.
    ///
    /// Deliberate break: derive `lastTaskFrameAge` from `Date().timeIntervalSince(entry.lastFrameAt)`.
    func testTheAgeOfTheLastTaskFrameIsMeasuredOnTheInjectedClock() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)

        let taskID = "task-invented-running-shell-1"
        let taskFrame = try await expectEventDelivery(in: fleet, on: k,
                                                      description: "the started task frame was delivered") {
            if case .frame = $0 { true } else { false }
        }
        defer { taskFrame.observer.cancel() }
        handle.push(.frame(try Self.taskStarted(taskID: taskID, session: k.session), handle.epoch))
        try await TestTiming.awaitDelivery([taskFrame.expectation])
        await fleet.channel(k)?.drainEligibility()

        do {
            _ = try await fleet.perform(.reap, on: k)
            XCTFail("the reap ended a child with a background task running")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notEligible(.taskRunning(taskID)),
                           "a task whose frame just arrived is running, not uncertain")
        }

        await harness.clock.advance(by: .seconds(31))

        do {
            _ = try await fleet.perform(.reap, on: k)
            XCTFail("the reap ended a child whose task state is unknown")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notEligible(.taskStateUncertain(taskID)),
                           "the manual clock moved the age past the heartbeat, so the mirror may have missed the end")
        }
        XCTAssertEqual(handle.terminateCount, 0, "neither refusal touched the child")
    }

    /// **Group H, the epoch.** A background shell is a child of the engine's process and dies with it, so the rows
    /// a child left behind say nothing about the channel once that child has gone. The mirror is the channel's, not
    /// the child's, so nothing else would clear them — and a row nobody ever notifies is live for ever, which would
    /// leave the channel permanently unreapable and permanently un-evictable on a fact that stopped being true when
    /// the child exited.
    ///
    /// Deliberate break: drop `taskMirror?.reset()` from `handleExit`.
    func testTheTasksOfAChildThatHasGoneDoNotHoldTheChannel() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)

        let taskFrame = try await expectEventDelivery(in: fleet, on: k,
                                                      description: "the running task frame was delivered") {
            if case .frame = $0 { true } else { false }
        }
        defer { taskFrame.observer.cancel() }
        handle.push(.frame(try Self.taskStarted(taskID: "task-invented-orphan-shell-1", session: k.session),
                           handle.epoch))
        try await TestTiming.awaitDelivery([taskFrame.expectation])
        await fleet.channel(k)?.drainEligibility()

        let rested = expectStateDelivery(in: fleet, description: "the channel delivered its dormant state") {
            $0.key == k && $0.origin == .owned(.dormant)
        }
        defer { rested.observer.cancel() }
        handle.push(.exited(.code(0, stderrTail: ""), handle.epoch))
        try await TestTiming.awaitDelivery([rested.expectation])
        let eligible = await fleet.isDormantEligible(k)
        XCTAssertTrue(eligible, "the shell died with the child, so nothing is holding the channel any more")
    }

    /// A `background_tasks_changed` listing, built from the published schema with invented identifiers and decoded
    /// through `FrameDecoder` rather than hand-assembled. It announces a task and starts nothing: the row it folds
    /// to is armed.
    private static func backgroundTasksChanged(taskIDs: [String], session: SessionID) throws -> Frame {
        let line = JSONValue.object([
            "type": .string("system"),
            "subtype": .string("background_tasks_changed"),
            "tasks": .array(taskIDs.map { id in
                .object(["task_id": .string(id), "task_type": .string("local_bash"),
                         "description": .string("an invented background shell"), "status": .string("running")])
            }),
            "uuid": .string("00000000-0000-4000-8000-00000000c4a1"),
            "session_id": .string(session.description),
        ])
        guard case .system(let system) = FrameDecoder.decode(line: try line.canonicalData()) else {
            struct NotASystemFrame: Error {}
            throw NotASystemFrame()
        }
        return .system(system)
    }

    /// A `task_started`, invented the same way: the row it folds to has started and has not been handed back, which
    /// is what the mirror calls running.
    private static func taskStarted(taskID: String, session: SessionID) throws -> Frame {
        let line = JSONValue.object([
            "type": .string("system"),
            "subtype": .string("task_started"),
            "task_id": .string(taskID),
            "tool_use_id": .string("toolu_inventedToolUseIdentifier02"),
            "description": .string("an invented background shell"),
            "is_backgrounded": .bool(true),
            "task_type": .string("local_bash"),
            "uuid": .string("00000000-0000-4000-8000-00000000c4a2"),
            "session_id": .string(session.description),
        ])
        guard case .system(let system) = FrameDecoder.decode(line: try line.canonicalData()) else {
            struct NotASystemFrame: Error {}
            throw NotASystemFrame()
        }
        return .system(system)
    }

    /// A fork of a fork. The sibling spawner captured the key its source was *filed under when it was built*, and a
    /// fork re-keys itself the moment its identity resolves — so the grandchild was looked up under a key the fleet
    /// no longer knows, found no seed, and launched in the config home instead of the project. The source key is a
    /// call-time argument now, and the directory comes from the source's own runtime state rather than from the
    /// seed, so a `/cd` moves the fork's children too.
    ///
    /// Deliberate break: capture `key` in the `spawnSibling` closure again.
    func testAForkOfAForkLaunchesInTheSourcesProjectAndNotTheConfigHome() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)

        _ = try await fleet.perform(.fork(at: nil), on: k)
        let forkHandle = try XCTUnwrap(harness.handles.all.last)
        let resolved = SessionID()
        let forkKey = ChannelKey(configHome: harness.home.url, session: resolved)
        let forkReady = expectStateDelivery(in: fleet, description: "the fork delivered ready on its resolved id") {
            $0.key == forkKey && $0.origin == .owned(.ready)
        }
        defer { forkReady.observer.cancel() }
        forkHandle.push(.sessionIdentityResolved(resolved, forkHandle.epoch))
        try await TestTiming.awaitDelivery([forkReady.expectation])

        _ = try await fleet.perform(.fork(at: nil), on: forkKey)

        let launches = harness.handles.launches
        XCTAssertEqual(launches.count, 3, "the channel, its fork and the fork's fork")
        // A boolean: both operands are under the harness's temporary tree (tracker entry 75, §6.3).
        XCTAssertTrue(launches[2].cwd.standardizedFileURL == harness.cwd.standardizedFileURL,
                      "the grandchild runs in the project, not in the config home")
        XCTAssertEqual(launches[2].session, .resume(resolved, fork: true),
                       "and forks the session its source is actually running")
    }

    /// The `can_use_tool` shape the engine asks with, from `DecisionTests`' own builder.
    private static func decisionRequest(epoch: ProcessEpoch) -> InboundRequest {
        let raw = JSONValue.object([
            "subtype": .string("can_use_tool"),
            "tool_name": .string("Bash"),
            "input": .object(["command": .string("echo hi")]),
            "tool_use_id": .string("toolu_facade-reap"),
        ])
        // The decode cannot fail on a body this file composed; a nil would silently make the test vacuous.
        let typed = try! JSONDecoder().decode(CanUseToolRequest.self, from: try! raw.canonicalData())
        return InboundRequest(id: RequestID(rawValue: "facade-reap"), epoch: epoch, receivedAt: .now,
                              payload: .canUseTool(typed), raw: raw)
    }

    // MARK: - States and updates

    func testOpenListsTheChannelAndPublishesEveryTransition() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        let collected = Collected()
        let secondTransition = expectation(description: "the merged stream delivered its second transition")
        let readyTransition = expectation(description: "the merged stream delivered the ready transition")
        let drain = Task {
            for await state in fleet.updates {
                if collected.append(state) == 2 { secondTransition.fulfill() }
                if state.origin == .owned(.ready) { readyTransition.fulfill() }
            }
        }
        defer { drain.cancel() }

        await fleet.start()
        let state = try await fleet.open(k, cwd: harness.cwd, recent: true)
        // Booleans: `ChannelKey` carries the harness's config home, which is under the temporary directory.
        XCTAssertTrue(state.key == k, "open returned a state on a different key")

        let listed = await fleet.states()
        XCTAssertTrue(listed.map(\.key) == [k], "the fleet lists \(listed.count) channels, not the 1 opened")
        let read = await fleet.state(of: k)
        XCTAssertTrue(read?.key == k, "reading the key back gave a state on a different key")
        let unknown = await fleet.state(of: key(SessionID()))
        XCTAssertNil(unknown, "a key the fleet has never been told about")

        try await TestTiming.awaitDelivery([secondTransition, readyTransition])
        XCTAssertTrue(collected.states.allSatisfy { $0.key == k })
        XCTAssertTrue(collected.states.contains { $0.origin == .owned(.ready) },
                      "the facade's `updates` merges every supervisor's stream")
    }

    func testPreconditionsRunForAChannelTheFleetKnows() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        await fleet.register(k, cwd: harness.cwd, recent: true)
        let verdict = await fleet.preconditions(for: k)
        XCTAssertEqual(verdict, .ready, "a trusted project with no holders and no project servers")

        let untrusted = key(SessionID())
        let elsewhere = harness.cwd.appending(path: "not-trusted")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        await fleet.register(untrusted, cwd: elsewhere, recent: true)
        let refused = await fleet.preconditions(for: untrusted)
        guard case .untrusted = refused else { return XCTFail("expected untrusted, got \(refused)") }
    }

    // MARK: - The event fan-out

    func testEventsAreFannedOutToEverySubscriberAndNilWithoutASupervisor() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        await fleet.register(k, cwd: harness.cwd, recent: true)

        let firstStream = await fleet.events(of: k)
        let secondStream = await fleet.events(of: k)
        let first = try XCTUnwrap(firstStream)
        let second = try XCTUnwrap(secondStream)
        let none = await fleet.events(of: key(SessionID()))
        XCTAssertNil(none, "no supervisor, no stream")

        let one = Frames(), two = Frames()
        let firstTwo = expectation(description: "the first subscriber delivered two replay events")
        let secondTwo = expectation(description: "the second subscriber delivered two replay events")
        let a = Task {
            for await event in first {
                if one.append(event) == 2 { firstTwo.fulfill() }
            }
        }
        let b = Task {
            for await event in second {
                if two.append(event) == 2 { secondTwo.fulfill() }
            }
        }
        defer { a.cancel(); b.cancel() }

        _ = try await fleet.perform(.open, on: k)
        try await TestTiming.awaitDelivery([firstTwo, secondTwo])
        XCTAssertEqual(Array(one.names.prefix(2)), Array(two.names.prefix(2)),
                       "both subscribers see the same frames alike")
    }

    // MARK: - Answers

    func testAnAnswerForAnIdNoProcessAskedIsDecisionGone() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        let id = RequestID(rawValue: "req-nobody-asked")
        do {
            _ = try await fleet.perform(.answer(id, .permission(.allow(updatedInput: nil, updatedPermissions: nil,
                                                                       classification: nil))), on: k)
            XCTFail("an id no process asked was answered")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .decisionGone(id))
        }
    }

    // MARK: - The terminal hatch

    func testOpenInTerminalHandsOffAndAPaneExitReAdopts() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        let request = try await harness.steppingClock { try await fleet.openInTerminal(k) }
        XCTAssertEqual(request.purpose, PanePurpose.hatch(k.session))
        XCTAssertEqual(request.arguments, ["--resume", k.session.description])
        XCTAssertEqual(request.executable, FakeClaudeLaunch.binary)
        XCTAssertTrue(request.environment["CLAUDE_CONFIG_DIR"] == harness.home.url.path,
                      "the hatch names a config home other than the harness's")
        let handedOff = await fleet.state(of: k)?.origin
        XCTAssertEqual(handedOff, .foreignLive(.ownTerminalTab))

        try await harness.steppingClock {
            await fleet.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        }
        try await harness.waitFor("the re-adoption") { await fleet.state(of: k)?.origin == .owned(.ready) }

        // A late exit for a request nobody is waiting on changes nothing and is recorded as stale.
        await fleet.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        let events = try await harness.diagnosticLines().compactMap { $0["event"] as? String }
        XCTAssertTrue(events.contains("stale_exit"), "the second exit for the same id was discarded")
    }

    // MARK: - Jobs

    /// A channel registered *after* its holder already exists learns about it at once.
    ///
    /// `fanOut` runs only on a published holder set and the observer publishes only what changed, so a supervisor
    /// built later would otherwise never hear about a holder that was already there — it would sit archived with a
    /// live job against its session until something unrelated moved the fleet-wide set. G5's adoption scenario
    /// found this against the installed CLI: the job was listed by `jobs()` and the channel stayed archived, so
    /// `perform(.adopt)` had nothing to adopt. C5 registers channels from C3's index, and a job or a terminal
    /// session that predates the register is the ordinary case rather than a corner.
    ///
    /// Deliberate break: remove the seeding task from `Fleet.build` → the wait times out with the channel archived.
    func testAChannelRegisteredAfterItsHolderExistsLearnsAboutItAtOnce() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let session = try fixtureSession()
        let k = key(session)

        // Written before the fleet reads anything, so the holder is present in the observer's *first* snapshot and
        // no later change can publish it: the only way the supervisor can hear about it is the seeding.
        try harness.files.writeJob(short: "jseed1", state: "working", sessionID: session, resumeSessionID: session,
                                   pid: ScriptedHolderFiles.livePID)
        await fleet.start()
        try await harness.waitFor("the observer's first read") { await fleet.jobs().contains { $0.sessionID == session } }

        let backgroundJob = expectStateDelivery(in: fleet,
                                                description: "the registered channel delivered background-job state") {
            $0.key == k && $0.origin == .backgroundJob
        }
        defer { backgroundJob.observer.cancel() }
        await fleet.register(k, cwd: harness.cwd, recent: true)
        try await TestTiming.awaitDelivery([backgroundJob.expectation])
    }

    func testJobsListsAnExecJobAndAConversationJobAndTheVerbsActOnThem() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        // An exec job: a roster worker whose job record names no session.
        try harness.files.writeJob(short: "jexec1", state: "working", pid: ScriptedHolderFiles.livePID)

        _ = try await harness.steppingClock { try await fleet.perform(.sendToBackground, on: k) }
        let handedOver = await fleet.state(of: k)?.origin
        XCTAssertEqual(handedOver, .backgroundJob,
                       "a session afleet sent to the background is a channel and a job at once")

        let jobs = await fleet.jobs()
        let exec = try XCTUnwrap(jobs.first { $0.short == JobShort(rawValue: "jexec1") })
        XCTAssertNil(exec.sessionID, "an exec job carries no session")
        let conversation = try XCTUnwrap(jobs.first { $0.sessionID == k.session })
        XCTAssertEqual(conversation.state, "working")

        // `attach` and `logs` are panes and change no ownership.
        let attach = try await fleet.attach(conversation.short)
        XCTAssertEqual(attach.purpose, PanePurpose.attach(conversation.short))
        XCTAssertEqual(attach.arguments, ["attach", conversation.short.rawValue])
        let logs = try await fleet.logs(conversation.short)
        XCTAssertEqual(logs.purpose, PanePurpose.logs(conversation.short))
        XCTAssertEqual(logs.arguments, ["logs", conversation.short.rawValue])
        let unchanged = await fleet.state(of: k)?.origin
        XCTAssertEqual(unchanged, .backgroundJob)

        // Stop: the runner ran the verb and the entry left the roster.
        try await fleet.performJob(.stop, conversation.short)
        XCTAssertTrue(harness.calls.invocations.contains(["stop", conversation.short.rawValue]))
        let after = await fleet.jobs()
        XCTAssertFalse(after.contains { $0.short == conversation.short }, "a stopped job left the roster")

        try await fleet.performJob(.respawn, JobShort(rawValue: "jexec1"))
        XCTAssertTrue(harness.calls.invocations.contains(["respawn", "jexec1"]))
        try await fleet.performJob(.remove, JobShort(rawValue: "jexec1"))
        XCTAssertTrue(harness.calls.invocations.contains(["rm", "jexec1"]))

        do {
            try await fleet.performJob(.respawn, JobShort(rawValue: "jfail"))
            XCTFail("a non-zero exit was not reported")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .verbFailed(verb: "respawn", exitCode: 3))
        }
    }

    /// The two `--bg` verbs run *in* the project's directory. `ProcessRunner` has no working-directory parameter,
    /// so FleetKit's own seam carries one; without it the job would be created in whatever directory afleet itself
    /// was started from.
    func testTheBackgroundVerbRunsInTheChannelsWorkingDirectory() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        _ = try await harness.steppingClock { try await fleet.perform(.sendToBackground, on: k) }

        let index = try XCTUnwrap(harness.calls.invocations.firstIndex { $0.starts(with: ["--bg", "--resume"]) })
        XCTAssertEqual(harness.calls.directoriesUsed[index], harness.cwd,
                       "the job was created in the channel's directory")
        let agents = try XCTUnwrap(harness.calls.invocations.firstIndex { $0.starts(with: ["agents", "--json"]) })
        XCTAssertNil(harness.calls.directoriesUsed[agents], "a verb that acts on the config home names no directory")
    }

    /// The production conformance of the working-directory seam really does start the child in the directory it
    /// names. The child here is `/bin/pwd`, a process this test starts itself.
    func testTheProductionRunnerStartsItsChildInTheNamedDirectory() async throws {
        let harness = self.harness!
        let runner = FoundationDirectoryRunner()
        let out = try await runner.run(URL(filePath: "/bin/pwd"), arguments: [], environment: [:],
                                       cwd: harness.cwd, timeout: .seconds(10))
        XCTAssertEqual(out.exitCode, 0)
        // Both sides resolved: `pwd` prints the real path and `/var/folders` is a symlink to `/private/var`, so
        // comparing the two spellings would compare one directory with itself and fail.
        let reported = URL(filePath: String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        func real(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        XCTAssertTrue(real(reported) == real(harness.cwd),
                      "the child's own `pwd` is not the working directory the harness launched it in")
    }

    // MARK: - A restart's unresolved settings

    /// Every name `Readback.verify` can report, mapped to the request that puts it back — `outputStyle` through
    /// `update_settings`, the one key that request accepts (parent §7.7, *Parity F-7*), and not through a
    /// `/config` turn read back with `get_settings`.
    ///
    /// This test owns the *mapping* half of the deliverable, deliberately and not by omission. The other half —
    /// that a failed apply leaves the banner where it was — needs a channel with a non-empty `unresolvedSettings`,
    /// which only a quiescent restart with a failing readback produces, and that rig and that banner both live in
    /// `RestartTests`. Splitting them keeps each assertion next to the machinery it is about.
    func testResolveSettingSendsTheRequestEachNameMapsTo() async throws {
        await harness.tearDown()
        harness = try Harness(scriptedHandles: true)
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }
        let handle = try XCTUnwrap(harness.handles.all.first)

        try await fleet.resolveSetting("model", to: .string("claude-haiku-4-5-20251001"), on: k)
        try await fleet.resolveSetting("permissionMode", to: .string("acceptEdits"), on: k)
        try await fleet.resolveSetting("effort", to: .string("high"), on: k)
        try await fleet.resolveSetting("outputStyle", to: .string("Explanatory"), on: k)
        try await fleet.resolveSetting("fastMode", to: .bool(true), on: k)
        try await fleet.resolveSetting("flagSettings.advisor", to: .string("on"), on: k)

        XCTAssertEqual(handle.controlRequests.map(\.subtype),
                       ["set_model", "set_permission_mode", "apply_flag_settings", "update_settings",
                        "apply_flag_settings", "apply_flag_settings"])
        let payloads = handle.controlRequests.map(\.payload)
        XCTAssertEqual(payloads[0]["model"]?.stringValue, "claude-haiku-4-5-20251001")
        XCTAssertEqual(payloads[1]["mode"]?.stringValue, "acceptEdits")
        XCTAssertEqual(payloads[2]["settings"]?["effortLevel"]?.stringValue, "high")
        XCTAssertEqual(payloads[3]["source"]?.stringValue, "localSettings",
                       "`update_settings` takes only the local source")
        XCTAssertEqual(payloads[3]["settings"]?["outputStyle"]?.stringValue, "Explanatory")
        XCTAssertEqual(payloads[4]["settings"]?["fastMode"]?.boolValue, true)
        XCTAssertEqual(payloads[5]["settings"]?["advisor"]?.stringValue, "on")

        // A name outside the closed set sends nothing rather than guessing at a request.
        try await fleet.resolveSetting("somethingTheReadbackNeverReports", to: .string("x"), on: k)
        XCTAssertEqual(handle.controlRequests.count, 6)

        // And a key the fleet owns no supervisor for is not a channel to apply anything to.
        do {
            try await fleet.resolveSetting("model", to: .string("m"), on: key(SessionID()))
            XCTFail("a setting was applied to a channel that does not exist")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notOwned)
        }
    }

    // MARK: - The composer's line

    /// The router is reachable through the facade, on a key, for every one of its three steps: routing a line
    /// against the channel's own engine report, sending the control request the line named, and running the
    /// strategy the line named.
    ///
    /// C6's composer holds a `ChannelKey` and nothing below it. Before this, `CommandRouter.route` and
    /// `StrategyExecutor` both took a `ChannelSupervisor`, which the facade never hands out — so the first slash
    /// command typed into the conversation surface had no way through, and every router test drove the executor on
    /// a supervisor it had built itself.
    ///
    /// Recorded: the `apply_flag_settings` bare success and the `get_settings` whose `effective` names the flag just
    /// applied are the `control-shapes` recording's own, and so is the `system/init` the script re-emits —
    /// `resume-no-replay`, the one fixture that stays alive after the handshake, records none of its own, and the
    /// terminal-only refusal is the half of `route` that reads one. The `mcp_status` answer is `zero-cost`'s.
    ///
    /// Deliberate break: drop `Fleet.route`, `Fleet.send` or `Fleet.run` → this test cannot compile, which is the
    /// only red a missing method on the facade can show.
    func testTheFacadeRoutesALineAndSendsAndRunsWhatItNames() async throws {
        let settings = try FixtureAnswers.body("control-shapes", "get_settings")
        let mcp = try FixtureAnswers.body("zero-cost", "mcp_status")
        let systemInit = try Self.recordedFrame("control-shapes", type: "system", subtype: "init")
        let steps = [["emit": systemInit]]
            + ReplayScript.exchange("apply_flag_settings",
                                    matching: ["request.settings.effortLevel": "low"])
            + ReplayScript.exchange("get_settings", answer: settings)
            + ReplayScript.exchange("mcp_status", answer: mcp)
        await harness.tearDown()
        harness = try Harness(replaying: steps)
        let harness = self.harness!
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        // The `system/init` lands one frame past the handshake, and `apiKeySource` is the part of it the channel
        // publishes: the routing context is only complete once it is here.
        try await harness.waitFor("the engine's system/init to land") {
            await fleet.state(of: k)?.apiKeySource != nil
        }

        // One: the line, routed on the key. `/effort low` is a single control request, and the facade builds it
        // from the channel's own handshake, `system/init` and runtime record rather than from nothing.
        guard case .controlRequest(let request) = await fleet.route("/effort low", on: k) else {
            return XCTFail("/effort low did not route to a control request")
        }
        XCTAssertEqual(request.subtype, ApplyFlagSettings.subtype)
        XCTAssertEqual(request.payload, .object(["settings": .object(["effortLevel": .string("low")])]))

        // Two: that request, sent on the key. It goes through the supervisor's own `perform`, so the answer passes
        // through `RuntimeStateUpdater` and the channel's runtime record is what the restart would relaunch from.
        let answer = try await fleet.send(request, on: k)
        XCTAssertEqual(answer, .object([:]), "the engine answers a bare success with no response key")
        let channel = await fleet.channel(k)
        let runtime = await (try XCTUnwrap(channel)).runtimeState()
        XCTAssertEqual(runtime.flagSettings["effortLevel"], .string("low"))

        // Three: a strategy, routed and then run on the same key. Bare `/permissions` is the read-only view over
        // `get_settings`, whose `effective` object names the flag the send just applied.
        guard case .strategy(let strategy, let arguments) = await fleet.route("/permissions", on: k) else {
            return XCTFail("/permissions did not route to a strategy")
        }
        XCTAssertEqual(strategy, .permissionsView)
        XCTAssertEqual(arguments, [])
        let outcome = try await fleet.run(strategy, arguments: arguments, on: k,
                                          ui: ScriptedStrategyUI(answers: .cancel))
        guard case .permissions(let view) = outcome else { return XCTFail("the strategy gave \(outcome)") }
        let effective = view.settings["effective"]?.objectValue.map { Array($0.keys) } ?? []
        XCTAssertTrue(effective.contains("effortLevel"),
                      "the readback names the key the flag set; got \(effective)")

        // And one zero-cost request, sent as the routed value a `/mcp` popover's own strategy would not build:
        // `send` is the facade's door for any `AnyControlRequest`, not only the ones `/effort` builds.
        let status = try await fleet.send(AnyControlRequest(MCPStatus()), on: k)
        XCTAssertEqual(status["mcpServers"]?.arrayValue?.count, (mcp["mcpServers"] as? [Any])?.count,
                       "the engine's own answer came back through the facade")

        // And the half of `route` that reads the channel's `system/init`: a command the engine says belongs to its
        // terminal interface is refused here rather than sent for the engine to refuse (parent §7.7, contract X10).
        // `/doctor` is one of the two this recording lists and is not in the local table.
        guard case .refusedLocally(let explanation) = await fleet.route("/doctor", on: k) else {
            return XCTFail("a terminal-only command was not refused through the facade")
        }
        XCTAssertEqual(explanation, RouterTable.explanation(forTerminalOnly: "/doctor"))
    }

    /// A key the fleet owns no supervisor for is not a channel to act on, and the two acting operations refuse it
    /// with the error the facade already uses for that case. Routing is not one of them: it is a pure function of
    /// the line, and a line typed into a channel that has not opened yet still resolves against the local table.
    func testRoutedRequestsOnAChannelTheFleetDoesNotOwnAreRefused() async throws {
        let fleet = harness.fleet
        await fleet.start()
        let unknown = key(SessionID())

        if case .controlRequest(let request) = await fleet.route("/effort low", on: unknown) {
            XCTAssertEqual(request.subtype, ApplyFlagSettings.subtype, "the local table alone decided")
        } else {
            XCTFail("/effort low did not route to a control request")
        }

        do {
            _ = try await fleet.send(AnyControlRequest(MCPStatus()), on: unknown)
            XCTFail("a request was sent to a channel that does not exist")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notOwned)
        }
        do {
            _ = try await fleet.run(.permissionsView, arguments: [], on: unknown,
                                    ui: ScriptedStrategyUI(answers: .cancel))
            XCTFail("a strategy was run on a channel that does not exist")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notOwned)
        }
    }

    // MARK: - The composer's prompt

    /// `sendPrompt` answers the uuid the engine will echo for the user message, and it is the uuid the frame
    /// written to the child carries. That is what lets the composer raise `HostSignal.promptSent(uuid:at:)` the
    /// moment the send returns, which is the pre-echo preview C3's `StreamIngestion.signal(_:)` exists to receive.
    ///
    /// `perform(.send)` answers a `ChannelState` and drops the uuid the supervisor minted, and reaching below the
    /// facade for it is contract Y5's refusal, so before this member there was no way for a host to know it.
    ///
    /// The child is `fake-claude` replaying a committed fixture and the frame is read back from parent §11's raw
    /// capture, which writes what afleet wrote — no double stands between the assertion and the wire. The script's
    /// one `expect` is what makes a user frame an accounted-for host frame in this recording rather than an
    /// unexpected one; nothing is composed from engine bytes.
    ///
    /// Deliberate break: return a fresh `UUID()` from `Fleet.sendPrompt` → the capture names the other one.
    func testSendPromptAnswersTheUuidTheFrameOnTheWireCarries() async throws {
        await harness.tearDown()
        harness = try Harness(replaying: [["expect": ["type": "user"], "timeout_ms": 60_000]], capturing: true)
        let harness = self.harness!
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        let minted = try await fleet.sendPrompt(UserInput(text: "invented prompt"), on: k)

        try await harness.waitFor("the user frame to reach the capture") {
            !harness.capturedUserFrames(of: k.session).isEmpty
        }
        let frames = harness.capturedUserFrames(of: k.session)
        XCTAssertEqual(frames.count, 1, "one prompt, one user frame")
        XCTAssertEqual(frames.first?["uuid"] as? String, minted.uuidString.lowercased(),
                       "the frame written to the engine carries a uuid the caller was never given")
    }

    /// A prompt arriving behind a lifecycle operation is refused with the operation that holds the channel, exactly
    /// as `perform(.send)` is: same guard, same error, and nothing written into a child being reaped.
    ///
    /// Deliberate break: call `ProcessHandle.send` from `Fleet.sendPrompt` instead of the supervisor's → the input
    /// is written to a process the reap has already decided to end and `handle.sent` names it.
    func testSendPromptIsRefusedWhileALifecycleOperationIsInFlight() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)
        let held = HeldAnswer(), entered = HeldAnswer()
        let reachedTerminate = entered.expectation(description: "the reap reached terminate")
        handle.terminateGate = { entered.release(); await held.wait() }

        let reaping = Task { try await fleet.perform(.reap, on: k) }
        defer { held.release(); reaping.cancel() }
        try await TestTiming.awaitDelivery([reachedTerminate])

        var thrown: (any Error)?
        do { _ = try await fleet.sendPrompt(UserInput(text: "invented prompt"), on: k) } catch { thrown = error }
        XCTAssertEqual(thrown as? LifecycleError, .busy(.reap), "the prompt was admitted into a channel being reaped")

        var viaPerform: (any Error)?
        do { _ = try await fleet.perform(.send(UserInput(text: "invented prompt")), on: k) } catch { viaPerform = error }
        XCTAssertEqual(viaPerform as? LifecycleError, thrown as? LifecycleError,
                       "the two doors refuse a busy channel differently")
        XCTAssertEqual(handle.sent, [], "nothing was written to a child being reaped")

        held.release()
        _ = try await reaping.value
    }

    /// A channel held in the user's terminal refuses a prompt the way `perform(.send)` does: rule 6's
    /// `heldElsewhere`, with the banner that offers *Fork* left on the channel. Nothing here stops or adopts the
    /// user's session; the holder is a scripted registry record and the pid is this test process's own.
    ///
    /// Deliberate break: read `state.origin` in `Fleet.sendPrompt` and write anyway → the refusal never happens.
    func testSendPromptOnAForeignChannelIsRefusedTheWayPerformSendIs() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let session = try fixtureSession()
        let k = key(session)
        try harness.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session)
        await fleet.start()
        await fleet.register(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the foreign holder to be seen") {
            await fleet.state(of: k)?.origin == .foreignLive(.usersTerminal)
        }

        var thrown: (any Error)?
        do { _ = try await fleet.sendPrompt(UserInput(text: "invented prompt"), on: k) } catch { thrown = error }
        guard case .heldElsewhere(let holders)? = thrown as? LifecycleError else {
            return XCTFail("a prompt on a channel held in the user's terminal gave \(String(describing: thrown))")
        }
        XCTAssertFalse(holders.holders.isEmpty, "the refusal names the holder the banner is drawn from")

        var viaPerform: (any Error)?
        do { _ = try await fleet.perform(.send(UserInput(text: "invented prompt")), on: k) } catch { viaPerform = error }
        XCTAssertEqual(viaPerform as? LifecycleError, thrown as? LifecycleError,
                       "the two doors refuse a foreign channel differently")

        let refused = await fleet.state(of: k)
        XCTAssertEqual(refused?.origin, .foreignLive(.usersTerminal), "the channel stayed where it was")
        XCTAssertEqual(refused?.banner, .heldElsewhere(holders), "the refusal is where the user can see why")
    }

    /// One out-frame a fixture recorded, by type and subtype, for a script to re-emit. The bytes are the reviewed
    /// recording's own; nothing here is composed (root `CLAUDE.md`, spec §11).
    private static func recordedFrame(_ fixture: String, type: String, subtype: String) throws -> [String: Any] {
        struct NotRecorded: Error, CustomStringConvertible {
            let fixture: String, type: String, subtype: String
            var description: String { "fixture \(fixture) records no \(type)/\(subtype) frame" }
        }
        let lines = try String(contentsOf: FakeClaudeLaunch.fixture(fixture).appending(path: "frames.ndjson"),
                               encoding: .utf8)
        for line in lines.split(separator: "\n") where !line.isEmpty {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["dropped"] == nil, record["dir"] as? String == "out",
                  let frame = record["frame"] as? [String: Any],
                  frame["type"] as? String == type, frame["subtype"] as? String == subtype else { continue }
            return frame
        }
        throw NotRecorded(fixture: fixture, type: type, subtype: subtype)
    }

    // MARK: - Rotation

    /// The log rotates once, into `fleet.log.1`, and keeps writing to `fleet.log`.
    func testTheDiagnosticsLogRotatesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-rotate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = FileFleetDiagnostics(directory: directory, rotateAt: 200)
        for index in 0..<40 { sink.record(.logout(step: "census", count: index)) }
        sink.flush()

        let current = directory.appending(path: "fleet.log")
        let rotated = directory.appending(path: "fleet.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)),
                      "the log never rotated")
        let lines = try String(contentsOf: current, encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 0, "the new log is being written to")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: current.path(percentEncoded: false))[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 200 + 64, "the current log is bounded by the rotation threshold")
    }

    /// *Delete diagnostics* unlinks `fleet.log` while the sink lives on, and `Fleet` builds its sink internally so
    /// the app cannot reach it to reopen. Opening per write means the next record recreates the file rather than
    /// writing into an unlinked inode nobody can read.
    func testTheDiagnosticsLogIsRecreatedAfterItIsDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-unlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = FileFleetDiagnostics(directory: directory)
        sink.record(.logout(step: "census", count: 1))
        sink.flush()

        let log = directory.appending(path: "fleet.log")
        try FileManager.default.removeItem(at: log)

        sink.record(.logout(step: "revoke", count: 2))
        sink.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path(percentEncoded: false)),
                      "the deleted log was never recreated")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "the recreated log holds exactly the record made after the deletion")
        let only = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
        XCTAssertEqual(only["event"], .string("logout"))
        XCTAssertEqual(only["step"], .string("revoke"))
        XCTAssertEqual(only["count"], .integer(2))
        let mode = try FileManager.default.attributesOfItem(
            atPath: log.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: - The §6.12 decline, project-wide

    /// §6.12's precondition is about the *project*, not about the channel the sheet happens to be open in. Two
    /// channels in one project — ordinary for this app — must not let the idle one write while the other's child is
    /// live: the live child has already loaded the server, and an `mcp_toggle` after the fact arrives too late.
    func testDeclineRefusesWhileAnyChannelInTheProjectHasALiveProcess() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let project = try TemporaryProject()
        defer { project.remove() }
        try harness.home.trust(root: project.root)

        await fleet.start()
        let live = key(try fixtureSession())
        // An id that sorts first, so the channel the facade picks to perform the write is deterministically the
        // one with no process of its own: a per-channel precondition would answer "nothing is live" from it.
        let idle = key(try XCTUnwrap(SessionID("00000000-0000-4000-8000-000000000001")))
        await fleet.register(idle, cwd: project.root, recent: false)
        XCTAssertLessThan(idle.session.description, live.session.description)
        _ = try await fleet.open(live, cwd: project.root, recent: true)
        try await harness.waitFor("the live channel") { await fleet.state(of: live)?.origin == .owned(.ready) }
        // The server is declared after the channel came up, exactly as a project gains one while afleet is
        // running: the live child has already loaded whatever it was going to load, which is why the write waits.
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])

        do {
            try await fleet.declineProjectServers(["d"], project: project.root)
            XCTFail("the decline was written while a channel in the project was live")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .declineRefused(reason: "processLive"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.localSettingsFile.path(percentEncoded: false)),
                       "a live process in the project means nothing is written at all")

        // With every channel in the project reaped, the same call goes through.
        _ = try await fleet.perform(.reap, on: live)
        try await fleet.declineProjectServers(["d"], project: project.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.localSettingsFile.path(percentEncoded: false)))
    }

    // MARK: - §7.4 *Quit*

    /// The quit verb is not the reap. `perform(.reap)` is gated on dormant eligibility on purpose — the reap the
    /// user asks for from the header must not kill a background shell that is still working — and that gate refuses
    /// exactly the channels the quit dialog has just warned about. `perform(.quit)` is the same terminate without
    /// the gate: §7.4's warning is what licenses it, so a confirmed quit ends the child the reap refused to touch.
    ///
    /// Deliberate break: route `.quit` through `perform(.reap)`'s eligibility gate -> the quit half throws the
    /// refusal the reap half asserts.
    func testAQuitEndsAChannelTheReapRefusesToTouch() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)

        let taskID = "task-invented-quit-shell-1"
        let frame = try await expectEventDelivery(in: fleet, on: k,
                                                  description: "the running task frame was delivered") {
            if case .frame = $0 { true } else { false }
        }
        defer { frame.observer.cancel() }
        handle.push(.frame(try Self.taskStarted(taskID: taskID, session: k.session), handle.epoch))
        try await TestTiming.awaitDelivery([frame.expectation])
        await fleet.channel(k)?.drainEligibility()

        do {
            _ = try await fleet.perform(.reap, on: k)
            XCTFail("the reap ended a child with a background task running")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .notEligible(.taskRunning(taskID)),
                           "the reap's gate refuses the channel the quit is about")
        }
        XCTAssertEqual(handle.terminateCount, 0, "the refusal did not touch the child")

        let quit = try await fleet.perform(.quit, on: k)
        XCTAssertEqual(handle.terminateCount, 1, "the confirmed quit ended the child the reap refused")
        XCTAssertEqual(quit.origin, .owned(.dormant), "a channel whose process really exited rests dormant")
        XCTAssertNil(quit.wedged, "the child exited, so nothing is left behind")
    }

    /// §7.4's "busy" is the fleet's fact: the ids come from the channel's own mirror, running and armed alike, and a
    /// key the fleet owns no supervisor for has none rather than an error.
    ///
    /// Deliberate break: answer from the caller's own count -> the unknown key stops being empty, or the armed task
    /// stops being listed.
    func testLiveTaskIDsAreTheChannelsRunningAndArmedTasksAndEmptyForAnUnknownKey() async throws {
        let harness = try scriptedHarness()
        let fleet = harness.fleet
        let k = ChannelKey(configHome: harness.home.url, session: SessionID())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        let handle = try XCTUnwrap(harness.handles.all.first)

        let running = "task-invented-live-running-1"
        let armed = "task-invented-live-armed-1"
        for (id, frame) in [(running, try Self.taskStarted(taskID: running, session: k.session)),
                            (armed, try Self.backgroundTasksChanged(taskIDs: [armed], session: k.session))] {
            let delivery = try await expectEventDelivery(in: fleet, on: k,
                                                         description: "a task frame was delivered") {
                if case .frame = $0 { true } else { false }
            }
            defer { delivery.observer.cancel() }
            _ = id
            handle.push(.frame(frame, handle.epoch))
            try await TestTiming.awaitDelivery([delivery.expectation])
        }
        await fleet.channel(k)?.drainEligibility()

        let live = await fleet.liveTaskIDs(of: k)
        XCTAssertEqual(Set(live), [running, armed], "the mirror's running and armed rows, both of them")
        let unknown = await fleet.liveTaskIDs(of: ChannelKey(configHome: harness.home.url, session: SessionID()))
        XCTAssertEqual(unknown.count, 0, "a key the fleet owns no supervisor for has no live tasks")
    }

    // MARK: - `/logout` is fleet-level

    /// The `/logout` barrier is not a channel banner: the plan is fleet-wide, the refusal it raises is
    /// `LifecycleError.logoutInProgress`, and the facade hands it to the caller for the shell to render.
    func testLogoutRaisesTheFleetWideBarrierAndAbandoningLowersIt() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        _ = try await fleet.perform(.logout, on: k)
        let built = await fleet.logoutCensus()
        let census = try XCTUnwrap(built)
        XCTAssertEqual(census.owned, [k])

        let blocked = key(SessionID())
        do {
            _ = try await fleet.open(blocked, cwd: harness.cwd, recent: true)
            XCTFail("a channel came up into a fleet that is signing out")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .logoutInProgress)
        }
        let stillArchived = await fleet.state(of: blocked)?.origin
        XCTAssertEqual(stillArchived, .archived, "the refusal left no half-opened channel behind")

        // Every action that can put work where the census cannot see it stands behind the same barrier as an open:
        // a handoff launches a `--bg` job the plan's `ownJobShorts` were read before, and `background_tasks` moves
        // the current turn's tools into background shells the same list has already been taken without. The
        // terminal hatch has been gated at this door from the start; these two were the gap.
        for hidden in [LifecycleAction.sendToBackground, .backgroundAll] {
            do {
                _ = try await fleet.perform(hidden, on: blocked)
                XCTFail("\(hidden) started work the census could not see")
            } catch {
                XCTAssertEqual(error as? LifecycleError, .logoutInProgress, "\(hidden) was admitted")
            }
        }

        await fleet.abandonLogout()
        let gone = await fleet.logoutCensus()
        XCTAssertNil(gone)
        _ = try await fleet.open(blocked, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the once-blocked channel") {
            await fleet.state(of: blocked)?.origin == .owned(.ready)
        }
    }

    // MARK: - Diagnostics

    /// One JSON line per event, structural fields only. The assertion is on the *key names*: a path under a config
    /// home, an environment, a record or stdout must not be able to reach this file, and a key with one of those
    /// names is how it would.
    func testTheDiagnosticsFileIsOneJSONLinePerEventAndCarriesNoForbiddenKey() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }
        _ = try await harness.steppingClock { try await fleet.openInTerminal(k) }

        let lines = try await harness.diagnosticLines()
        XCTAssertGreaterThan(lines.count, 0, "the fleet wrote no diagnostics at all")
        for line in lines { XCTAssertNotNil(line["event"] as? String, "every line names its event") }

        let forbidden: Set<String> = ["path", "environment", "stdout", "record"]
        let names = Set(lines.flatMap(\.keys))
        XCTAssertTrue(names.contains("event"))
        XCTAssertTrue(names.isDisjoint(with: forbidden),
                      "forbidden keys: \(names.intersection(forbidden).sorted())")
        let events = Set(lines.compactMap { $0["event"] as? String })
        XCTAssertTrue(events.contains("ownership_check"), "the ownership checks around the spawn")
        XCTAssertTrue(events.contains("pane_request"), "the hatch")
        XCTAssertTrue(events.contains("cap_decision"), "the cap counter's decision")
    }

    // MARK: - Collecting

    /// The scripted handles a harness built, in spawn order.
    final class ScriptedHandles: @unchecked Sendable {   // `lock` serialises `storage` and `lines`
        private let lock = NSLock()
        private var storage: [ScriptedProcessHandle] = []
        private var lines: [LaunchConfiguration] = []
        func append(_ handle: ScriptedProcessHandle, _ launch: LaunchConfiguration) {
            lock.lock(); storage.append(handle); lines.append(launch); lock.unlock()
        }
        var all: [ScriptedProcessHandle] { lock.lock(); defer { lock.unlock() }; return storage }
        /// The line each spawn was composed from, in spawn order: what the facade asked the factory for, which is
        /// where a channel's working directory and its `--model` are visible from outside the supervisor.
        var launches: [LaunchConfiguration] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private final class Collected: @unchecked Sendable {   // `lock` serialises `storage`
        private let lock = NSLock()
        private var storage: [ChannelState] = []
        @discardableResult
        func append(_ state: ChannelState) -> Int {
            lock.lock(); defer { lock.unlock() }
            storage.append(state)
            return storage.count
        }
        var states: [ChannelState] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class Frames: @unchecked Sendable {   // `lock` serialises `storage`
        private let lock = NSLock()
        private var storage: [String] = []
        @discardableResult
        func append(_ event: WireEvent) -> Int {
            let name: String
            switch event {
            case .frame(let frame, _): name = "frame:" + frame.typeName
            case .handshakeCompleted: name = "handshake"
            case .sessionIdentityResolved: name = "identity"
            case .request(let request): name = "request:" + request.subtype
            default: name = "other"
            }
            lock.lock(); defer { lock.unlock() }
            storage.append(name)
            return storage.count
        }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
