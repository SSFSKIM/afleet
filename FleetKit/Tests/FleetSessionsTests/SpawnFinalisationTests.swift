import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The window between a clean handshake and the confirmed slot. Three awaits stand in it — the pid read, the
/// post-handshake ownership check and the counter's own turn — and the child can die in any of them. What the spawn
/// owes the fleet then is the same on every path: nothing published ready over a process that has gone, and the
/// reservation given back rather than held for the life of the app.
final class SpawnFinalisationTests: XCTestCase {
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

    /// The child exits cleanly while the spawn is reading its pid. The epoch is still this spawn's, so the epoch
    /// check alone lets the finalisation through: it confirms a slot for a process that no longer exists and
    /// publishes a channel ready over it. `ProcessHandle` is `Sendable` rather than `AnyObject`, so the handle
    /// cannot be compared by identity; `process != nil` beside the epoch is the whole test, because only a new
    /// spawn replaces the handle and that advances the epoch.
    ///
    /// Scripted, not recorded: an exit timed inside a post-handshake read is not something a recording produces.
    ///
    /// Deliberate break: drop `process != nil` from the guard after the handshake.
    func testAnExitDuringThePostHandshakeCheckConfirmsNothingAndPublishesNoReady() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let held = HeldAnswer(), entered = HeldAnswer()
        rig.configureScriptedHandles { handle in
            handle.pidGate = { entered.release(); await held.wait() }
        }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await supervisor.spawn(reason: .open) }
        try await rig.waitFor("the spawn to reach its post-handshake pid read") { entered.isReleased }
        let handle = try XCTUnwrap(rig.scriptedHandles.first)

        let published = await supervisor.publishedCount
        handle.push(.exited(.code(0, stderrTail: ""), handle.epoch))
        try await rig.waitForPublish(supervisor, above: published)
        held.release()
        _ = try? await spawning.value

        let occupancy = await rig.fleet.occupancy
        XCTAssertEqual(occupancy, 0, "the reservation of a spawn whose child has gone goes back")
        let live = await rig.fleet.isLive(supervisor.key)
        XCTAssertFalse(live, "and no slot was confirmed")
        try await rig.drainPublished(of: supervisor)
        XCTAssertFalse(rig.published(of: supervisor).contains { $0.origin == .owned(.ready) },
                       "nothing is ready over a process that has exited")
    }

    /// The same window, and the invariant ruling 1 states: never leave an owned channel in ready or connecting with
    /// no process. A child that exits *cleanly* there is nobody's crash — `handleExit` takes `.exitedClean` only
    /// from ready, so it leaves a connecting channel alone — and the finalisation's own guard returned holding
    /// nothing but the rollback. The channel stayed connecting with no process: no send resumes it, no timer fires
    /// on it, and only a relaunch of the app moves it. It rests where it started instead.
    ///
    /// Deliberate break: drop `restoreResting(ifEpochIs: mine)` from the post-handshake guards.
    func testACleanExitDuringThePostHandshakeCheckRestsTheChannelRatherThanLeavingItConnecting() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let held = HeldAnswer(), entered = HeldAnswer()
        rig.configureScriptedHandles { handle in
            handle.pidGate = { entered.release(); await held.wait() }
        }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await supervisor.spawn(reason: .open) }
        try await rig.waitFor("the spawn to reach its post-handshake pid read") { entered.isReleased }
        let handle = try XCTUnwrap(rig.scriptedHandles.first)

        let published = await supervisor.publishedCount
        handle.push(.exited(.code(0, stderrTail: ""), handle.epoch))
        try await rig.waitForPublish(supervisor, above: published)
        held.release()
        _ = try? await spawning.value

        try await rig.waitUntil(supervisor, "the channel to rest") { $0.origin != .owned(.connecting) }
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.dormant),
                       "a processless owned channel rests dormant; connecting would name a process that has gone")
        let pid = await supervisor.livePID()
        XCTAssertNil(pid, "and it rests with no process")
        XCTAssertNil(state.systemItem, "a clean exit is not a crash: no item and no Reopen")
    }

    /// A crash the spawn was suspended past. `handleExit` has already continued the series and the respawn behind it
    /// owns the channel now, so this attempt's only remaining duty is to give its slot back — and today it returns
    /// without doing so, which costs one of the fleet's six slots permanently, per race.
    ///
    /// Scripted, not recorded: two children of one channel, the first parked inside its own handshake.
    ///
    /// Deliberate break: return from the epoch guard without `fleet.rollback(reservation)`.
    func testASpawnARespawnOvertookGivesItsReservationBack() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let held = HeldAnswer(), entered = HeldAnswer()
        rig.configureScriptedHandles { handle in
            // The first child only: the respawn behind it has to run to completion for the overtake to happen.
            guard handle.epoch.rawValue == 1 else { handle.spawnGate = nil; return }
            handle.spawnGate = { entered.release(); await held.wait() }
        }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await supervisor.spawn(reason: .open) }
        try await rig.waitFor("the first spawn to park inside its handshake") { entered.isReleased }
        let first = try XCTUnwrap(rig.scriptedHandles.first)

        let published = await supervisor.publishedCount
        first.push(.exited(.code(1, stderrTail: ""), first.epoch))
        try await rig.waitForPublish(supervisor, above: published)
        try await rig.waitForSleeper(due: .seconds(1))
        await rig.clock.advance(by: .seconds(1))
        try await rig.waitUntil(supervisor, "the respawn to be ready") { $0.origin == .owned(.ready) }

        held.release()
        _ = try? await spawning.value

        let occupancy = await rig.fleet.occupancy
        XCTAssertEqual(occupancy, 1, "one live child holds one slot; the overtaken attempt kept none")
        let decision = await rig.fleet.acquire(for: ChannelKey(configHome: supervisor.key.configHome,
                                                               session: SessionID()))
        guard case .granted = decision else {
            return XCTFail("a fleet with one child refused the next spawn: \(decision)")
        }
    }
}
