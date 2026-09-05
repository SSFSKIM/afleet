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
    /// `exit` is `nil`.
    ///
    /// The connecting half is Task 6's own doing. `spawn(reason: .restart)` returns before `.ready` so the readbacks
    /// can run first, which leaves the channel connecting *with* a live process and no operation of its own in
    /// flight — and a readback that does not match leaves it there behind a banner. A second restart arriving on
    /// that channel is what this half drives; a restart asked for while the first is still running merges into the
    /// pending change instead and terminates nothing, which is a different claim with its own test.
    func testTerminateReturningNilDuringRestartSpawnsNothing() async throws {
        for from in [LifecycleTable.StateName.ready, .connecting] {
            let rig = try Rig()
            rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: Self.wedgedSteps))
            let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))

            try await supervisor.spawn(reason: from == .ready ? .open : .restart)
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

            await rig.shutdown()
            await rig.tearDown()
        }
    }
}
