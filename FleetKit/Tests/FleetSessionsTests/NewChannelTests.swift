import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// §8.2's *New channel* and §14 item 3, on the fleet's side: the creation verb, the launch line it
/// composes, and the one-way `--session-id` to `--resume` transition.
///
/// The invariant every test here is about is a **process's own argv**, captured at the process
/// factory, because that is the only place the flag afleet actually passes can be read. It is not
/// cosmetic: `--session-id <id>` is refused once `<projects>/<projectKey>/<id>.jsonl` exists —
/// *Session ID <id> is already in use.*, 2.1.263 `cli.pretty.js:294952` — and `--resume <id>` needs
/// that file, so a channel that changed the flag one spawn too early or too late cannot come up at
/// all.
///
/// Nothing here prints an argument, a path or a session id: every assertion is a boolean with a
/// fixed message (§11), and the one fixture-derived identifier in the file is read out of
/// `FakeClaudeLaunch.sessionID(of:)` and never written down.
final class NewChannelTests: XCTestCase {

    private static let fixture = "plain-two-turn"

    // MARK: - Reading a launch line

    /// The value that follows `flag` in an argv, or nil when the flag is absent.
    private static func value(of flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.index(after: index) < argv.endIndex else { return nil }
        return argv[argv.index(after: index)]
    }

    private static func argv(of launch: LaunchConfiguration) throws -> [String] {
        try launch.arguments()
    }

    // MARK: - The harness

    /// A `Fleet` built the way production builds it, with the clock, the CLI runner and the process
    /// factory swapped, and with the `SessionID` a creation mints pinned.
    ///
    /// Pinning the id is what makes the chain one claim rather than two: the id afleet "chose" is
    /// the id the committed fixture's `auth_status.session_id` carries, so *the launch line names
    /// the key's id* and *the file that appears is `<key>.jsonl`* are assertions about the same
    /// value.
    private final class Harness: @unchecked Sendable {   // every stored value is set once, in `init`
        let home: ScratchConfigHome
        let clock = TestClock()
        let fleet: Fleet
        let cwd: URL
        /// Every launch the factory was asked to build a process for, in spawn order.
        let launches = LaunchLog()
        private let files: ScriptedHolderFiles
        private let store: FileStateStore
        private let storeDirectory: URL
        private let diagnosticsDirectory: URL

        /// `liveFirstSpawn` builds a real `fake-claude` child for the first spawn and a scripted
        /// handle for every later one. That split is deliberate: only a real child writes a
        /// transcript, and only a scripted handle makes the *respawn's* argv readable without
        /// replaying a whole second recording.
        init(source: ConfigHome.Source = .environment, liveFirstSpawn: Bool = false,
             trusted: Bool = true) throws {
            home = try ScratchConfigHome(source: source)
            files = ScriptedHolderFiles(home: home)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            cwd = temporary.appending(path: "afleet-newchannel-cwd-\(UUID().uuidString)")
            storeDirectory = temporary.appending(path: "afleet-newchannel-store-\(UUID().uuidString)")
            diagnosticsDirectory = temporary.appending(path: "afleet-newchannel-diag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            if trusted { try home.trust(root: cwd) }
            store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])

            let session = try FakeClaudeLaunch.sessionID(of: NewChannelTests.fixture)
            var environment = FakeClaudeLaunch.environment(fixture: NewChannelTests.fixture)
            if liveFirstSpawn {
                // The one switch that makes the replayer write: it appends every mirror frame's
                // entries into `<home>/projects/<slug(cwd)>/…`, which is how a fixture recorded as a
                // fresh `--session-id` launch materialises its transcript under a scratch home.
                environment.variables["FAKE_CLAUDE_CONFIG_HOME"] = home.url.path
                // `fake-claude` refuses to write into `~/.claude` as *its own* HOME resolves it, so
                // the child is given a HOME that is not this home's parent.
                environment.variables["HOME"] = temporary.appending(path: "afleet-newchannel-home-\(UUID().uuidString)").path
                // **The unresolved spelling, and that is not an oversight.** `rewrite_paths` replaces
                // the recording's `fixture.json` cwd inside every frame by plain substring: the
                // recorded `system/init.cwd` is the *realpath* `/private/tmp/afleet-fixtures/…`
                // while `fixture.json` holds `/tmp/afleet-fixtures/…`, so the replacement leaves the
                // `/private` in front of whatever it substitutes. Handing it this directory's
                // unresolved spelling is what makes the rewritten cwd the real one — and the cwd
                // the engine reports is the directory every later precondition of this channel is
                // keyed on, so a doubled prefix reads as an untrusted project. Filed as tracker 442.
                environment.variables["FAKE_CLAUDE_CWD"] = cwd.path(percentEncoded: false)
            }
            let log = launches
            let childEnvironment = environment
            let configHome = home.configHome
            let wireSink = FileDiagnostics(directory: diagnosticsDirectory)
            let projectCWD = cwd
            fleet = Fleet(configHome: configHome, environment: childEnvironment,
                          binary: FakeClaudeLaunch.binary, store: store,
                          diagnosticsDirectory: diagnosticsDirectory, clock: clock,
                          factory: { epoch, launch in
                              log.append(launch)
                              guard liveFirstSpawn, epoch.rawValue == 1 else {
                                  return ScriptedProcessHandle(epoch: epoch, session: session,
                                                               pid: 600_000 + Int32(epoch.rawValue))
                              }
                              let capturing = CapturingDiagnostics(forwardingTo: wireSink)
                              let process = ClaudeProcess(epoch: epoch, launch: launch,
                                                          environment: childEnvironment, configHome: configHome,
                                                          mcpServer: AfleetMCPServer(serverVersion: "0.0.0",
                                                                                     cwd: projectCWD,
                                                                                     tools: [SendUserFileTool()]),
                                                          diagnostics: capturing, capture: nil)
                              return LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
                          },
                          runner: ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files)),
                          // Pinned only where a real child replays: the fixture carries one session
                          // id and two creations under it would be one channel, so every other test
                          // mints freshly, as production does.
                          newSessionID: { liveFirstSpawn ? session : SessionID() })
        }

        /// Whether a transcript named `<session>.jsonl` exists anywhere under this home's
        /// `projects/`.
        ///
        /// A search rather than a computed path, deliberately: the slug is the engine's own rule
        /// over the *realpath* of the working directory, and transcribing it here would put a
        /// second copy of that rule in a test whose subject is the launch line. What the claim
        /// needs is the file's **name** — the id afleet chose — and where under `projects/` it sits
        /// is the engine's business.
        func hasTranscript(of session: SessionID) -> Bool {
            let projects = home.url.appending(path: "projects", directoryHint: .isDirectory)
            guard let walk = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil) else {
                return false
            }
            let wanted = "\(session.description).jsonl"
            for case let url as URL in walk where url.lastPathComponent == wanted { return true }
            return false
        }

        /// The marker `fake-claude` refuses to replay without.
        ///
        /// Written here rather than by `fake-claude materialize`, and the two are the same thing for
        /// this fixture: `plain-two-turn`'s `initial/` holds nothing but git's own `.gitkeep`, which
        /// the materialiser skips, and its `streams.json` is `{}` — so laying down the initial state
        /// is creating the directory and this marker and nothing else. The file is empty and lives in
        /// a directory this test made.
        func markAsFakeClaudeHome() throws {
            try Data().write(to: home.url.appending(path: ".afleet-fake-home"))
        }

        func tearDown() async {
            await fleet.shutdown()
            home.removeAll()
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnosticsDirectory)
        }

        func waitFor(_ description: String, timeout: Duration = .seconds(30),
                     file: StaticString = #filePath, line: UInt = #line,
                     _ predicate: @Sendable () async -> Bool) async throws {
            try await TestTiming.waitFor(description, timeout: timeout, file: file, line: line, predicate)
        }
    }

    /// The launches a factory was asked for. A class because a `ProcessFactory` is a synchronous,
    /// non-isolated closure and cannot reach an actor.
    private final class LaunchLog: @unchecked Sendable {   // `lock` serialises the one field
        private let lock = NSLock()
        private var entries: [LaunchConfiguration] = []
        func append(_ launch: LaunchConfiguration) { lock.lock(); entries.append(launch); lock.unlock() }
        var all: [LaunchConfiguration] { lock.lock(); defer { lock.unlock() }; return entries }
        var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    }

    // MARK: - Creation spawns nothing

    /// Directive 8's first clause: a creation files a supervisor and no process.
    ///
    /// If it spawned, every later gate would be decoration — the trust banner of item 47 is drawn
    /// *after* the channel exists, and a child already running in an untrusted project cannot be
    /// called back.
    func testCreateSpawnsNoProcessAndWritesNothingUnderTheConfigHome() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let before = try Self.manifest(of: harness.home.url)
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        let after = try Self.manifest(of: harness.home.url)

        XCTAssertEqual(harness.launches.count, 0, "creating a channel built a process")
        XCTAssertTrue(before == after,
                      "creating a channel changed the config home before the engine's first record")
        let state = await harness.fleet.state(of: key)
        XCTAssertTrue(state != nil, "the created channel has no supervisor")
        let holdsNew = await harness.fleet.channel(key)?.holdsNewSession()
        XCTAssertTrue(holdsNew == true, "a created channel's launch line does not name --session-id")
    }

    // MARK: - The launch line a creation composes

    /// Item 3 and item 4's isolation, on one launch line: the id afleet chose, and
    /// `--setting-sources ""` from the Developer setting the request carries.
    func testTheFirstSpawnPassesSessionIDAndTheIsolatedSettingSources() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd, isolatedSettings: true))
        _ = try await harness.fleet.perform(.open, on: key)

        let launch = try XCTUnwrap(harness.launches.all.first, "the open built no process")
        let argv = try Self.argv(of: launch)
        XCTAssertTrue(Self.value(of: "--session-id", in: argv) == key.session.description,
                      "the first spawn's --session-id is not the key's own id")
        XCTAssertFalse(argv.contains("--resume"), "the first spawn of a created channel passed --resume")
        XCTAssertTrue(Self.value(of: "--setting-sources", in: argv) == "",
                      "the isolated setting did not reach the launch as --setting-sources \"\"")
    }

    /// Isolation off leaves the CLI's own default, which is the other direction of the same claim: a
    /// launch that always passed `--setting-sources` would silently narrow every channel.
    func testIsolationOffPassesNoSettingSourcesFlag() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd, isolatedSettings: false))
        _ = try await harness.fleet.perform(.open, on: key)

        let argv = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertFalse(argv.contains("--setting-sources"),
                       "a channel created with isolation off still narrowed its setting sources")
    }

    /// §8.2's *New isolated session*: the CLI makes the checkout from `-w <name>` on the launch line.
    func testAWorktreeCreationPassesTheWorktreeFlagOnTheFirstSpawn() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd,
                                                             worktree: .named("invented-worktree")))
        _ = try await harness.fleet.perform(.open, on: key)

        let argv = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertTrue(Self.value(of: "-w", in: argv) == "invented-worktree",
                      "the worktree name did not reach the launch line")
    }

    // MARK: - The transition, by the index's evidence

    /// Directive 3(b): a `register` for a key whose supervisor still holds `.new` is the index
    /// saying the transcript exists, so every later spawn resumes it.
    ///
    /// The `-w` clause is in the same test on purpose. `--worktree` is restart-required and "creates
    /// a new channel" (§7.4's table): a resumed launch that passed it again would ask the CLI for a
    /// second checkout, so the two flags have to move together or not at all.
    func testARegistrationPromotesTheLaunchLineToResumeAndDropsTheWorktree() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd,
                                                             worktree: .named("invented-worktree")))
        await harness.fleet.register(key, cwd: harness.cwd, recent: true)
        let promoted = await harness.fleet.channel(key)?.holdsNewSession()
        XCTAssertTrue(promoted == false, "a registration left the launch line naming --session-id")

        _ = try await harness.fleet.perform(.open, on: key)

        let argv = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertTrue(Self.value(of: "--resume", in: argv) == key.session.description,
                      "the spawn after the index listed the channel did not resume its own session")
        XCTAssertFalse(argv.contains("--session-id"),
                       "a spawn after the transcript exists still passed --session-id, which the engine refuses")
        XCTAssertFalse(argv.contains("-w"),
                       "a resumed channel asked the CLI for a second worktree")
    }

    /// The transition is one-way and idempotent: two registrations do not undo it, and a registration
    /// for a channel that never held `.new` changes nothing.
    func testTheTransitionIsIdempotentAndDoesNotReopenOnASecondRegistration() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        await harness.fleet.register(key, cwd: harness.cwd, recent: true)
        await harness.fleet.register(key, cwd: harness.cwd, recent: true)
        _ = try await harness.fleet.perform(.open, on: key)

        let argv = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertFalse(argv.contains("--session-id"), "a second registration put --session-id back")
        XCTAssertTrue(argv.contains("--resume"), "a second registration lost the resume")
    }

    // MARK: - The precondition still gates the first child

    /// Item 47's first half on the fleet's side: a created channel in an untrusted root refuses to
    /// spawn, and nothing was built.
    func testAnUntrustedRootRefusesTheCreatedChannelsFirstSpawn() async throws {
        let harness = try Harness(trusted: false)
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        let verdict = await harness.fleet.preconditions(for: key)
        var refused = false
        switch verdict {
        case .untrusted: refused = true
        default: break
        }
        XCTAssertTrue(refused, "an untrusted root did not refuse a created channel")

        do {
            _ = try await harness.fleet.perform(.open, on: key)
            XCTFail("an untrusted created channel opened")
        } catch {
            XCTAssertEqual(harness.launches.count, 0, "an untrusted created channel built a process")
        }
    }

    /// `preconditions(for:)` reads the *created* launch and not a resume composed from the key, which
    /// is what makes the isolation flag decide `--strict-mcp-config` for a channel with no history.
    func testPreconditionsReadTheCreatedLaunchesSettingSources() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        try FileManager.default.createDirectory(at: harness.cwd, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"invented-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: harness.cwd.appending(path: ".mcp.json"))

        let isolated = await harness.fleet.create(ChannelCreation(cwd: harness.cwd, isolatedSettings: true))
        let plain = await harness.fleet.create(ChannelCreation(cwd: harness.cwd, isolatedSettings: false))

        // Isolated: the rejection gate would not read the store a decline was written into, so no
        // `.mcp.json` server loads at all and there is nothing left to consent to (§6.12).
        let isolatedVerdict = await harness.fleet.preconditions(for: isolated)
        XCTAssertTrue(isolatedVerdict == .ready,
                      "an isolated created channel was asked for consent it cannot act on")
        let plainVerdict = await harness.fleet.preconditions(for: plain)
        var asked = false
        if case .consentNeeded = plainVerdict { asked = true }
        XCTAssertTrue(asked, "a non-isolated created channel skipped the project-server consent sheet")
    }

    /// Item 47's flip, against the **real** trust reader: the record appears in the scratch global
    /// config document and the same channel's verdict becomes `.ready`.
    ///
    /// The write is this test's own file — a `.claude.json` in a home this test created — and never
    /// a real one (X9). What it holds is that the verdict is re-read from disk rather than cached
    /// per channel: afleet never writes trust, so the only thing that can change the answer is the
    /// file, and a reader that answered once per channel would leave a project the user has since
    /// trusted refusing to spawn for the life of the process.
    func testTheTrustRecordAppearingMakesTheCreatedChannelsVerdictReady() async throws {
        let harness = try Harness(trusted: false)
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        var refused = false
        if case .untrusted = await harness.fleet.preconditions(for: key) { refused = true }
        XCTAssertTrue(refused, "an untrusted root did not refuse a created channel")

        try harness.home.trust(root: harness.cwd)

        let after = await harness.fleet.preconditions(for: key)
        XCTAssertTrue(after == .ready, "the trust record appeared and the verdict did not become ready")
        XCTAssertEqual(harness.launches.count, 0, "re-reading the verdict built a process")
    }

    // MARK: - The transition, by the engine's own frames

    /// The whole chain against a real child: create, send, the transcript appears under the scratch
    /// home, the launch line moves to `--resume`, and the respawn proves it.
    ///
    /// The evidence for the transition here is the channel's **own** first `transcript_mirror` and
    /// nothing else — no `register` is made, so the index's half cannot be what moved it.
    func testTheEnginesFirstMirrorFrameMaterialisesTheTranscriptAndMovesTheLaunchLineToResume() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: FakeClaudeLaunch.binary.path),
                          "Tools/fake-claude is not executable in this checkout")
        let harness = try Harness(source: .default, liveFirstSpawn: true)
        defer { Task { await harness.tearDown() } }
        try harness.markAsFakeClaudeHome()

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd, isolatedSettings: true))
        XCTAssertFalse(harness.hasTranscript(of: key.session), "a created channel already had a transcript")

        _ = try await harness.fleet.sendPrompt(UserInput(text: "invented prompt"), on: key)

        try await harness.waitFor("the engine wrote the created channel's transcript") { [harness] in
            harness.hasTranscript(of: key.session)
        }
        try await harness.waitFor("the mirror frame moved the launch line to --resume") { [fleet = harness.fleet] in
            await fleet.channel(key)?.holdsNewSession() == false
        }

        // The respawn. `.quit` is §7.4's unconditional teardown, so the channel rests with no
        // process and the next send has to spawn one.
        _ = try await harness.fleet.perform(.quit, on: key)
        try await harness.waitFor("the child exited") { [fleet = harness.fleet] in
            await fleet.channel(key)?.livePID() == nil
        }
        _ = try await harness.fleet.sendPrompt(UserInput(text: "invented follow-up"), on: key)
        try await harness.waitFor("the respawn built a process") { [launches = harness.launches] in
            launches.count >= 2
        }

        let first = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertTrue(Self.value(of: "--session-id", in: first) == key.session.description,
                      "the first spawn did not name the id afleet chose")
        XCTAssertTrue(Self.value(of: "--setting-sources", in: first) == "",
                      "the isolated setting did not reach the created channel's first launch")

        let respawn = try Self.argv(of: try XCTUnwrap(harness.launches.all.dropFirst().first))
        XCTAssertTrue(Self.value(of: "--resume", in: respawn) == key.session.description,
                      "the respawn after the transcript exists did not resume it")
        XCTAssertFalse(respawn.contains("--session-id"),
                       "the respawn passed --session-id, which the engine refuses once the transcript exists")
        XCTAssertFalse(respawn.contains("-w"), "the respawn asked the CLI for a worktree")
        XCTAssertTrue(Self.value(of: "--setting-sources", in: respawn) == "",
                      "the isolated setting did not survive the respawn under the same session id")
    }

    // MARK: - Support

    /// A recursive manifest of `root`: the relative path of every entry with a file's size. Counts
    /// and shapes, never a path outside the relative one and never a byte (§11).
    private static func manifest(of root: URL) throws -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var lines: [String] = []
        let prefix = root.path(percentEncoded: false)
        for case let url as URL in walk {
            let path = url.path(percentEncoded: false)
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : "!unstripped"
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            lines.append("\(relative) \(size)")
        }
        return lines.sorted()
    }
}
