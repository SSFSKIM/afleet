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

    /// **The published presence is the channel's own turn state, and it is recomputed at publication.**
    ///
    /// `deliver` marks the turn running and publishes; the pump's `.result` arm clears it and publishes. Neither
    /// recomputed `state.presence`, so both yielded whatever the last transition had stored — an ordinary running
    /// turn read as idle by everything above X5. §7.4's *Quit* clause asks exactly this field whether to warn before
    /// it ends a channel, so a stale idle is a working conversation terminated with no dialog.
    ///
    /// The frame is decoded from an invented line rather than taken from a recording: nothing here is an engine byte
    /// (§11), and the fields are the four `ResultFields` requires plus the two the arm reads.
    ///
    /// Deliberate break: drop the `state.presence = presenceNow()` from `publish()`.
    func testADeliveredSendPublishesBusyAndItsResultPublishesIdle() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        try await rig.waitUntil(supervisor, "the channel to be ready") { $0.origin == .owned(.ready) }
        let handle = try XCTUnwrap(rig.scriptedHandles.first)
        let before = await supervisor.publishedCount

        _ = try await supervisor.send(UserInput(text: "an invented prompt"))

        let sending = await supervisor.state
        XCTAssertEqual(sending.presence, .busy,
                       "the channel that has just been written to publishes a presence that is not busy")

        handle.push(.frame(Self.result, handle.epoch))
        try await rig.waitUntil(supervisor, "the result to reach the pump") { $0.presence == .idle }
        let done = await supervisor.state
        XCTAssertEqual(done.presence, .idle, "the finished turn publishes a presence that is not idle")

        // A floor: both readings above have to be publications and not a field the test happened to catch between
        // two of them.
        let published = await supervisor.publishedCount
        XCTAssertGreaterThanOrEqual(published - before, 2,
                                    "the send and its result published \(published - before) state(s), not 2")
    }

    /// One `result` frame, built from an invented line through the decoder every frame reaches the supervisor
    /// through. Nothing recorded, nothing quoted.
    private static let result: Frame = {
        let line = Data("""
            {"type":"result","subtype":"success","duration_ms":1,"is_error":false,"num_turns":1,\
            "total_cost_usd":0,"uuid":"invented-result-uuid","session_id":"invented-session-id"}
            """.utf8)
        return FrameDecoder.decode(line: line)
    }()
}
