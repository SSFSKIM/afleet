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
        "testArchivedBecomesForeignOrJobWhenAHolderAppears": [
            T(.dormantHolderAppeared, .archivedRecent, .holderAppeared, .foreignUsersTerminal),
            T(.dormantHolderAppeared, .archivedRecent, .holderAppeared, .backgroundJob),
            T(.dormantHolderAppeared, .archivedOlder, .holderAppeared, .foreignUsersTerminal),
            T(.dormantHolderAppeared, .archivedOlder, .holderAppeared, .backgroundJob)],
        "testNonZeroExitRespawnsWithBackoffThenOffersReopen": [
            T(.exitedNonZero, .ready, .exitedNonZero, .connecting), T(.exitedNonZero, .connecting, .exitedNonZero, .connecting),
            T(.exitedNonZero, .ready, .exitedNonZero, .ready), T(.exitedNonZero, .connecting, .exitedNonZero, .archivedOlder),
            T(.connectingClean, .connecting, .handshakeClean, .ready)],
        // Task 5's rows.
        "testTerminateReturningNilMarksTheChannelWedgedAndReopenWaitsForNoHolder": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .reap), .wedged),
            // *Reopen* clears the trace first, so what the user asked for is the ordinary dormant resume: the table
            // has no transition out of `wedged` and none is invented.
            T(.dormantSent, .dormant, .userSent, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testTerminateReturningNilDuringSendToBackgroundRunsNoVerb": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .sendToBackground), .wedged)],
        "testTerminateReturningNilDuringOpenInTerminalReturnsNoPaneRequest": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .openInTerminal), .wedged)],
        "testTerminateReturningNilOnThePostHandshakeYieldMarksTheChannelWedged": [
            T(.terminateExhausted, .connecting, .terminateReturnedNil(during: .postHandshakeYield), .wedged)],
        "testAVictimThatWedgesMidEvictionFreesNoSlot": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .capEviction), .wedged),
            T(.capReached, .ready, .seventhSpawnNeeded, .dormant), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testCapEvictsTheLeastRecentlyUsedEligibleChannelAndRefusesWhenNoneIsEligible": [
            T(.capReached, .ready, .seventhSpawnNeeded, .dormant), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testTwoConcurrentOpensAtTheCapTakeDistinctVictimsOrOneIsRefused": [
            T(.capReached, .ready, .seventhSpawnNeeded, .dormant), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testAReleaseArrivingWhileTheVictimIsPendingCompletesTheEvictionAndNeverFreesASeventhSlot": [
            T(.capReached, .ready, .seventhSpawnNeeded, .dormant), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testAdoptStopsTheJobWaitsForRosterRemovalThenResumes": [
            T(.jobAdopt, .backgroundJob, .adopt, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testAStaleRecordSeenDuringAHandoffDoesNotTurnTheChannelContended": [
            T(.ownedSendToBackground, .ready, .sendToBackground, .backgroundJob)],
        "testSendToBackgroundTerminatesWaitsForRegistryRemovalThenStartsAJob": [
            T(.ownedSendToBackground, .ready, .sendToBackground, .backgroundJob),
            T(.ownedSendToBackground, .dormant, .sendToBackground, .backgroundJob)],
        "testOpenInTerminalReturnsAHatchPaneRequestUnderTheSameConfigHome": [
            T(.ownedOpenInTerminal, .ready, .openInTerminal, .foreignOwnTab),
            T(.ownedOpenInTerminal, .dormant, .openInTerminal, .foreignOwnTab),
            // The second request is compared after a real re-adoption, which is that row's transition.
            T(.ownTabExited, .foreignOwnTab, .paneExitedAndRecordGone, .connecting),
            T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testAHolderAppearingAfterReleaseAndBeforeLaunchPreemptsSendToBackground": LifecycleRowTests.preemptScenarios,
        "testAHolderAppearingAfterReleaseAndBeforeLaunchPreemptsOpenInTerminal": LifecycleRowTests.preemptScenarios,
        "testPaneExitReAdoptsWhenTheRecordIsGone": [
            T(.ownTabExited, .foreignOwnTab, .paneExitedAndRecordGone, .connecting),
            T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testAStaleExitFromAnIdenticalOlderHatchIsDiscardedByID": [
            T(.ownTabExited, .foreignOwnTab, .paneExitedAndRecordGone, .connecting),
            T(.connectingClean, .connecting, .handshakeClean, .ready),
            // The closing check hatches once more to show a value-equal request with a fresh id never matches.
            T(.ownedOpenInTerminal, .ready, .openInTerminal, .foreignOwnTab)],
        "testForeignRecordDisappearingArchivesTheChannel": [
            T(.foreignRecordGone, .foreignUsersTerminal, .recordDisappeared, .archivedRecent)],
        "testSendOnAForeignSessionIsRefusedWithForkOffered": [
            T(.foreignSendRefused, .foreignUsersTerminal, .sendRefused, .foreignUsersTerminal)],
        "testHandoffTimeoutEntersContendedFromEveryHandoff": [
            T(.handoffTimedOut, .backgroundJob, .handoffTimedOut, .contended),
            T(.handoffTimedOut, .ready, .handoffTimedOut, .contended),
            T(.handoffTimedOut, .dormant, .handoffTimedOut, .contended),
            T(.handoffTimedOut, .foreignOwnTab, .handoffTimedOut, .contended)],
        "testDesiredOwnedWithAForeignHolderIsContendedFromEveryOwnedState": [
            T(.desiredObservedDisagree, .connecting, .desiredObservedDisagree, .contended),
            T(.desiredObservedDisagree, .ready, .desiredObservedDisagree, .contended),
            T(.desiredObservedDisagree, .dormant, .desiredObservedDisagree, .contended)],
        "testContendedSettlingToNobodyLeavesAnOlderChannelOlder": [
            T(.contendedSettled, .contended, .holdersSettled, .archivedOlder),
            T(.archivedOlderOpened, .archivedOlder, .opened, .archivedOlder)],
        "testContendedResolvesWhenHoldersSettle": [
            T(.contendedSettled, .contended, .holdersSettled, .archivedRecent),
            T(.contendedSettled, .contended, .holdersSettled, .ready),
            T(.contendedSettled, .contended, .holdersSettled, .dormant),
            T(.contendedSettled, .contended, .holdersSettled, .foreignUsersTerminal),
            T(.contendedSettled, .contended, .holdersSettled, .backgroundJob)],
        // Task 6's rows (the test lives in `LifecycleRowTests+Restart.swift`).
        "testTerminateReturningNilDuringRestartSpawnsNothing": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .restart), .wedged),
            T(.terminateExhausted, .connecting, .terminateReturnedNil(during: .restart), .wedged)],
        // Task 8's rows (the test lives in `LifecycleRowTests+Logout.swift`). The two `/logout` scenarios, plus the
        // ordinary reap the channel that *did* go takes: a terminate with no replacement is a reap, and the plan
        // invents no transition of its own.
        "testTerminateReturningNilDuringLogoutRunsNoAuthLogout": [
            T(.terminateExhausted, .ready, .terminateReturnedNil(during: .logout), .wedged),
            T(.terminateExhausted, .connecting, .terminateReturnedNil(during: .logout), .wedged),
            T(.readyDormantEligible, .ready, .dormantTimerFired, .dormant)],
    ]

    /// The six `handoffPreempted` scenarios: three holder kinds, from ready and from dormant. Both preempt tests
    /// drive all six, so both declare the same set.
    static let preemptScenarios: Set<T> = [
        T(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .foreignUsersTerminal),
        T(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .backgroundJob),
        T(.handoffPreempted, .ready, .holderAppearedBeforeLaunch, .contended),
        T(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .foreignUsersTerminal),
        T(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .backgroundJob),
        T(.handoffPreempted, .dormant, .holderAppearedBeforeLaunch, .contended),
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

    /// The same row from the two archived states, which is where a channel a shell registered from C3's index
    /// actually sits: it has never been opened, so it has never been dormant, and until this landed a live foreign
    /// holder against its session left it archived forever. G5's foreign-session scenario is the live half of this;
    /// this half needs no CLI and no account.
    ///
    /// Deliberate break: narrow the guard in `holdersChanged` back to `here == .dormant` → all four waits time out.
    func testArchivedBecomesForeignOrJobWhenAHolderAppears() async throws {
        let recentForeign = try newRig()
        let recentJob = try newRig(sharing: recentForeign.diagnostics)
        let olderForeign = try newRig(sharing: recentForeign.diagnostics)
        let olderJob = try newRig(sharing: recentForeign.diagnostics)
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)

        // Never opened: `origin: .archived` with no spawn, which is exactly what `Fleet.register` leaves behind.
        let sides = [(recentForeign, true, false), (recentJob, true, true),
                     (olderForeign, false, false), (olderJob, false, true)]
        var supervisors: [ChannelSupervisor] = []
        for (rig, isRecent, isJob) in sides {
            supervisors.append(rig.supervisor(session: session, fixture: Self.idleFixture, isRecent: isRecent))
            if isJob {
                try rig.files.writeJob(short: "j0001", state: "working", sessionID: session,
                                       resumeSessionID: session, pid: ScriptedHolderFiles.livePID)
            } else {
                try rig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                            kind: "interactive", entrypoint: "cli")
            }
            await rig.startObserver()
        }

        for (index, (rig, isRecent, isJob)) in sides.enumerated() {
            let expected: ChannelOrigin = isJob ? .backgroundJob : .foreignLive(.usersTerminal)
            let label = "\(isRecent ? "archivedRecent" : "archivedOlder") → \(isJob ? "backgroundJob" : "foreignUsersTerminal")"
            try await rig.waitUntil(supervisors[index], label) { $0.origin == expected }
        }
        recentForeign.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
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

    // MARK: - terminateExhausted: the wedged rows

    /// ClaudeProcess's own escalation vocabulary (`ClaudeProcess.swift:511-582`); the full set also has
    /// `never_launched` and `no_live_child_to_signal`.
    static let wedgedSteps = ["graceful_phase_deadline_exceeded", "end_session", "stdin_close_requested",
                              "SIGTERM", "SIGKILL", "exit_not_observed"]
    private static var wedgingReport: TerminationReport {
        TerminationReport(exit: nil, steps: LifecycleRowTests.wedgedSteps)
    }

    /// Drives a scripted channel to ready. Every wedged row runs against a scripted handle because SIGKILL cannot be
    /// refused: no real child can produce a `terminate()` that answers no exit (C2 recorded the same limit).
    @discardableResult
    private func readyScripted(_ rig: Rig, session: SessionID = SessionID(),
                               eligibility: EligibilityBox = EligibilityBox(),
                               desired: DesiredOwnership = .none) async throws -> ChannelSupervisor {
        let supervisor = rig.supervisor(session: session, origin: .owned(.connecting), desired: desired,
                                        eligibility: eligibility)
        try await supervisor.spawn(reason: .open)
        return supervisor
    }

    /// The reap's `nil` exit: the channel is wedged, keeps its slot, refuses a send, and *Reopen* spawns only once
    /// the pre-spawn check finds nobody holding the session.
    func testTerminateReturningNilMarksTheChannelWedgedAndReopenWaitsForNoHolder() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: Self.wedgingReport)
        let session = SessionID()
        let supervisor = try await readyScripted(rig, session: session)
        let handle = rig.scriptedHandles[0]
        rig.forgetTransitions()

        await supervisor.reap()

        let wedged = await supervisor.state
        XCTAssertEqual(wedged.origin, .owned(.dormant))
        XCTAssertEqual(wedged.wedged?.steps, Self.wedgedSteps, "the report's steps, in order and entire")
        XCTAssertEqual(wedged.wedged?.pid, handle.pid)
        XCTAssertEqual(wedged.wedged?.epoch, handle.epoch)
        guard case .wedged(_, let reopenOffered)? = wedged.systemItem else { return XCTFail("no wedged item") }
        XCTAssertTrue(reopenOffered)
        let counted = await rig.fleet.liveCount
        XCTAssertEqual(counted, 1, "the ghost still costs a slot")
        await supervisor.drainEligibility()
        let verdict = await rig.fleet.verdict(of: supervisor.key)
        XCTAssertEqual(verdict, .blocked(.wedged))

        var sendError: (any Error)?
        do { _ = try await supervisor.send(UserInput(text: "hi")) } catch { sendError = error }
        guard case .wedged? = sendError as? LifecycleError else {
            return XCTFail("a send on a wedged channel gave \(String(describing: sendError))")
        }
        XCTAssertEqual(rig.spawnCount, 1, "no respawn under a session id a ghost may still hold")

        // Reopen while somebody holds it: nothing spawns and nothing changes but the banner.
        try rig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                    kind: "interactive", entrypoint: "cli")
        var reopenError: (any Error)?
        do { try await supervisor.reopen() } catch { reopenError = error }
        guard case .heldElsewhere? = reopenError as? LifecycleError else {
            return XCTFail("reopen against a holder gave \(String(describing: reopenError))")
        }
        XCTAssertEqual(rig.spawnCount, 1)
        let held = await supervisor.state
        XCTAssertNotNil(held.wedged, "the trace is still the channel's situation")

        // Reopen with nobody holding it: the trace clears and the channel resumes.
        rig.files.removeRegistry(pid: ScriptedHolderFiles.livePID)
        try await supervisor.reopen()
        XCTAssertEqual(rig.spawnCount, 2)
        let reopened = await supervisor.state
        XCTAssertNil(reopened.wedged)
        XCTAssertNil(reopened.systemItem)
        XCTAssertEqual(reopened.origin, .owned(.ready))
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The send-to-background handoff stops at the `nil`: no `--bg --resume`, no stored short.
    func testTerminateReturningNilDuringSendToBackgroundRunsNoVerb() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: Self.wedgingReport)
        let supervisor = try await readyScripted(rig)
        rig.forgetTransitions()

        var thrown: (any Error)?
        do { _ = try await supervisor.sendToBackground() } catch { thrown = error }
        guard case .wedged(let trace)? = thrown as? LifecycleError else {
            return XCTFail("send to background gave \(String(describing: thrown))")
        }
        XCTAssertEqual(trace.steps, Self.wedgedSteps)
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["--bg"]), 0, "no verb ran")
        let shorts = try await rig.store.read([String].self, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        XCTAssertNil(shorts, "nothing was recorded as a job of ours")
        let state = await supervisor.state
        XCTAssertEqual(state.wedged?.steps, Self.wedgedSteps)
        XCTAssertEqual(state.origin, .owned(.dormant))
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The hatch stops at the `nil`: no `PaneRequest` is returned for a process that would still be alive.
    func testTerminateReturningNilDuringOpenInTerminalReturnsNoPaneRequest() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: Self.wedgingReport)
        let supervisor = try await readyScripted(rig)
        rig.forgetTransitions()

        var thrown: (any Error)?
        do { _ = try await supervisor.openInTerminal() } catch { thrown = error }
        guard case .wedged(let trace)? = thrown as? LifecycleError else {
            return XCTFail("open in terminal gave \(String(describing: thrown))")
        }
        XCTAssertEqual(trace.steps, Self.wedgedSteps)
        XCTAssertEqual(rig.diagnostics.paneRequests.count, 0, "no pane request was even recorded")
        let pending = await supervisor.pendingPaneRequest
        XCTAssertNil(pending)
        let state = await supervisor.state
        XCTAssertEqual(state.wedged?.steps, Self.wedgedSteps)
        XCTAssertEqual(state.origin, .owned(.dormant))
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The post-handshake yield is a terminating action like any other. The parent's wedged row is "Owned, any", and
    /// Owned-connecting is one of the states "any" admits, so a yield whose `terminate()` answers no exit wedges the
    /// channel through the table — before the contended/foreign branch, which is why it is one scenario and not two.
    func testTerminateReturningNilOnThePostHandshakeYieldMarksTheChannelWedged() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: Self.wedgingReport)
        let session = SessionID()
        let supervisor = rig.supervisor(session: session, origin: .owned(.connecting))

        // Clean before the spawn, held after it: the record appears between the two checks.
        let files = rig.files
        rig.reader.onLabel(OwnershipLabel.beforeSpawn) {
            try? files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                     kind: "interactive", entrypoint: "cli")
        }

        try await supervisor.spawn(reason: .open)

        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.dormant), "wedged is an owned-dormant carrying a trace")
        XCTAssertEqual(state.wedged?.steps, Self.wedgedSteps)
        XCTAssertNotEqual(state.banner, .releasedToTerminal,
                          "nothing was released: our own ghost is still holding the session")
        if case .contended? = state.banner { XCTFail("the yield wedged before it could classify the holder") }
        let occupied = await rig.fleet.occupiedCount
        XCTAssertEqual(occupied, 1, "the reservation rolled back; only the ghost's slot is held")
        let counted = await rig.fleet.liveCount
        XCTAssertEqual(counted, 1, "fleet.markWedged kept the count")
        XCTAssertEqual(rig.diagnostics.wedged.count, 1)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - capReached

    /// The cap's actual safety property, asserted at **every** decision from the three numbers each one carries.
    ///
    /// `live` is every slot holding a process — a live channel, a ghost, or a victim whose eviction has not
    /// completed — `reserved` is every claim on a slot, and `pendingEvictions` is how many of the holding slots are
    /// victims. Each victim is the slot one reservation is waiting for, because the incoming process replaces it
    /// rather than joining it, so the occupancy is `live + reserved - pendingEvictions` and it may never exceed six.
    /// No exception per decision kind: a grant, an eviction and a refusal are all bound by the same number, which is
    /// the one `pick` tests. A counter that granted while holding four live channels and three unbacked
    /// reservations breaks this and satisfies any assertion made on `live` alone.
    private func assertNoDecisionOverGranted(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        for decision in rig.diagnostics.capDecisions {
            let occupancy = decision.live + decision.reserved - decision.pendingEvictions
            XCTAssertLessThanOrEqual(occupancy, FleetCapCounter.capacity,
                                     "a \(decision.decision) decision was taken against \(decision.live) holding "
                                     + "slots, \(decision.reserved) reservations and \(decision.pendingEvictions) "
                                     + "pending evictions", file: file, line: line)
            XCTAssertLessThanOrEqual(decision.pendingEvictions, decision.reserved,
                                     "a pending eviction with no reservation waiting on it", file: file, line: line)
        }
        XCTAssertFalse(rig.diagnostics.capDecisions.isEmpty, "no cap decision was recorded at all",
                       file: file, line: line)
    }

    /// Six ready channels on scripted handles, with one channel's box so a test can make it ineligible.
    private func sixReady(_ rig: Rig) async throws -> (supervisors: [ChannelSupervisor], boxes: [EligibilityBox]) {
        var boxes: [EligibilityBox] = []
        var supervisors: [ChannelSupervisor] = []
        for _ in 0..<6 {
            let box = EligibilityBox()
            boxes.append(box)
            supervisors.append(try await readyScripted(rig, eligibility: box))
        }
        return (supervisors, boxes)
    }

    private func makeIneligible(_ supervisor: ChannelSupervisor, _ box: EligibilityBox, _ name: String) async {
        box.mirror = [MirrorEntryStandIn(taskID: name, isRunning: true, isBackground: true)]
        await supervisor.mirrorChanged()
    }

    private func makeEligible(_ supervisor: ChannelSupervisor, _ box: EligibilityBox) async {
        box.mirror = []
        await supervisor.mirrorChanged()
    }

    /// Recency is driven through the supervisors and never by assigning a value: channel 3 is busy first and then
    /// nothing more reaches it, so the fleet's own activity clock makes it the least recent of the six.
    func testCapEvictsTheLeastRecentlyUsedEligibleChannelAndRefusesWhenNoneIsEligible() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let (sups, boxes) = try await sixReady(rig)

        for _ in 0..<10 { try await rig.pushFrameAndAwaitStamp(rig.scriptedHandles[2], of: sups[2]) }
        for i in [0, 1, 3, 4, 5] { try await rig.pushFrameAndAwaitStamp(rig.scriptedHandles[i], of: sups[i]) }
        rig.forgetTransitions()

        let seventhBox = EligibilityBox()
        let seventh = rig.supervisor(session: SessionID(), origin: .owned(.connecting), eligibility: seventhBox)
        try await seventh.spawn(reason: .open)

        XCTAssertEqual(rig.scriptedHandles[2].terminateCount, 1, "the least recently used eligible channel was reaped")
        for i in [0, 1, 3, 4, 5] {
            XCTAssertEqual(rig.scriptedHandles[i].terminateCount, 0, "channel \(i) was not the victim")
        }
        XCTAssertEqual(rig.diagnostics.evictions.map(\.outcome), ["evicted"])
        let victimState = await sups[2].state
        XCTAssertEqual(victimState.origin, .owned(.dormant))
        let seventhState = await seventh.state
        XCTAssertEqual(seventhState.origin, .owned(.ready))
        let victimHoldsASlot = await rig.fleet.isLive(sups[2].key)
        XCTAssertFalse(victimHoldsASlot, "a dormant channel holds no slot, so it is never a victim either")

        // Nobody left is eligible: no eviction, and the header carries the count and the offer.
        for i in [0, 1, 3, 4, 5] { await makeIneligible(sups[i], boxes[i], "t-\(i)") }
        await makeIneligible(seventh, seventhBox, "t-7")
        let eighth = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        var refusal: (any Error)?
        do { try await eighth.spawn(reason: .open) } catch { refusal = error }
        guard case .capReached(let live)? = refusal as? LifecycleError else {
            return XCTFail("the eighth spawn gave \(String(describing: refusal))")
        }
        XCTAssertEqual(live, 6)
        XCTAssertEqual(rig.scriptedHandles.map(\.terminateCount).reduce(0, +), 1, "no second channel was reaped")
        XCTAssertEqual(rig.diagnostics.evictions.map(\.outcome), ["evicted"],
                       "with nobody eligible the counter named no victim at all, rather than naming and retracting")
        XCTAssertEqual(rig.spawnCount, 7, "the refused spawn built no process")
        let refused = await eighth.state
        XCTAssertEqual(refused.headerNote, .capReached(live: 6))
        XCTAssertEqual(refused.liveCount, 6)
        let counted = await rig.fleet.liveCount
        XCTAssertEqual(counted, 6)

        // A wedged channel is never the eviction pick even when it is the least recent. It leaves the live set the
        // moment it wedges, which is the counter's half of the rule; the wedge itself is four other rows' work, so
        // the ghost is marked on the counter directly here and nothing else about the channel changes.
        await makeEligible(sups[0], boxes[0])       // the least recent of the live six
        await makeEligible(sups[1], boxes[1])       // the next least recent
        await rig.fleet.markWedged(sups[0].key)
        let ninth = ChannelKey(configHome: rig.home.url, session: SessionID())
        guard case .evict(let pick, let reservation) = await rig.fleet.acquire(for: ninth) else {
            return XCTFail("the counter named no victim while one was eligible")
        }
        XCTAssertEqual(pick, sups[1].key, "the wedged channel was less recent and was still not the pick")
        await rig.fleet.rollback(reservation)

        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// A victim whose `terminate()` answers no exit frees nothing: the counter moves to the next eligible victim, or
    /// refuses when there is none. Either way no channel ever spawns against the ghost's slot.
    func testAVictimThatWedgesMidEvictionFreesNoSlot() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let (sups, _) = try await sixReady(rig)
        for _ in 0..<10 { try await rig.pushFrameAndAwaitStamp(rig.scriptedHandles[2], of: sups[2]) }
        for i in [0, 1, 3, 4, 5] { try await rig.pushFrameAndAwaitStamp(rig.scriptedHandles[i], of: sups[i]) }
        rig.scriptedHandles[2].terminateReturns = Self.wedgingReport
        rig.forgetTransitions()

        // Parked between the victim wedging and the report of it: the one window where the ghost could be counted
        // both as a pending eviction and as a wedged slot, which would make the fleet look full when it is not.
        rig.holdEviction(of: sups[2].key)
        let seventh = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await seventh.spawn(reason: .open) }
        try await rig.waitFor("the wedged victim to reach the barrier") { rig.evictionIsHeld }
        let midWedge = await rig.fleet.occupancy
        XCTAssertEqual(midWedge, 6, "the ghost occupies the slot it was already occupying, and not a second one")
        rig.releaseEviction()
        try await spawning.value

        let ghost = await sups[2].state
        XCTAssertEqual(ghost.wedged?.steps, Self.wedgedSteps)
        XCTAssertEqual(rig.diagnostics.evictions.map(\.outcome), ["victimWedged", "evicted"],
                       "the counter was told the victim wedged and then that the next one went")
        XCTAssertEqual(rig.scriptedHandles[0].terminateCount, 1, "the next least recent eligible channel went instead")
        let nextVictim = await sups[0].state
        XCTAssertEqual(nextVictim.origin, .owned(.dormant))
        let seventhState = await seventh.state
        XCTAssertEqual(seventhState.origin, .owned(.ready))
        let holding = await rig.fleet.liveCount
        XCTAssertEqual(holding, 6, "the ghost still counts; the fleet never holds seven processes' worth of slots")
        assertNoDecisionOverGranted(rig)

        // With no other eligible channel there is nothing to move to, so the spawn is refused and builds nothing.
        let lone = try newRig(sharing: rig.diagnostics)
        lone.useScriptedHandle()
        let (loneSups, loneBoxes) = try await sixReady(lone)
        for i in 1..<6 { await makeIneligible(loneSups[i], loneBoxes[i], "t-\(i)") }
        lone.scriptedHandles[0].terminateReturns = Self.wedgingReport
        let loneSeventh = lone.supervisor(session: SessionID(), origin: .owned(.connecting))
        var refusal: (any Error)?
        do { try await loneSeventh.spawn(reason: .open) } catch { refusal = error }
        guard case .capReached(let live)? = refusal as? LifecycleError else {
            return XCTFail("the lone-victim spawn gave \(String(describing: refusal))")
        }
        XCTAssertEqual(live, 6)
        XCTAssertEqual(lone.spawnCount, 6, "nothing spawned on the ghost's slot")
        let loneHolding = await lone.fleet.liveCount
        XCTAssertEqual(loneHolding, 6)

        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// Two channels opened at the cap in the same instant take two distinct victims, or one of them is refused. They
    /// never both spawn against one freed slot, because a victim leaves the live set in the turn it is named.
    func testTwoConcurrentOpensAtTheCapTakeDistinctVictimsOrOneIsRefused() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let (sups, boxes) = try await sixReady(rig)
        for i in 2..<6 { await makeIneligible(sups[i], boxes[i], "t-\(i)") }
        rig.forgetTransitions()

        // Both evictions are held open, so the two acquisitions are pinned to the moment each has been decided and
        // neither has completed. Without the barrier the test only discriminates when the two `acquire` calls happen
        // to interleave; with it, "the second acquirer saw the first one's claim" is what is actually asserted.
        rig.holdEviction(of: sups[0].key)
        rig.holdEviction(of: sups[1].key)

        let a = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let b = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        var failures: [any Error] = []
        let opens = Task {
            var thrown: [any Error] = []
            await withTaskGroup(of: (any Error)?.self) { group in
                group.addTask { do { try await a.spawn(reason: .open); return nil } catch { return error } }
                group.addTask { do { try await b.spawn(reason: .open); return nil } catch { return error } }
                for await outcome in group { if let outcome { thrown.append(outcome) } }
            }
            return thrown
        }
        // Either both opens reached an eviction of their own — the healthy shape — or one of them got a slot with no
        // eviction at all, which is the break this test exists to catch and which shows up as a seventh process.
        try await rig.waitFor("both opens to be decided") {
            rig.heldEvictionCount == 2 || rig.spawnCount > 6
        }
        rig.releaseEviction()
        failures = await opens.value

        let victims = [0, 1].filter { rig.scriptedHandles[$0].terminateCount == 1 }.count
        let aState = await a.state, bState = await b.state
        let newcomersReady = [aState, bState].filter { $0.origin == .owned(.ready) }.count
        let refusals = failures.filter { if case LifecycleError.capReached = $0 { true } else { false } }.count

        XCTAssertFalse(victims == 1 && newcomersReady == 2, "two channels spawned against one freed slot")
        XCTAssertTrue((victims == 2 && newcomersReady == 2 && refusals == 0)
                      || (victims == 1 && newcomersReady == 1 && refusals == 1),
                      "victims: \(victims), ready: \(newcomersReady), refused: \(refusals)")
        assertNoDecisionOverGranted(rig)
        let holding = await rig.fleet.liveCount
        XCTAssertEqual(holding, 6)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The victim's own release arriving while its eviction is still pending completes that eviction into the waiting
    /// reservation. It does not free a seventh slot, and reporting the outcome afterwards finds the work done.
    func testAReleaseArrivingWhileTheVictimIsPendingCompletesTheEvictionAndNeverFreesASeventhSlot() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let (sups, boxes) = try await sixReady(rig)
        for i in 1..<6 { await makeIneligible(sups[i], boxes[i], "t-\(i)") }
        rig.forgetTransitions()

        let victim = sups[0].key
        rig.holdEviction(of: victim)
        let seventh = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        let spawning = Task { try await seventh.spawn(reason: .open) }
        try await rig.waitFor("the eviction to park at the barrier") { rig.evictionIsHeld }
        XCTAssertEqual(rig.scriptedHandles[0].terminateCount, 1, "the victim was reaped before the barrier")

        await rig.fleet.release(victim)
        let stillLive = await rig.fleet.isLive(victim)
        XCTAssertFalse(stillLive)
        let occupied = await rig.fleet.occupiedCount
        XCTAssertEqual(occupied, 6, "the slot moved into the waiting reservation; the live set was not touched")

        let eighth = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        var refusal: (any Error)?
        do { try await eighth.spawn(reason: .open) } catch { refusal = error }
        guard case .capReached(let live)? = refusal as? LifecycleError else {
            return XCTFail("the eighth spawn gave \(String(describing: refusal))")
        }
        XCTAssertEqual(live, 6, "the freed slot is spoken for by the seventh's reservation")
        XCTAssertEqual(rig.spawnCount, 6, "nothing spawned while the eviction was still pending")

        rig.releaseEviction()
        try await spawning.value
        XCTAssertEqual(rig.diagnostics.evictions.map(\.outcome), ["evicted"])
        let seventhState = await seventh.state
        XCTAssertEqual(seventhState.origin, .owned(.ready))
        XCTAssertEqual(rig.spawnCount, 7)

        let before = await rig.fleet.liveCount
        await rig.fleet.release(victim)
        let after = await rig.fleet.liveCount
        XCTAssertEqual(after, before, "a second release of the same key is a no-op")
        XCTAssertEqual(after, 6)
        assertNoDecisionOverGranted(rig)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - jobAdopt

    /// Adopting a job: `claude stop <short>`, wait for the worker to leave the roster *and* die, then resume owned.
    /// The worker is a real child this test started, because a release wait that never sees a pid die never ends.
    func testAdoptStopsTheJobWaitsForRosterRemovalThenResumes() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let short = "j00001"
        let worker = try rig.startHelper()
        try rig.files.writeJob(short: short, state: "working", sessionID: session, resumeSessionID: session,
                               pid: worker)
        rig.files.onStopJob = { [weak rig] stopped in if stopped == short { rig?.killHelper(worker) } }
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .backgroundJob)
        _ = await rig.observer.reconcileNow()
        rig.forgetTransitions()
        let labelsBefore = rig.reader.checkLabels.count

        try await rig.steppingClock { try await supervisor.adopt() }

        XCTAssertEqual(rig.runnerCalls.invocations.filter { $0.first == "stop" }, [["stop", short]])
        XCTAssertNil(rig.files.rosterWorkers()[short], "the worker left the roster")
        let labels = Array(rig.reader.checkLabels.dropFirst(labelsBefore))
        XCTAssertEqual(labels.first, OwnershipLabel.release, "the wait came before the spawn, not after it")
        XCTAssertEqual(Array(labels.suffix(2)), [OwnershipLabel.beforeSpawn, OwnershipLabel.afterHandshake])
        XCTAssertEqual(rig.spawnCount, 1)
        guard case .resume(let id, false) = rig.launches[0].session else {
            return XCTFail("the adoption launch did not resume the session")
        }
        XCTAssertEqual(id, session)
        let adopted = await supervisor.state
        XCTAssertEqual(adopted.origin, .owned(.ready))
        try await rig.drainPublished(of: supervisor)
        XCTAssertTrue(rig.published(of: supervisor).contains { $0.origin == .owned(.connecting) })
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - ownedSendToBackground

    /// From ready: terminate, wait for our own record to go, run the verb, and remember the short as ours. From
    /// dormant there is no process and nothing of ours to wait for, so the verb runs straight away.
    func testSendToBackgroundTerminatesWaitsForRegistryRemovalThenStartsAJob() async throws {
        // The wait is for a *record*, and only a pid that outlives the read can prove it blocked: a real child's pid
        // is dead the instant `terminate()` returns, so the very first read would already be released. The scripted
        // handle therefore stands in for our child with the pid of a real process this test started, and the record
        // is removed — as the CLI removes its own — only once the wait has looked for it.
        let readyRig = try newRig()
        readyRig.useScriptedHandle()
        let session = SessionID()
        let fromReady = try await readyScripted(readyRig, session: session)
        let childPID = try readyRig.startHelper()
        readyRig.scriptedHandles[0].pid = childPID
        try readyRig.files.writeRegistry(pid: childPID, sessionID: session, kind: "interactive",
                                         entrypoint: "sdk-cli")
        readyRig.reader.onLabel(OwnershipLabel.release) { [weak readyRig] in
            readyRig?.files.removeRegistry(pid: childPID)
            readyRig?.killHelper(childPID)
        }

        let dormantRig = try newRig(sharing: readyRig.diagnostics)
        dormantRig.useScriptedHandle()
        let fromDormant = try await readyScripted(dormantRig)
        await fromDormant.reap()
        XCTAssertEqual(dormantRig.scriptedHandles[0].terminateCount, 1)

        readyRig.forgetTransitions()
        let labelsBefore = readyRig.reader.checkLabels.count

        let short = try await readyRig.steppingClock { try await fromReady.sendToBackground() }

        XCTAssertTrue(readyRig.runnerCalls.invocations.contains(["--bg", "--resume", session.description]))
        let labels = Array(readyRig.reader.checkLabels.dropFirst(labelsBefore))
        XCTAssertEqual(labels.first, OwnershipLabel.release,
                       "the release was waited out before anything else ran")
        XCTAssertEqual(labels.filter { $0 == OwnershipLabel.release }.count, 2,
                       "the first read still saw our record, so the wait really blocked on it")
        XCTAssertEqual(labels.last, OwnershipLabel.beforeSpawn,
                       "and the check ran again immediately before the verb")
        XCTAssertEqual(readyRig.diagnostics.handoffWaits.map(\.outcome), ["released"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: readyRig.files.root.appending(path: "sessions/\(childPID).json").path(percentEncoded: false)),
                       "our own record was gone before the job was started")
        XCTAssertEqual(readyRig.files.job(short.rawValue)?.resumeSessionId, session.description)
        let backgrounded = await fromReady.state
        XCTAssertEqual(backgrounded.origin, .backgroundJob)
        let stored = try await readyRig.store.read([String].self, namespace: .fleetKit,
                                                   key: FleetKitKeys.ownJobShorts)
        XCTAssertEqual(stored, [short.rawValue])

        let dormantShort = try await dormantRig.steppingClock { try await fromDormant.sendToBackground() }
        XCTAssertTrue(dormantRig.runnerCalls.invocations
            .contains(["--bg", "--resume", fromDormant.key.session.description]))
        XCTAssertEqual(dormantRig.scriptedHandles[0].terminateCount, 1, "there was no process left to terminate")
        XCTAssertEqual(dormantRig.files.job(dormantShort.rawValue)?.resumeSessionId,
                       fromDormant.key.session.description)
        let dormantState = await fromDormant.state
        XCTAssertEqual(dormantState.origin, .backgroundJob)
        readyRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The CLI exiting zero is not the confirmation; the job being listed is. When the listing does not have it the
    /// handoff has failed, and the channel must not be left presenting as owned: its child is already gone and its
    /// slot already released, so "owned" would name a process that does not exist.
    ///
    /// This declares no scenario of its own. The claim is that a failed launch takes the one row that describes what
    /// happened — the channel let go of its process and got no replacement — and nothing else.
    func testAJobTheListingDoesNotNameFailsTheHandoffAndLeavesNoOwnedChannelBehind() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        // `--bg --resume` succeeds and the roster names the worker, so the verb's own confirmation passes; the
        // listing the sidebar reads is what does not have it.
        rig.files.agentsListsJobs = false
        rig.forgetTransitions()

        var thrown: (any Error)?
        do { _ = try await rig.steppingClock { try await supervisor.sendToBackground() } } catch { thrown = error }

        guard case .verbFailed(let verb, let exitCode)? = thrown as? LifecycleError else {
            return XCTFail("the handoff gave \(String(describing: thrown))")
        }
        XCTAssertEqual(verb, "--bg --resume")
        XCTAssertEqual(exitCode, 0, "the CLI succeeded; it is the confirmation that failed")
        XCTAssertEqual(rig.diagnostics.jobNotListed, [supervisor.key.session.description])

        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.dormant),
                       "the channel let go of its process and got no replacement, so it is dormant, not owned-ready")
        XCTAssertNil(state.wedged, "nothing wedged: the child ended when it was asked to")
        let holding = await rig.fleet.liveCount
        XCTAssertEqual(holding, 0, "and it holds no slot")

        // And it is an ordinary dormant channel, not a special one: nothing blocks it, so the cap counter may reap
        // its slot away and a later send may resume it. A channel left presenting as owned would have gone on
        // holding an eligibility verdict for a process that does not exist.
        await supervisor.drainEligibility()
        let verdict = await rig.fleet.verdict(of: supervisor.key)
        XCTAssertEqual(verdict, .eligible)
        XCTAssertEqual(rig.spawnCount, 1, "no replacement process was built for the failed handoff")

        rig.assertObserved([T(.readyDormantEligible, .ready, .dormantTimerFired, .dormant)])
    }

    // MARK: - ownedOpenInTerminal

    /// The hatch resumes under the same config home and the same scrubbed, re-injected environment the owned process
    /// ran under, because the environment is composed by ClaudeWire's launch configuration and not assembled here.
    func testOpenInTerminalReturnsAHatchPaneRequestUnderTheSameConfigHome() async throws {
        let readyRig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let fromReady = readyRig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        try await fromReady.spawn(reason: .open)
        let childPID = await readyRig.liveHandles[0].childProcessIdentifier

        let dormantRig = try newRig(sharing: readyRig.diagnostics)
        dormantRig.useScriptedHandle()
        let fromDormant = try await readyScripted(dormantRig)
        await fromDormant.reap()

        readyRig.forgetTransitions()

        let request = try await readyRig.steppingClock { try await fromReady.openInTerminal() }

        XCTAssertFalse(self.isAlive(childPID), "the owned process let go before the tab was offered")
        XCTAssertEqual(request.purpose, .hatch(session))
        XCTAssertEqual(request.arguments, ["--resume", session.description])
        XCTAssertEqual(request.executable, FakeClaudeLaunch.binary)
        XCTAssertEqual(request.cwd, readyRig.cwd)
        let composed = readyRig.launches[0].childEnvironment(
            over: readyRig.environment(fixture: Self.idleFixture), configHome: readyRig.home.configHome)
        XCTAssertEqual(Set(request.environment.keys), Set(composed.keys),
                       "the key set is exactly what LaunchConfiguration.childEnvironment produces")
        XCTAssertEqual(request.environment, composed)
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], readyRig.home.url.path)
        let hatched = await fromReady.state
        XCTAssertEqual(hatched.origin, .foreignLive(.ownTerminalTab))
        let pending = await fromReady.pendingPaneRequest
        XCTAssertEqual(pending?.id, request.id)

        // The panel reports the exit; the channel re-adopts, and a second hatch is the same request but for its id.
        await fromReady.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        try await readyRig.waitUntil(fromReady, "the re-adoption") { $0.origin == .owned(.ready) }
        let second = try await readyRig.steppingClock { try await fromReady.openInTerminal() }
        XCTAssertNotEqual(second.id, request.id, "two requests with identical fields are two requests")
        XCTAssertEqual(second.executable, request.executable)
        XCTAssertEqual(second.arguments, request.arguments)
        XCTAssertEqual(second.cwd, request.cwd)
        XCTAssertEqual(second.environment, request.environment)
        XCTAssertEqual(second.purpose, request.purpose)

        let dormantRequest = try await dormantRig.steppingClock { try await fromDormant.openInTerminal() }
        XCTAssertEqual(dormantRig.scriptedHandles[0].terminateCount, 1, "there was no process left to terminate")
        XCTAssertEqual(dormantRequest.purpose, .hatch(fromDormant.key.session))
        XCTAssertEqual(dormantRequest.arguments, ["--resume", fromDormant.key.session.description])
        let dormantState = await fromDormant.state
        XCTAssertEqual(dormantState.origin, .foreignLive(.ownTerminalTab))
        readyRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// `attach` and `logs` are pane requests too, and they change no ownership.
    func testAttachAndLogsAreParallelPaneRequestsThatChangeNoOwnership() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = try await readyScripted(rig)
        let jobCwd = rig.cwd.appending(path: "job")
        let job = JobEntry(short: JobShort(rawValue: "j00001"), state: "working", kind: "bg",
                           sessionID: supervisor.key.session, cwd: jobCwd, name: nil)

        let attach = await supervisor.attach(job: job)
        let logs = await supervisor.logs(job: job)

        XCTAssertEqual(attach.arguments, ["attach", "j00001"])
        XCTAssertEqual(logs.arguments, ["logs", "j00001"])
        XCTAssertEqual(attach.cwd, jobCwd)
        XCTAssertEqual(attach.purpose, .attach(job.short))
        XCTAssertEqual(logs.purpose, .logs(job.short))
        XCTAssertEqual(attach.environment, logs.environment)
        let unchanged = await supervisor.state
        XCTAssertEqual(unchanged.origin, .owned(.ready))
        let pending = await supervisor.pendingPaneRequest
        XCTAssertNil(pending, "neither is a hatch, so neither is waited on")
    }

    /// A poll that lands inside a handoff, while our own child's registry record has outlived its process, must
    /// not turn the channel Contended.
    ///
    /// The record is removed by the CLI, not by the terminate, which is the whole reason the release wait exists;
    /// and once `process` is nil the fleet's own-pid set no longer claims that pid, so a `HolderSet` read in that
    /// window shows our own dying child as a stranger. Rule 1 used to fire on it. The handoff then finished, put a
    /// real job on the roster, and left the channel reading `owned(contended)` — because `sendToBackground`'s own
    /// transition has no candidate from Contended.
    ///
    /// Found by G5's adoption scenario against the installed CLI, which asserted `.backgroundJob` and got
    /// `owned(contended)` after a send-to-background that had otherwise entirely succeeded. The holder here is
    /// pushed straight through `holdersChanged` and never written to the scripted files, which is exactly the live
    /// shape: seen by one poll, gone by the time the handoff's own recheck runs.
    ///
    /// Deliberate break: drop `!handingOff` from the rule-1 guard in `holdersChanged` → the channel ends
    /// `owned(contended)` and this fails with the live run's own message.
    func testAStaleRecordSeenDuringAHandoffDoesNotTurnTheChannelContended() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let session = SessionID()
        // `desired: .owned` is the point: rule 1 fires only when afleet wants the channel owned, which is what
        // every path into this handoff leaves behind — the live scenario arrived here through `adopt`.
        let supervisor = try await readyScripted(rig, session: session, desired: .owned)
        let childPID = try rig.startHelper()
        rig.scriptedHandles[0].pid = childPID
        try rig.files.writeRegistry(pid: childPID, sessionID: session, kind: "interactive", entrypoint: "sdk-cli")
        rig.reader.onLabel(OwnershipLabel.release) { [weak rig] in
            rig?.files.removeRegistry(pid: childPID)
            rig?.killHelper(childPID)
        }
        // The poll that lands in the window: our own child's record, no longer recognised as ours.
        rig.onReleased = { [weak supervisor] in
            await supervisor?.holdersChanged(HolderSet(
                holders: [Holder(pid: childPID, sessionID: session, sources: [.registry], kind: "interactive",
                                 entrypoint: "sdk-cli", isOwnChild: false)],
                observedAt: Date()))
        }

        rig.forgetTransitions()
        _ = try await rig.steppingClock { try await supervisor.sendToBackground() }

        let origin = await supervisor.state.origin
        XCTAssertEqual(origin, .backgroundJob,
                       "a stale record of our own child inside the handoff window turned the channel Contended")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - handoffPreempted

    /// What the holder that appears in the window between the release and the launch is.
    private enum PreemptHolder { case foreign, job, own }

    private struct PreemptCase {
        let rig: Rig
        let supervisor: ChannelSupervisor
        let holder: PreemptHolder
        let from: LifecycleTable.StateName
    }

    /// Builds one preempt scenario up to the moment before the handoff, and arms the holder so that it appears
    /// exactly in the window the row is about: through `OwnershipCheck`'s `onReleased` seam from ready, and simply
    /// present beforehand from dormant, where there is no process and no wait and the recheck is the only check.
    private func arrangePreempt(_ shared: RecordingDiagnostics, from: LifecycleTable.StateName,
                                holder: PreemptHolder) async throws -> PreemptCase {
        let rig = try newRig(sharing: shared)
        rig.useScriptedHandle()
        let session = SessionID()
        let supervisor = try await readyScripted(rig, session: session)
        if from == .dormant { await supervisor.reap() }
        if holder == .own { rig.extraOwnPIDs = [ScriptedHolderFiles.livePID] }

        let files = rig.files
        let appear: @Sendable () -> Void = {
            switch holder {
            case .foreign:
                try? files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                         kind: "interactive", entrypoint: "cli")
            case .job:
                try? files.writeJob(short: "j00001", state: "working", sessionID: session,
                                    resumeSessionID: session, pid: ScriptedHolderFiles.livePID)
            case .own:
                try? files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                         kind: "interactive", entrypoint: "sdk-cli")
            }
        }
        if from == .dormant { appear() } else { rig.onReleased = { appear() } }
        return PreemptCase(rig: rig, supervisor: supervisor, holder: holder, from: from)
    }

    /// Runs the handoff and asserts that nothing launched and that the channel took the origin the holder implies.
    private func assertPreempted(_ preempt: PreemptCase, hatch: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let rig = preempt.rig
        var thrown: (any Error)?
        do {
            if hatch { _ = try await rig.steppingClock { try await preempt.supervisor.openInTerminal() } }
            else { _ = try await rig.steppingClock { try await preempt.supervisor.sendToBackground() } }
        } catch { thrown = error }

        guard case .heldElsewhere(let set)? = thrown as? LifecycleError else {
            return XCTFail("the handoff gave \(String(describing: thrown))", file: file, line: line)
        }
        XCTAssertEqual(set.holders.map(\.pid), [ScriptedHolderFiles.livePID], file: file, line: line)
        let state = await preempt.supervisor.state
        switch preempt.holder {
        case .foreign:
            XCTAssertEqual(state.origin, .foreignLive(.usersTerminal), file: file, line: line)
            XCTAssertEqual(state.banner, .heldElsewhere(set), file: file, line: line)
        case .job:
            XCTAssertEqual(state.origin, .backgroundJob, file: file, line: line)
            XCTAssertEqual(state.banner, .heldElsewhere(set), file: file, line: line)
        case .own:
            XCTAssertEqual(state.origin, .owned(.contended), file: file, line: line)
            XCTAssertEqual(state.banner, .contended(set), file: file, line: line)
        }
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["--bg"]), 0, "no verb ran", file: file, line: line)
        let stored = try await rig.store.read([String].self, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        XCTAssertNil(stored, "no short was recorded as ours", file: file, line: line)
        if hatch {
            XCTAssertEqual(rig.diagnostics.paneRequests.count, 0, "no request was built", file: file, line: line)
            let pending = await preempt.supervisor.pendingPaneRequest
            XCTAssertNil(pending, file: file, line: line)
        }
    }

    private func arrangeAllPreempts(_ shared: RecordingDiagnostics) async throws -> [PreemptCase] {
        var cases: [PreemptCase] = []
        for from in [LifecycleTable.StateName.ready, .dormant] {
            for holder in [PreemptHolder.foreign, .job, .own] {
                cases.append(try await arrangePreempt(shared, from: from, holder: holder))
            }
        }
        return cases
    }

    /// A holder that appears after the release and before the launch preempts the handoff: nothing launches, the
    /// channel takes the holder's origin, and the caller is told who has the session.
    func testAHolderAppearingAfterReleaseAndBeforeLaunchPreemptsSendToBackground() async throws {
        let shared = RecordingDiagnostics()
        let cases = try await arrangeAllPreempts(shared)
        shared.forgetTransitions()
        for preempt in cases { try await assertPreempted(preempt, hatch: false) }
        cases[0].rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// The same six, for the terminal hatch: no request is returned and the panel never spawns beside the holder.
    func testAHolderAppearingAfterReleaseAndBeforeLaunchPreemptsOpenInTerminal() async throws {
        let shared = RecordingDiagnostics()
        let cases = try await arrangeAllPreempts(shared)
        shared.forgetTransitions()
        for preempt in cases { try await assertPreempted(preempt, hatch: true) }
        cases[0].rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - ownTabExited

    /// The tab closing is not the release: the record it wrote is. The re-adoption waits for that record to go and
    /// for its pid to die, and only then does the pre-spawn check run and a process start.
    func testPaneExitReAdoptsWhenTheRecordIsGone() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idleFixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.idleFixture, origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let request = try await rig.steppingClock { try await supervisor.openInTerminal() }

        // The "terminal" is a real process this test started, so its pid can genuinely stop being alive.
        let tab = try rig.startHelper()
        try rig.files.writeRegistry(pid: tab, sessionID: session, kind: "interactive", entrypoint: "cli")
        // A background job on the same session, sorted ahead of the tab by pid. The re-adoption must wait for the
        // record *the tab wrote*: waiting out whichever holder came first would be waiting for a process that was
        // never the tab's, and this one's pid is the test runner's and never dies.
        try rig.files.writeJob(short: "j00001", state: "working", sessionID: session, resumeSessionID: session,
                               pid: ScriptedHolderFiles.livePID)
        XCTAssertLessThan(ScriptedHolderFiles.livePID, tab, "the decoy holder sorts first")
        _ = await rig.observer.reconcileNow()
        rig.forgetTransitions()
        let labelsBefore = rig.reader.checkLabels.count
        rig.reader.onLabel(OwnershipLabel.release) { [weak rig] in
            rig?.files.removeRegistry(pid: tab)
            rig?.killHelper(tab)
            try? rig?.files.stopJob(short: "j00001")   // the job ends too, so the pre-spawn check is clean
        }

        try await rig.steppingClock {
            await supervisor.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        }

        let labels = Array(rig.reader.checkLabels.dropFirst(labelsBefore))
        XCTAssertEqual(labels.filter { $0 == OwnershipLabel.release }.count, 2,
                       "the first read still saw the tab's record, so the wait blocked on it")
        XCTAssertEqual(Array(labels.suffix(2)), [OwnershipLabel.beforeSpawn, OwnershipLabel.afterHandshake],
                       "the spawn ran after the removal, behind the pre-spawn check")
        XCTAssertEqual(rig.spawnCount, 2)
        let readopted = await supervisor.state
        XCTAssertEqual(readopted.origin, .owned(.ready))
        let pending = await supervisor.pendingPaneRequest
        XCTAssertNil(pending)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// Two requests with identical fields are two requests. A pane exit is matched to the pending hatch by
    /// `PaneRequest.id`, whichever order the exits arrive in.
    func testAStaleExitFromAnIdenticalOlderHatchIsDiscardedByID() async throws {
        let shared = RecordingDiagnostics()

        /// Hatches twice with a re-adoption in between, so `first` and `second` differ in nothing but their id.
        func arrange() async throws -> (rig: Rig, supervisor: ChannelSupervisor, first: PaneRequest,
                                        second: PaneRequest) {
            let rig = try newRig(sharing: shared)
            rig.useScriptedHandle()
            let supervisor = try await readyScripted(rig)
            let first = try await rig.steppingClock { try await supervisor.openInTerminal() }
            await supervisor.paneExited(PaneExit(request: first, code: 0, observedAt: Date()))
            try await rig.waitUntil(supervisor, "the first re-adoption") { $0.origin == .owned(.ready) }
            let second = try await rig.steppingClock { try await supervisor.openInTerminal() }
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertEqual(first.arguments, second.arguments)
            XCTAssertEqual(first.environment, second.environment)
            XCTAssertEqual(first.purpose, second.purpose)
            return (rig, supervisor, first, second)
        }

        let newestFirst = try await arrange()
        let oldestFirst = try await arrange()
        shared.forgetTransitions()

        // The newest exit arrives first, then the stale one.
        await newestFirst.supervisor.paneExited(PaneExit(request: newestFirst.second, code: 0, observedAt: Date()))
        try await newestFirst.rig.waitUntil(newestFirst.supervisor, "the re-adoption") {
            $0.origin == .owned(.ready)
        }
        await newestFirst.supervisor.paneExited(PaneExit(request: newestFirst.first, code: 0, observedAt: Date()))

        // And the other way round.
        await oldestFirst.supervisor.paneExited(PaneExit(request: oldestFirst.first, code: 0, observedAt: Date()))
        let afterStale = await oldestFirst.supervisor.state
        XCTAssertEqual(afterStale.origin, .foreignLive(.ownTerminalTab), "the stale exit changed nothing")
        await oldestFirst.supervisor.paneExited(PaneExit(request: oldestFirst.second, code: 0, observedAt: Date()))
        try await oldestFirst.rig.waitUntil(oldestFirst.supervisor, "the re-adoption") {
            $0.origin == .owned(.ready)
        }

        for run in [newestFirst, oldestFirst] {
            XCTAssertEqual(run.rig.spawnCount, 3, "one arranging spawn, one arranging re-adopt, one act re-adopt")
            let pending = await run.supervisor.pendingPaneRequest
            XCTAssertNil(pending)
        }
        XCTAssertEqual(Set(shared.staleExits), [newestFirst.first.id, oldestFirst.first.id],
                       "each run discarded exactly its older request's exit")

        // A request equal to the pending one in every field but its id is still a different request.
        let twin = PaneRequest(executable: oldestFirst.second.executable, arguments: oldestFirst.second.arguments,
                               cwd: oldestFirst.second.cwd, environment: oldestFirst.second.environment,
                               purpose: oldestFirst.second.purpose)
        let hatch = try await oldestFirst.rig.steppingClock { try await oldestFirst.supervisor.openInTerminal() }
        XCTAssertNotEqual(hatch.id, twin.id)
        await oldestFirst.supervisor.paneExited(PaneExit(request: twin, code: 0, observedAt: Date()))
        let unchanged = await oldestFirst.supervisor.state
        XCTAssertEqual(unchanged.origin, .foreignLive(.ownTerminalTab), "a value-equal request never matches")
        XCTAssertEqual(oldestFirst.rig.spawnCount, 3)
        XCTAssertTrue(shared.staleExits.contains(twin.id))

        newestFirst.rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - The foreign rows

    private func foreignHolder(_ session: SessionID, pid: Int32 = ScriptedHolderFiles.livePID) -> Holder {
        Holder(pid: pid, sessionID: session, sources: [.registry], kind: "interactive", entrypoint: "cli")
    }

    private func jobHolder(_ session: SessionID, short: String,
                           pid: Int32 = ScriptedHolderFiles.livePID) -> Holder {
        Holder(pid: pid, sessionID: session, sources: [.roster], kind: "bg", jobShort: short)
    }

    private func set(_ holders: [Holder]) -> HolderSet { HolderSet(holders: holders, observedAt: Date()) }

    /// A session running in the user's terminal whose record goes away is nobody's: the channel is archived.
    func testForeignRecordDisappearingArchivesTheChannel() async throws {
        let rig = try newRig()
        let session = SessionID()
        let supervisor = rig.supervisor(session: session, isRecent: true, origin: .foreignLive(.usersTerminal))
        try rig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                    kind: "interactive", entrypoint: "cli")
        await rig.startObserver()
        try await rig.waitUntil(supervisor, "the holder to be observed") { $0.observed.holders.count == 1 }
        rig.forgetTransitions()

        rig.files.removeRegistry(pid: ScriptedHolderFiles.livePID)
        await rig.clock.advance(by: .seconds(5))          // the observer's poll
        try await rig.waitUntil(supervisor, "the archived outcome") { $0.origin == .archived }

        XCTAssertEqual(rig.spawnCount, 0, "an archived channel is not a channel afleet took over")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// Rule 6: a send on a session somebody else is running is refused where the user can see why, and *Fork* is
    /// what the banner offers.
    func testSendOnAForeignSessionIsRefusedWithForkOffered() async throws {
        let rig = try newRig()
        let session = SessionID()
        let supervisor = rig.supervisor(session: session, isRecent: true, origin: .foreignLive(.usersTerminal))
        try rig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                    kind: "interactive", entrypoint: "cli")
        await rig.startObserver()
        try await rig.waitUntil(supervisor, "the holder to be observed") { $0.observed.holders.count == 1 }
        rig.forgetTransitions()
        let before = await supervisor.state
        let desiredBefore = before.desired

        var thrown: (any Error)?
        do { _ = try await supervisor.send(UserInput(text: "hi")) } catch { thrown = error }

        guard case .heldElsewhere(let holders)? = thrown as? LifecycleError else {
            return XCTFail("the send gave \(String(describing: thrown))")
        }
        XCTAssertEqual(holders.holders.map(\.pid), [ScriptedHolderFiles.livePID])
        let refused = await supervisor.state
        XCTAssertEqual(refused.banner, .heldElsewhere(holders))
        XCTAssertEqual(refused.origin, .foreignLive(.usersTerminal))
        XCTAssertEqual(refused.desired, desiredBefore, "a refusal is not a change of intent")
        XCTAssertEqual(rig.spawnCount, 0)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - handoffTimedOut

    /// Every handoff that waits: the adoption, the two owned handoffs from ready and from dormant, and the pane
    /// exit. Past ten seconds each of them makes the channel Contended and names who is holding it.
    func testHandoffTimeoutEntersContendedFromEveryHandoff() async throws {
        let shared = RecordingDiagnostics()

        // 1. Adopt: `stop` runs but the worker never leaves the roster and never dies.
        let adoptRig = try newRig(sharing: shared)
        let adoptSession = SessionID()
        let worker = try adoptRig.startHelper()
        adoptRig.files.stopRemovesWorker = false
        try adoptRig.files.writeJob(short: "j00001", state: "working", sessionID: adoptSession,
                                    resumeSessionID: adoptSession, pid: worker)
        let adopting = adoptRig.supervisor(session: adoptSession, origin: .backgroundJob)
        _ = await adoptRig.observer.reconcileNow()

        // 2 and 3. Send to background from ready and from dormant, with a record of ours that never goes.
        //          The scripted handle carries the pid of a real process, because a record naming a dead pid is
        //          already "gone" as far as the reader is concerned and the wait would end at once.
        let readyRig = try newRig(sharing: shared)
        readyRig.useScriptedHandle()
        let readySession = SessionID()
        let fromReady = try await readyScripted(readyRig, session: readySession)
        let readyPID = try readyRig.startHelper()
        readyRig.scriptedHandles[0].pid = readyPID
        try readyRig.files.writeRegistry(pid: readyPID, sessionID: readySession, kind: "interactive",
                                         entrypoint: "sdk-cli")

        let dormantRig = try newRig(sharing: shared)
        dormantRig.useScriptedHandle()
        let dormantSession = SessionID()
        let fromDormant = try await readyScripted(dormantRig, session: dormantSession)
        await fromDormant.reap()
        let ghostPID = try dormantRig.startHelper()
        dormantRig.extraOwnPIDs = [ghostPID]      // a record of ours that outlived the child that wrote it
        try dormantRig.files.writeRegistry(pid: ghostPID, sessionID: dormantSession, kind: "interactive",
                                           entrypoint: "sdk-cli")
        _ = await dormantRig.observer.reconcileNow()

        // 4. A pane exit whose tab record never disappears.
        let tabRig = try newRig(sharing: shared)
        tabRig.useScriptedHandle()
        let tabSession = SessionID()
        let hatched = try await readyScripted(tabRig, session: tabSession)
        let request = try await tabRig.steppingClock { try await hatched.openInTerminal() }
        let tabPID = try tabRig.startHelper()
        try tabRig.files.writeRegistry(pid: tabPID, sessionID: tabSession, kind: "interactive", entrypoint: "cli")
        _ = await tabRig.observer.reconcileNow()

        shared.forgetTransitions()

        try await self.assertTimesOutIntoContended(adoptRig, adopting, holder: worker) {
            try await adopting.adopt()
        }
        try await self.assertTimesOutIntoContended(readyRig, fromReady, holder: readyPID) {
            _ = try await fromReady.sendToBackground()
        }
        try await self.assertTimesOutIntoContended(dormantRig, fromDormant, holder: ghostPID) {
            _ = try await fromDormant.sendToBackground()
        }
        // A pane exit reports no error, so this one is asserted on the state alone.
        try await tabRig.steppingClock(upTo: .seconds(10)) {
            await hatched.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        }
        let contendedTab = await hatched.state
        XCTAssertEqual(contendedTab.origin, .owned(.contended))
        XCTAssertEqual(contendedTab.banner, .contended(contendedTab.observed))
        XCTAssertEqual(contendedTab.observed.holders.map(\.pid), [tabPID])
        XCTAssertEqual(tabRig.spawnCount, 1, "no re-adoption happened while the tab still held the session")

        adoptRig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// Runs a handoff that will not complete, ten seconds of test time at a time, and asserts the channel became
    /// Contended and says whose pid is holding it.
    private func assertTimesOutIntoContended(_ rig: Rig, _ supervisor: ChannelSupervisor, holder pid: Int32,
                                             file: StaticString = #filePath, line: UInt = #line,
                                             _ body: @escaping @Sendable () async throws -> Void) async throws {
        var thrown: (any Error)?
        do { try await rig.steppingClock(upTo: .seconds(10), body) } catch { thrown = error }
        guard case .handoffTimedOut? = thrown as? LifecycleError else {
            return XCTFail("the handoff gave \(String(describing: thrown))", file: file, line: line)
        }
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.contended), file: file, line: line)
        XCTAssertEqual(state.banner, .contended(state.observed), file: file, line: line)
        XCTAssertEqual(state.observed.holders.map(\.pid), [pid], file: file, line: line)
        XCTAssertEqual(rig.runnerCalls.count(prefix: ["--bg"]), 0, "no verb ran", file: file, line: line)
    }

    /// Not a §7.4 row: the window between a spawn taking its reservation and applying its own outcome.
    ///
    /// A holder update that arrives in that window must not raise the disagreement. If it did, the channel would be
    /// Contended by the time the post-handshake check applied `handshakeClean` or `handshakeFoundHolder`, neither of
    /// which the table admits from `contended` — a `transitionNotInTable`, which Task 12's gate reads as a
    /// programming error. The holder belongs to the pre-spawn and post-handshake checks, which have rows for it.
    ///
    /// The eviction barrier is what makes this deterministic: it parks the seventh channel *inside* `spawn`, after
    /// the reservation and before the pre-spawn check, which is exactly the window.
    func testAHolderArrivingWhileASpawnIsInFlightIsLeftToTheOwnershipChecks() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let (sups, boxes) = try await sixReady(rig)
        for i in 1..<6 { await makeIneligible(sups[i], boxes[i], "t-\(i)") }
        rig.forgetTransitions()

        rig.holdEviction(of: sups[0].key)
        let session = SessionID()
        let seventh = rig.supervisor(session: session, isRecent: true)
        let opening = Task { try await seventh.open() }
        try await rig.waitFor("the seventh to park inside its spawn") { rig.evictionIsHeld }
        let connecting = await seventh.state
        XCTAssertEqual(connecting.origin, .owned(.connecting))
        XCTAssertEqual(connecting.desired, .owned, "the intent is set, so the disagreement rule would otherwise fire")

        // The holder appears mid-spawn, and is also on disk so the pre-spawn check will find it.
        try rig.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session,
                                    kind: "interactive", entrypoint: "cli")
        await seventh.holdersChanged(HolderSet(holders: [foreignHolder(session)], observedAt: Date()))

        let duringSpawn = await seventh.state
        XCTAssertEqual(duringSpawn.origin, .owned(.connecting), "the spawn in flight still owns the transition")
        XCTAssertEqual(rig.diagnostics.notInTable, [])

        rig.releaseEviction()
        var refusal: (any Error)?
        do { try await opening.value } catch { refusal = error }
        guard case .heldElsewhere? = refusal as? LifecycleError else {
            return XCTFail("the pre-spawn check gave \(String(describing: refusal))")
        }
        let refused = await seventh.state
        XCTAssertEqual(refused.origin, .foreignLive(.usersTerminal), "the check took the holder's origin, as it does")
        XCTAssertEqual(rig.spawnCount, 6, "no seventh process was built")
        XCTAssertEqual(rig.diagnostics.notInTable, [], "and no transition the table refuses was recorded")

        rig.assertObserved([T(.archivedRecentOpened, .archivedRecent, .opened, .connecting),
                            T(.capReached, .ready, .seventhSpawnNeeded, .dormant)])
        assertNoDecisionOverGranted(rig)
    }

    // MARK: - desiredObservedDisagree

    /// Rule 1 as its own event: afleet wants this channel and somebody else has it. It is raised from connecting,
    /// from ready and from dormant, and it is never reported as a handoff timeout.
    func testDesiredOwnedWithAForeignHolderIsContendedFromEveryOwnedState() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()

        // Connecting for real: `open()` sets the intent and the spawn fails before the handshake, so the channel is
        // where it says it is — owned-connecting, with no process.
        rig.failScriptedSpawns()
        let connectingSession = SessionID()
        let connecting = rig.supervisor(session: connectingSession, isRecent: true)
        do { try await connecting.open() } catch {}
        let connectingState = await connecting.state
        XCTAssertEqual(connectingState.origin, .owned(.connecting))
        XCTAssertEqual(connectingState.desired, .owned)

        rig.clearScriptedSpawnFailure()
        let readySession = SessionID()
        let ready = rig.supervisor(session: readySession, isRecent: true)
        try await ready.open()
        let dormantSession = SessionID()
        let dormant = rig.supervisor(session: dormantSession, isRecent: true)
        try await dormant.open()
        await dormant.reap()
        let dormantState = await dormant.state
        XCTAssertEqual(dormantState.desired, .owned, "the intent survives the reap")

        rig.forgetTransitions()

        await connecting.holdersChanged(set([foreignHolder(connectingSession)]))
        await ready.holdersChanged(set([foreignHolder(readySession)]))
        await dormant.holdersChanged(set([foreignHolder(dormantSession)]))

        for supervisor in [connecting, ready, dormant] {
            let state = await supervisor.state
            XCTAssertEqual(state.origin, .owned(.contended))
            XCTAssertEqual(state.banner, .contended(state.observed))
            XCTAssertEqual(state.observed.holders.map(\.pid), [ScriptedHolderFiles.livePID])
        }
        XCTAssertEqual(rig.diagnostics.handoffWaits.map(\.outcome), [], "no handoff was waited on, so none timed out")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    // MARK: - contendedSettled

    /// A channel that was not recently active is still not recently active after passing through Contended. The
    /// parent's row is "the matching origin", and for a channel afleet holds no process for and that nobody else
    /// holds either, archived-older is the matching origin — so the table admits it and the channel has a way out.
    ///
    /// Deriving the name from the flag without the row is worse than getting the flag wrong: `apply` refuses a
    /// transition it has no candidate for, and the channel is left Contended with no banner and no way out.
    func testContendedSettlingToNobodyLeavesAnOlderChannelOlder() async throws {
        let rig = try newRig()
        let session = SessionID()
        let supervisor = rig.supervisor(session: session, isRecent: false, origin: .owned(.ready), desired: .owned)
        await supervisor.holdersChanged(set([foreignHolder(session)]))
        let contended = await supervisor.state
        XCTAssertEqual(contended.origin, .owned(.contended))
        rig.forgetTransitions()

        await supervisor.holdersChanged(set([]))

        let settled = await supervisor.state
        XCTAssertEqual(settled.origin, .archived)
        XCTAssertNil(settled.banner, "the contended banner is cleared when the holders settle")
        XCTAssertEqual(rig.diagnostics.notInTable, [], "the channel had a transition to take")

        // Still older: opening it renders history and spawns nothing, which is the whole point of the flag.
        try await supervisor.open()
        XCTAssertEqual(rig.spawnCount, 0)
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
    }

    /// Contended is a state the channel comes back out of. Zero holders means the session is nobody's — unless the
    /// channel still owns a process, or was dormant when the disagreement arrived; one holder means that holder's
    /// origin.
    func testContendedResolvesWhenHoldersSettle() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()

        /// A channel already Contended, reached through the disagreement so nothing is set behind the table's back.
        func contended(origin: ChannelOrigin, holders: (SessionID) -> [Holder],
                       spawning: Bool = false) async throws -> (ChannelSupervisor, SessionID) {
            let session = SessionID()
            let supervisor = rig.supervisor(session: session, origin: origin, desired: .owned)
            if spawning { try await supervisor.spawn(reason: .open) }
            await supervisor.holdersChanged(set(holders(session)))
            let state = await supervisor.state
            XCTAssertEqual(state.origin, .owned(.contended))
            return (supervisor, session)
        }

        let (owning, _) = try await contended(origin: .owned(.connecting), holders: { [foreignHolder($0)] },
                                              spawning: true)
        let (wasDormant, _) = try await contended(origin: .owned(.dormant), holders: { [foreignHolder($0)] })
        let (letGo, _) = try await contended(origin: .owned(.connecting), holders: { [foreignHolder($0)] })
        let (toForeign, foreignSession) = try await contended(origin: .owned(.ready), holders: {
            [foreignHolder($0), foreignHolder($0, pid: ScriptedHolderFiles.livePID + 1)]
        })
        let (toJob, jobSession) = try await contended(origin: .owned(.ready), holders: {
            [foreignHolder($0), self.jobHolder($0, short: "j00001", pid: ScriptedHolderFiles.livePID + 1)]
        })
        rig.forgetTransitions()

        await owning.holdersChanged(set([]))
        await wasDormant.holdersChanged(set([]))
        await letGo.holdersChanged(set([]))
        await toForeign.holdersChanged(set([foreignHolder(foreignSession)]))
        await toJob.holdersChanged(set([jobHolder(jobSession, short: "j00001")]))

        let owningState = await owning.state
        XCTAssertEqual(owningState.origin, .owned(.ready), "the channel still owns its process")
        let dormantState = await wasDormant.state
        XCTAssertEqual(dormantState.origin, .owned(.dormant), "it goes back to being the dormant channel it was")
        let letGoState = await letGo.state
        XCTAssertEqual(letGoState.origin, .archived, "nobody holds it and afleet holds no process")
        let foreignState = await toForeign.state
        XCTAssertEqual(foreignState.origin, .foreignLive(.usersTerminal))
        let jobState = await toJob.state
        XCTAssertEqual(jobState.origin, .backgroundJob)
        for supervisor in [owning, wasDormant, letGo, toForeign, toJob] {
            let state = await supervisor.state
            XCTAssertNil(state.banner, "the contended banner is cleared when the holders settle")
        }
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
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
