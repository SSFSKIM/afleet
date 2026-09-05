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
}
