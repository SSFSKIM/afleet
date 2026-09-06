import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Ruling 1's rows and non-rows: an owned channel with no process of its own rests in **dormant**, and a spawn that
/// does not complete leaves the channel in the resting state it left.
///
/// The scenarios these drive are declared in `LifecycleRowTests.coverage` under each test's own name, so Task 12's
/// gate sees the two rows this ruling added — `readyExitedClean` and the crash exhaustion that rests dormant from
/// connecting — driven rather than merely written down.
extension LifecycleRowTests {

    /// A child that ended on its own with a clean status is not a crash: no item, no *Reopen*, the slot goes back,
    /// and the channel is dormant — which is the one state a send can resume from under the same session id.
    ///
    /// Deliberate break: drop the `.exitedClean` transition from `handleExit`'s clean branch → the channel is
    /// published as `.owned(.ready)` with no process, and the send that follows throws `notOwned`.
    func testACleanExitFromReadyRestsDormantAndASendResumesIt() async throws {
        let rig = try Rig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let handle = rig.scriptedHandles[0]
        let liveBefore = await rig.fleet.liveCount
        XCTAssertEqual(liveBefore, 1)
        let published = await supervisor.publishedCount
        rig.forgetTransitions()

        // The child exits zero on its own: nothing of ours terminated it, so this is not a reap's own exit.
        handle.push(.exited(.code(0, stderrTail: ""), handle.epoch))
        try await rig.waitForPublish(supervisor, above: published)

        let rested = await supervisor.state
        XCTAssertEqual(rested.origin, .owned(.dormant),
                       "a processless owned channel rests dormant; ready would name a process that has gone")
        XCTAssertNil(rested.systemItem, "a clean exit is not a crash, so nothing offers Reopen")
        let live = await rig.fleet.liveCount
        XCTAssertEqual(live, 0, "the slot went back")

        // And the resting state is the one a send resumes from.
        _ = try await supervisor.send(UserInput(text: "again"))
        let resumed = await supervisor.state
        XCTAssertEqual(resumed.origin, .owned(.ready))
        XCTAssertEqual(rig.spawnCount, 2, "the send built a replacement child")

        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
        await rig.shutdown(); await rig.tearDown()
    }

    /// A spawn that never happens leaves the channel where it was. Both halves raise the fleet's spawn barrier,
    /// which is the cheapest of the four refusals — the precondition verdict, the cap, the barrier and our own
    /// terminate all leave through the same restore.
    ///
    /// Deliberate break: remove the restore from `spawn`'s refusal paths → both channels are left `.owned(.connecting)`
    /// with no process, and the retry that follows queues its input against a handshake that will never land.
    func testARefusedSpawnReturnsADormantOrArchivedChannelToWhereItWas() async throws {
        let dormantRig = try Rig()
        dormantRig.useScriptedHandle()
        let dormant = dormantRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await dormant.spawn(reason: .open)
        await dormant.reap()

        let archivedRig = try Rig(sharing: dormantRig.diagnostics)
        archivedRig.useScriptedHandle()
        let archived = archivedRig.supervisor(session: SessionID(), isRecent: false, origin: .archived)

        dormantRig.forgetTransitions()
        dormantRig.spawnBarrier.raise()
        archivedRig.spawnBarrier.raise()

        var fromDormant: (any Error)?
        do { _ = try await dormant.send(UserInput(text: "one")) } catch { fromDormant = error }
        var fromArchived: (any Error)?
        do { _ = try await archived.send(UserInput(text: "one")) } catch { fromArchived = error }

        XCTAssertEqual(fromDormant as? LifecycleError, .logoutInProgress)
        XCTAssertEqual(fromArchived as? LifecycleError, .logoutInProgress)
        let dormantState = await dormant.state
        XCTAssertEqual(dormantState.origin, .owned(.dormant), "the dormant channel is dormant again")
        let archivedState = await archived.state
        XCTAssertEqual(archivedState.origin, .archived, "the archived channel is archived again")
        XCTAssertEqual(dormantRig.spawnCount, 1, "no child was built for the refused spawn")
        XCTAssertEqual(archivedRig.spawnCount, 0)

        // And each is a state its own send row leaves again: the archived half takes `archivedOlderSent`, which
        // exists only from archived-*older*, so the recency the channel had is back too.
        dormantRig.spawnBarrier.lower()
        archivedRig.spawnBarrier.lower()
        _ = try await dormant.send(UserInput(text: "two"))
        _ = try await archived.send(UserInput(text: "two"))
        let dormantAgain = await dormant.state
        XCTAssertEqual(dormantAgain.origin, .owned(.ready))
        let archivedAgain = await archived.state
        XCTAssertEqual(archivedAgain.origin, .owned(.ready))

        dormantRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
        await dormantRig.shutdown(); await dormantRig.tearDown()
        await archivedRig.shutdown(); await archivedRig.tearDown()
    }

    /// `/logout` terminating a channel mid-handshake is the same non-row seen from the other side: the in-flight
    /// spawn's failure path puts the channel back where it started. The second half is a channel whose only claim
    /// to a process is a respawn parked on its backoff — that task is cancelled and the channel rests the same way.
    ///
    /// Deliberate break: drop the respawn-cancelling branch from `endProcess` → the second half is left connecting
    /// and the backoff still fires, launching a child into a fleet that has just signed out.
    func testLogoutTerminatingAConnectingChannelLeavesItResting() async throws {
        // Half one: a spawn parked inside the handshake, terminated by the plan.
        let parkedRig = try Rig()
        parkedRig.useScriptedHandle()
        let held = HeldAnswer()
        parkedRig.holdNextSpawn { await held.wait() }
        let parked = parkedRig.supervisor(session: SessionID(), isRecent: true, origin: .archived)
        let parkedChild = parkedRig.expectScriptedHandles(1, description: "the parked spawn built its child")
        let opening = Task { try? await parked.open() }
        defer { held.release(); opening.cancel() }
        try await TestTiming.awaitDelivery([parkedChild])
        guard !parkedRig.scriptedHandles.isEmpty else { return XCTFail("the parked spawn built no child") }
        let connecting = await parked.state
        XCTAssertEqual(connecting.origin, .owned(.connecting), "connecting, with a live process of its own")

        let outcome = await parked.terminateForLogout()
        guard case .exited = outcome else { return XCTFail("the terminate did not report an exit") }
        // The child is gone, so the handshake it was waiting on cannot land.
        parkedRig.scriptedHandles[0].spawnError = ScriptedSpawnFailure()
        held.release()
        await opening.value

        let rested = await parked.state
        XCTAssertEqual(rested.origin, .archived,
                       "the terminate did not happen to the channel; the spawn did not happen, so it is archived again")
        XCTAssertEqual(parkedRig.diagnostics.notInTable, [])

        // Half two: nothing but a respawn waiting on its backoff.
        let backoffRig = try Rig(sharing: parkedRig.diagnostics)
        backoffRig.useScriptedHandle()
        let crashed = backoffRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await crashed.spawn(reason: .open)
        backoffRig.scriptedHandles[0].push(.exited(.code(1, stderrTail: ""), backoffRig.scriptedHandles[0].epoch))
        try await backoffRig.waitForSleeper(due: ChannelSupervisor.backoffs[0])
        let waiting = await crashed.state
        XCTAssertEqual(waiting.origin, .owned(.connecting), "connecting on the strength of a pending respawn")

        _ = await crashed.terminateForLogout()

        let stopped = await crashed.state
        XCTAssertEqual(stopped.origin, .owned(.dormant),
                       "the series had been ready, so the channel it left was dormant")
        await backoffRig.clock.advance(by: ChannelSupervisor.backoffs[0])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(backoffRig.spawnCount, 1, "the cancelled respawn launched nothing")
        XCTAssertEqual(backoffRig.diagnostics.notInTable, [])

        await parkedRig.shutdown(); await parkedRig.tearDown()
        await backoffRig.shutdown(); await backoffRig.tearDown()
    }

    /// The fourth failure of a series that *had* reached ready rests dormant whether the failure lands from ready or
    /// mid-handshake. This half is the mid-handshake one: the channel reaches ready once, and every respawn after
    /// that dies before its own handshake can land.
    ///
    /// Deliberate break: make the exhaustion target `wasReadyInThisSeries ? .ready : .archivedOlder` again → the
    /// channel is published `.owned(.ready)` with no process and its send throws `notOwned`.
    func testACrashSeriesThatHadBeenReadyRestsDormantWhenTheLastFailureIsMidHandshake() async throws {
        let rig = try Rig()
        rig.useScriptedHandle()
        // Every child after the first dies inside its own handshake: the gate runs before `spawn` reads its error,
        // so the exit is on the stream and the spawn then fails, which is the live ordering.
        rig.configureScriptedHandles { handle in
            guard handle.epoch.rawValue > 1 else { return }
            handle.spawnError = ScriptedSpawnFailure()
            handle.spawnGate = { handle.push(.exited(.code(1, stderrTail: ""), handle.epoch)) }
        }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let ready = await supervisor.state
        XCTAssertEqual(ready.origin, .owned(.ready), "the series reached ready once")
        rig.forgetTransitions()

        rig.scriptedHandles[0].push(.exited(.code(1, stderrTail: ""), rig.scriptedHandles[0].epoch))
        for backoff in ChannelSupervisor.backoffs {
            try await rig.waitForSleeper(due: backoff)
            await rig.clock.advance(by: backoff)
            try await rig.waitUntil(supervisor, "the next failure") {
                $0.epoch.map { $0.rawValue } ?? 0 >= UInt64(rig.spawnCount)
            }
        }
        try await rig.waitUntil(supervisor, "the resting state") { $0.systemItem != nil }

        let rested = await supervisor.state
        XCTAssertEqual(rested.origin, .owned(.dormant),
                       "the series owned the session, so it rests dormant rather than in a ready with no process")
        guard case .crashed(_, let reopenOffered)? = rested.systemItem else { return XCTFail("no crashed item") }
        XCTAssertTrue(reopenOffered)
        XCTAssertEqual(rig.spawnCount, 4, "three respawns and no fourth")

        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
        await rig.shutdown(); await rig.tearDown()
    }

    /// *Reopen* is honoured for every item that offers it, not for the wedged one alone. Both halves are crash
    /// exhaustion: the series that had been ready rests dormant and takes the dormant send row, and the one that
    /// never was rests archived-older and takes that state's send row. No new event and no new row.
    ///
    /// Deliberate break: restore `guard state.wedged != nil` at the top of `reopen()` → both halves return silently
    /// with the item still on the channel and no child built.
    func testReopenSpawnsAgainForACrashedChannelFromDormantAndFromArchived() async throws {
        let readyRig = try Rig()
        readyRig.useScriptedHandle()
        let fromDormant = readyRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await Self.exhaustTheCrashSeries(readyRig, fromDormant, reachingReady: true)
        let dormantState = await fromDormant.state
        XCTAssertEqual(dormantState.origin, .owned(.dormant))

        let neverRig = try Rig(sharing: readyRig.diagnostics)
        neverRig.useScriptedHandle()
        let fromArchived = neverRig.supervisor(session: SessionID(), isRecent: true, origin: .archived)
        try await Self.exhaustTheCrashSeries(neverRig, fromArchived, reachingReady: false)
        let archivedState = await fromArchived.state
        XCTAssertEqual(archivedState.origin, .archived)

        readyRig.forgetTransitions()
        readyRig.configureScriptedHandles { _ in }
        neverRig.configureScriptedHandles { _ in }

        try await fromDormant.reopen()
        try await fromArchived.reopen()

        let reopenedDormant = await fromDormant.state
        XCTAssertEqual(reopenedDormant.origin, .owned(.ready), "the crashed channel came back")
        XCTAssertNil(reopenedDormant.systemItem, "the item the user acted on is cleared")
        XCTAssertEqual(readyRig.spawnCount, 5, "a new child, on the resting state's own send row")
        let reopenedArchived = await fromArchived.state
        XCTAssertEqual(reopenedArchived.origin, .owned(.ready))
        XCTAssertNil(reopenedArchived.systemItem)

        readyRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
        await readyRig.shutdown(); await readyRig.tearDown()
        await neverRig.shutdown(); await neverRig.tearDown()
    }

    /// Four non-zero exits, with the backoffs run on the manual clock. `reachingReady` decides whether the first
    /// child completes its handshake, which is what tells the two resting states apart.
    static func exhaustTheCrashSeries(_ rig: Rig, _ supervisor: ChannelSupervisor,
                                      reachingReady: Bool) async throws {
        let firstFails = !reachingReady
        rig.configureScriptedHandles { handle in
            guard firstFails || handle.epoch.rawValue > 1 else { return }
            handle.spawnError = ScriptedSpawnFailure()
            handle.spawnGate = { handle.push(.exited(.code(1, stderrTail: ""), handle.epoch)) }
        }
        if reachingReady {
            try await supervisor.spawn(reason: .open)
            rig.scriptedHandles[0].push(.exited(.code(1, stderrTail: ""), rig.scriptedHandles[0].epoch))
        } else {
            try? await supervisor.open()
        }
        for backoff in ChannelSupervisor.backoffs {
            try await rig.waitForSleeper(due: backoff)
            await rig.clock.advance(by: backoff)
            try await rig.waitUntil(supervisor, "the next failure") {
                $0.epoch.map { $0.rawValue } ?? 0 >= UInt64(rig.spawnCount)
            }
        }
        try await rig.waitUntil(supervisor, "the resting state") { $0.systemItem != nil }
    }
}
