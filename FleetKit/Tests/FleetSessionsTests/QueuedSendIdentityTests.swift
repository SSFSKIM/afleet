import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// X5's `sendPrompt` contract in the one state where the answer and the write are separated in time.
///
/// A send that arrives while the channel is connecting is queued and written when the handshake lands, so the uuid
/// the caller was answered is minted long before the frame exists. The host raises `HostSignal.promptSent` with that
/// uuid at once; if the write then carries a different one, the fold attributes the turn to an identifier the engine
/// never echoes and the promise the signal exists to make is silently false.
final class QueuedSendIdentityTests: XCTestCase {
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

    /// Queued during connecting, written after the handshake — under the uuid the caller holds.
    ///
    /// Scripted, not recorded: the window is a spawn parked inside its own handshake with a send arriving in it,
    /// which no recording produces.
    ///
    /// Deliberate break: mint a fresh `UUID()` in the `.owned(.connecting)` arm of `ChannelSupervisor.send`, or in
    /// `flushQueuedInput` → the frame names a prompt the caller never saw.
    func testASendQueuedWhileConnectingIsWrittenUnderTheUUIDItsCallerWasAnswered() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let held = HeldAnswer(), entered = HeldAnswer()
        let parked = entered.expectation(description: "the spawn parked inside its handshake")
        rig.holdNextSpawn { entered.release(); await held.wait() }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await supervisor.spawn(reason: .open) }
        defer { held.release(); spawning.cancel() }
        try await TestTiming.awaitDelivery([parked])
        let handle = try XCTUnwrap(rig.scriptedHandles.first)
        XCTAssertTrue(handle.sent.isEmpty, "the parked spawn already wrote \(handle.sent.count) user frame(s)")

        let answered = try await supervisor.send(UserInput(text: "an invented queued prompt"))
        XCTAssertTrue(handle.sent.isEmpty,
                      "the send during connecting wrote \(handle.sent.count) frame(s) instead of queueing")

        held.release()
        _ = try? await spawning.value
        try await rig.waitUntil(supervisor, "the queued input to reach the wire") { _ in !handle.sent.isEmpty }

        XCTAssertEqual(handle.sentUUIDs.count, 1,
                       "the queue drained \(handle.sentUUIDs.count) user frame(s), not exactly 1")
        XCTAssertEqual(handle.sentUUIDs.first, answered,
                       "the frame on the wire names a prompt the caller was never answered, so the host's "
                       + "`promptSent` raise attributes the turn to an identifier the engine will never echo")
    }

    /// The ordinary path keeps the same promise: a send on a ready channel is written under the uuid it returned.
    ///
    /// The floor under the arm above — without it a supervisor that answered `handle.sentUUIDs.first` by accident
    /// in one state and not the other would still look correct.
    func testASendOnAReadyChannelIsWrittenUnderTheUUIDItReturned() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        try await rig.waitUntil(supervisor, "the channel to be ready") { $0.origin == .owned(.ready) }
        let handle = try XCTUnwrap(rig.scriptedHandles.first)

        let answered = try await supervisor.send(UserInput(text: "an invented prompt"))

        XCTAssertEqual(handle.sentUUIDs, [answered],
                       "the ready channel wrote \(handle.sentUUIDs.count) frame(s), and not under the uuid the "
                       + "caller was answered")
    }
}
