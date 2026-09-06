import XCTest
import Darwin
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Two guards the supervisor owes its callers: *Reopen* does not spawn behind a ghost that is still running, and a
/// channel that has archived finishes the wire streams it handed out.
final class SupervisorGuardTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    private func newRig() throws -> Rig {
        let rig = try Rig()
        rigs.append(rig)
        return rig
    }

    /// A ghost stops mattering when its registry record is gone *and* its pid is dead. `holdersChanged` already
    /// applies both halves before it frees the slot; `reopen` applied only the first, so a child that would not die
    /// but whose record the CLI had already removed let a second writer onto the same transcript — which is the one
    /// thing every pre-spawn check exists to prevent.
    ///
    /// The live pid is this test process's own: a pid that is certainly running, owned by nobody the rig started.
    ///
    /// Deliberate break: drop the `ProcessLiveness.isRunning(pid:)` guard from `reopen`.
    func testReopenRefusesWhileTheGhostIsStillRunning() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: ["SIGTERM", "SIGKILL"]))
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        rig.scriptedHandles[0].pid = getpid()
        await supervisor.reap()

        let wedged = await supervisor.state
        let trace = try XCTUnwrap(wedged.wedged, "the reap wedged the channel")
        let spawnsBefore = rig.spawnCount

        do {
            try await supervisor.reopen()
            XCTFail("reopen spawned a second writer behind a ghost that is still running")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .wedged(trace))
        }

        let after = await supervisor.state
        XCTAssertEqual(after.wedged, trace, "the trace survives: the ghost is still out there")
        XCTAssertNotNil(after.systemItem, "and *Reopen* is still what the item offers")
        XCTAssertEqual(rig.spawnCount, spawnsBefore, "nothing was launched")
    }

    /// `events()` hands out an unbounded fan-out per call and `shutdown()` finishes them — but a channel archives on
    /// ordinary transitions, long before the app exits, and a consumer looping over a stream of a channel that is no
    /// longer owned waits forever on frames that can never come.
    ///
    /// Deliberate break: finish the subscribers only in `shutdown()` again.
    func testTheEventStreamsOfAChannelThatArchivesAreFinished() async throws {
        let rig = try newRig()
        let supervisor = rig.supervisor(session: SessionID(), isRecent: true,
                                        origin: .foreignLive(.usersTerminal))
        let stream = await supervisor.events()
        let finished = HeldAnswer()
        let streamFinished = finished.expectation(description: "the archived channel's event stream finished")
        let consumer = Task { for await _ in stream {}; finished.release() }

        // The holder's record went away: the session is nobody's and the channel is archived.
        await supervisor.holdersChanged(HolderSet(holders: [], observedAt: Date()))
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .archived)

        try await TestTiming.awaitDelivery([streamFinished])
        consumer.cancel()
    }
}
