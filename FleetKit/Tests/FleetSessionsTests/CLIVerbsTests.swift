import XCTest
import AfleetCore
import WireTransport
@testable import FleetSessions

final class CLIVerbsTests: XCTestCase {
    private var home: ScratchConfigHome!
    private var files: ScriptedHolderFiles!
    private var calls: ScriptedProcessRunner.Recorder!
    private var sink: CollectingFleetDiagnostics!
    private var verbs: CLIVerbs!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = try ScratchConfigHome()
        files = ScriptedHolderFiles(home: home)
        calls = ScriptedProcessRunner.Recorder()
        sink = CollectingFleetDiagnostics()
        verbs = CLIVerbs(runner: ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files), calls: calls),
                         binary: URL(filePath: "/usr/bin/true"), configHome: home.configHome,
                         environment: childEnvironment(), diagnostics: sink)
    }

    override func tearDown() {
        home.removeAll()
        home = nil; files = nil; calls = nil; sink = nil; verbs = nil
        super.tearDown()
    }

    /// What the facade composes once: a dummy launch's child environment over a resolved one, pinned to this home.
    private func childEnvironment() -> [String: String] {
        let launch = LaunchConfiguration(binary: URL(filePath: "/usr/bin/true"), cwd: home.url,
                                         session: .new(SessionID()))
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], shell: "/bin/zsh",
                                       capturedAt: Date(), mode: .processFallback)
        return launch.childEnvironment(over: base, configHome: home.configHome)
    }

    func testAgentsJSONDecodesTheScriptedArray() async throws {
        let session = SessionID()
        try files.writeJob(short: "j00001", state: "working", sessionID: session, pid: ScriptedHolderFiles.livePID)
        try files.writeRegistry(pid: ScriptedHolderFiles.deadPID, sessionID: SessionID(), status: "idle")

        let rows = try await verbs.agentsJSON()
        XCTAssertEqual(calls.invocations, [["agents", "--json"]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, "j00001")
        XCTAssertEqual(rows.first?.state, "working")
        XCTAssertEqual(rows.first?.sessionId, session.description)
        XCTAssertEqual(rows.last?.kind, "interactive")
        XCTAssertEqual(rows.last?.status, "idle")
    }

    /// The verb runs in the resolved environment with `CLAUDE_CONFIG_DIR` pinned to this home. The value is compared,
    /// never printed.
    func testStopRecordsTheInvocationAndRunsInTheHomesEnvironment() async throws {
        try files.writeJob(short: "j00001", state: "working", sessionID: SessionID(),
                           pid: ScriptedHolderFiles.livePID)
        try await verbs.stop(JobShort(rawValue: "j00001"))

        XCTAssertEqual(calls.invocations, [["stop", "j00001"]])
        let environment = try XCTUnwrap(calls.environments.first)
        XCTAssertTrue(environment.keys.contains("CLAUDE_CONFIG_DIR"))
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], home.url.path)
        XCTAssertEqual(files.job("j00001")?.state, "stopped")
        XCTAssertNil(files.rosterWorkers()["j00001"])
    }

    func testBackgroundResumeReturnsTheShortOfTheMatchingJob() async throws {
        let wanted = SessionID()
        // A job that was already there, resuming a different session, must not be mistaken for the new one.
        try files.writeJob(short: "j00000", state: "working", sessionID: SessionID(),
                           resumeSessionID: SessionID(), pid: ScriptedHolderFiles.livePID)

        let short = try await verbs.backgroundResume(wanted, cwd: home.url)
        XCTAssertEqual(calls.invocations, [["--bg", "--resume", wanted.description]])
        XCTAssertNotEqual(short.rawValue, "j00000")
        XCTAssertEqual(files.job(short.rawValue)?.resumeSessionId, wanted.description)
        XCTAssertNotNil(files.rosterWorkers()[short.rawValue], "the short is confirmed in the roster")
    }

    /// The CLI exiting zero does not mean the daemon has written the roster yet, and this package has no probe
    /// evidence either way, so the confirmation re-reads on the injected clock instead of assuming.
    func testBackgroundResumeWaitsForTheRosterToNameTheNewWorker() async throws {
        let clock = TestClock()
        let files = self.files!
        let short = "j00007"
        // The job file lands with the CLI's exit; the roster entry does not.
        let rule = ScriptedProcessRunner.Rule(
            match: { $0.count == 3 && $0[0] == "--bg" && $0[1] == "--resume" },
            respond: { argv in
                guard let id = SessionID(argv[2]) else { return .exit(1) }
                try files.writeJob(short: short, state: "working", sessionID: id, resumeSessionID: id, pid: nil)
                return .exit(0)
            })
        let waiting = CLIVerbs(runner: ScriptedProcessRunner(rules: [rule], calls: calls),
                               binary: URL(filePath: "/usr/bin/true"), configHome: home.configHome,
                               environment: [:], diagnostics: sink, clock: clock)

        let wanted = SessionID()
        let cwd = home.url
        let call = Task { try await waiting.backgroundResume(wanted, cwd: cwd) }
        // A genuine synchronisation point on the clock's own state — see `TestClock.waitForSleeperCount` — rather
        // than a bounded guess at how many yields the first roster miss takes to register.
        await clock.waitForSleeperCount(atLeast: 1)
        XCTAssertEqual(clock.sleeperCount, 1, "the first roster read missed and the verb is waiting on the clock")

        try files.addRosterWorker(short: short, pid: ScriptedHolderFiles.livePID)
        await clock.advance(by: .milliseconds(200))
        let resolved = try await call.value
        XCTAssertEqual(resolved.rawValue, short)
        XCTAssertTrue(sink.names.allSatisfy { $0 != "job_not_listed_after_background" })
    }

    func testANonZeroExitThrowsVerbFailed() async {
        // `respawn` has no rule in the default script, so the runner exits 1.
        do {
            try await verbs.respawn(JobShort(rawValue: "j00001"))
            XCTFail("a non-zero exit must throw")
        } catch let error as LifecycleError {
            XCTAssertEqual(error, .verbFailed(verb: "respawn", exitCode: 1))
        } catch {
            XCTFail("the wrong error escaped: \(type(of: error))")
        }
    }

    /// The diagnostic carries the verb, the exit code and the duration and nothing else — never stdout, never the
    /// environment, never a path under a config home.
    func testEveryVerbRecordsExactlyVerbExitCodeAndDuration() async throws {
        _ = try await verbs.agentsJSON()
        try? await verbs.respawn(JobShort(rawValue: "j00001"))

        let events = sink.events.filter { $0.jsonValue["event"]?.stringValue == "cli_verb" }
        XCTAssertEqual(events.count, 2)
        for event in events {
            let object = try XCTUnwrap(event.jsonValue.objectValue)
            XCTAssertEqual(Set(object.keys), ["event", "verb", "exit_code", "duration_ms"])
        }
        XCTAssertEqual(events.first?.jsonValue["verb"]?.stringValue, "agents")
        XCTAssertEqual(events.first?.jsonValue["exit_code"]?.intValue, 0)
        XCTAssertEqual(events.last?.jsonValue["verb"]?.stringValue, "respawn")
        XCTAssertEqual(events.last?.jsonValue["exit_code"]?.intValue, 1)
        XCTAssertNotNil(events.last?.jsonValue["duration_ms"]?.intValue)
    }
}
