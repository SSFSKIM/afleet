import XCTest
import Darwin
import AfleetCore
import ClaudeWire
import FleetTimeline
@testable import FleetSessions

/// **G2.** Dormant eligibility read through C3's real registry mirror.
///
/// `DormantEligibilityTests.testTheMirrorBoundaryCases` asserts the same five boundary cases over
/// `MirrorEntryStandIn`; this drives them over `RegistryMirror`, folded by C3's own reducer from the frames a
/// `background-shell` replay actually emitted under a `ChannelSupervisor`. The two must agree case for case, and each
/// case below names its number:
///
/// 1. an armed entry blocks — `.blocked(.taskArmed)`, and thirty minutes pass with no terminate;
/// 2. a running entry whose last frame is fresh blocks — `.blocked(.taskRunning)`;
/// 3. a running entry whose last frame is older than the heartbeat is uncertainty — `.blocked(.taskStateUncertain)`;
/// 4. the mirror the `task_notification` emptied, with an old last frame, is stale history — eligible, and the
///    channel reaps;
/// 5. a mirror holding only a completed entry, with an old last frame, is history too — eligible, and it reaps.
///
/// Cases 4 and 5 both end in a terminate and a channel terminates once, so they take a channel each: two rigs, as the
/// thirty-minute row's own test does, because two channels under one config home would need two session ids and the
/// fixture's own id is what makes its `auth_status` match.
final class MirrorEligibilityTests: XCTestCase {
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

    /// The one committed fixture that records a background task's whole life: it is announced by
    /// `background_tasks_changed`, started, unlisted, updated to a terminal status and handed back by
    /// `task_notification`. Every state the five cases need is in it.
    private static let fixture = "background-shell"
    /// The same heartbeat the unit test uses, so 29 s and 31 s mean the same thing on both sides.
    private static let heartbeat = Duration.seconds(30)

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// The host's reading of `lastTaskFrameAge`: how long ago, on the host's own clock, the last frame naming this
    /// task arrived. The stamp is the mirror's own — `RegistryEntry.lastFrameAt`, written by C3's reducer as it
    /// folded that frame — and the test moves the host's clock, because a frame *not* arriving is exactly what makes
    /// an age grow. Nothing here waits on wall time for it.
    private func age(of entry: RegistryEntry, hostClockSecondsLater seconds: Double) -> Duration {
        let host = entry.lastFrameAt.addingTimeInterval(seconds)
        return .milliseconds(Int((host.timeIntervalSince(entry.lastFrameAt) * 1000).rounded()))
    }

    /// A channel replaying the fixture to its end: ready, no turn running, its dormant timer armed, and a fold of
    /// every registry frame it emitted.
    private func replayed(_ rig: Rig, eligibility: EligibilityBox) async throws
        -> (supervisor: ChannelSupervisor, fold: MirrorFold, pid: Int32) {
        let session = try FakeClaudeLaunch.sessionID(of: Self.fixture)
        let supervisor = rig.supervisor(session: session, fixture: Self.fixture, origin: .owned(.connecting),
                                        eligibility: eligibility)
        let fold = MirrorFold(await supervisor.events())
        try await supervisor.spawn(reason: .open)
        let pid = await rig.liveHandles.last!.childProcessIdentifier
        _ = try await supervisor.send(UserInput(text: "hi"))
        try await fold.waitForResults(2)
        return (supervisor, fold, pid)
    }

    /// Pins one mirror reading and its age, and reads back the verdict the supervisor itself computed from them.
    @discardableResult
    private func pin(_ mirror: [RegistryEntry], age: Duration?, into box: EligibilityBox,
                     on supervisor: ChannelSupervisor, _ rig: Rig) async -> DormantEligibility.Verdict? {
        box.mirror = mirror
        box.lastTaskFrameAge = age
        await supervisor.mirrorChanged()
        return await rig.fleet.verdict(of: supervisor.key)
    }

    /// Fires the thirty-minute timer and waits for the supervisor to arm the next one. `dormantTimerFired` re-arms
    /// only on the branch that refused the reap, so returning from this *is* the observation that nothing was
    /// terminated — no polling for the absence of a state.
    private func advanceAndExpectNoReap(_ rig: Rig, _ supervisor: ChannelSupervisor, _ pid: Int32,
                                        _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await rig.waitForSleeper(due: ChannelSupervisor.dormantAfter, file: file, line: line)
        await rig.clock.advance(by: ChannelSupervisor.dormantAfter)
        try await rig.waitForSleeper(due: ChannelSupervisor.dormantAfter, file: file, line: line)
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.ready), "\(label): the channel was reaped", file: file, line: line)
        XCTAssertTrue(isAlive(pid), "\(label): the child was terminated", file: file, line: line)
    }

    func testTheRealMirrorsBoundaryCasesAreTheStandInsCaseForCase() async throws {
        let beforeTheReplay = Date()
        let blockedRig = try newRig()
        let blockedBox = EligibilityBox()
        let (blocked, blockedFold, blockedPID) = try await replayed(blockedRig, eligibility: blockedBox)
        let emptiedRig = try newRig()
        let emptiedBox = EligibilityBox()
        let (emptied, emptiedFold, _) = try await replayed(emptiedRig, eligibility: emptiedBox)
        blockedRig.forgetTransitions()
        emptiedRig.forgetTransitions()
        XCTAssertEqual(blockedBox.input().heartbeatInterval, Self.heartbeat,
                       "29 s and 31 s straddle the same boundary the unit test's do")

        // Case 1. `background_tasks_changed` announced the task and no `task_started` has arrived: armed, not running.
        let armedReading = try XCTUnwrap(blockedFold.firstSnapshot { $0.contains(where: \.isArmed) },
                                         "the replay never produced an armed entry")
        let armed = try XCTUnwrap(armedReading.first(where: \.isArmed))
        XCTAssertFalse(armed.isRunning, "armed and running are separate facts")
        let armedVerdict = await pin(armedReading, age: nil, into: blockedBox, on: blocked, blockedRig)
        XCTAssertEqual(armedVerdict, .blocked(.taskArmed(armed.id)))
        try await advanceAndExpectNoReap(blockedRig, blocked, blockedPID, "case 1, armed")

        // Case 2. `task_started` arrived and no `task_notification` has: running, with a fresh last frame.
        let runningReading = try XCTUnwrap(blockedFold.firstSnapshot { $0.contains(where: \.isRunning) },
                                           "the replay never produced a running entry")
        let running = try XCTUnwrap(runningReading.first(where: \.isRunning))
        XCTAssertFalse(running.isArmed, "a started task is no longer armed")
        XCTAssertTrue(running.isBackground, "the fixture's `task_started` carries `is_backgrounded`")
        // The stamp the ages are measured from is C3's reducer's own, written as it folded this replay's frames.
        XCTAssertGreaterThanOrEqual(running.lastFrameAt, beforeTheReplay)
        let freshVerdict = await pin(runningReading, age: age(of: running, hostClockSecondsLater: 29),
                                     into: blockedBox, on: blocked, blockedRig)
        XCTAssertEqual(freshVerdict, .blocked(.taskRunning(running.id)))
        try await advanceAndExpectNoReap(blockedRig, blocked, blockedPID, "case 2, running and fresh")

        // Case 3. The same running entry, one second past its heartbeat: the mirror may have missed the completion.
        let staleVerdict = await pin(runningReading, age: age(of: running, hostClockSecondsLater: 31),
                                     into: blockedBox, on: blocked, blockedRig)
        XCTAssertEqual(staleVerdict, .blocked(.taskStateUncertain(running.id)))
        try await advanceAndExpectNoReap(blockedRig, blocked, blockedPID, "case 3, running and stale")

        // Case 5. `task_notification` arrived: the row is completed and handed back, and an hour-old frame is history.
        let completedReading = blockedFold.snapshot
        XCTAssertFalse(completedReading.isEmpty, "the notification left no row to read")
        XCTAssertEqual(completedReading.filter { $0.isRunning || $0.isArmed }, [],
                       "the notification left work the host still calls live")
        let completedVerdict = await pin(completedReading, age: .seconds(3_600), into: blockedBox,
                                         on: blocked, blockedRig)
        XCTAssertEqual(completedVerdict, .eligible)
        await blockedRig.clock.advance(by: ChannelSupervisor.dormantAfter)
        try await blockedRig.waitUntil(blocked, "the reap of the completed-entry channel") {
            $0.origin == .owned(.dormant)
        }
        XCTAssertFalse(isAlive(blockedPID), "the reap terminated the child")
        blockedRig.assertObserved([LifecycleTable.Transition(.readyDormantEligible, .ready, .dormantTimerFired,
                                                             .dormant)])

        // Case 4. The rows the host may forget are forgotten — notified, terminal, unlisted and past their grace —
        // so the mirror is empty, and an old last frame is still only history.
        let emptyReading = emptiedFold.afterEviction(secondsAfterTheLastFrame: 31)
        XCTAssertEqual(emptyReading, [], "the notified row was not evictable")
        let emptyVerdict = await pin(emptyReading, age: .seconds(3_600), into: emptiedBox, on: emptied, emptiedRig)
        XCTAssertEqual(emptyVerdict, .eligible)
        try await emptiedRig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        await emptiedRig.clock.advance(by: ChannelSupervisor.dormantAfter)
        try await emptiedRig.waitUntil(emptied, "the reap of the emptied-mirror channel") {
            $0.origin == .owned(.dormant)
        }
        emptiedRig.assertObserved([LifecycleTable.Transition(.readyDormantEligible, .ready, .dormantTimerFired,
                                                             .dormant)])

        // Deliberate break: feed the supervisor the empty stand-in instead of the mirror -> cases 1 to 3 reap.
        // Deliberate break: treat any old frame as uncertainty -> cases 4 and 5 never reap.
    }
}

/// Folds every registry frame one channel emits into C3's `RegistryMirror`, keeping the reading after each fold.
///
/// The engine's task frames pass in microseconds — the fixture's `background_tasks_changed` and its `task_started`
/// carry the same recorded millisecond — so a test that could only read the mirror as it stands would never catch it
/// armed. Every reading here was produced by C3's reducer from a frame the replay really sent.
private final class MirrorFold: Sendable {
    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<WireEvent>) {
        let box = self.box
        task = Task {
            for await event in stream {
                guard case .frame(let frame, let epoch) = event else { continue }
                box.note(frame, epoch: epoch)
            }
        }
    }

    deinit { task.cancel() }

    fileprivate final class Box: @unchecked Sendable {   // `lock` serialises the mirror, the readings and the count
        private let lock = NSLock()
        private var mirror = RegistryMirror()
        private var readings: [[RegistryEntry]] = []
        private var results = 0
        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

        func note(_ frame: Frame, epoch: ProcessEpoch) {
            switch frame {
            case .system(let system):
                lock.lock()
                mirror.apply(system, at: Date(), epoch: epoch)
                readings.append(mirror.entries.values.sorted { $0.id < $1.id })
                lock.unlock()
            case .result:
                locked { results += 1 }
            default:
                break
            }
        }

        var resultCount: Int { locked { results } }
        var all: [[RegistryEntry]] { locked { readings } }
        var latest: [RegistryEntry] { locked { readings.last ?? [] } }
        func evictable(asOf now: Date) -> Set<String> { locked { Set(mirror.evictable(asOf: now)) } }
    }

    /// The first reading in which the fold's own predicate held.
    func firstSnapshot(where predicate: ([RegistryEntry]) -> Bool) -> [RegistryEntry]? {
        box.all.first(where: predicate)
    }

    /// The mirror as it stands now.
    var snapshot: [RegistryEntry] { box.latest }

    /// The mirror once the rows the host may forget are dropped: notified, terminal, unlisted by the engine and past
    /// the eviction grace, measured from the last frame the mirror recorded. `RegistryMirror` has no remover, so the
    /// reading is filtered — which is all eligibility needs, since it reads a list of entries.
    func afterEviction(secondsAfterTheLastFrame seconds: Double) -> [RegistryEntry] {
        let latest = box.latest
        guard let newest = latest.map(\.lastFrameAt).max() else { return [] }
        let forgotten = box.evictable(asOf: newest.addingTimeInterval(seconds))
        return latest.filter { !forgotten.contains($0.id) }
    }

    /// Waits for the replay's turns to finish, so the whole fixture has been folded and no turn is running. Wall
    /// time, because a child process takes as long as it takes; nothing in the lifecycle moves on it.
    func waitForResults(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if box.resultCount >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the replay produced \(box.resultCount) result frames, not \(count)", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }
}
