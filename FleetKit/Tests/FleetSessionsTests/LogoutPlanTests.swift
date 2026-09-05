import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// G4's `/logout` half: the census, the spawn barrier, the *Wait* and *Stop* choices, and the order the plan runs
/// its steps in — `claude auth logout` last, and only once every listed process and job has gone.
///
/// Both channels are real `fake-claude` replays of `resume-no-replay`, the fixture that stays alive after the
/// handshake. The `interrupt` and `stop_task` answers are scripted bare successes: the corpus records neither
/// subtype's answer, both are answered by the engine with a bare success like every other setter, and the payloads
/// are FleetKit's own, so no engine byte is invented. The CLI verbs run through the rig's scripted `ProcessRunner`,
/// which mutates the scripted holder files the way the CLI would.
final class LogoutPlanTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    private func newRig() throws -> Rig {
        let rig = try Rig(sharing: nil)
        rigs.append(rig)
        return rig
    }

    private static let idle = "resume-no-replay"
    private func scriptDirectory(_ rig: Rig) -> URL { rig.scratch.appending(path: "scripts") }

    private func context(_ rig: Rig, channels: [ChannelSupervisor],
                         ownJobShorts: [JobShort] = []) -> LogoutContext {
        LogoutContext(channels: channels, observer: rig.observer, verbs: rig.verbs, barrier: rig.spawnBarrier,
                      ownJobShorts: ownJobShorts, diagnostics: rig.diagnostics, clock: rig.clock)
    }

    /// Two idle owned channels: both are listed, both are terminated, and `claude auth logout` runs only after they
    /// have gone. The barrier the plan raised refuses a spawn while it is up and is lowered when the plan is done.
    func testTwoIdleOwnedChannelsAreListedAndTerminatedBeforeLogout() async throws {
        let rig = try newRig()
        let a = rig.supervisor(session: SessionID(), fixture: Self.idle)
        let b = rig.supervisor(session: SessionID(), fixture: Self.idle)
        try await a.open()
        try await b.open()
        let fleet = context(rig, channels: [a, b])

        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(Set(census.owned), [a.key, b.key])
        XCTAssertTrue(census.nonEligible.isEmpty, "two idle channels block nothing")
        XCTAssertTrue(census.ownJobs.isEmpty)
        XCTAssertTrue(census.foreign.isEmpty)

        // The barrier is up from the moment the plan exists, which is what stops a channel being opened into a
        // fleet that is signing out from under it.
        let latecomer = rig.supervisor(session: SessionID(), fixture: Self.idle)
        var refused: (any Error)?
        do { try await latecomer.spawn(reason: .open) } catch { refused = error }
        XCTAssertEqual(refused as? LifecycleError, .logoutInProgress)
        XCTAssertEqual(rig.spawnCount, 2, "nothing launched behind the barrier")

        // And `open()` asks before it transitions, so the refusal leaves the channel exactly where it was rather
        // than parked in connecting with no process — the rule that no partial state sits behind a transition
        // that may be refused.
        let secondLatecomer = rig.supervisor(session: SessionID(), fixture: Self.idle)
        var openRefused: (any Error)?
        do { try await secondLatecomer.open() } catch { openRefused = error }
        XCTAssertEqual(openRefused as? LifecycleError, .logoutInProgress)
        let untouched = await secondLatecomer.state
        XCTAssertEqual(untouched.origin, .archived, "the refused open left no half-opened channel")
        XCTAssertEqual(untouched.desired, .none)
        XCTAssertEqual(rig.spawnCount, 2, "still nothing launched behind the barrier")

        rig.diagnostics.mark("act")
        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        XCTAssertEqual(outcome, .success(exited: census.owned, foreignLeftRunning: []))

        let timeline = rig.diagnostics.timeline.drop { $0 != "act" }
        let terminated = timeline.indices.filter { timeline[$0] == "transition:readyDormantEligible:dormant" }
        XCTAssertEqual(terminated.count, 2, "both channels were terminated; got \(Array(timeline))")
        let logout = try XCTUnwrap(timeline.firstIndex(of: "verb:auth logout"), "auth logout never ran")
        XCTAssertTrue(terminated.allSatisfy { $0 < logout }, "auth logout ran before a channel had gone")

        let stateA = await a.state, stateB = await b.state
        XCTAssertEqual(stateA.origin, .owned(.dormant))
        XCTAssertEqual(stateB.origin, .owned(.dormant))
        XCTAssertNil(stateA.wedged)
        XCTAssertNil(stateB.wedged)

        XCTAssertFalse(rig.spawnBarrier.isRaised, "the barrier is lowered when the plan is done")
        try await latecomer.spawn(reason: .open)
        XCTAssertEqual(rig.spawnCount, 3)
    }

    /// A channel that was **already** wedged before the plan started is not a channel that has gone: the ghost is
    /// still out there holding the transcript. The plan is blocked before it acts — nothing else is terminated and
    /// `claude auth logout` does not run — because signing out behind a live process is the one thing this plan
    /// exists to prevent.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so the wedge is produced on the scripted handle.
    func testAChannelAlreadyWedgedBeforeThePlanBlocksItBeforeItActs() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: ["SIGKILL", "exit_not_observed"]))
        let ghost = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await ghost.spawn(reason: .open)
        let healthy = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await healthy.spawn(reason: .open)
        rig.scriptedHandles[1].terminateReturns = TerminationReport(exit: .code(0, stderrTail: ""), steps: [])

        // The wedge happens before the plan exists, which is the case the plan's own terminate never sees.
        await ghost.reap()
        let wedged = await ghost.state
        XCTAssertNotNil(wedged.wedged, "the arrangement did not wedge the channel")

        let fleet = context(rig, channels: [ghost, healthy])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(Set(census.owned), [ghost.key, healthy.key], "a wedged channel is still owned")

        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        XCTAssertEqual(outcome, .blocked(wedged: [ghost.key], jobsStillListed: []))
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0,
                       "a live ghost must not lose its credentials")
        XCTAssertEqual(rig.scriptedHandles[1].terminateCount, 0,
                       "a plan that cannot finish tears nothing else down")
        let healthyState = await healthy.state
        XCTAssertEqual(healthyState.origin, .owned(.ready))
        XCTAssertFalse(rig.spawnBarrier.isRaised, "a blocked plan lifts its barrier")
    }

    /// The same ghost, wedged *after* the census was taken. The plan's list says the channel can be ended, so the
    /// only thing standing between a live ghost and `claude auth logout` here is the terminate's own answer — a
    /// channel that is already wedged must answer `.wedged` and never `.exited`.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so the wedge is produced on the scripted handle.
    func testAChannelWedgedAfterTheCensusStillBlocksTheLogout() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: ["SIGKILL", "exit_not_observed"]))
        let ghost = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await ghost.spawn(reason: .open)

        let fleet = context(rig, channels: [ghost])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.wedged, [], "the census saw a channel it could still have ended")

        // Between the census and the plan running, the channel wedges on somebody else's terminate.
        await ghost.reap()
        let wedged = await ghost.state
        XCTAssertNotNil(wedged.wedged)

        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        XCTAssertEqual(outcome, .blocked(wedged: [ghost.key], jobsStillListed: []))
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0,
                       "a live ghost must not lose its credentials")
        XCTAssertFalse(rig.spawnBarrier.isRaised)
    }

    /// A job whose worker never leaves the roster is a live process, exactly like a ghost, and gets the same answer:
    /// the plan stops, names the job, terminates no channel and does not sign out.
    func testAJobWhoseWorkerNeverLeavesTheRosterBlocksTheLogout() async throws {
        let rig = try newRig()
        let short = JobShort(rawValue: "jstuck1")
        let channel = rig.supervisor(session: SessionID(), fixture: Self.idle)
        try await channel.open()
        try rig.files.writeJob(short: short.rawValue, state: "working", sessionID: SessionID(),
                               pid: ScriptedHolderFiles.livePID)
        rig.files.stopRemovesWorker = false          // the daemon never drops it

        let fleet = context(rig, channels: [channel], ownJobShorts: [short])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.ownJobs, [short])

        let outcome = try await rig.steppingClock(upTo: .seconds(20)) {
            await LogoutPlan.execute(census, choice: .stop, fleet: fleet)
        }
        XCTAssertEqual(outcome, .blocked(wedged: [], jobsStillListed: [short]))
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0,
                       "a running worker must not be signed out from under")
        let state = await channel.state
        XCTAssertEqual(state.origin, .owned(.ready), "a plan that cannot finish terminates nothing")
        XCTAssertFalse(rig.spawnBarrier.isRaised)
    }

    /// Every channel went and the CLI then refused to sign out. The terminations stand and are reported; the
    /// sign-out is reported as what it was.
    func testASignOutTheCLIRefusesIsNotReportedAsSuccess() async throws {
        let rig = try newRig()
        let channel = rig.supervisor(session: SessionID(), fixture: Self.idle)
        try await channel.open()
        rig.files.authLogoutExitCode = 1

        let fleet = context(rig, channels: [channel])
        let census = await LogoutPlan.build(fleet: fleet)
        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }

        guard case .signOutFailed(let exited, let reason) = outcome else {
            return XCTFail("a refused sign-out gave \(outcome)")
        }
        XCTAssertEqual(exited, [channel.key], "the channel did go, and the report says so")
        XCTAssertTrue(reason.contains("auth logout"), "the report names the verb that failed; got \(reason)")
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 1, "it was attempted")
        let state = await channel.state
        XCTAssertEqual(state.origin, .owned(.dormant))
        XCTAssertFalse(rig.spawnBarrier.isRaised)
    }

    /// *Stop* stops the tasks the channel has **when Stop runs**, not the list the census wrote down
    /// (`scalpel-2#2`). The census and the sheet are separated by however long the user looks at it, and the engine
    /// keeps working in between: a background shell announced in that window would be left running under a CLI that
    /// had just signed out, which is the one thing this plan exists to prevent. `liveTaskIDs()` is read again at the
    /// moment the stop is sent; the census list stays what it always was, the payload of *Wait*.
    ///
    /// Scripted handles rather than a replay: what the test reads is the requests the plan actually sent, in order.
    ///
    /// Deliberate break: `for task in entry.tasks` in `LogoutPlan.execute`.
    func testStopStopsTheTasksTheChannelHasWhenItRunsAndNotTheCensusList() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let running = "task-invented-logout-shell-1", armedLater = "task-invented-logout-shell-2"
        let eligibility = EligibilityBox()
        eligibility.mirror = [MirrorEntryStandIn(taskID: running, isRunning: true, isBackground: true)]
        let channel = rig.supervisor(session: SessionID(), fixture: Self.idle, eligibility: eligibility)
        try await channel.open()
        let handle = try XCTUnwrap(rig.scriptedHandles.first)
        let fleet = context(rig, channels: [channel])

        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.nonEligible.map(\.key), [channel.key])
        XCTAssertEqual(census.nonEligible.first?.tasks, [running], "the census names the task it saw")

        // The user reads the sheet; the engine arms a second background task in the meantime.
        eligibility.mirror = [MirrorEntryStandIn(taskID: running, isRunning: true, isBackground: true),
                              MirrorEntryStandIn(taskID: armedLater, isRunning: false, isArmed: true,
                                                 isBackground: true)]
        await channel.mirrorChanged()

        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        XCTAssertEqual(outcome, .success(exited: [channel.key], foreignLeftRunning: []))
        XCTAssertEqual(handle.controlRequests.map(\.subtype), ["interrupt", "stop_task", "stop_task"],
                       "the turn first, then one stop per task the channel has now")
        XCTAssertEqual(handle.controlRequests.filter { $0.subtype == "stop_task" }
                           .compactMap { $0.payload["task_id"]?.stringValue },
                       [running, armedLater],
                       "the task armed between the census and the stop was stopped too")
    }

    /// One channel with a running mirror task and one afleet-launched job: the plan lists both, *Wait* holds without
    /// acting, and *Stop* interrupts the turn, stops the task, stops the job and waits for the roster to drop its
    /// worker before `claude auth logout` runs. A foreign registry record keeps its token and is named.
    func testALiveTaskAndAnOwnJobAreListedWaitHoldsStopSendsStopTaskFirst() async throws {
        let rig = try newRig()
        let taskID = "task-router-probe-1"
        let short = JobShort(rawValue: "jlogout1")
        let jobSession = SessionID()
        let foreignSession = SessionID()

        let eligibility = EligibilityBox()
        eligibility.mirror = [MirrorEntryStandIn(taskID: taskID, isRunning: true, isBackground: true)]
        let script = try ReplayScript.write(
            ReplayScript.exchange("interrupt", matching: ["request.cancel_queued": true])
                + ReplayScript.exchange("stop_task", matching: ["request.task_id": taskID]),
            fixture: Self.idle, into: scriptDirectory(rig))
        let channel = rig.supervisor(session: SessionID(), fixture: Self.idle, eligibility: eligibility,
                                     script: script)
        try await channel.open()

        try rig.files.writeJob(short: short.rawValue, state: "working", sessionID: jobSession,
                               resumeSessionID: jobSession, pid: ScriptedHolderFiles.livePID)
        let foreignPID = try rig.startHelper()
        try rig.files.writeRegistry(pid: foreignPID, sessionID: foreignSession, kind: "interactive",
                                    entrypoint: "cli")

        let fleet = context(rig, channels: [channel], ownJobShorts: [short])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.owned, [channel.key])
        XCTAssertEqual(census.nonEligible.map(\.key), [channel.key])
        XCTAssertEqual(census.nonEligible.first?.tasks, [taskID])
        XCTAssertEqual(census.ownJobs, [short])
        XCTAssertEqual(census.foreign.map(\.sessionID), [foreignSession])

        // Wait holds: the plan names what it is waiting on and touches nothing.
        let waiting = await LogoutPlan.execute(census, choice: .wait, fleet: fleet)
        XCTAssertEqual(waiting, .waiting(on: [taskID]))
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["stop"]), 0, "Wait stopped nothing")
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0)

        // The daemon's side of `claude stop`: the worker leaves the roster only once the plan is already waiting on
        // it, so "the job is gone before logout runs" is an order the recorder can see rather than an artefact of
        // the verb having done it synchronously.
        rig.files.stopRemovesWorker = false
        // Bounded, so a plan that never waits for the roster fails this test on an assertion rather than leaving
        // it parked here: a hang says nothing about which claim broke.
        let removal = Task { [files = rig.files, diagnostics = rig.diagnostics] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !diagnostics.timeline.contains("logout:jobRosterWait") {
                if Task.isCancelled || ContinuousClock.now > deadline { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
            try? files.removeRosterWorker(short: short.rawValue)
            diagnostics.mark("roster:removed")
        }
        defer { removal.cancel() }

        rig.diagnostics.mark("act")
        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        _ = await removal.value
        XCTAssertEqual(outcome, .success(exited: [channel.key], foreignLeftRunning: [foreignSession]))

        let timeline = Array(rig.diagnostics.timeline.drop { $0 != "act" })
        func at(_ tag: String) throws -> Int {
            try XCTUnwrap(timeline.firstIndex(of: tag), "\(tag) never happened; got \(timeline)")
        }
        XCTAssertLessThan(try at("verb:stop"), try at("logout:jobRosterWait"))
        XCTAssertLessThan(try at("logout:jobRosterWait"), try at("roster:removed"))
        XCTAssertLessThan(try at("roster:removed"), try at("logout:jobsStopped"))
        XCTAssertLessThan(try at("logout:jobsStopped"), try at("verb:auth logout"))
        XCTAssertLessThan(try at("transition:readyDormantEligible:dormant"), try at("verb:auth logout"))
        XCTAssertNil(rig.files.rosterWorkers()[short.rawValue], "the worker is gone from the roster")
        XCTAssertEqual(rig.runnerCalls.invocations.filter { $0 == ["stop", short.rawValue] }.count, 1)
        XCTAssertFalse(rig.spawnBarrier.isRaised)
    }

    /// *Wait* holds for **every** non-eligible channel, not only for the ones whose blocker is a task. A turn in
    /// flight is the commonest blocker of all and it names no task id, so a plan that decides on the task list
    /// alone reads an empty list, falls through *Wait* entirely, terminates the channel mid-turn and signs out —
    /// the opposite of what the user asked for (parent §7.7, acceptance item 59).
    ///
    /// Scripted, not recorded: the turn is held open inside the handle's `send`, which no recording can do.
    ///
    /// Deliberate break: gate the wait on `!blocking.isEmpty` again → the plan terminates the channel and
    /// `auth logout` runs behind a live turn.
    func testWaitHoldsForAChannelBlockedByARunningTurnAndNoTask() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let handle = rig.scriptedHandles[0]
        let held = HeldAnswer()
        handle.sendGate = { await held.wait() }

        let sending = Task { try await supervisor.send(UserInput(text: "hi")) }
        try await rig.waitFor("the send to reach the write") { handle.sent.count == 1 }

        let fleet = context(rig, channels: [supervisor])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.nonEligible.map(\.key), [supervisor.key], "a turn in flight is a blocker")
        XCTAssertEqual(census.nonEligible.first?.tasks, [], "and it names no task; the mirror is empty")

        let outcome = await LogoutPlan.execute(census, choice: .wait, fleet: fleet)
        XCTAssertEqual(outcome, .waiting(on: []), "Wait holds on a blocker that is not a task")
        XCTAssertEqual(handle.terminateCount, 0, "Wait terminated a channel with a turn in flight")
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0,
                       "the token was taken out from under a running turn")
        XCTAssertTrue(rig.spawnBarrier.isRaised, "a waiting plan keeps its barrier up")
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.ready), "the channel is where it was")

        held.release()
        _ = try await sending.value
        LogoutPlan.abandon(fleet: fleet)
    }

    /// A channel afleet has registered but never opened owns no process, so it is not in `owned` — and a terminal
    /// holding *its* session is a foreign session like any other. Building the our-sessions set from every
    /// registered supervisor hides exactly those: the user is told everything signed out while a live `claude` in
    /// Terminal.app keeps its token.
    ///
    /// Deliberate break: build `ourSessions` from `fleet.channels` again → `foreignLeftRunning` comes back empty.
    func testAForeignHolderOnARegisteredButNeverOpenedChannelIsReported() async throws {
        let rig = try newRig()
        let neverOpened = SessionID()
        let registered = rig.supervisor(session: neverOpened, fixture: Self.idle)
        let opened = rig.supervisor(session: SessionID(), fixture: Self.idle)
        try await opened.open()

        // Somebody else's `claude`, on the session afleet has a supervisor for and no process of.
        let foreignPID = try rig.startHelper()
        try rig.files.writeRegistry(pid: foreignPID, sessionID: neverOpened, kind: "interactive", entrypoint: "cli")

        let fleet = context(rig, channels: [registered, opened])
        let census = await LogoutPlan.build(fleet: fleet)
        XCTAssertEqual(census.owned, [opened.key], "the never-opened channel owns no process")
        XCTAssertEqual(census.foreign.map(\.sessionID), [neverOpened],
                       "a terminal on a registered session is still somebody else's session")

        let outcome = try await rig.steppingClock { await LogoutPlan.execute(census, choice: .stop, fleet: fleet) }
        XCTAssertEqual(outcome, .success(exited: [opened.key], foreignLeftRunning: [neverOpened]),
                       "the report names the session that kept its token")
    }
}
