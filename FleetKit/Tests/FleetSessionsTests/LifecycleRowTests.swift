import XCTest
import Darwin
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// One test per parent §7.4 row, and one declared scenario set per test. `coverage` maps every test method to the
/// `(row, from, event, to)` scenarios it drives; each test ends with `rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))`,
/// where `static func testID(_ function: String = #function) -> String` strips from the first `(`: Swift reports `testFoo()`,
/// the keys are bare names, and Task 12's parity gate matches the same bare names against the suite,
/// which compares the transitions the supervisor recorded on the diagnostics sink with the declared set (extra
/// transitions fail too). Task 12's `LifecycleCoverageTests` asserts that the union of the declared sets equals
/// `LifecycleTable.scenarios`, so a row, a from-state or an outcome added to the table without a test that drives it
/// fails the gate; until then each task's tests assert exactly the scenarios it has landed.
final class LifecycleRowTests: XCTestCase {
    typealias T = LifecycleTable.Transition
    static let coverage: [String: Set<T>] = [
        "testArchivedRecentOpenedSpawnsEagerly": [T(.archivedRecentOpened, .archivedRecent, .opened, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testArchivedOlderOpenedRendersHistoryOnly": [T(.archivedOlderOpened, .archivedOlder, .opened, .archivedOlder)],
        "testArchivedOlderSentSpawnsThenSends": [T(.archivedOlderSent, .archivedOlder, .userSent, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testConnectingBecomesReadyWhenThePostHandshakeCheckIsClean": [T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testConnectingYieldsWhenThePostHandshakeCheckFindsAForeignHolder": [T(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .foreignUsersTerminal)],
        "testTwoOwnProcessesOnOneSessionRefuseBeforeSpawnAndYieldAfterHandshake": [T(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .contended)],
        "testReadyReapsAfterThirtyMinutesEligibleAndNotWhileATaskRuns": [T(.readyDormantEligible, .ready, .dormantTimerFired, .dormant)],
        "testDormantSendResumesUnderTheSameSessionID": [T(.dormantSent, .dormant, .userSent, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testDormantBecomesForeignOrJobWhenAHolderAppears": [T(.dormantHolderAppeared, .dormant, .holderAppeared, .foreignUsersTerminal), T(.dormantHolderAppeared, .dormant, .holderAppeared, .backgroundJob)],
        "testNonZeroExitRespawnsWithBackoffThenOffersReopen": [
            T(.exitedNonZero, .ready, .exitedNonZero, .connecting), T(.exitedNonZero, .connecting, .exitedNonZero, .connecting),
            T(.exitedNonZero, .ready, .exitedNonZero, .ready), T(.exitedNonZero, .connecting, .exitedNonZero, .archivedOlder),
            T(.connectingClean, .connecting, .handshakeClean, .ready)],
        // Task 5 adds: terminateExhausted for reap, sendToBackground, openInTerminal and capEviction; capReached (the ready victim: the LRU test and the mid-eviction wedge);
        // jobAdopt; ownedSendToBackground (both); ownedOpenInTerminal (both); handoffPreempted (six: three holder kinds, from ready and from dormant, declared by both preempt tests); ownTabExited; foreignRecordGone;
        // foreignSendRefused; handoffTimedOut (four); desiredObservedDisagree (three); contendedSettled (five).
        // Task 6 adds terminateExhausted during restart (two); Task 8 adds terminateExhausted during logout (two).
    ]
    // Tasks 5, 6 and 8 add their test methods (Task 5 here, Tasks 6 and 8 in extension files) and their entries to this
    // literal; nothing is registered at runtime. Task 12's gate reads this dictionary.

    static func testID(_ function: String = #function) -> String { String(function.prefix { $0 != "(" }) }

    // MARK: - Harness

    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    private func newRig(sharing shared: RecordingDiagnostics? = nil) throws -> Rig {
        let rig = try Rig(sharing: shared)
        rigs.append(rig)
        return rig
    }

    /// The fixture whose replay stays alive after the handshake until the host asks it to stop.
    private static let idleFixture = "resume-no-replay"
    /// The fixture that waits for a user frame and replays a whole turn.
    private static let turnFixture = "plain-two-turn"

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Drives a channel to dormant: spawn, then the thirty-minute reap on the manual clock.
    private func makeDormant(_ rig: Rig, _ supervisor: ChannelSupervisor) async throws {
        try await supervisor.spawn(reason: .open)
        try await rig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        await rig.clock.advance(by: ChannelSupervisor.dormantAfter)
        try await rig.waitUntil(supervisor, "dormant") { $0.origin == .owned(.dormant) }
    }

    // MARK: - archivedRecentOpened

    func testArchivedRecentOpenedSpawnsEagerly() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, isRecent: true)

        try await supervisor.open()

        XCTAssertEqual(rig.reader.checkLabels, ["beforeSpawn", "afterHandshake"])
        XCTAssertEqual(rig.spawnCount, 1)
        let opened = await supervisor.state
        XCTAssertEqual(opened.origin, .owned(.ready))
        try await rig.drainPublished(of: supervisor)
        XCTAssertTrue(rig.published(of: supervisor).contains { $0.origin == .owned(.connecting) },
                      "the channel was published as connecting before it was published as ready")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - archivedOlderOpened

    func testArchivedOlderOpenedRendersHistoryOnly() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, isRecent: false)

        try await supervisor.open()

        XCTAssertEqual(rig.spawnCount, 0, "an older archived channel renders history and spawns nothing")
        XCTAssertTrue(rig.reader.checkLabels.isEmpty)
        let history = await supervisor.state
        XCTAssertEqual(history.origin, .archived)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - archivedOlderSent

    func testArchivedOlderSentSpawnsThenSends() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.turnFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.turnFixture, isRecent: false)
        let frames = FrameCollector(await supervisor.events())

        let uuid = try await supervisor.send(UserInput(text: "hi"))

        XCTAssertEqual(rig.spawnCount, 1)
        let sent = await supervisor.state
        XCTAssertEqual(sent.origin, .owned(.ready))
        XCTAssertNotEqual(uuid, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        try await frames.waitForResult()
        XCTAssertTrue(frames.sawUserFrame, "the engine replayed the user frame this send produced")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - connectingClean

    func testConnectingBecomesReadyWhenThePostHandshakeCheckIsClean() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))

        try await supervisor.spawn(reason: .open)

        let childPID = await rig.liveHandles.last!.childProcessIdentifier
        XCTAssertEqual(rig.reader.checkLabels, ["beforeSpawn", "afterHandshake"])
        let afterHandshake = rig.reader.calls.first { $0.label == "afterHandshake" }
        XCTAssertEqual(afterHandshake?.ownPIDs, [childPID],
                       "the post-handshake read ran while the only pid of ours was the child this spawn started")
        let clean = await supervisor.state
        XCTAssertEqual(clean.origin, .owned(.ready))
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - connectingFoundHolder, the foreign half

    func testConnectingYieldsWhenThePostHandshakeCheckFindsAForeignHolder() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))

        // The record appears between the two checks: the pre-spawn read is clean and the post-handshake read is not.
        let files = rig.files
        let foreign = ScriptedHolderFiles.livePID
        rig.reader.onLabel("beforeSpawn") {
            try? files.writeRegistry(pid: foreign, sessionID: session, kind: "interactive", entrypoint: "cli")
        }

        try await supervisor.spawn(reason: .open)

        let childPID = await rig.liveHandles.last!.childProcessIdentifier
        let yielded = await supervisor.state
        XCTAssertEqual(yielded.origin, .foreignLive(.usersTerminal))
        XCTAssertEqual(yielded.banner, .releasedToTerminal)
        XCTAssertEqual(yielded.desired, .owned)
        XCTAssertFalse(isAlive(childPID), "our own process was terminated when the check found another holder")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - connectingFoundHolder, the own-pid half

    func testTwoOwnProcessesOnOneSessionRefuseBeforeSpawnAndYieldAfterHandshake() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)

        // A owns the session. Its own transitions are two other tests' rows, so A records none of them here.
        let a = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting),
                               records: false)
        try await a.spawn(reason: .open)
        let aPID = await rig.liveHandles.last!.childProcessIdentifier
        try rig.files.writeRegistry(pid: aPID, sessionID: session, kind: "interactive", entrypoint: "sdk-cli")
        try await rig.drainPublished(of: a)
        let aPublished = await a.publishedCount
        XCTAssertEqual(rig.published(of: a).count, aPublished)

        // First half: B's pre-spawn check sees a pid that is ours, and refuses. Nothing spawns.
        let b = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        var refusal: (any Error)?
        do { try await b.spawn(reason: .open) } catch { refusal = error }
        guard case .heldElsewhere? = refusal as? LifecycleError else {
            return XCTFail("the pre-spawn check refused with \(String(describing: refusal))")
        }
        XCTAssertEqual(rig.spawnCount, 1, "no second process was built")
        let refused = await b.state
        XCTAssertEqual(refused.origin, .owned(.contended))
        guard case .contended(let set)? = refused.banner else { return XCTFail("no contended banner") }
        XCTAssertEqual(set.holders.map(\.pid), [aPID])
        XCTAssertTrue(set.holders.allSatisfy(\.isOwnChild))

        // Second half, the race: the pre-spawn read misses A once, so B2 spawns; the post-handshake read excludes
        // exactly B2's own child, so A's pid is a holder and B2 yields.
        let b2 = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        rig.reader.hide(pid: aPID, forLabel: "beforeSpawn")
        try await b2.spawn(reason: .open)

        let b2PID = await rig.liveHandles.last!.childProcessIdentifier
        XCTAssertEqual(rig.spawnCount, 2)
        XCTAssertNotEqual(b2PID, aPID)
        let yielded = await b2.state
        XCTAssertEqual(yielded.origin, .owned(.contended))
        XCTAssertFalse(isAlive(b2PID), "the second of our own processes was terminated")
        XCTAssertTrue(isAlive(aPID), "A keeps the session")
        let aState = await a.state
        XCTAssertEqual(aState.origin, .owned(.ready))
        try await rig.drainPublished(of: a)
        let aPublishedAfter = await a.publishedCount
        XCTAssertEqual(aPublishedAfter, aPublished, "A published nothing while B contended for its session")
        XCTAssertEqual(rig.published(of: a).count, aPublished)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - readyDormantEligible

    func testReadyReapsAfterThirtyMinutesEligibleAndNotWhileATaskRuns() async throws {
        // Two channels, so the two halves are one clock advance apart rather than one test apart. They sit in two
        // rigs because two channels under one config home would need two session ids, and the fixture's own id is
        // what makes its `auth_status` match.
        let eligibleRig = try newRig()
        let blockedRig = try newRig(sharing: eligibleRig.diagnostics)
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)

        let eligible = eligibleRig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        let box = EligibilityBox()
        box.mirror = [MirrorEntryStandIn(taskID: "t-1", isRunning: true, isBackground: true)]
        let blocked = blockedRig.supervisor(session: session, fixture: Self.idleFixture,
                                            origin: .owned(.connecting), eligibility: box)
        try await eligible.spawn(reason: .open)
        try await blocked.spawn(reason: .open)
        let blockedPID = await blockedRig.liveHandles.last!.childProcessIdentifier
        eligibleRig.forgetTransitions()   // arranging both channels is other rows' work

        try await eligibleRig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        try await blockedRig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        await eligibleRig.clock.advance(by: .seconds(29 * 60))
        await blockedRig.clock.advance(by: .seconds(29 * 60))
        let atTwentyNine = await eligible.state
        XCTAssertEqual(atTwentyNine.origin, .owned(.ready), "29 minutes is not 30")

        await eligibleRig.clock.advance(by: .seconds(60))
        await blockedRig.clock.advance(by: .seconds(60))
        try await eligibleRig.waitUntil(eligible, "the reap") { $0.origin == .owned(.dormant) }

        // The blocked half re-arms instead of reaping, so its process is still there a whole timer later.
        try await blockedRig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        let blockedState = await blocked.state
        XCTAssertEqual(blockedState.origin, .owned(.ready))
        XCTAssertTrue(isAlive(blockedPID), "a channel with a running task is not reaped")
        await blocked.drainEligibility()
        let verdict = await blockedRig.fleet.verdict(of: blocked.key)
        XCTAssertEqual(verdict, .blocked(.taskRunning("t-1")))
        eligibleRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - dormantSent

    func testDormantSendResumesUnderTheSameSessionID() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.turnFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.turnFixture, origin: .owned(.connecting))
        try await makeDormant(rig, supervisor)
        rig.forgetTransitions()

        let frames = FrameCollector(await supervisor.events())
        try await rig.drainPublished(of: supervisor)
        let publishedBefore = rig.published(of: supervisor).count
        let labelsBefore = rig.reader.checkLabels.count

        _ = try await supervisor.send(UserInput(text: "hi"))

        let resumed = await supervisor.state
        XCTAssertEqual(resumed.origin, .owned(.ready))
        XCTAssertEqual(Array(rig.reader.checkLabels.dropFirst(labelsBefore)), ["beforeSpawn", "afterHandshake"])
        XCTAssertEqual(rig.launches.count, 2)
        guard case .resume(let id, let fork) = rig.launches[1].session else {
            return XCTFail("the resume launch did not name a session")
        }
        XCTAssertEqual(id, session, "the same session id, not a new one")
        XCTAssertFalse(fork)
        XCTAssertEqual(resumed.epoch, ProcessEpoch(rawValue: 2), "the next epoch, never the old one")
        try await rig.drainPublished(of: supervisor)
        let connecting = rig.published(of: supervisor).dropFirst(publishedBefore)
            .filter { $0.origin == .owned(.connecting) }
        XCTAssertEqual(connecting.count, 1, "one connecting glyph")
        try await frames.waitForResult()
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - dormantHolderAppeared

    func testDormantBecomesForeignOrJobWhenAHolderAppears() async throws {
        let foreignRig = try newRig()
        let jobRig = try newRig(sharing: foreignRig.diagnostics)
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)

        let foreignSide = foreignRig.supervisor(session: session, fixture: Self.idleFixture,
                                                origin: .owned(.connecting))
        let jobSide = jobRig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        try await makeDormant(foreignRig, foreignSide)
        try await makeDormant(jobRig, jobSide)
        foreignRig.forgetTransitions()

        try foreignRig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                           kind: "interactive", entrypoint: "cli")
        try jobRig.files.writeJob(short: "j0001", state: "working", sessionID: session, resumeSessionID: session,
                                  pid: ScriptedHolderFiles.livePID)

        await foreignRig.startObserver()
        await jobRig.startObserver()

        try await foreignRig.waitUntil(foreignSide, "the foreign origin") { $0.origin == .foreignLive(.usersTerminal) }
        try await jobRig.waitUntil(jobSide, "the job origin") { $0.origin == .backgroundJob }
        foreignRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - exitedNonZero

    func testNonZeroExitRespawnsWithBackoffThenOffersReopen() async throws {
        // Half one: a channel that reaches ready between crashes. Half two: a launch that never gets that far, which
        // is what distinguishes the fourth crash of a channel that had been ready from one that never was.
        let readyRig = try newRig()
        let neverReadyRig = try newRig(sharing: readyRig.diagnostics)
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)

        let ready = readyRig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        try await ready.spawn(reason: .open)
        for backoff in ChannelSupervisor.backoffs {
            let pid = await readyRig.liveHandles.last!.childProcessIdentifier
            XCTAssertEqual(kill(pid, SIGKILL), 0)
            try await readyRig.waitForSleeper(due: backoff)
            await readyRig.clock.advance(by: backoff)
            try await readyRig.waitUntil(ready, "the respawn") { $0.origin == .owned(.ready) && $0.systemItem == nil }
        }
        let lastPID = await readyRig.liveHandles.last!.childProcessIdentifier
        XCTAssertEqual(kill(lastPID, SIGKILL), 0)
        try await readyRig.waitUntil(ready, "the crashed item") { $0.systemItem != nil }

        XCTAssertEqual(readyRig.backoffSleeps, ChannelSupervisor.backoffs)
        XCTAssertEqual(readyRig.spawnCount, 4, "three respawns and no fourth")
        XCTAssertEqual(readyRig.reader.checkLabels.filter { $0 == "beforeSpawn" }.count, 4,
                       "every respawn ran behind the pre-spawn check")
        let crashed = await ready.state
        XCTAssertEqual(crashed.origin, .owned(.ready))
        guard case .crashed(let exit, let reopenOffered)? = crashed.systemItem else {
            return XCTFail("no crashed system item")
        }
        XCTAssertTrue(reopenOffered)
        guard case .signal(9, _) = exit else { return XCTFail("the item did not carry the signal that killed it") }

        // Half two: every launch exits non-zero before the handshake, so the series never leaves connecting.
        let neverReady = neverReadyRig.supervisor(session: session, fixture: Self.idleFixture,
                                                  origin: .owned(.connecting), dropFixture: true)
        try? await neverReady.spawn(reason: .open)
        for backoff in ChannelSupervisor.backoffs {
            try await neverReadyRig.waitForSleeper(due: backoff)
            await neverReadyRig.clock.advance(by: backoff)
            try await neverReadyRig.waitUntil(neverReady, "the next failure") {
                $0.epoch.map { $0.rawValue } ?? 0 >= UInt64(neverReadyRig.spawnCount)
            }
        }
        try await neverReadyRig.waitUntil(neverReady, "the archived outcome") { $0.origin == .archived }
        XCTAssertEqual(neverReadyRig.backoffSleeps, ChannelSupervisor.backoffs)
        XCTAssertEqual(neverReadyRig.spawnCount, 4)
        let archivedState = await neverReady.state
        guard case .crashed? = archivedState.systemItem else { return XCTFail("no crashed system item") }

        readyRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - Not a §7.4 row: the exit that follows a deliberate termination

    /// `ClaudeProcess` settles the exit waiter that `terminate()` blocks on before it pushes the `.exited` event —
    /// `ClaudeProcess.swift:431` and `:450`, either side of a reader drain bounded at two seconds — so the event a
    /// supervisor's pump sees normally arrives *after* its own `terminate()` has already returned. An escalation that
    /// reached SIGTERM or SIGKILL never produces `.code(0)`, so suppressing "our own termination" with anything
    /// narrower than the epoch reads that exit as a crash and respawns a channel the user deliberately reaped.
    ///
    /// This drives the scripted handle because that is the only way to produce the ordering: `fake-claude` answers
    /// `end_session` and exits zero, so the reap path in every other test only ever produces a clean exit. It
    /// declares no scenarios and belongs to no row — the claim is that the reap produces exactly one transition and
    /// the exit that follows it produces none at all.
    func testTheExitThatFollowsADeliberateTerminationIsNotACrash() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: .signal(9, stderrTail: ""),
                                                                  steps: ["SIGTERM", "SIGKILL"]))
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let handle = rig.scriptedHandles[0]
        rig.forgetTransitions()

        await supervisor.reap()
        let reaped = await supervisor.state
        XCTAssertEqual(reaped.origin, .owned(.dormant))
        let publishedAfterReap = await supervisor.publishedCount

        // The escalation's own exit, arriving after `terminate()` returned, exactly as ClaudeWire orders it.
        handle.push(.exited(.signal(9, stderrTail: ""), handle.epoch))
        handle.finish()
        try await rig.waitForPublish(supervisor, above: publishedAfterReap)

        let settled = await supervisor.state
        XCTAssertEqual(settled.origin, .owned(.dormant), "a reaped channel stays reaped")
        XCTAssertNil(settled.systemItem, "a deliberate termination is not a crash the user is offered a Reopen for")
        XCTAssertEqual(rig.spawnCount, 1, "no replacement child was built")
        XCTAssertEqual(rig.clock.sleeperCount(due: ChannelSupervisor.backoffs[0]), 0, "no backoff was armed")
        rig.assertObserved([T(.readyDormantEligible, .ready, .dormantTimerFired, .dormant)])
    }

    /// `rekey` rewrites the *stored* reservation when a fork learns its own session id, so `confirm` has to read the
    /// key back out of the counter rather than off the caller's copy — which is still the provisional one. Task 6
    /// forks; the counter is this task's, so the guarantee is pinned here.
    func testAReservationConfirmedAfterARekeyTakesTheResolvedKey() async throws {
        let rig = try newRig()
        let provisional = ChannelKey(configHome: rig.home.url, session: SessionID())
        let resolved = ChannelKey(configHome: rig.home.url, session: SessionID())

        guard case .granted(let reservation) = await rig.fleet.acquire(for: provisional) else {
            return XCTFail("an empty counter refused a reservation")
        }
        await rig.fleet.rekey(provisional, to: resolved)
        await rig.fleet.confirm(reservation)

        let underResolved = await rig.fleet.isLive(resolved)
        let underProvisional = await rig.fleet.isLive(provisional)
        XCTAssertTrue(underResolved, "the slot is held under the id the engine resolved")
        XCTAssertFalse(underProvisional, "nothing would ever release a slot held under the provisional key")

        await rig.fleet.release(resolved)
        let remaining = await rig.fleet.liveCount
        XCTAssertEqual(remaining, 0, "the channel's own release frees the slot")
    }
}

/// Collects the engine frames one channel produced, for the rows that assert a send was delivered.
private final class FrameCollector: Sendable {
    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<WireEvent>) {
        let box = self.box
        task = Task {
            for await event in stream {
                guard case .frame(let frame, _) = event else { continue }
                box.note(frame)
            }
        }
    }

    final class Box: @unchecked Sendable {   // `lock` serialises both fields
        private let lock = NSLock()
        private var _result = false
        private var _user = false
        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
        func note(_ frame: Frame) {
            switch frame {
            case .result: locked { _result = true }
            case .user: locked { _user = true }
            default: break
            }
        }
        var result: Bool { locked { _result } }
        var user: Bool { locked { _user } }
    }

    var sawUserFrame: Bool { box.user }

    func waitForResult(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if box.result { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the turn never produced a result frame", file: file, line: line)
    }
}
