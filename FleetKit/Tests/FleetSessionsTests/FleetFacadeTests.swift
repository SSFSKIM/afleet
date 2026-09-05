import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The facade over everything Tasks 1 through 8 landed: one `Fleet` per config home, built the way production
/// builds it — its own diagnostics sink, its own holder reader, its own observer, cap counter, preconditions and
/// verbs — with only the clock and the CLI runner swapped for scripted ones. The processes are real children of
/// `fake-claude` replaying a committed fixture.
final class FleetFacadeTests: XCTestCase {

    private static let fixture = "resume-no-replay"

    // MARK: - The harness

    /// A `Fleet` over a scratch config home, its scripted holder files, a manual clock and a scripted CLI runner.
    private final class Harness: @unchecked Sendable {   // every stored value is set once, in `init`
        let home: ScratchConfigHome
        let files: ScriptedHolderFiles
        let clock = TestClock()
        let runner: ScriptedProcessRunner
        let calls: ScriptedProcessRunner.Recorder
        let store: FileStateStore
        let fleet: Fleet
        let cwd: URL
        let diagnosticsDirectory: URL
        private let storeDirectory: URL

        init() throws {
            home = try ScratchConfigHome()
            files = ScriptedHolderFiles(home: home)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            cwd = temporary.appending(path: "afleet-c4-facade-cwd-\(UUID().uuidString)")
            storeDirectory = temporary.appending(path: "afleet-c4-facade-store-\(UUID().uuidString)")
            diagnosticsDirectory = temporary.appending(path: "afleet-c4-facade-diag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try home.trust(root: cwd)

            let recorder = ScriptedProcessRunner.Recorder()
            calls = recorder
            runner = ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files) + Harness.jobRules(),
                                           calls: recorder)
            store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])
            fleet = try Fleet(configHome: home.configHome,
                              environment: FakeClaudeLaunch.environment(fixture: FleetFacadeTests.fixture),
                              binary: FakeClaudeLaunch.binary, store: store,
                              diagnosticsDirectory: diagnosticsDirectory, clock: clock, runner: runner)
        }

        /// `respawn` and `rm`, which the shared default script does not answer: `jfail` is the short whose respawn
        /// the CLI refuses, which is the only way to reach the non-zero-exit arm.
        static func jobRules() -> [ScriptedProcessRunner.Rule] {
            [.init(match: { $0.count == 2 && $0[0] == "respawn" },
                   respond: { argv in .exit(argv[1] == "jfail" ? 3 : 0) }),
             .init(match: { $0.count == 2 && $0[0] == "rm" }, respond: { _ in .exit(0) })]
        }

        func tearDown() async {
            await fleet.shutdown()
            home.removeAll()
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnosticsDirectory)
        }

        /// Steps the manual clock in the release wait's own poll interval while `body` runs, so a clock-driven wait
        /// makes progress. Nothing here sleeps on wall time to move the lifecycle: every step is the test moving
        /// the clock, and the wall-clock guard only turns a hang into a named failure.
        func steppingClock<T: Sendable>(upTo limit: Duration = ChannelSupervisor.handoffBudget,
                                        file: StaticString = #filePath, line: UInt = #line,
                                        _ body: @escaping @Sendable () async throws -> T) async throws -> T {
            let done = Rig.LockedFlag()
            let clock = self.clock
            let interval = OwnershipCheck.releasePollInterval
            let stepper = Task {
                var stepped = Duration.zero
                while !done.value && stepped < limit {
                    guard clock.sleeperCount(due: interval) >= 1 else {
                        try? await Task.sleep(for: .milliseconds(1))
                        continue
                    }
                    await clock.advance(by: interval)
                    stepped += interval
                }
            }
            let work = Task { try await body() }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, !done.value else { return }
                XCTFail("the clock-stepped call never returned", file: file, line: line)
                work.cancel()
            }
            defer { done.set(); stepper.cancel(); watchdog.cancel() }
            return try await work.value
        }

        /// Waits, on wall time, for something already in flight to reach a point the test can read. It moves no
        /// part of the lifecycle: only the manual clock does that.
        func waitFor(_ description: String, timeout: Duration = .seconds(30),
                     file: StaticString = #filePath, line: UInt = #line,
                     _ predicate: @Sendable () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if await predicate() { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
            XCTFail("timed out waiting for \(description)", file: file, line: line)
            struct Timeout: Error {}
            throw Timeout()
        }

        /// Every line the fleet's own diagnostics file holds, as decoded objects.
        func diagnosticLines() async throws -> [[String: Any]] {
            await fleet.flushDiagnostics()
            let url = diagnosticsDirectory.appending(path: "fleet.log")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { line in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    struct NotAnObject: Error {}
                    throw NotAnObject()
                }
                return object
            }
        }
    }

    private var harness: Harness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try Harness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func key(_ session: SessionID) -> ChannelKey {
        ChannelKey(configHome: harness.home.url, session: session)
    }

    private func fixtureSession() throws -> SessionID { try FakeClaudeLaunch.sessionID(of: Self.fixture) }

    // MARK: - States and updates

    func testOpenListsTheChannelAndPublishesEveryTransition() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        let collected = Collected()
        let drain = Task { for await state in fleet.updates { collected.append(state) } }
        defer { drain.cancel() }

        await fleet.start()
        let state = try await fleet.open(k, cwd: harness.cwd, recent: true)
        XCTAssertEqual(state.key, k)

        let listed = await fleet.states()
        XCTAssertEqual(listed.map(\.key), [k])
        let read = await fleet.state(of: k)
        XCTAssertEqual(read?.key, k)
        let unknown = await fleet.state(of: key(SessionID()))
        XCTAssertNil(unknown, "a key the fleet has never been told about")

        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }
        try await harness.waitFor("the merged stream to carry the transitions") { collected.count >= 2 }
        XCTAssertTrue(collected.states.allSatisfy { $0.key == k })
        XCTAssertTrue(collected.states.contains { $0.origin == .owned(.ready) },
                      "the facade's `updates` merges every supervisor's stream")
    }

    func testPreconditionsRunForAChannelTheFleetKnows() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        await fleet.register(k, cwd: harness.cwd, recent: true)
        let verdict = await fleet.preconditions(for: k)
        XCTAssertEqual(verdict, .ready, "a trusted project with no holders and no project servers")

        let untrusted = key(SessionID())
        let elsewhere = harness.cwd.appending(path: "not-trusted")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        await fleet.register(untrusted, cwd: elsewhere, recent: true)
        let refused = await fleet.preconditions(for: untrusted)
        guard case .untrusted = refused else { return XCTFail("expected untrusted, got \(refused)") }
    }

    // MARK: - The event fan-out

    func testEventsAreFannedOutToEverySubscriberAndNilWithoutASupervisor() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        await fleet.register(k, cwd: harness.cwd, recent: true)

        let firstStream = await fleet.events(of: k)
        let secondStream = await fleet.events(of: k)
        let first = try XCTUnwrap(firstStream)
        let second = try XCTUnwrap(secondStream)
        let none = await fleet.events(of: key(SessionID()))
        XCTAssertNil(none, "no supervisor, no stream")

        let one = Frames(), two = Frames()
        let a = Task { for await event in first { one.append(event) } }
        let b = Task { for await event in second { two.append(event) } }
        defer { a.cancel(); b.cancel() }

        _ = try await fleet.perform(.open, on: k)
        try await harness.waitFor("both subscribers to see the replay") { one.count >= 2 && two.count >= 2 }
        XCTAssertEqual(Array(one.names.prefix(2)), Array(two.names.prefix(2)),
                       "both subscribers see the same frames alike")
    }

    // MARK: - Answers

    func testAnAnswerForAnIdNoProcessAskedIsDecisionGone() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        let id = RequestID(rawValue: "req-nobody-asked")
        do {
            _ = try await fleet.perform(.answer(id, .permission(.allow(updatedInput: nil, updatedPermissions: nil,
                                                                       classification: nil))), on: k)
            XCTFail("an id no process asked was answered")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .decisionGone(id))
        }
    }

    // MARK: - The terminal hatch

    func testOpenInTerminalHandsOffAndAPaneExitReAdopts() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        let request = try await harness.steppingClock { try await fleet.openInTerminal(k) }
        XCTAssertEqual(request.purpose, PanePurpose.hatch(k.session))
        XCTAssertEqual(request.arguments, ["--resume", k.session.description])
        XCTAssertEqual(request.executable, FakeClaudeLaunch.binary)
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], harness.home.url.path)
        let handedOff = await fleet.state(of: k)?.origin
        XCTAssertEqual(handedOff, .foreignLive(.ownTerminalTab))

        try await harness.steppingClock {
            await fleet.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        }
        try await harness.waitFor("the re-adoption") { await fleet.state(of: k)?.origin == .owned(.ready) }

        // A late exit for a request nobody is waiting on changes nothing and is recorded as stale.
        await fleet.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))
        let events = try await harness.diagnosticLines().compactMap { $0["event"] as? String }
        XCTAssertTrue(events.contains("stale_exit"), "the second exit for the same id was discarded")
    }

    // MARK: - Jobs

    func testJobsListsAnExecJobAndAConversationJobAndTheVerbsActOnThem() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        // An exec job: a roster worker whose job record names no session.
        try harness.files.writeJob(short: "jexec1", state: "working", pid: ScriptedHolderFiles.livePID)

        _ = try await harness.steppingClock { try await fleet.perform(.sendToBackground, on: k) }
        let handedOver = await fleet.state(of: k)?.origin
        XCTAssertEqual(handedOver, .backgroundJob,
                       "a session afleet sent to the background is a channel and a job at once")

        let jobs = await fleet.jobs()
        let exec = try XCTUnwrap(jobs.first { $0.short == JobShort(rawValue: "jexec1") })
        XCTAssertNil(exec.sessionID, "an exec job carries no session")
        let conversation = try XCTUnwrap(jobs.first { $0.sessionID == k.session })
        XCTAssertEqual(conversation.state, "working")

        // `attach` and `logs` are panes and change no ownership.
        let attach = try await fleet.attach(conversation.short)
        XCTAssertEqual(attach.purpose, PanePurpose.attach(conversation.short))
        XCTAssertEqual(attach.arguments, ["attach", conversation.short.rawValue])
        let logs = try await fleet.logs(conversation.short)
        XCTAssertEqual(logs.purpose, PanePurpose.logs(conversation.short))
        XCTAssertEqual(logs.arguments, ["logs", conversation.short.rawValue])
        let unchanged = await fleet.state(of: k)?.origin
        XCTAssertEqual(unchanged, .backgroundJob)

        // Stop: the runner ran the verb and the entry left the roster.
        try await fleet.performJob(.stop, conversation.short)
        XCTAssertTrue(harness.calls.invocations.contains(["stop", conversation.short.rawValue]))
        let after = await fleet.jobs()
        XCTAssertFalse(after.contains { $0.short == conversation.short }, "a stopped job left the roster")

        try await fleet.performJob(.respawn, JobShort(rawValue: "jexec1"))
        XCTAssertTrue(harness.calls.invocations.contains(["respawn", "jexec1"]))
        try await fleet.performJob(.remove, JobShort(rawValue: "jexec1"))
        XCTAssertTrue(harness.calls.invocations.contains(["rm", "jexec1"]))

        do {
            try await fleet.performJob(.respawn, JobShort(rawValue: "jfail"))
            XCTFail("a non-zero exit was not reported")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .verbFailed(verb: "respawn", exitCode: 3))
        }
    }

    /// The two `--bg` verbs run *in* the project's directory. `ProcessRunner` has no working-directory parameter,
    /// so FleetKit's own seam carries one; without it the job would be created in whatever directory afleet itself
    /// was started from.
    func testTheBackgroundVerbRunsInTheChannelsWorkingDirectory() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        _ = try await harness.steppingClock { try await fleet.perform(.sendToBackground, on: k) }

        let index = try XCTUnwrap(harness.calls.invocations.firstIndex { $0.starts(with: ["--bg", "--resume"]) })
        XCTAssertEqual(harness.calls.directoriesUsed[index], harness.cwd,
                       "the job was created in the channel's directory")
        let agents = try XCTUnwrap(harness.calls.invocations.firstIndex { $0.starts(with: ["agents", "--json"]) })
        XCTAssertNil(harness.calls.directoriesUsed[agents], "a verb that acts on the config home names no directory")
    }

    /// The production conformance of the working-directory seam really does start the child in the directory it
    /// names. The child here is `/bin/pwd`, a process this test starts itself.
    func testTheProductionRunnerStartsItsChildInTheNamedDirectory() async throws {
        let harness = self.harness!
        let runner = FoundationDirectoryRunner()
        let out = try await runner.run(URL(filePath: "/bin/pwd"), arguments: [], environment: [:],
                                       cwd: harness.cwd, timeout: .seconds(10))
        XCTAssertEqual(out.exitCode, 0)
        // Both sides resolved: `pwd` prints the real path and `/var/folders` is a symlink to `/private/var`, so
        // comparing the two spellings would compare one directory with itself and fail.
        let reported = URL(filePath: String(decoding: out.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        func real(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        XCTAssertEqual(real(reported), real(harness.cwd))
    }

    // MARK: - The §6.12 decline, project-wide

    /// §6.12's precondition is about the *project*, not about the channel the sheet happens to be open in. Two
    /// channels in one project — ordinary for this app — must not let the idle one write while the other's child is
    /// live: the live child has already loaded the server, and an `mcp_toggle` after the fact arrives too late.
    func testDeclineRefusesWhileAnyChannelInTheProjectHasALiveProcess() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let project = try TemporaryProject()
        defer { project.remove() }
        try harness.home.trust(root: project.root)

        await fleet.start()
        let live = key(try fixtureSession())
        // An id that sorts first, so the channel the facade picks to perform the write is deterministically the
        // one with no process of its own: a per-channel precondition would answer "nothing is live" from it.
        let idle = key(try XCTUnwrap(SessionID("00000000-0000-4000-8000-000000000001")))
        await fleet.register(idle, cwd: project.root, recent: false)
        XCTAssertLessThan(idle.session.description, live.session.description)
        _ = try await fleet.open(live, cwd: project.root, recent: true)
        try await harness.waitFor("the live channel") { await fleet.state(of: live)?.origin == .owned(.ready) }
        // The server is declared after the channel came up, exactly as a project gains one while afleet is
        // running: the live child has already loaded whatever it was going to load, which is why the write waits.
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])

        do {
            try await fleet.declineProjectServers(["d"], project: project.root)
            XCTFail("the decline was written while a channel in the project was live")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .declineRefused(reason: "processLive"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.localSettingsFile.path(percentEncoded: false)),
                       "a live process in the project means nothing is written at all")

        // With every channel in the project reaped, the same call goes through.
        _ = try await fleet.perform(.reap, on: live)
        try await fleet.declineProjectServers(["d"], project: project.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.localSettingsFile.path(percentEncoded: false)))
    }

    // MARK: - `/logout` is fleet-level

    /// The `/logout` barrier is not a channel banner: the plan is fleet-wide, the refusal it raises is
    /// `LifecycleError.logoutInProgress`, and the facade hands it to the caller for the shell to render.
    func testLogoutRaisesTheFleetWideBarrierAndAbandoningLowersIt() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }

        _ = try await fleet.perform(.logout, on: k)
        let built = await fleet.logoutCensus()
        let census = try XCTUnwrap(built)
        XCTAssertEqual(census.owned, [k])

        let blocked = key(SessionID())
        do {
            _ = try await fleet.open(blocked, cwd: harness.cwd, recent: true)
            XCTFail("a channel came up into a fleet that is signing out")
        } catch {
            XCTAssertEqual(error as? LifecycleError, .logoutInProgress)
        }
        let stillArchived = await fleet.state(of: blocked)?.origin
        XCTAssertEqual(stillArchived, .archived, "the refusal left no half-opened channel behind")

        await fleet.abandonLogout()
        let gone = await fleet.logoutCensus()
        XCTAssertNil(gone)
        _ = try await fleet.open(blocked, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the once-blocked channel") {
            await fleet.state(of: blocked)?.origin == .owned(.ready)
        }
    }

    // MARK: - Diagnostics

    /// One JSON line per event, structural fields only. The assertion is on the *key names*: a path under a config
    /// home, an environment, a record or stdout must not be able to reach this file, and a key with one of those
    /// names is how it would.
    func testTheDiagnosticsFileIsOneJSONLinePerEventAndCarriesNoForbiddenKey() async throws {
        let harness = self.harness!
        let fleet = harness.fleet
        let k = key(try fixtureSession())
        await fleet.start()
        _ = try await fleet.open(k, cwd: harness.cwd, recent: true)
        try await harness.waitFor("the channel to be ready") { await fleet.state(of: k)?.origin == .owned(.ready) }
        _ = try await harness.steppingClock { try await fleet.openInTerminal(k) }

        let lines = try await harness.diagnosticLines()
        XCTAssertGreaterThan(lines.count, 0, "the fleet wrote no diagnostics at all")
        for line in lines { XCTAssertNotNil(line["event"] as? String, "every line names its event") }

        let forbidden: Set<String> = ["path", "environment", "stdout", "record"]
        let names = Set(lines.flatMap(\.keys))
        XCTAssertTrue(names.contains("event"))
        XCTAssertTrue(names.isDisjoint(with: forbidden),
                      "forbidden keys: \(names.intersection(forbidden).sorted())")
        let events = Set(lines.compactMap { $0["event"] as? String })
        XCTAssertTrue(events.contains("ownership_check"), "the ownership checks around the spawn")
        XCTAssertTrue(events.contains("pane_request"), "the hatch")
        XCTAssertTrue(events.contains("cap_decision"), "the cap counter's decision")
    }

    // MARK: - Collecting

    private final class Collected: @unchecked Sendable {   // `lock` serialises `storage`
        private let lock = NSLock()
        private var storage: [ChannelState] = []
        func append(_ state: ChannelState) { lock.lock(); storage.append(state); lock.unlock() }
        var states: [ChannelState] { lock.lock(); defer { lock.unlock() }; return storage }
        var count: Int { states.count }
    }

    private final class Frames: @unchecked Sendable {   // `lock` serialises `storage`
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ event: WireEvent) {
            let name: String
            switch event {
            case .frame(let frame, _): name = "frame:" + frame.typeName
            case .handshakeCompleted: name = "handshake"
            case .sessionIdentityResolved: name = "identity"
            case .request(let request): name = "request:" + request.subtype
            default: name = "other"
            }
            lock.lock(); storage.append(name); lock.unlock()
        }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        var count: Int { names.count }
    }
}
