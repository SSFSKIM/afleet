import XCTest
import AfleetCore
@testable import FleetSessions

/// A sink that keeps what it was told, so a test can assert the reader diagnosed a liveness fallback. It prints
/// nothing: only a pid ever reaches these events.
final class CollectingFleetDiagnostics: FleetDiagnosticsSink, @unchecked Sendable {   // `lock` serialises `storage`
    private let lock = NSLock()
    private var storage: [FleetDiagnosticEvent] = []
    init() {}
    func record(_ event: FleetDiagnosticEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [FleetDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    /// The `event` value of each recorded event, in order.
    var names: [String] { events.compactMap { $0.jsonValue["event"]?.stringValue } }
    /// The pids the named event was recorded for.
    func pids(of name: String) -> [Int64] {
        events.filter { $0.jsonValue["event"]?.stringValue == name }.compactMap { $0.jsonValue["pid"]?.intValue }
    }
}

final class HolderReaderTests: XCTestCase {
    private var home: ScratchConfigHome!
    private var files: ScriptedHolderFiles!
    private var sink: CollectingFleetDiagnostics!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = try ScratchConfigHome()
        files = ScriptedHolderFiles(home: home)
        sink = CollectingFleetDiagnostics()
    }

    override func tearDown() {
        home.removeAll()
        home = nil; files = nil; sink = nil
        super.tearDown()
    }

    private func read(ownPIDs: Set<Int32> = [], verbs: CLIVerbs? = nil, agentsJSON: Bool = false,
                      startTime: @escaping ProcessLiveness.StartTimeReader = ProcessLiveness.startTime(of:),
                      label: String = OwnershipLabel.poll) async -> HolderSnapshot {
        await FileHolderReader(verbs: verbs, diagnostics: sink, startTime: startTime)
            .read(configHome: home.configHome, ownPIDs: ownPIDs, includeAgentsJSON: agentsJSON, label: label)
    }

    /// A live pid and a never-live one, side by side. The dead record is ignored, never deleted.
    func testALiveRegistryRecordIsAHolderAndADeadOneIsNot() async throws {
        let live = SessionID(), dead = SessionID()
        try files.writeRegistry(pid: ScriptedHolderFiles.livePID, sessionID: live)
        try files.writeRegistry(pid: ScriptedHolderFiles.deadPID, sessionID: dead,
                                procStart: .literal("Fri Sep  5 03:12:41 2026"))
        let snapshot = await read()
        XCTAssertEqual(snapshot.holders.holders.map(\.pid), [ScriptedHolderFiles.livePID])
        XCTAssertEqual(snapshot.holders.holders.map(\.sessionID), [live])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: files.root.appending(path: "sessions/\(ScriptedHolderFiles.deadPID).json")
                .path(percentEncoded: false)), "a dead record is ignored, never deleted")
    }

    /// A pid the kernel handed out again is live, but it is not the process that wrote the record. With no usable
    /// token the sixty-second window is all there is, and it says no — and says so with a diagnostic.
    func testAReusedPIDIsNotAHolder() async throws {
        let pid = ScriptedHolderFiles.livePID
        let aDayBefore = try XCTUnwrap(ProcessLiveness.startTime(of: pid)).timeIntervalSince1970 * 1000 - 86_400_000

        try files.writeRegistry(pid: pid, sessionID: SessionID(), startedAt: aDayBefore, procStart: .absent)
        var snapshot = await read()
        XCTAssertTrue(snapshot.holders.holders.isEmpty)
        XCTAssertEqual(sink.pids(of: "proc_start_absent"), [Int64(pid)])

        sink = CollectingFleetDiagnostics()
        try files.writeRegistry(pid: pid, sessionID: SessionID(), startedAt: aDayBefore,
                                procStart: .literal("scripted"))
        snapshot = await read()
        XCTAssertTrue(snapshot.holders.holders.isEmpty)
        XCTAssertEqual(sink.pids(of: "proc_start_unparseable"), [Int64(pid)])
    }

    /// A present, parseable token *is* the comparison. The window is only the fallback, so a token that disagrees
    /// rejects the holder however fresh `startedAt` looks, and a token that agrees accepts it however stale it looks.
    func testAWrongProcStartRejectsTheHolderEvenInsideTheStartedAtWindow() async throws {
        let pid = ScriptedHolderFiles.livePID
        let started = try XCTUnwrap(ProcessLiveness.startTime(of: pid))
        let aMinuteLater = ProcessLiveness.token(for: started.addingTimeInterval(60))

        try files.writeRegistry(pid: pid, sessionID: SessionID(),
                                startedAt: Date().timeIntervalSince1970 * 1000, procStart: .literal(aMinuteLater))
        var snapshot = await read()
        XCTAssertTrue(snapshot.holders.holders.isEmpty, "a token that disagrees is a reused pid")
        XCTAssertEqual(ProcessLiveness.evaluate(pid: pid, startedAt: Date().timeIntervalSince1970 * 1000,
                                                procStart: aMinuteLater), .startMismatch)
        XCTAssertEqual(sink.names, [], "the token decided, so no fallback was taken and none is diagnosed")

        files.removeRegistry(pid: pid)
        sink = CollectingFleetDiagnostics()
        try files.writeRegistry(pid: pid, sessionID: SessionID(),
                                startedAt: started.timeIntervalSince1970 * 1000 - 86_400_000, procStart: .correct)
        snapshot = await read()
        XCTAssertEqual(snapshot.holders.holders.count, 1, "a correct token holds whatever startedAt says")
        XCTAssertEqual(sink.names, [])
    }

    /// The roster is the liveness authority for a job: `state.json` alone outlives the worker.
    func testAJobIsLiveOnlyWhileTheRosterNamesItsWorker() async throws {
        let session = SessionID()
        try files.writeJob(short: "j00001", state: "working", sessionID: session, pid: ScriptedHolderFiles.livePID)
        var snapshot = await read()
        XCTAssertEqual(snapshot.holders.holders.count, 1)
        XCTAssertEqual(snapshot.holders.holders.first?.jobShort, "j00001")
        XCTAssertEqual(snapshot.holders.holders.first?.isJob, true)

        try files.stopJob(short: "j00001")
        snapshot = await read()
        XCTAssertTrue(snapshot.holders.holders.isEmpty)
        XCTAssertEqual(snapshot.jobs[JobShort(rawValue: "j00001")]?.state, "stopped",
                       "the record stays readable; only the holder is gone")
    }

    func testOwnChildrenAreMarkedNotForeign() async throws {
        let pid = ScriptedHolderFiles.livePID
        try files.writeRegistry(pid: pid, sessionID: SessionID(), entrypoint: "sdk-cli")
        let snapshot = await read(ownPIDs: [pid])
        XCTAssertEqual(snapshot.holders.holders.count, 1)
        XCTAssertEqual(snapshot.holders.holders.first?.isOwnChild, true)
        XCTAssertTrue(snapshot.holders.foreign.isEmpty)
    }

    /// `agents --json` lists afleet's own children and every job too, which is why the two reads name one holder by
    /// two words and are reconciled by pid rather than unioned.
    func testAgentsJSONRowsReconcileByPIDNotByUnion() async throws {
        let session = SessionID()
        try files.writeJob(short: "j00001", state: "working", sessionID: session, pid: ScriptedHolderFiles.livePID)
        let snapshot = await read(verbs: verbs(), agentsJSON: true)
        XCTAssertEqual(snapshot.holders.holders.count, 1)
        XCTAssertEqual(snapshot.holders.holders.first?.sources, [.roster, .agentsJSON])
        XCTAssertEqual(snapshot.holders.holders.first?.sessionID, session)
    }

    func testUnreadableAndMalformedFilesAreSkippedAndCounted() async throws {
        let sessions = files.root.appending(path: "sessions")
        try Data(#"{"pid": 4242, "sessionId": "#.utf8).write(to: sessions.appending(path: "4242.json"))
        try Data("not json at all".utf8).write(to: sessions.appending(path: "x.json"))
        let snapshot = await read()
        XCTAssertTrue(snapshot.holders.holders.isEmpty)
        XCTAssertEqual(snapshot.skipped, 2)
    }

    /// The reader sets `jobShort` on a holder it merged from a registry record and a roster entry, so a conversation
    /// job's worker is a job and never a foreign terminal.
    func testAHolderMergedFromARegistryRecordAndARosterEntryCarriesTheJobShort() async throws {
        let session = SessionID(), pid = ScriptedHolderFiles.livePID
        try files.writeRegistry(pid: pid, sessionID: session, kind: "bg", entrypoint: "cli")
        try files.writeJob(short: "j00001", state: "working", sessionID: session, pid: pid)
        let snapshot = await read()
        let holder = try XCTUnwrap(snapshot.holders.holders.first)
        XCTAssertEqual(snapshot.holders.holders.count, 1)
        XCTAssertEqual(holder.sources, [.registry, .roster])
        XCTAssertEqual(holder.jobShort, "j00001")
        XCTAssertTrue(holder.isJob)
    }

    /// `kill(pid, 0)` has already said the process is live; only the start-time read failed, so neither the token
    /// nor the window can be compared against anything. Answering "not a holder" there is the unsafe direction —
    /// these checks exist to *refuse* a spawn — so an unreadable live pid counts as a holder and says why it had to.
    /// The refusal is injected through the start-time seam: no test touches a process it did not start.
    func testALivePIDWhoseStartTimeCannotBeReadIsStillAHolder() async throws {
        let pid = ScriptedHolderFiles.livePID
        let session = SessionID()
        try files.writeRegistry(pid: pid, sessionID: session, procStart: .correct)

        let snapshot = await read(startTime: { _ in nil })

        XCTAssertEqual(snapshot.holders.holders.map(\.pid), [pid], "an unreadable live pid is still a holder")
        XCTAssertEqual(snapshot.holders.holders.map(\.sessionID), [session])
        XCTAssertEqual(sink.pids(of: "start_time_unreadable"), [Int64(pid)], "and the fallback is diagnosed")
        XCTAssertEqual(ProcessLiveness.evaluate(pid: pid, startedAt: nil, procStart: nil,
                                                startTime: { _ in nil }),
                       .liveByWindow(.startTimeUnreadable))
        // A pid that is not running is still not running: `kill(pid, 0)` decides that, and no seam changes it.
        XCTAssertEqual(ProcessLiveness.evaluate(pid: ScriptedHolderFiles.deadPID, startedAt: nil, procStart: nil,
                                                startTime: { _ in nil }),
                       .dead)
    }

    /// A roster worker whose start time cannot be read is a holder for the same reason, and the job it belongs to
    /// stays live.
    func testARosterWorkerWhoseStartTimeCannotBeReadIsStillAHolder() async throws {
        let session = SessionID()
        try files.writeJob(short: "j00001", state: "working", sessionID: session, pid: ScriptedHolderFiles.livePID)

        let snapshot = await read(startTime: { _ in nil })

        XCTAssertEqual(snapshot.holders.holders.map(\.jobShort), ["j00001"])
        XCTAssertEqual(sink.pids(of: "start_time_unreadable"), [Int64(ScriptedHolderFiles.livePID)])
    }

    private func verbs() -> CLIVerbs {
        CLIVerbs(runner: ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files)),
                 binary: URL(filePath: "/usr/bin/true"), configHome: home.configHome,
                 environment: [:], diagnostics: NullFleetDiagnostics())
    }
}
