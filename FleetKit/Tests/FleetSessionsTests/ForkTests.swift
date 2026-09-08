import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Forking: a new channel under a provisional key that stays `.connecting` until `.sessionIdentityResolved`, when
/// the ownership check runs against the id that actually arrived and the counter's slot is rekeyed onto it.
final class ForkTests: XCTestCase {
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

    private static let idle = "resume-no-replay"
    /// The fixture whose `auth_status` carries the id this fork resolves to.
    private static let turn = "plain-two-turn"

    /// A fork is keyed on a provisional id until the engine announces its own, and only then does the key, the
    /// counter's slot and the channel's readiness move onto the resolved one.
    ///
    /// The fork replays `plain-two-turn`, whose recorded `auth_status` carries the fixture's session id: for this
    /// test that id *is* the new one, because the source channel is a different session.
    func testForkIsKeyedProvisionallyUntilTheIdentityEventThenReKeyed() async throws {
        let rig = try newRig()
        let source = SessionID()
        let resolved = try FakeClaudeLaunch.sessionID(of: Self.turn)
        let supervisor = rig.supervisor(session: source, fixture: Self.idle, forkFixture: Self.turn)
        try await supervisor.open()

        let provisional = try await supervisor.fork(at: nil)

        XCTAssertNotEqual(provisional.session, source, "the fork is not keyed on the session it forked from")
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        XCTAssertEqual(rig.launches[1].session, .resume(source, fork: true))

        try await rig.waitUntil(fork, "the fork to be ready on its resolved id") {
            $0.origin == .owned(.ready) && $0.identity == .known(resolved)
        }
        // Booleans over `ChannelKey` throughout this file: the key carries the rig's config home, which is under
        // the temporary directory (tracker entry 75, §6.3).
        XCTAssertTrue(fork.key == ChannelKey(configHome: provisional.configHome, session: resolved),
                      "the fork is not keyed on the id its child resolved to")

        try await rig.drainPublished(of: fork)
        let published = rig.published(of: fork)
        let readyIndex = try XCTUnwrap(published.firstIndex { $0.origin == .owned(.ready) })
        for state in published[..<readyIndex] {
            XCTAssertEqual(state.identity, .awaitingFork(from: source, provisional: provisional.session))
            XCTAssertTrue(state.key == provisional, "a state published before ready is not on the provisional key")
        }
        XCTAssertEqual(published.filter { $0.key.session == resolved }.count, 1,
                       "the re-keyed state is published once")

        let holdsResolved = await rig.fleet.isLive(ChannelKey(configHome: provisional.configHome,
                                                              session: resolved))
        let holdsProvisional = await rig.fleet.isLive(provisional)
        XCTAssertTrue(holdsResolved, "the counter holds the resolved key")
        XCTAssertFalse(holdsProvisional, "and not the provisional one")
    }

    /// *Fork from here* launches `SessionStart.forkFrom` with the clicked record and the discarded turn. The line
    /// composer emits `--resume-session-at` and `--resume-drops-turn` from that value and C2's tests pin the argv;
    /// this asserts the value FleetKit hands it and adds no argument of its own.
    func testForkFromAMessageLaunchesForkFromWithTheClickedRecordAndTheDroppedTurn() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let source = SessionID()
        let supervisor = rig.supervisor(session: source, origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)

        let point = ForkPoint(entryUUID: "u-42", dropsTurn: "p-41")
        let first = try await supervisor.fork(at: point)

        XCTAssertEqual(rig.launches[1].session, .forkFrom(source, at: point))
        let fork = try XCTUnwrap(rig.supervisor(for: first))
        let forked = await fork.state
        XCTAssertEqual(forked.identity, .awaitingFork(from: source, provisional: first.session))
        XCTAssertEqual(forked.origin, .owned(.connecting), "a fork stays connecting until its identity resolves")

        _ = try await supervisor.fork(at: ForkPoint(entryUUID: "u-42"))
        guard case .forkFrom(_, let carried) = rig.launches[2].session else {
            return XCTFail("the second fork did not launch forkFrom")
        }
        XCTAssertNil(carried.dropsTurn)
    }

    /// A fork whose resolved identity is a session another supervisor already owns yields to that owner, from
    /// connecting, never having published `.ready`.
    ///
    /// The identity event is pushed through the scripted handle: a fork's id resolves from the first `auth_status`
    /// frame and never from the initialize response, so `FAKE_CLAUDE_INIT`, which patches only that response,
    /// cannot script it.
    func testAForkWhoseIdentityCollidesWithAnOwnedSessionYields() async throws {
        let rig = try newRig()
        let owned = try FakeClaudeLaunch.sessionID(of: Self.idle)
        let holder = rig.supervisor(session: owned, fixture: Self.idle)
        try await holder.open()
        let livePID = await holder.livePID()
        let holderPID = try XCTUnwrap(livePID)
        try rig.files.writeRegistry(pid: holderPID, sessionID: owned, kind: "interactive", entrypoint: "sdk-cli")

        rig.useScriptedHandle()
        let source = SessionID()
        let supervisor = rig.supervisor(session: source, origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let forkHandle = try XCTUnwrap(rig.scriptedHandles.last)
        let occupiedBefore = await rig.fleet.occupancy
        rig.forgetTransitions()

        forkHandle.push(.sessionIdentityResolved(owned, forkHandle.epoch))

        try await rig.waitUntil(fork, "the fork to yield") { $0.origin == .owned(.contended) }
        XCTAssertEqual(forkHandle.terminateCount, 1, "the fork's own process was terminated")
        let yielded = await fork.state
        guard case .contended(let holders)? = yielded.banner else { return XCTFail("no contended banner") }
        XCTAssertEqual(holders.holders.map(\.pid), [holderPID])
        XCTAssertTrue(fork.key == provisional, "the facade is not asked to re-index the fork over the owner")
        let stillProvisional = await rig.fleet.isLive(provisional)
        XCTAssertFalse(stillProvisional, "the provisional reservation was rolled back")
        // The owner's key is live because the *owner* holds it; what the rollback has to show is that the fork's
        // own slot is gone and none was rekeyed onto the owner's, which is one slot fewer in total.
        let occupiedAfter = await rig.fleet.occupancy
        XCTAssertEqual(occupiedAfter, occupiedBefore - 1)

        try await rig.drainPublished(of: fork)
        XCTAssertFalse(rig.published(of: fork).contains { $0.origin == .owned(.ready) },
                       "the fork never published ready")
        rig.assertObserved([LifecycleTable.Transition(.connectingFoundHolder, .connecting, .handshakeFoundHolder,
                                                      .contended)])

        let owner = await holder.state
        XCTAssertEqual(owner.origin, .owned(.ready), "the owner's state is untouched")
        let stillLive = await holder.livePID()
        XCTAssertEqual(stillLive, holderPID, "and so is its process")
    }

    /// A fork whose engine never announces an id does not sit connecting forever. The spawn's own handshake timeout
    /// cannot cover this: `ClaudeProcess.spawn` returns at the initialize response and cancels its timer there,
    /// while a fork's id arrives much later off the frame reader. The deadline is the supervisor's own, on the
    /// injected clock, and without it the channel would hold a live child and a cap slot the counter never reclaims.
    ///
    /// Scripted, not recorded: the whole child is scripted, because what the test needs is an engine that emits no
    /// `auth_status` at all — which no recording of a real fork contains.
    func testAForkWhoseIdentityNeverArrivesIsFailedOnTheIdentityDeadline() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let forkHandle = try XCTUnwrap(rig.scriptedHandles.last)
        let occupiedBefore = await rig.fleet.occupancy

        try await rig.waitForSleeper(due: Self.handshakeTimeout)
        let published = await fork.publishedCount
        await rig.clock.advance(by: Self.handshakeTimeout)

        // `terminateCount` rises *inside* `terminateOrWedge`, which is before the reservation goes back, so it is
        // not a synchronisation point for anything the handler does afterwards. The expiry publishes once, after
        // the whole decision, and that is the point to wait on — reading the occupancy off the terminate count
        // alone is a race that happens to pass most of the time.
        try await rig.waitForPublish(fork, above: published)
        XCTAssertEqual(forkHandle.terminateCount, 1, "the identity deadline terminated its child")
        let occupiedAfter = await rig.fleet.occupancy
        XCTAssertEqual(occupiedAfter, occupiedBefore - 1, "the provisional reservation went back")
        let stillProvisional = await rig.fleet.isLive(provisional)
        XCTAssertFalse(stillProvisional)
        let state = await fork.state
        XCTAssertEqual(state.origin, .archived,
                       "failed the way a spawn that does not complete fails a channel: back where it started, "
                       + "because nothing rests in connecting with no process")
        XCTAssertEqual(state.identity, .awaitingFork(from: supervisor.key.session,
                                                     provisional: provisional.session))
        try await rig.drainPublished(of: fork)
        XCTAssertFalse(rig.published(of: fork).contains { $0.origin == .owned(.ready) },
                       "the fork never published ready")
    }

    /// The supervisor's default handshake budget, which is the identity deadline's too.
    private static let handshakeTimeout = Duration.seconds(30)

    /// The slot a fork reserved lands under the id the engine resolved, so the channel's own release frees it.
    func testAForkReleasesItsSlotUnderTheResolvedKey() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let source = SessionID()
        let supervisor = rig.supervisor(session: source, origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let forkHandle = try XCTUnwrap(rig.scriptedHandles.last)
        let resolved = SessionID()
        let resolvedKey = ChannelKey(configHome: provisional.configHome, session: resolved)

        forkHandle.push(.sessionIdentityResolved(resolved, forkHandle.epoch))
        try await rig.waitUntil(fork, "the fork to be ready") { $0.origin == .owned(.ready) }

        let holdsResolved = await rig.fleet.isLive(resolvedKey)
        let holdsProvisional = await rig.fleet.isLive(provisional)
        XCTAssertTrue(holdsResolved)
        XCTAssertFalse(holdsProvisional, "the provisional key never held the live slot after the rekey")
        try await rig.drainPublished(of: fork)
        XCTAssertEqual(rig.published(of: fork).filter { $0.origin == .owned(.ready) }.count, 1)

        let before = await rig.fleet.occupancy
        await fork.reap()
        let after = await rig.fleet.occupancy
        XCTAssertEqual(after, before - 1, "the reap released the slot the rekey moved")

        let decision = await rig.fleet.acquire(for: ChannelKey(configHome: provisional.configHome,
                                                               session: SessionID()))
        guard case .granted = decision else { return XCTFail("the freed slot was not granted: \(decision)") }
    }

    // MARK: - What the resolved identity has to change

    /// Once a fork has learned its own id, every later launch of that channel resumes *it*. The template it was
    /// built with names the session it forked from and carries `--fork-session`, so a crash respawn from that
    /// template would mint a third session and leave the fork's own transcript behind.
    ///
    /// Scripted, not recorded: the crash, the backoff and the identity event are the test's.
    ///
    /// Deliberate break: drop the `launchTemplate.session` assignment from `resolveForkIdentity`.
    func testACrashAfterAForkResolvedItsIdentityResumesTheForksOwnSession() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let source = SessionID()
        let supervisor = rig.supervisor(session: source, origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let handle = try XCTUnwrap(rig.scriptedHandles.last)
        let resolved = SessionID()

        handle.push(.sessionIdentityResolved(resolved, handle.epoch))
        try await rig.waitUntil(fork, "the fork to be ready on its own id") { $0.origin == .owned(.ready) }

        let published = await fork.publishedCount
        handle.push(.exited(.code(1, stderrTail: ""), handle.epoch))
        try await rig.waitForPublish(fork, above: published)
        try await rig.waitForSleeper(due: .seconds(1))
        let thirdChild = rig.expectScriptedHandles(3, description: "the respawn launched its child")
        await rig.clock.advance(by: .seconds(1))
        try await TestTiming.awaitDelivery([thirdChild])
        guard rig.launches.count >= 3 else { return XCTFail("the respawn built no third child") }

        XCTAssertEqual(rig.launches[2].session, .resume(resolved, fork: false),
                       "the respawn resumes the fork's own session and forks nothing")
    }

    /// The identity check reads the pid and asks the ownership question, and the child can die in that window. The
    /// checks that follow are about a process that no longer exists: nothing may be published ready, and the
    /// reservation the fork was holding has to go back — `handleExit` cannot give it back, because the identity
    /// check took it out of `forkReservation` before its first await.
    ///
    /// Scripted, not recorded: an exit timed inside a post-handshake read is not something a recording can produce.
    ///
    /// Deliberate break: remove the `resolvedEpoch == epoch, process != nil` re-guard after the two awaits.
    func testAnExitDuringTheIdentityCheckPublishesNoReadyAndGivesTheSlotBack() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let occupiedBeforeTheFork = await rig.fleet.occupancy

        let held = HeldAnswer(), entered = HeldAnswer()
        let reachedPIDRead = entered.expectation(description: "the identity check reached the pid read")
        rig.configureScriptedHandles { handle in
            handle.pidGate = { entered.release(); await held.wait() }
        }
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let handle = try XCTUnwrap(rig.scriptedHandles.last)

        let resolutionFinished = expectation(description: "the identity handler completed its rollback")
        let resolving = Task {
            await fork.handle(event: .sessionIdentityResolved(SessionID(), handle.epoch))
            resolutionFinished.fulfill()
        }
        defer { held.release(); resolving.cancel() }
        try await TestTiming.awaitDelivery([reachedPIDRead])
        let published = await fork.publishedCount
        // Delivered on the actor: the identity handler is parked on the pid read, so an exit pushed onto the same
        // stream would queue behind the very handler it is meant to race.
        await fork.handle(event: .exited(.code(1, stderrTail: ""), handle.epoch))
        let afterTheExit = await fork.publishedCount
        XCTAssertGreaterThan(afterTheExit, published, "the exit was taken")
        held.release()

        try await TestTiming.awaitDelivery([resolutionFinished])
        await resolving.value
        let occupiedAfterRollback = await rig.fleet.occupancy
        XCTAssertEqual(occupiedAfterRollback, occupiedBeforeTheFork, "the fork's reservation went back")
        try await rig.drainPublished(of: fork)
        XCTAssertFalse(rig.published(of: fork).contains { $0.origin == .owned(.ready) },
                       "nothing is ready on a process that has already exited")
        let holdsProvisional = await rig.fleet.isLive(provisional)
        XCTAssertFalse(holdsProvisional, "and no live slot was confirmed under the provisional key")
    }

    /// An id announced by one child is that child's. A spawn parked past its own exit stashes the id it saw; the
    /// respawn behind it is a *different* engine with a *different* session, and consuming the stash there re-keys
    /// the channel onto an id nothing is running under.
    ///
    /// Scripted, not recorded: two children of one channel, the first parked inside its handshake.
    ///
    /// Deliberate break: store the stashed identity without its epoch and consume it unconditionally.
    func testAnIdentityStashedByOneEpochIsNotConsumedByTheNext() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let source = SessionID(), provisional = SessionID()
        let template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(source, fork: true))
        let held = HeldAnswer()
        rig.holdNextSpawn { await held.wait() }
        let fork = rig.supervisor(session: provisional, origin: .owned(.connecting), template: template)
        let firstChild = rig.expectScriptedHandles(1, description: "the fork built its first child")
        let spawning = Task { try await fork.spawn(reason: .open) }
        defer { held.release(); spawning.cancel() }
        try await TestTiming.awaitDelivery([firstChild])
        let first = try XCTUnwrap(rig.scriptedHandles.first)

        // Delivered on the actor rather than through the pump, so the order of the two events is the test's.
        let stale = SessionID()
        await fork.handle(event: .sessionIdentityResolved(stale, first.epoch))
        await fork.handle(event: .exited(.code(1, stderrTail: ""), first.epoch))
        held.release()
        _ = try? await spawning.value

        try await rig.waitForSleeper(due: .seconds(1))
        let secondChild = rig.expectScriptedHandles(2, description: "the respawn built its child")
        await rig.clock.advance(by: .seconds(1))
        try await TestTiming.awaitDelivery([secondChild])
        // The second child has announced nothing, so the fork is still waiting for an id and its deadline is armed.
        // Without the epoch beside the stash there is no deadline: the channel went ready on the dead child's id.
        try await rig.waitForSleeper(due: Self.handshakeTimeout)

        let state = await fork.state
        XCTAssertEqual(state.origin, .owned(.connecting), "the fork is still waiting for its own id")
        XCTAssertEqual(state.identity, .awaitingFork(from: source, provisional: provisional))
        XCTAssertNotEqual(fork.key.session, stale, "the id the dead child announced is not this child's")
    }

    // MARK: - Past the rekeyed slot

    /// The fork's finalisation has the same shape as the spawn's and one more thing to undo. `rekey` and `confirm`
    /// run after its last guard, and the reservation left `forkReservation` before the first await, so
    /// `handleExit`'s rollback finds nothing to give back: an exit in that window confirms a slot for a dead child
    /// under a key the fleet has just been told to use, and publishes `.ready` over no process.
    ///
    /// Scripted, not recorded: the rig parks the resolution on the far side of the counter's two turns, and the
    /// exit is delivered on the actor, so both the order and the window are the test's.
    ///
    /// Deliberate break: remove the `commitFinalisation` call from the end of `resolveForkIdentity`.
    func testAnExitPastTheForksRekeyedSlotPublishesNoReadyAndLeavesTheKeyAlone() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let occupiedBeforeTheFork = await rig.fleet.occupancy

        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let handle = try XCTUnwrap(rig.scriptedHandles.last)
        let resolved = SessionID()
        let resolvedKey = ChannelKey(configHome: provisional.configHome, session: resolved)

        // Set after the source's own spawn and the fork's: neither reaches the finalisation this parks at — a
        // fork's spawn returns at the awaiting-fork branch, before the counter turn.
        let held = HeldAnswer(), entered = HeldAnswer()
        let parkedAfterRekey = entered.expectation(description: "the identity resolution parked past the rekey")
        rig.onFinalising = { entered.release(); await held.wait() }
        let resolutionFinished = expectation(description: "the identity handler completed its rollback")
        let resolving = Task {
            await fork.handle(event: .sessionIdentityResolved(resolved, handle.epoch))
            resolutionFinished.fulfill()
        }
        defer { held.release(); resolving.cancel() }
        try await TestTiming.awaitDelivery([parkedAfterRekey])

        // Delivered on the actor: the identity handler is parked past the rekey, so an exit pushed onto the same
        // stream would queue behind the very handler it is meant to race.
        let published = await fork.publishedCount
        await fork.handle(event: .exited(.code(0, stderrTail: ""), handle.epoch))
        let afterTheExit = await fork.publishedCount
        XCTAssertGreaterThan(afterTheExit, published, "the exit was taken")
        held.release()

        try await TestTiming.awaitDelivery([resolutionFinished])
        await resolving.value
        let occupiedAfterRollback = await rig.fleet.occupancy
        XCTAssertEqual(occupiedAfterRollback, occupiedBeforeTheFork, "the fork's slot went back")
        let holdsResolved = await rig.fleet.isLive(resolvedKey)
        XCTAssertFalse(holdsResolved, "a slot confirmed under the resolved key of a dead child is never released")
        let holdsProvisional = await rig.fleet.isLive(provisional)
        XCTAssertFalse(holdsProvisional)
        try await rig.drainPublished(of: fork)
        XCTAssertFalse(rig.published(of: fork).contains { $0.origin == .owned(.ready) },
                       "nothing is ready over a process that has exited")
        XCTAssertTrue(fork.key == provisional, "the channel is keyed as it was; nothing was rewritten under it")
        let state = await fork.state
        XCTAssertEqual(state.origin, .archived, "a fork that never reached ready rests where its spawn found it")
    }

    /// Ruling 2 put the `inFlight` marker on every multi-await entry, and this is one: reached from the pump when
    /// the identity arrives after `open` has returned, `resolveForkIdentity` runs the ownership check, the rekey
    /// and the confirm across four awaits. Unmarked, the thirty-minute reap, the cap eviction, `/logout`'s
    /// terminate and the quiescent restart all pass their own `inFlight == nil` guards and run inside it — ending
    /// the child the resolution is about to publish ready.
    ///
    /// The reap is the marker's own witness: it refuses in silence, so what it did is visible only in the child.
    ///
    /// Deliberate break: drop the marker adoption from the top of `resolveForkIdentity`.
    func testAReapDuringTheForksIdentityResolutionIsRefused() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let handle = try XCTUnwrap(rig.scriptedHandles.last)
        let resolved = SessionID()
        let resolvedKey = ChannelKey(configHome: provisional.configHome, session: resolved)

        let held = HeldAnswer(), entered = HeldAnswer()
        let parkedAfterRekey = entered.expectation(description: "the identity resolution parked past the rekey")
        rig.onFinalising = { entered.release(); await held.wait() }
        handle.push(.sessionIdentityResolved(resolved, handle.epoch))
        try await TestTiming.awaitDelivery([parkedAfterRekey])

        await fork.reap()
        XCTAssertEqual(handle.terminateCount, 0, "a reap ran inside the fork's own resolution")
        held.release()

        try await rig.waitUntil(fork, "the fork to be ready") { $0.origin == .owned(.ready) }
        let holdsResolved = await rig.fleet.isLive(resolvedKey)
        XCTAssertTrue(holdsResolved, "the resolution finished on the slot it moved")
        XCTAssertTrue(fork.key == resolvedKey, "the fork did not end up on the resolved key")
    }
}
