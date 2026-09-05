import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The `terminateExhausted` scenarios the quiescent restart injects the `nil` exit through: from ready, and from
/// connecting, where a restart catches a handshake that has not finished. Both scenarios are declared in
/// `LifecycleRowTests.coverage` under this test's name.
extension LifecycleRowTests {

    /// A `terminate()` that answers no exit wedges the channel and the restart stops there: no replacement process,
    /// no change queued behind the ghost, and no readback banner — nothing got far enough to read anything back.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so no real child can produce a `TerminationReport` whose
    /// `exit` is `nil`. The connecting half parks the channel in connecting *with* a live process by holding the
    /// scripted handle's `spawn` open, which is the state a scripted spawn that throws cannot produce.
    func testTerminateReturningNilDuringRestartSpawnsNothing() async throws {
        for from in [LifecycleTable.StateName.ready, .connecting] {
            let rig = try Rig()
            rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: Self.wedgedSteps))
            let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))

            let held = HeldAnswer()
            var parked: Task<Void, Never>?
            if from == .ready {
                try await supervisor.spawn(reason: .open)
            } else {
                // The handle is built and the pump started before `spawn` awaits the handshake, so the channel is
                // genuinely connecting with a process of its own while this task is parked.
                rig.holdNextSpawn { await held.wait() }
                parked = Task { try? await supervisor.spawn(reason: .open) }
                try await rig.waitFor("the parked spawn") { rig.scriptedHandles.count == 1 }
            }
            let handle = rig.scriptedHandles[0]
            let spawnsBefore = rig.spawnCount
            rig.forgetTransitions()

            var thrown: (any Error)?
            do { try await supervisor.quiescentRestart(RestartRequest()) } catch { thrown = error }

            guard case .wedged(let trace)? = thrown as? LifecycleError else {
                return XCTFail("the restart from \(from.rawValue) gave \(String(describing: thrown))")
            }
            XCTAssertEqual(trace.steps, Self.wedgedSteps)
            XCTAssertEqual(handle.terminateCount, 1)
            XCTAssertEqual(rig.spawnCount, spawnsBefore, "no replacement process for one session id")
            let state = await supervisor.state
            XCTAssertEqual(state.origin, .owned(.dormant))
            XCTAssertEqual(state.wedged?.steps, Self.wedgedSteps)
            XCTAssertNil(state.pendingChange, "the change is not silently queued behind a ghost")
            if case .settingDidNotSurvive = state.banner { XCTFail("nothing was read back") }

            rig.assertObserved([LifecycleTable.Transition(.terminateExhausted, from,
                                                          .terminateReturnedNil(during: .restart), .wedged)])

            // The parked spawn is unwound rather than resumed: the channel is wedged now, and letting a handshake
            // it has already moved past complete would be a transition the table rightly has no row for.
            handle.spawnError = ScriptedSpawnFailure()
            await held.release()
            _ = await parked?.value
            await rig.shutdown()
            await rig.tearDown()
        }
    }
}
