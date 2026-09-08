import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The two `terminateExhausted` scenarios §7.4's *Quit* adds: the `nil` exit injected through the quit's own
/// terminate, from ready and from connecting, where the quit catches a handshake that has not finished. Both are
/// declared in `LifecycleRowTests.coverage` under this test's name.
extension LifecycleRowTests {

    /// A quit records its ghost as a quit's. The terminate is the same one a reap runs and the trace is the same
    /// trace, so nothing but the action name distinguishes them — and that name is the whole point: a ghost left
    /// behind at quit is a different observation from one left behind by the thirty-minute reap.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so no real child can produce a `TerminationReport` whose
    /// `exit` is `nil`. The connecting half parks its channel in connecting *with* a live process by holding the
    /// scripted handle's `spawn` open.
    func testTerminateReturningNilDuringQuitWedgesTheChannelAsAQuit() async throws {
        for from in [LifecycleTable.StateName.ready, .connecting] {
            let rig = try Rig()
            rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: Self.wedgedSteps))

            let ghost = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
            let held = HeldAnswer()
            var parked: Task<Void, Never>?
            defer { held.release(); parked?.cancel() }
            if from == .ready {
                try await ghost.spawn(reason: .open)
            } else {
                rig.holdNextSpawn { await held.wait() }
                let parkedChild = rig.expectScriptedHandles(1, description: "the parked spawn built its child")
                parked = Task { try? await ghost.spawn(reason: .open) }
                try await TestTiming.awaitDelivery([parkedChild])
            }
            guard let ghostHandle = rig.scriptedHandles.first else { return XCTFail("the ghost built no child") }
            rig.forgetTransitions()

            let outcome = await ghost.terminateForQuit()

            guard case .wedged(let trace) = outcome else {
                return XCTFail("the quit's terminate answered \(String(describing: outcome))")
            }
            XCTAssertEqual(trace.steps, Self.wedgedSteps, "the report's steps, in order and entire")
            XCTAssertEqual(ghostHandle.terminateCount, 1)
            let state = await ghost.state
            XCTAssertEqual(state.wedged?.steps, Self.wedgedSteps)
            XCTAssertEqual(state.origin, .owned(.dormant))
            let counted = await rig.fleet.liveCount
            XCTAssertEqual(counted, 1, "the ghost still costs a slot")

            rig.assertObserved([
                LifecycleTable.Transition(.terminateExhausted, from,
                                          .terminateReturnedNil(during: .quit), .wedged),
            ])

            // The parked spawn is unwound rather than resumed, for the reason the logout row records: the channel is
            // wedged now, and letting a handshake it has already moved past complete would be a transition the table
            // rightly has no row for.
            ghostHandle.spawnError = ScriptedSpawnFailure()
            held.release()
            _ = await parked?.value
            await rig.shutdown()
            await rig.tearDown()
        }
    }
}
