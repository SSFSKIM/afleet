import XCTest
import AfleetCore
@testable import FleetSessions

final class FleetObserverTests: XCTestCase {
    private var home: ScratchConfigHome!
    private var files: ScriptedHolderFiles!
    private var clock: TestClock!
    private var observer: FleetObserver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = try ScratchConfigHome()
        files = ScriptedHolderFiles(home: home)
        clock = TestClock()
    }

    override func tearDown() async throws {
        await observer?.stop()
        home.removeAll()
        home = nil; files = nil; clock = nil; observer = nil
        try await super.tearDown()
    }

    /// The label travels as an argument from the check to the reader. It is what G1's spawn assertions read, so a
    /// mechanism that could silently leave it blank would weaken the central safety property to nothing.
    func testEveryReadCarriesTheLabelOfTheCheckItServes() async throws {
        let recording = RecordingHolderReader(base: FileHolderReader(verbs: nil))
        observer = FleetObserver(configHome: home.configHome, reader: recording, clock: clock, ownPIDs: { [] })

        await observer.start()
        await settle()
        _ = await observer.reconcileNow(label: OwnershipLabel.beforeSpawn)
        _ = await observer.reconcileNow()

        XCTAssertEqual(recording.labels,
                       [OwnershipLabel.poll, OwnershipLabel.beforeSpawn, OwnershipLabel.poll])
        XCTAssertEqual(recording.checkLabels, [OwnershipLabel.beforeSpawn])
    }

    private func start(verbs: CLIVerbs? = nil) async {
        observer = FleetObserver(configHome: home.configHome, reader: FileHolderReader(verbs: verbs),
                                 clock: clock, ownPIDs: { [] })
        await observer.start()
        await settle()
    }

    /// Both timers armed means both refreshes finished: each loop awaits its refresh before it sleeps again.
    /// `TestClock.waitForSleeperCount` is a genuine synchronisation point on the clock's own state — resumed the
    /// instant a `sleep` call brings the count to two — rather than a bounded guess at how many yields that takes.
    private func settle() async {
        await clock.waitForSleeperCount(atLeast: 2)
    }

    /// An in-place edit of a registry record fires no directory event, which is exactly why the five-second poll
    /// exists.
    func testTheFivesecondPollSeesAnInPlaceStatusChange() async throws {
        let session = SessionID(), pid = ScriptedHolderFiles.livePID
        try files.writeRegistry(pid: pid, sessionID: session, status: "idle")
        await start()
        let atStart = await observer.holders(for: session).first?.presence?.status
        XCTAssertEqual(atStart, "idle")

        try files.writeRegistry(pid: pid, sessionID: session, status: "busy")
        await clock.advance(by: .seconds(5))
        await settle()
        let afterPoll = await observer.holders(for: session).first?.presence?.status
        XCTAssertEqual(afterPoll, "busy")
    }

    /// The one test in this package that waits on wall time, bounded at two seconds, because the vnode source is
    /// the thing under test: a new file in `sessions/` must not have to wait for the poll.
    func testANewRecordIsSeenWithoutWaitingForThePoll() async throws {
        await start()
        let published = PublishedSets()
        let collector = Task { [observer] in
            guard let observer else { return }
            for await set in observer.updates { published.append(set) }
        }
        defer { collector.cancel() }

        let session = SessionID()
        try files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: session)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, published.sessions.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(published.sessions.contains(session), "the vnode source did not publish the new record")
        XCTAssertEqual(clock.now.offset, .zero, "no clock time was needed")
    }

    /// Each `agents --json` boots the CLI, so it runs on the sixty-second reconciliation and never on the poll.
    func testAgentsJSONRunsOnlyOnReconciliationNotOnThePoll() async throws {
        let calls = ScriptedProcessRunner.Recorder()
        let runner = ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files), calls: calls)
        await start(verbs: CLIVerbs(runner: runner, binary: URL(filePath: "/usr/bin/true"),
                                    configHome: home.configHome, environment: [:],
                                    diagnostics: NullFleetDiagnostics()))

        for _ in 0..<11 {
            await clock.advance(by: .seconds(5))
            await settle()
        }
        XCTAssertEqual(calls.count(prefix: ["agents", "--json"]), 0)

        await clock.advance(by: .seconds(5))
        await settle()
        XCTAssertEqual(calls.count(prefix: ["agents", "--json"]), 1)
    }

    func testUpdatesArePublishedOnlyOnChange() async throws {
        try files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: SessionID())
        await start()
        // `start()` already awaited the initial `refresh` to completion, so the one read it publishes is sitting in
        // the stream's buffer before this line runs: drawing it is an immediate `next()`, not a race.
        var iterator = observer.updates.makeAsyncIterator()
        let published = PublishedSets()
        if let first = await iterator.next() { published.append(first) }
        XCTAssertEqual(published.count, 1, "the initial read")

        for _ in 0..<3 {
            await clock.advance(by: .seconds(5))
            await settle()
        }
        // `settle()` proves every one of those polls has already run `perform()` to completion, so whatever it did
        // or did not publish is already sitting in the stream. `stop()` finishes the stream, which turns "did
        // nothing more get published" from a guess into a real drain: `next()` returns every remaining buffered
        // element and then `nil`, deterministically, with nothing left to race.
        await observer.stop()
        while let next = await iterator.next() { published.append(next) }
        XCTAssertEqual(published.count, 1, "three polls over unchanged files publish nothing")
    }
}

/// The sets the observer published, collected off its stream.
private final class PublishedSets: @unchecked Sendable {   // `lock` serialises `storage`
    private let lock = NSLock()
    private var storage: [HolderSet] = []
    func append(_ set: HolderSet) { lock.lock(); storage.append(set); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var sessions: Set<SessionID> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.flatMap { $0.holders.map(\.sessionID) })
    }
}
