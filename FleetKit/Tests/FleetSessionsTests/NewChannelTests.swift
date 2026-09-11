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
        /// The scripted handles the factory built, in spawn order, so a test can push a frame into the
        /// process the channel is actually running.
        let handles = HandleLog()
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
            let handleLog = handles
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
                                  let handle = ScriptedProcessHandle(epoch: epoch, session: session,
                                                                     pid: 600_000 + Int32(epoch.rawValue))
                                  handleLog.append(handle)
                                  return handle
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

    // MARK: - Invented frames

    /// A `system/init` naming `cwd`, built by hand.
    ///
    /// Every value is invented — no engine byte reaches this file (§11) — and the one field the tests read is
    /// `cwd`, which is the engine's report of where the child actually started. That report is the whole of the
    /// worktree relocation: `-w <name>` makes the CLI create the checkout during startup, so the first `system/init`
    /// of such a launch already names it.
    static func systemInit(cwd: String, session: SessionID) -> Frame {
        let object: [String: Any] = [
            "type": "system", "subtype": "init", "cwd": cwd, "session_id": session.description,
            "tools": [], "mcp_servers": [], "model": "invented-model", "permissionMode": "default",
            "slash_commands": [], "apiKeySource": "none", "claude_code_version": "0.0.0",
            "output_style": "invented", "skills": [], "plugins": [],
            "uuid": "00000000-0000-4000-8000-0000000000f1",
        ]
        return FrameDecoder.decode(line: try! JSONSerialization.data(withJSONObject: object))
    }

    /// A `transcript_mirror` naming `file`, with or without records in it.
    static func mirror(file: URL, entries: Int) -> Frame {
        let object: [String: Any] = [
            "type": "transcript_mirror", "filePath": file.path(percentEncoded: false),
            "entries": (0..<entries).map { ["type": "invented-record", "index": $0] },
        ]
        return FrameDecoder.decode(line: try! JSONSerialization.data(withJSONObject: object))
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

    /// The scripted handles a factory built, for the same reason and with the same shape.
    private final class HandleLog: @unchecked Sendable {   // `lock` serialises the one field
        private let lock = NSLock()
        private var entries: [ScriptedProcessHandle] = []
        func append(_ handle: ScriptedProcessHandle) { lock.lock(); entries.append(handle); lock.unlock() }
        var all: [ScriptedProcessHandle] { lock.lock(); defer { lock.unlock() }; return entries }
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

    /// **The worktree flag and the session flag move on different evidence, because the two facts are
    /// different ages.**
    ///
    /// `-w <name>` makes the CLI create the checkout during startup, so from the first `system/init`
    /// the worktree exists and that frame's `cwd` is it — while the transcript still does not exist
    /// until the first record. Every respawn in the gap between them is a real one: the thirty-minute
    /// reap's resume, a crash respawn, a restart-required change, a quit and return inside one app
    /// run. Each of those used to pass `-w <name>` again, from *inside* the checkout, asking the CLI
    /// for a second worktree under the first (§7.4's table: `--worktree` is restart-required and
    /// "creates a new channel").
    func testTheWorktreeFlagIsClearedByTheHandshakeAndNotByTheTranscript() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let checkout = harness.cwd.appending(path: ".claude/worktrees/invented-worktree",
                                             directoryHint: .isDirectory)
        // The CLI would make this during startup; here the test does, and trusts it, because the
        // subject is which flag the respawn carries and not which directory the engine keys on —
        // that is `WorktreeTrustTests`'.
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try harness.home.trust(root: checkout)
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd,
                                                             worktree: .named("invented-worktree")))
        _ = try await harness.fleet.perform(.open, on: key)
        let built = await harness.fleet.channel(key)
        let supervisor = try XCTUnwrap(built)

        // The engine reports where it started: the checkout it just made.
        await supervisor.handle(event: .frame(Self.systemInit(cwd: checkout.path(percentEncoded: false),
                                                              session: key.session),
                                              ProcessEpoch.first))
        let stillNew = await supervisor.holdsNewSession()
        let worktreeGone = await supervisor.holdsWorktree()
        XCTAssertTrue(stillNew, "the handshake moved the session flag, which only a transcript may do")
        XCTAssertFalse(worktreeGone, "the handshake left the launch line asking for a second checkout")

        // A respawn before any record. A restart-required change is the case a user is most likely to
        // reach here — it is the one thing the header offers on a channel that has not been sent to.
        try await harness.waitFor("the created channel came up") { [fleet = harness.fleet] in
            await fleet.state(of: key)?.origin == .owned(.ready)
        }
        _ = try? await harness.fleet.perform(.quiescentRestart(RestartRequest(promptSuggestions: true)), on: key)
        try await harness.waitFor("the respawn built a process") { [launches = harness.launches] in
            launches.count >= 2
        }
        let respawn = try XCTUnwrap(harness.launches.all.dropFirst().first)
        let beforeRecord = try Self.argv(of: respawn)
        XCTAssertTrue(Self.value(of: "--session-id", in: beforeRecord) == key.session.description,
                      "a respawn before the first record did not pass --session-id")
        XCTAssertFalse(beforeRecord.contains("-w"),
                       "a respawn from inside the checkout asked the CLI for a second worktree")
        XCTAssertTrue(respawn.cwd.path(percentEncoded: false) == checkout.path(percentEncoded: false),
                      "the respawn did not launch from the checkout the engine reported")

        // Now the transcript. Only the session flag is left to move.
        let transcript = harness.home.url.appending(path: "projects/invented/\(key.session).jsonl")
        await supervisor.handle(event: .frame(Self.mirror(file: transcript, entries: 1),
                                              ProcessEpoch(rawValue: 2)))
        let movedNow = await supervisor.holdsNewSession()
        XCTAssertFalse(movedNow, "the transcript's own evidence did not move the session flag")
    }

    /// A **restart that adds a worktree** adopts the checkout the engine reports.
    ///
    /// `RuntimeStateUpdater` seeds `runtime.cwd` from a channel's *first* `system/init` ever, which
    /// is right for everything else and wrong here: a `RestartRequest(worktree:)` puts `-w` on a
    /// channel that has already handshaked, so the seed is long taken, and clearing the flag without
    /// adopting the reported directory would leave every later respawn running in the main working
    /// copy under a channel whose transcript lives under the checkout's slug.
    func testARestartThatAddsAWorktreeAdoptsTheReportedCheckout() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }
        let checkout = harness.cwd.appending(path: ".claude/worktrees/added-later", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try harness.home.trust(root: checkout)

        // A channel that has already handshaked once, so the runtime seed has been taken.
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)
        let built = await harness.fleet.channel(key)
        let supervisor = try XCTUnwrap(built)
        await supervisor.handle(event: .frame(Self.systemInit(cwd: harness.cwd.path(percentEncoded: false),
                                                              session: key.session),
                                              ProcessEpoch.first))
        try await harness.waitFor("the channel came up") { [fleet = harness.fleet] in
            await fleet.state(of: key)?.origin == .owned(.ready)
        }

        // Now the restart adds the worktree, and the replacement reports the checkout.
        _ = try? await harness.fleet.perform(.quiescentRestart(RestartRequest(worktree: .named("added-later"))),
                                             on: key)
        try await harness.waitFor("the restart built a process") { [launches = harness.launches] in
            launches.count >= 2
        }
        let restart = try XCTUnwrap(harness.launches.all.dropFirst().first)
        XCTAssertTrue(try Self.value(of: "-w", in: Self.argv(of: restart)) == "added-later",
                      "the restart did not ask the CLI for the worktree the request named")

        await supervisor.handle(event: .frame(Self.systemInit(cwd: checkout.path(percentEncoded: false),
                                                              session: key.session),
                                              ProcessEpoch(rawValue: 2)))
        let stillAsks = await supervisor.holdsWorktree()
        XCTAssertFalse(stillAsks, "the replacement's handshake left the launch line asking for a second checkout")

        let adopted = await supervisor.runtimeState().cwd
        XCTAssertTrue(adopted.path(percentEncoded: false) == checkout.path(percentEncoded: false),
                      "the relocation cleared the flag without adopting the checkout the engine reported")
    }

    /// A mirror carrying **no records** does not move the session flag.
    ///
    /// The frame's promise is the records the CLI just wrote; one carrying none has written none, so
    /// the file may still not exist and `--resume` would be refused outright.
    func testAMirrorWithNoRecordsDoesNotMoveTheSessionFlag() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)
        let built = await harness.fleet.channel(key)
        let supervisor = try XCTUnwrap(built)
        let transcript = harness.home.url.appending(path: "projects/invented/\(key.session).jsonl")

        await supervisor.handle(event: .frame(Self.mirror(file: transcript, entries: 0),
                                              ProcessEpoch.first))
        let afterEmpty = await supervisor.holdsNewSession()
        XCTAssertTrue(afterEmpty, "an empty mirror moved the launch line to --resume")

        await supervisor.handle(event: .frame(Self.mirror(file: transcript, entries: 1),
                                              ProcessEpoch.first))
        let afterRecords = await supervisor.holdsNewSession()
        XCTAssertFalse(afterRecords, "a mirror carrying records did not move the launch line")
    }

    // MARK: - The transition, by the index's evidence

    /// Directive 3(b): a `register` for a key whose supervisor still holds `.new` is the index
    /// saying the transcript exists, so every later spawn resumes it.
    ///
    /// The worktree is **not** this evidence's to clear — see
    /// `testTheWorktreeFlagIsClearedByTheHandshakeAndNotByTheTranscript`, which is where that flag
    /// lives, because the checkout exists a whole handshake before the transcript does.
    func testARegistrationPromotesTheLaunchLineToResume() async throws {
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
        // The checkout is still asked for, because no handshake has reported one: an indexed
        // transcript says nothing about whether the CLI has made the worktree.
        let stillAsks = await harness.fleet.channel(key)?.holdsWorktree()
        XCTAssertTrue(stillAsks == true, "the index's evidence cleared a flag only a handshake may clear")
    }

    /// The transition answers **once**, and that return value is what the facade acts on.
    ///
    /// `Fleet.register` rewrites its own copy of the launch line only when the supervisor says it
    /// did something, and the gate that keeps the registration loop off a cross-actor round trip
    /// reads that copy. A `transcriptObserved()` that answered true every time would make every one
    /// of roughly three thousand registrations rewrite a line that is already right; one that
    /// answered true after the *frame* evidence had already moved the template would say a
    /// transition happened that did not.
    func testTheTransitionAnswersOnceAndIsIdempotent() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        let found = await harness.fleet.channel(key)
        let supervisor = try XCTUnwrap(found, "the created channel has no supervisor")

        let first = await supervisor.transcriptObserved()
        let second = await supervisor.transcriptObserved()
        XCTAssertTrue(first, "the first evidence did not move the launch line")
        XCTAssertFalse(second, "the transition reported itself a second time")

        // And a registration arriving after the frame evidence changes nothing it can see.
        await harness.fleet.register(key, cwd: harness.cwd, recent: true)
        _ = try await harness.fleet.perform(.open, on: key)
        let argv = try Self.argv(of: try XCTUnwrap(harness.launches.all.first))
        XCTAssertFalse(argv.contains("--session-id"), "a later registration put --session-id back")
        XCTAssertTrue(argv.contains("--resume"), "a later registration lost the resume")
    }

    /// A quiescent restart before the first turn keeps `--session-id`, and one after it keeps
    /// `--resume`.
    ///
    /// `relaunch(from:applying:)` forces `.resume(key.session)` so a fork's template — which names
    /// the session it forked *from* and carries `--fork-session` — cannot mint a third session. A
    /// created channel's `.new(id)` is the one template that must survive it: the transcript does
    /// not exist yet, `--resume` needs one, and a restart-required setting changed before the first
    /// send is exactly when a user changes one. The channel would come up refused.
    func testAQuiescentRestartBeforeTheFirstTurnKeepsSessionID() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)
        try await harness.waitFor("the created channel came up") { [fleet = harness.fleet] in
            await fleet.state(of: key)?.origin == .owned(.ready)
        }
        _ = try? await harness.fleet.perform(.quiescentRestart(RestartRequest(promptSuggestions: true)), on: key)
        try await harness.waitFor("the restart built a process") { [launches = harness.launches] in
            launches.count >= 2
        }

        let restart = try Self.argv(of: try XCTUnwrap(harness.launches.all.dropFirst().first))
        XCTAssertTrue(Self.value(of: "--session-id", in: restart) == key.session.description,
                      "a restart before the first turn dropped --session-id for a transcript that does not exist")
        XCTAssertFalse(restart.contains("--resume"),
                       "a restart before the first turn passed --resume, which the engine refuses with no transcript")
        XCTAssertTrue(restart.contains("--prompt-suggestions"), "the restart request's own change was lost")
    }

    /// The other direction, so the clause above is not simply "never rewrite the session start": a
    /// restart *after* the transcript exists resumes it.
    func testAQuiescentRestartAfterTheTranscriptExistsResumes() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }

        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        await harness.fleet.register(key, cwd: harness.cwd, recent: true)
        _ = try await harness.fleet.perform(.open, on: key)
        try await harness.waitFor("the created channel came up") { [fleet = harness.fleet] in
            await fleet.state(of: key)?.origin == .owned(.ready)
        }
        _ = try? await harness.fleet.perform(.quiescentRestart(RestartRequest(promptSuggestions: true)), on: key)
        try await harness.waitFor("the restart built a process") { [launches = harness.launches] in
            launches.count >= 2
        }

        let restart = try Self.argv(of: try XCTUnwrap(harness.launches.all.dropFirst().first))
        XCTAssertTrue(Self.value(of: "--resume", in: restart) == key.session.description,
                      "a restart after the transcript exists did not resume it")
        XCTAssertFalse(restart.contains("--session-id"),
                       "a restart after the transcript exists passed --session-id, which the engine refuses")
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

/// §6.11's *Review trust in terminal* on a channel with **no owned process** (§14 item 47, tracker
/// 314, ruled by the architect 2026-09-11).
///
/// The whole defect this closes is that a trust review is not a handoff. `handOff` refuses any
/// origin that is not `.owned(.ready)` or `.owned(.dormant)`, and an untrusted channel never spawns,
/// so the press threw `notOwned` before a pane could open — which made item 47's second half
/// unreachable in the running app however correctly the re-read was wired.
final class TrustReviewPaneTests: XCTestCase {

    private final class Harness: @unchecked Sendable {   // every stored value is set once, in `init`
        let home: ScratchConfigHome
        let fleet: Fleet
        let cwd: URL
        let spawns = SpawnBox()
        private let files: ScriptedHolderFiles
        private let store: FileStateStore
        private let storeDirectory: URL
        let diagnosticsDirectoryForReading: URL

        init(trusted: Bool = false) throws {
            home = try ScratchConfigHome()
            files = ScriptedHolderFiles(home: home)
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            cwd = temporary.appending(path: "afleet-trust-review-cwd-\(UUID().uuidString)")
            storeDirectory = temporary.appending(path: "afleet-trust-review-store-\(UUID().uuidString)")
            diagnosticsDirectoryForReading = temporary.appending(path: "afleet-trust-review-diag-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            if trusted { try home.trust(root: cwd) }
            store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url])
            let session = try FakeClaudeLaunch.sessionID(of: "plain-two-turn")
            let box = spawns
            fleet = Fleet(configHome: home.configHome,
                          environment: FakeClaudeLaunch.environment(fixture: "plain-two-turn"),
                          binary: FakeClaudeLaunch.binary, store: store,
                          diagnosticsDirectory: diagnosticsDirectoryForReading, clock: TestClock(),
                          factory: { epoch, _ in
                              box.count += 1
                              return ScriptedProcessHandle(epoch: epoch, session: session,
                                                           pid: 700_000 + Int32(epoch.rawValue))
                          },
                          runner: ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files)),
                          newSessionID: { SessionID() })
        }

        func tearDown() async {
            await fleet.shutdown()
            home.removeAll()
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnosticsDirectoryForReading)
        }

        /// Every line the fleet's own diagnostics file holds, as decoded objects.
        func diagnosticLines() async throws -> [[String: Any]] {
            await fleet.flushDiagnostics()
            guard let files = try? FileManager.default
                .contentsOfDirectory(at: diagnosticsDirectoryForReading,
                                     includingPropertiesForKeys: nil) else { return [] }
            var out: [[String: Any]] = []
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                        out.append(object)
                    }
                }
            }
            return out
        }
    }

    /// How many processes the factory built. A `ProcessFactory` is a synchronous, non-isolated
    /// closure, so the counter cannot live on an actor.
    private final class SpawnBox: @unchecked Sendable {   // `lock` serialises the one field
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// The request's shape: `claude`, **no arguments**, in the channel's own directory.
    ///
    /// No arguments is the whole point. `--resume` opens the conversation; what §6.11 asks for is
    /// the interactive run whose *startup* puts the trust dialog up.
    func testATrustReviewRunsTheBinaryWithNoArgumentsInTheChannelsDirectory() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))

        let request = try await harness.fleet.reviewTrustInTerminal(key)

        XCTAssertTrue(request.arguments.isEmpty,
                      "a trust review passed \(request.arguments.count) argument(s), so it opens a conversation")
        XCTAssertTrue(request.cwd.path(percentEncoded: false) == harness.cwd.path(percentEncoded: false),
                      "the trust review does not run in the channel's own directory")
        XCTAssertTrue(request.executable == FakeClaudeLaunch.binary,
                      "the trust review runs something other than the resolved binary")
        var isReview = false
        if case .trustReview(let session) = request.purpose { isReview = session == key.session }
        XCTAssertTrue(isReview, "the request is not a trust review for this channel's own session")
    }

    /// Nothing moved: no process, no transition, no ownership change.
    ///
    /// A handoff terminates a child, waits for the release and changes the channel's origin. There
    /// is nothing to hand over here — that is why the banner is drawn — so a press that moved the
    /// channel would be moving it away from the one state the banner is correct for.
    func testATrustReviewChangesNothingAboutTheChannel() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        let before = await harness.fleet.state(of: key)

        _ = try await harness.fleet.reviewTrustInTerminal(key)

        let after = await harness.fleet.state(of: key)
        XCTAssertEqual(harness.spawns.count, 0, "a trust review built a process")
        XCTAssertTrue(after?.origin == before?.origin, "a trust review moved the channel's origin")
        XCTAssertTrue(after?.desired == before?.desired, "a trust review changed what afleet wants")
        XCTAssertNil(after?.banner, "a trust review raised a lifecycle banner")
    }

    /// The exit clears the pending request, so the pane is matched and re-adopts nothing.
    ///
    /// It has to be *pending* for `Fleet.paneExited` to find the channel at all — that lookup is by
    /// request id — and it must not be a `pendingHatch`, because clearing one of those waits out a
    /// holder and spawns the channel back.
    func testTheExitClearsThePendingRequestAndAdoptsNothing() async throws {
        let harness = try Harness()
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))

        let request = try await harness.fleet.reviewTrustInTerminal(key)
        let pending = await harness.fleet.channel(key)?.pendingPaneRequest
        XCTAssertTrue(pending?.id == request.id, "the trust review is not the channel's pending pane request")

        await harness.fleet.paneExited(PaneExit(request: request, code: 0, observedAt: Date()))

        let cleared = await harness.fleet.channel(key)?.pendingPaneRequest
        XCTAssertNil(cleared, "the exit left the trust review pending")
        XCTAssertEqual(harness.spawns.count, 0, "the trust review's exit re-adopted the channel")
        let lines = try await harness.diagnosticLines()
        XCTAssertTrue(lines.contains { $0["event"] as? String == "pane_ended" },
                      "the trust review's exit was not recorded")
        XCTAssertFalse(lines.contains { $0["event"] as? String == "stale_exit" },
                       "the trust review's own exit was recorded as one nobody was waiting for")
    }

    /// The two verbs are two verbs, and each refuses what the other is for.
    ///
    /// This is the whole of the ruling that made the trust review its own X5 member: folding it into
    /// `openInTerminal` made that verb's answer depend on the channel's origin, so the header's
    /// *Open in Terminal* on an archived channel silently stopped meaning what its copy says. A
    /// channel with a child has a session to hand over and the hatch is the verb for it; a channel
    /// with none has nothing to hand over and the review is the verb for that.
    func testTheHatchAndTheReviewRefuseEachOthersChannels() async throws {
        let harness = try Harness(trusted: true)
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))

        // No process: the hatch refuses, exactly as it did before item 47's work.
        do {
            _ = try await harness.fleet.openInTerminal(key)
            XCTFail("the hatch handed over a channel with nothing running")
        } catch let error as LifecycleError {
            guard case .notOwned = error else {
                return XCTFail("the hatch refused a processless channel for the wrong reason")
            }
        }

        _ = try await harness.fleet.perform(.open, on: key)
        XCTAssertEqual(harness.spawns.count, 1, "the channel came up with no process, so this proves nothing")

        // A process: the hatch is a hatch, and the review refuses.
        let hatch = try await harness.fleet.openInTerminal(key)
        var isHatch = false
        if case .hatch = hatch.purpose { isHatch = true }
        XCTAssertTrue(isHatch, "an owned channel's Open in terminal stopped being a hatch")
        XCTAssertTrue(hatch.arguments.contains("--resume"), "the hatch no longer resumes the session")
    }

    /// The review refuses a channel whose child is live.
    func testTheReviewRefusesAChannelWithALiveChild() async throws {
        let harness = try Harness(trusted: true)
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)

        do {
            _ = try await harness.fleet.reviewTrustInTerminal(key)
            XCTFail("the review answered for a channel with a session to hand over")
        } catch let error as LifecycleError {
            guard case .busy = error else {
                return XCTFail("the review refused a live channel for the wrong reason")
            }
        }
    }

    /// A stale hatch does not misroute a later review's exit.
    ///
    /// `PanelHostModel.run` can throw — `noPaneRunner` on a build with no Terminal leaf — and the
    /// host discharges the request, but a `pendingHatch` this supervisor never cleared can still sit
    /// there. Reading only the hatch, or giving it precedence, routed the review's **own** exit to
    /// `staleExit` and left its request pending for ever; the match is by id, on either.
    func testAStaleHatchDoesNotMisrouteALaterReviewsExit() async throws {
        let harness = try Harness(trusted: true)
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)
        let hatch = try await harness.fleet.openInTerminal(key)

        // The hatch's pane never ran, so nothing ever reports its exit. The channel is processless
        // now — the handoff terminated its child — so the review is offered.
        let review = try await harness.fleet.reviewTrustInTerminal(key)
        XCTAssertFalse(review.id == hatch.id, "the review reused the hatch's request id")

        await harness.fleet.paneExited(PaneExit(request: review, code: 0, observedAt: Date()))

        let lines = try await harness.diagnosticLines()
        XCTAssertTrue(lines.contains { $0["event"] as? String == "pane_ended" },
                      "the review's exit was not matched, so nothing recorded it")
        XCTAssertFalse(lines.contains { $0["event"] as? String == "stale_exit" },
                       "the stale hatch swallowed the review's own exit")
    }

    /// A **dormant** channel gets the review — the original ruling's words — and its hatch still
    /// works, because a dormant channel is owned and §7.4's table has that row.
    func testADormantChannelGetsBothVerbs() async throws {
        let harness = try Harness(trusted: true)
        defer { Task { await harness.tearDown() } }
        let key = await harness.fleet.create(ChannelCreation(cwd: harness.cwd))
        _ = try await harness.fleet.perform(.open, on: key)
        _ = try await harness.fleet.perform(.quit, on: key)
        let origin = await harness.fleet.state(of: key)?.origin
        XCTAssertTrue(origin == .owned(.dormant), "the channel is not dormant, so this proves nothing")

        let review = try await harness.fleet.reviewTrustInTerminal(key)
        var isReview = false
        if case .trustReview = review.purpose { isReview = true }
        XCTAssertTrue(isReview, "a dormant channel's review is not a trust review")
        XCTAssertTrue(review.arguments.isEmpty, "the review passed arguments")
    }
}
