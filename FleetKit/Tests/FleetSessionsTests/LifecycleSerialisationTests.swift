import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Ruling 2: one in-flight marker per channel, refusal rather than queueing, and the two exceptions.
///
/// `ChannelSupervisor.swift`'s send comment used to promise that the facade serialises one channel's actions and
/// nothing did, so two entrants both passed a guard neither of them held. These drive the four claims that replace
/// it: a second operation is refused, a restart asked for while one runs merges, a send that has *started* is
/// visible to the eviction, and a send is refused while the channel is being taken away.
///
/// None of these is a §7.4 row, so none declares a scenario; each asserts what the marker changed and nothing about
/// the table.
final class LifecycleSerialisationTests: XCTestCase {

    /// Parks its *first* caller and lets every later one straight through.
    ///
    /// The seams these tests park in — the release wait, the terminate — are the seams a second entrant reaches
    /// too when the marker is missing, and a gate that held both would deadlock the very run that is meant to show
    /// the defect. One-shot keeps the failing run finite and its message readable.
    final class OneShotGate: @unchecked Sendable {   // `lock` serialises `taken`
        private let lock = NSLock()
        private var taken = false
        private let held = HeldAnswer()
        func release() { held.release() }
        /// Synchronous, because `NSLock.lock()` is unavailable from an async context: the claim is taken here and
        /// only the parking is awaited.
        private func claim() -> Bool { lock.lock(); defer { lock.unlock() }; let mine = !taken; taken = true; return mine }
        func wait() async {
            guard claim() else { return }
            await held.wait()
        }
    }

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

    /// A ready scripted channel: every one of these is about what a second caller may do to a channel that is
    /// already busy, and the scripted handle is the only way to park the first caller where it matters.
    private func readyScripted(_ rig: Rig) async throws -> ChannelSupervisor {
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        return supervisor
    }

    /// Two *Send to background* clicks on one channel run one `claude --bg --resume`. The second is refused with
    /// the operation the first is running, rather than terminating a channel whose process the first has already
    /// let go of and starting a second job for one session id.
    ///
    /// Deliberate break: drop the marker from `handOff` → the second call finds `process` already nil, waits for
    /// nothing, and runs the verb again; `runnerCalls` then names two `--bg --resume` for one session.
    func testASecondHandoffIsRefusedWhileOneIsInFlight() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        let handle = rig.scriptedHandles[0]
        let held = OneShotGate()
        // The window the finding is about: past the terminate, before the launch.
        rig.onReleased = { await held.wait() }

        let first = Task { try await rig.steppingClock { try await supervisor.sendToBackground() } }
        try await rig.waitFor("the first handoff to reach its release wait") { handle.terminateCount == 1 }

        // Inside the stepper as well: the refusal is synchronous, but a second handoff that is *not* refused runs
        // the verb, and the verb's own roster wait is on the injected clock.
        var second: (any Error)?
        do { _ = try await rig.steppingClock { try await supervisor.sendToBackground() } } catch { second = error }

        XCTAssertEqual(second as? LifecycleError, .busy(.handOff),
                       "the second click was allowed into a channel the first had already taken")
        held.release()
        _ = try await first.value

        XCTAssertEqual(rig.runnerCalls.count(prefix: ["--bg", "--resume"]), 1,
                       "one session id, one background job")
        XCTAssertEqual(handle.terminateCount, 1)
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .backgroundJob)
    }

    /// The first exception: a restart asked for while one is running merges into the pending change rather than
    /// terminating and relaunching a second time. Two of them merge with each other, so nothing the user asked for
    /// is dropped on the way.
    ///
    /// Deliberate break: throw `busy` for a second restart instead of merging → the two queued directories are lost
    /// and `pendingChange` is nil.
    func testARestartAskedForWhileOneRunsMergesIntoThePendingChange() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        let handle = rig.scriptedHandles[0]
        let held = OneShotGate()
        rig.onReleased = { await held.wait() }

        let a = rig.scratch.appending(path: "a")
        let b = rig.scratch.appending(path: "b")
        let c = rig.scratch.appending(path: "c")
        let first = Task {
            try await rig.steppingClock {
                try await supervisor.quiescentRestart(RestartRequest(addDirectories: [a]))
            }
        }
        try await rig.waitFor("the restart to reach its release wait") { handle.terminateCount == 1 }

        try await supervisor.quiescentRestart(RestartRequest(addDirectories: [b]))
        try await supervisor.quiescentRestart(RestartRequest(addDirectories: [c]))

        let queued = await supervisor.state.pendingChange
        XCTAssertEqual(queued?.addDirectories, [b, c],
                       "both changes asked for behind the running restart are still there, in order")
        held.release()
        try await first.value

        XCTAssertEqual(rig.spawnCount, 2, "one restart relaunched one child; the queued ones did not run")
    }

    /// `deliver` marks the turn running *before* the write, so an eviction that re-evaluates eligibility at reap
    /// time sees a send that has started and refuses to be the victim. Setting the flag after the write leaves a
    /// window in which the channel looks idle while its input is already on its way to the engine.
    ///
    /// Deliberate break: move `turnRunning = true` back below `await handle.send` → the eviction reads the channel
    /// as eligible, terminates it, and the outcome is `.evicted`.
    func testASendThatHasStartedKeepsTheChannelOutOfTheEviction() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        let handle = rig.scriptedHandles[0]
        let held = HeldAnswer()
        handle.sendGate = { await held.wait() }

        let sending = Task { try await supervisor.send(UserInput(text: "hi")) }
        try await rig.waitFor("the send to reach the write") { handle.sent.count == 1 }

        let outcome = await supervisor.evict()

        XCTAssertEqual(outcome, .victimBecameIneligible,
                       "the channel was evicted with a send already in flight")
        XCTAssertEqual(handle.terminateCount, 0, "and nothing terminated it")
        held.release()
        _ = try await sending.value
    }

    /// The other half of the same window: once a reap has taken the channel, a send arriving behind it is refused
    /// rather than written into a child that is being ended.
    ///
    /// Deliberate break: drop the marker check from `send` → the input is written to a process the reap has
    /// already decided to end, and `handle.sent` names it.
    func testASendIsRefusedWhileAReapIsInFlight() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        let handle = rig.scriptedHandles[0]
        let held = HeldAnswer()
        handle.terminateGate = { await held.wait() }

        let reaping = Task { await supervisor.reap() }
        try await rig.waitFor("the reap to reach its terminate") { handle.terminateCount == 1 }

        var thrown: (any Error)?
        do { _ = try await supervisor.send(UserInput(text: "hi")) } catch { thrown = error }

        XCTAssertEqual(thrown as? LifecycleError, .busy(.reap))
        XCTAssertEqual(handle.sent, [], "nothing was written to a child being reaped")
        held.release()
        await reaping.value
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.dormant))
    }

    /// The barrier is read once at the top of `spawn` and three awaits stand between that read and the epoch the
    /// spawn advances. `/logout`'s census runs in exactly that window: it reports the channel as having no process,
    /// `claude auth logout` runs, and a child launched behind it loses its credentials mid-handshake. The barrier
    /// is therefore read again after the last of those awaits, and the reservation goes back on the refusal.
    ///
    /// Deliberate break: remove the second `spawnBarrier.check()` → a handle is built (`spawnCount` is 1) and the
    /// counter is left holding a confirmed slot for a channel signing out.
    func testTheSpawnBarrierIsRecheckedAfterTheLastAwaitBeforeTheEpochAdvances() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), isRecent: true, origin: .archived)
        // The pre-spawn check is the last await before the epoch advances; the plan raises the barrier while the
        // spawn is suspended in it.
        rig.reader.onLabel(OwnershipLabel.beforeSpawn) { [weak rig] in rig?.spawnBarrier.raise() }

        var thrown: (any Error)?
        do { try await supervisor.open() } catch { thrown = error }

        XCTAssertEqual(thrown as? LifecycleError, .logoutInProgress)
        XCTAssertEqual(rig.spawnCount, 0, "no child was built behind the census")
        let occupancy = await rig.fleet.occupancy
        XCTAssertEqual(occupancy, 0, "the reservation the refused spawn took went back")
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .archived, "and the channel is where it started")
        rig.spawnBarrier.lower()
    }
}
