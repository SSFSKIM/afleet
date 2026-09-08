import Foundation
import XCTest
import AfleetCore
@testable import FleetSessions

/// X5's roster signal: `LifecycleAPI.jobUpdates`.
///
/// `updates` is keyed by channel and cannot carry this. An exec job has no session and therefore no channel at all,
/// and a conversation job changing state — `working` to `blocked` — moves only its own `jobs/<short>/state.json`,
/// which `HolderReader` does not turn into a holder. A surface listening to `updates` alone therefore never learns
/// that the roster moved, and the only route left to it is `jobs()`, which runs `agents --json` and boots the CLI.
/// So the roster is published from the read the observer was already taking.
///
/// The publication rule is the one `f9da990` established for holders: publish only when the view actually changed.
/// A read whose `jobs` equal the last published read's is not a roster change however many holders moved
/// underneath it, and a read that moved the holders alone is not one either.
///
/// Every assertion here is on the whole published sequence, drawn after `shutdown()` has finished the stream: "and
/// nothing else was published" is then a drain to `nil` rather than a wait long enough to feel safe.
///
/// Deliberate break: make `FleetObserver.perform` yield on `jobsContinuation` unconditionally → the holder-only and
/// unchanged-roster tests each gain a publication and fail.
final class RosterSignalTests: XCTestCase {

    private var harness: Harness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// A job that appears where afleet did not put it is published once, with the whole roster as `jobs()` would
    /// answer it. The job here carries no session — an exec job, the case a channel-keyed stream is structurally
    /// unable to represent.
    func testAJobAppearingOutsideAfleetPublishesTheRosterOnce() async throws {
        let harness = try newHarness()
        try await harness.start()

        try harness.files.writeJob(short: "jexec1", state: "working", pid: ScriptedHolderFiles.livePID)
        try await harness.poll()
        try await harness.poll()

        let rosters = await harness.published()
        XCTAssertEqual(rosters.count, 2, "the initial empty roster, then the new job once")
        XCTAssertEqual(rosters.first, [], "the first read found no jobs")
        XCTAssertEqual(rosters.last?.map(\.short.rawValue), ["jexec1"])
        XCTAssertEqual(rosters.last?.map(\.state), ["working"])
        XCTAssertNil(rosters.last?.first?.sessionID, "an exec job carries no session")
    }

    /// A holder moving is not a roster change. The registry record here is a session with no job behind it, which
    /// is what every interactive channel on the machine is: republishing the roster for each of them would put a
    /// listening sidebar back on one republication per registration.
    func testAHolderChangeWithNoJobBehindItPublishesNoRoster() async throws {
        let harness = try newHarness()
        try await harness.start()

        try harness.files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: SessionID())
        try await harness.poll()

        let rosters = await harness.published()
        XCTAssertEqual(rosters.count, 1, "a holder with no job behind it published a roster")
    }

    /// Two reads of the same files are one roster, however often the observer takes them.
    func testAnUnchangedRosterPublishesNothingHoweverOftenItIsRead() async throws {
        let harness = try newHarness()
        try harness.files.writeJob(short: "jstill", state: "working", pid: ScriptedHolderFiles.livePID)
        try await harness.start()

        try await harness.poll()
        try await harness.poll()

        let rosters = await harness.published()
        XCTAssertEqual(rosters.count, 1, "re-reading the same files republished the roster")
        XCTAssertEqual(rosters.first?.map(\.short.rawValue), ["jstill"])
    }

    /// A job changing state without moving a holder is the other half of the finding: the worker's pid is the same
    /// process throughout, so the holders are identical across both reads and only the record moved.
    func testAJobChangingStatePublishesTheNewState() async throws {
        let harness = try newHarness()
        let session = SessionID()
        try harness.files.writeJob(short: "jturn", state: "working", sessionID: session,
                                   pid: ScriptedHolderFiles.livePID)
        try await harness.start()

        try harness.files.writeJob(short: "jturn", state: "blocked", sessionID: session,
                                   pid: ScriptedHolderFiles.livePID)
        try await harness.poll()

        let rosters = await harness.published()
        XCTAssertEqual(rosters.count, 2)
        XCTAssertEqual(rosters.first?.map(\.state), ["working"])
        XCTAssertEqual(rosters.last?.map(\.state), ["blocked"])
        XCTAssertEqual(rosters.last?.first?.sessionID, session, "a conversation job carries its session")
    }

    // MARK: - The harness

    private func newHarness() throws -> Harness {
        let harness = try Harness()
        self.harness = harness
        return harness
    }

    /// A `Fleet` over a scratch config home, its scripted holder files and a manual clock, with the CLI runner
    /// scripted. It registers no channel and spawns nothing: every read here is the observer's own.
    private final class Harness: @unchecked Sendable {   // every stored value is set once, in `init`
        let home: ScratchConfigHome
        let files: ScriptedHolderFiles
        let clock = TestClock()
        let fleet: Fleet
        private let store: FileStateStore
        private let storeDirectory: URL
        private let diagnosticsDirectory: URL
        private var stream: AsyncStream<[JobEntry]>?
        private var shutDown = false

        init() throws {
            home = try ScratchConfigHome()
            files = ScriptedHolderFiles(home: home)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            storeDirectory = temporary.appending(path: "afleet-roster-store-\(UUID().uuidString)")
            diagnosticsDirectory = temporary.appending(path: "afleet-roster-diag-\(UUID().uuidString)")
            store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])
            let runner = ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files),
                                               calls: ScriptedProcessRunner.Recorder())
            fleet = Fleet(configHome: home.configHome,
                          environment: FakeClaudeLaunch.environment(fixture: "resume-no-replay"),
                          binary: FakeClaudeLaunch.binary, store: store,
                          diagnosticsDirectory: diagnosticsDirectory, clock: clock, runner: runner)
        }

        /// Starts the fleet and holds the stream. The stream buffers without bound, so every roster published from
        /// here on is drawn later whatever order the reads and this line happen in.
        func start() async throws {
            stream = fleet.jobUpdates
            await fleet.start()
            await settle()
        }

        /// One five-second poll, run to completion.
        func poll() async throws {
            await clock.advance(by: .seconds(5))
            await settle()
        }

        /// Every roster published, in order. `shutdown()` drains the observer into the fleet's stream and then
        /// finishes it, so the iteration below ends rather than waiting on a publication that can never come.
        func published() async -> [[JobEntry]] {
            await shutdown()
            guard let stream else { return [] }
            var rosters: [[JobEntry]] = []
            for await roster in stream { rosters.append(roster) }
            return rosters
        }

        /// Both of the observer's timers armed means both of its refreshes have run to completion.
        private func settle() async {
            await clock.waitForSleeperCount(atLeast: 2)
        }

        private func shutdown() async {
            guard !shutDown else { return }
            shutDown = true
            await fleet.shutdown()
        }

        func tearDown() async {
            await shutdown()
            home.removeAll()
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnosticsDirectory)
        }
    }
}
