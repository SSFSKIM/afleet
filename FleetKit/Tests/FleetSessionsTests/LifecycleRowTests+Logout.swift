import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The last two `terminateExhausted` scenarios: the `nil` exit injected through `/logout`, from ready and from
/// connecting, where the plan catches a handshake that has not finished. Both are declared in
/// `LifecycleRowTests.coverage` under this test's name; with them every scenario in `LifecycleTable.scenarios` has a
/// declaring test, which is what Task 12's gate proves.
extension LifecycleRowTests {

    /// A channel whose `terminate()` answers no exit stops the whole plan: the credentials stay where they are.
    /// Running `claude auth logout` behind a ghost would take the token out from under a process that is still
    /// alive and still mid-turn, which is the one thing the wedged row exists to prevent.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so no real child can produce a `TerminationReport` whose
    /// `exit` is `nil`; both channels run on the scripted handle. The connecting half parks its channel in
    /// connecting *with* a live process by holding the scripted handle's `spawn` open.
    func testTerminateReturningNilDuringLogoutRunsNoAuthLogout() async throws {
        for from in [LifecycleTable.StateName.ready, .connecting] {
            let rig = try Rig()
            rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: Self.wedgedSteps))

            let healthy = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
            try await healthy.spawn(reason: .open)
            rig.scriptedHandles[0].terminateReturns = TerminationReport(exit: .code(0, stderrTail: ""), steps: [])

            let ghost = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
            let held = HeldAnswer()
            var parked: Task<Void, Never>?
            defer { held.release(); parked?.cancel() }
            if from == .ready {
                try await ghost.spawn(reason: .open)
            } else {
                rig.holdNextSpawn { await held.wait() }
                let parkedChild = rig.expectScriptedHandles(2, description: "the parked spawn built its child")
                parked = Task { try? await ghost.spawn(reason: .open) }
                try await TestTiming.awaitDelivery([parkedChild])
            }
            guard rig.scriptedHandles.count >= 2 else { return XCTFail("the ghost built no second child") }
            let ghostHandle = rig.scriptedHandles[1]

            let fleet = LogoutContext(channels: [healthy, ghost], observer: rig.observer, verbs: rig.verbs,
                                      barrier: rig.spawnBarrier, ownJobShorts: [], diagnostics: rig.diagnostics,
                                      clock: rig.clock)
            let census = await LogoutPlan.build(fleet: fleet)
            XCTAssertEqual(Set(census.owned), [healthy.key, ghost.key])
            rig.forgetTransitions()

            let outcome = try await rig.steppingClock {
                await LogoutPlan.execute(census, choice: .stop, fleet: fleet)
            }

            XCTAssertEqual(outcome, .blocked(wedged: [ghost.key], jobsStillListed: []),
                           "the plan names the channel that would not go")
            XCTAssertEqual(rig.runnerCalls.count(prefix: ["auth", "logout"]), 0,
                           "a live process must not lose its credentials mid-turn")
            XCTAssertEqual(ghostHandle.terminateCount, 1)
            let ghostState = await ghost.state
            XCTAssertEqual(ghostState.wedged?.steps, Self.wedgedSteps)
            XCTAssertEqual(ghostState.origin, .owned(.dormant))
            let healthyState = await healthy.state
            XCTAssertNil(healthyState.wedged, "the channel that did go is dormant, not wedged")
            XCTAssertEqual(healthyState.origin, .owned(.dormant))
            XCTAssertFalse(rig.spawnBarrier.isRaised, "a blocked plan lifts its barrier")

            rig.assertObserved([
                LifecycleTable.Transition(.terminateExhausted, from,
                                          .terminateReturnedNil(during: .logout), .wedged),
                LifecycleTable.Transition(.readyDormantEligible, .ready, .dormantTimerFired, .dormant),
            ])

            // The parked spawn is unwound rather than resumed: the channel is wedged now, and letting a handshake
            // it has already moved past complete would be a transition the table rightly has no row for.
            ghostHandle.spawnError = ScriptedSpawnFailure()
            held.release()
            _ = await parked?.value
            await rig.shutdown()
            await rig.tearDown()
        }
    }
}
