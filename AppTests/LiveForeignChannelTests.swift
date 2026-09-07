import Foundation
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G1e: the only place in C5 that starts a real `claude`.
///
/// **Zero model turns and zero dollars.** The child is interactive and is sent **no prompt**, so it
/// registers itself, sits at its composer and ends without a `result` frame. `AFLEET_LIVE_CLI_TURNS`
/// is not read here or anywhere else in this child; a scenario that needed a turn would be a scope
/// change, not a test change.
///
/// **Nothing here writes under a config home.** The scratch home is read — the witness reads it with
/// `lstat(2)`, the trust document with `O_RDONLY | O_NOFOLLOW` — and the only process that writes
/// into it is the `claude` this test spawns, which is exactly what the witness's allowlist is a
/// claim about. afleet's own two write roots are under a `TempTree`.
///
/// **The child is resumed, not created**, and that is a protocol fact rather than a convenience.
/// An unprompted `claude` writes its registry record and **no transcript**: `projects/` is untouched
/// until a session has something to record. The app lists channels from C3's index over `projects/`,
/// so a brand-new unprompted session is a session afleet has nothing to list — and the only way to
/// give it one would be to write a transcript into the config home, which X9 forbids outright. So
/// the scenario resumes a session the scratch home already holds a transcript for: the engine keeps
/// the session id across `--resume` (measured), the record it writes names that id, and the row the
/// sidebar already had is the row that turns live. That is the foreign-session scenario the gate is
/// about, with the one part afleet cannot legally fabricate supplied by the corpus instead.
final class LiveForeignChannelTests: XCTestCase {

    func testAForeignSessionAppearsWithinFiveSeconds() async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        let directory = try ScratchLiveGate.trustedDirectory()

        // 1. The app, launched over the scratch home exactly as it launches over any other, with a
        //    recording fleet in the one seam that can reach a termination.
        let tree = try TempTree()
        let environment = try await Self.appEnvironment(configHome: home)
        let recorder = RecordingAppFleet.Log()
        var sequence = LaunchSequence(
            storeRoot: try tree.directory("store"),
            diagnosticsRoot: try tree.directory("logs"),
            resolveEnvironment: { environment },
            fleetFactory: { configHome, resolved, binary, store, diagnostics in
                RecordingAppFleet(inner: LaunchSequence.makeFleet(configHome, resolved, binary, store, diagnostics),
                                  log: recorder)
            })
        let box = ModelBox()
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }

        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the launch did not reach a workspace over the scratch home")
        let coordinator = try await MainActor.run { try XCTUnwrap(box.value, "the launch built no coordinator") }
        defer {
            Task { @MainActor in coordinator.stop() }
        }
        await coordinator.model.whenChanged { !$0.isProvisional && $0.allRows.count > 0 }

        // 2. A session the sidebar already lists, whose working directory is the trusted one. The
        //    engine resolves a transcript by its project directory, so the child has to be started
        //    in the directory the session was recorded in.
        let canonicalDirectory = CanonicalPath.string(directory)
        let target = await MainActor.run { () -> SessionID? in
            coordinator.model.allRows.first { row in
                guard let cwd = row.cwd else { return false }
                return CanonicalPath.string(cwd) == canonicalDirectory
            }?.id
        }
        guard let session = target else {
            await workspace.fleet.shutdown()
            throw XCTSkip("the scratch config home holds no listed transcript recorded in a trusted directory")
        }
        let key = ChannelKey(configHome: home, session: session)

        // The floor under the gate below. A row that was already live before the child existed would
        // satisfy the five-second poll on its first iteration and measure nothing at all — the
        // shape of half the assertions this child has had to rewrite. So the state the gate is about
        // to observe a change in is read first, and a session somebody else is already holding is a
        // reason to skip rather than a reason to pass.
        let originBefore = await MainActor.run { coordinator.model.row(session)?.origin }
        if let originBefore, case .foreignLive = originBefore {
            await workspace.fleet.shutdown()
            throw XCTSkip("the chosen session is already held by a live process; nothing for the gate to observe")
        }

        // 3. The child. Its environment is built from scratch rather than inherited, because a
        //    `CLAUDE_CODE_CHILD_SESSION` in the parent's environment makes the engine skip session
        //    registration outright (2.1.263 `cli.pretty.js:96608`, `wF()`), and a test run from
        //    inside another Claude Code session inherits exactly that. Measured: with the marker
        //    present no `sessions/<pid>.json` is ever written and the gate fails on an engine that
        //    is behaving correctly.
        let binary = workspace.binary
        let child = try PseudoTerminalChild(executable: binary,
                                            arguments: ["--resume", session.description],
                                            environment: Self.childEnvironment(configHome: home,
                                                                               resolved: environment),
                                            cwd: directory)
        var stopped = false
        defer { if !stopped { child.stop() } }

        // The engine's own startup is not what the five seconds are about: the claim is that afleet
        // reports the session within five seconds of there **being** one to report. So the record is
        // waited for first, on a budget of its own, and the clock starts when it exists.
        let childPID = child.pid
        let recordAppeared = try await Self.poll(upTo: .seconds(30)) { Self.registryRecord(home: home, pid: childPID) }
        let record = try XCTUnwrap(recordAppeared,
                                   "the pty child wrote no registry record under sessions/ within thirty seconds")
        XCTAssertTrue(record.sessionId == session.description,
                      "the record the fleet can see is not this test's own child's")

        // 4. The gate.
        let clock = ContinuousClock()
        let start = clock.now
        let seen = try await Self.poll(upTo: .seconds(5)) { () -> ChannelRow? in
            await MainActor.run { () -> ChannelRow? in
                guard let row = coordinator.model.row(session), case .foreignLive = row.origin else { return nil }
                return row
            }
        }
        let elapsed = start.duration(to: clock.now)
        if seen == nil {
            let origin = await MainActor.run { coordinator.model.row(session)?.origin }
            let state = await workspace.fleet.state(of: key)
            XCTFail("""
                no foreign live row within five seconds; \
                model origin \(String(describing: origin)), fleet origin \(String(describing: state?.origin))
                """)
        }
        let row = try XCTUnwrap(seen, "no foreign live row within five seconds")
        XCTAssertTrue(row.origin == .foreignLive(.usersTerminal),
                      "the row is live but not the user's terminal: \(String(describing: row.origin))")
        XCTAssertTrue(row.presence != nil, "the live row carries no presence read from the record")

        // 5. The trace assertion. The break this stands in for cannot be executed: performing it
        //    would kill the very process the invariant protects. So the substitute is the record of
        //    what the app asked the fleet to do — every lifecycle action, every job verb — held up
        //    against the set that ends a session.
        let performed = recorder.actions
        let terminating = performed.filter { RecordingAppFleet.terminating.contains($0) }
        XCTAssertTrue(terminating.isEmpty, "the app entered \(terminating.count) termination paths: \(terminating.sorted())")
        XCTAssertTrue(recorder.registrations > 0,
                      "the recording fleet saw nothing at all, so the trace proves nothing")

        // 6. This test's own child, ended by this test. Nothing else is signalled.
        child.stop()
        stopped = true

        await workspace.fleet.shutdown()

        // 7. The witness. Not an empty diff: an unprompted interactive session legitimately writes
        //    its registry record, refreshes `.claude.json` and rotates a backup, and demanding
        //    emptiness would fail the gate on the engine doing what the scenario needs. What is
        //    required is that every changed path is one a spawned `claude` writes **and** that the
        //    two families carrying an identity carry this child's.
        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        let attribution = ConfigHomeWitness.Attribution(childPID: childPID, session: session.description)
        let unattributed = ConfigHomeWitness.unattributed(difference, attribution: attribution)
        XCTAssertTrue(unattributed.isEmpty,
                      "\(unattributed.count) changed paths under the config home are unattributed: \(unattributed)")
        XCTAssertTrue(!difference.isEmpty,
                      "the config home did not change at all, so the witness watched nothing happen")

        // And the proof the comparison discriminates, taken from the same reading rather than from
        // a second live run: a deliberately narrowed allowlist reports what the full one explains.
        let narrowed = ConfigHomeWitness.unattributed(difference, against: ["projects/"])
        XCTAssertTrue(narrowed.count > 0, "a narrowed allowlist explained every path, so the check is vacuous")

        print("""
        G1e a foreign session, live and unprompted
          registry record .............. seen, session matched
          origin before the child ...... \(String(describing: originBefore))
          foreign live row ............. \(Self.ms(elapsed)) ms after the record existed
          lifecycle actions performed .. \(performed.count), of which terminating \(terminating.count)
          registrations ................ \(recorder.registrations)
          config home ................. \(difference.summary), unattributed \(unattributed.count)
          model turns .................. 0
        """)
    }

    // MARK: - The app's environment, and the child's

    /// The login shell's environment with `CLAUDE_CONFIG_DIR` pointed at the scratch home.
    private static func appEnvironment(configHome: URL) async throws -> ResolvedEnvironment {
        let resolved = await LaunchSequence.resolveLoginShellEnvironment()
        var variables = resolved.variables
        variables["CLAUDE_CONFIG_DIR"] = configHome.path(percentEncoded: false)
        return ResolvedEnvironment(variables: variables, shell: resolved.shell,
                                   capturedAt: resolved.capturedAt, mode: resolved.mode)
    }

    /// What the spawned `claude` runs under: the resolved PATH and home, the scratch config home, a
    /// terminal of a real shape, and **not one** `CLAUDE_*` or `ANTHROPIC_*` variable inherited from
    /// whatever started this test. See the note at the spawn: one of those markers turns session
    /// registration off entirely.
    private static func childEnvironment(configHome: URL, resolved: ResolvedEnvironment) -> [String: String] {
        var variables: [String: String] = [:]
        for name in ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "LANG", "TMPDIR"] {
            if let value = resolved.variables[name] { variables[name] = value }
        }
        variables["CLAUDE_CONFIG_DIR"] = configHome.path(percentEncoded: false)
        variables["TERM"] = "xterm-256color"
        return variables
    }

    // MARK: - Reading the child's own record

    /// The engine's registry record for a pid, read (never written) from the scratch home.
    private static func registryRecord(home: URL, pid: pid_t) -> RegistryRecord? {
        let file = home.appending(path: "sessions/\(pid).json")
        guard let data = ClaudeJSONReader.read(file) else { return nil }
        return RegistryRecord.decode(data)
    }

    /// Polls `body` every 100 ms until it answers or `deadline` passes.
    private static func poll<T: Sendable>(upTo deadline: Duration,
                                          _ body: @Sendable () async -> T?) async throws -> T? {
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < deadline {
            if let value = await body() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await body()
    }

    private static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    /// The coordinator the launch built. A single-owner box; every access is on the main actor.
    private final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }
}

// MARK: - The trace

/// Every lifecycle action and job verb the app asked the fleet for, by name.
///
/// The foreign-session safety invariant is absolute — afleet never stops, kills, signals or adopts a
/// session running in the user's terminal — and it is the one invariant whose break cannot be
/// executed in a test, because executing it destroys the thing the invariant protects. The
/// substitute the plan asks for is this: a decorator on the one seam every such act must pass
/// through, and an assertion that the naming set was never entered.
final class RecordingAppFleet: AppFleet {

    /// The actions that end, take over or displace a session. `.open`, `.send`, `.answer`, `.fork`
    /// and `.reopen` are not here: none of them stops anything.
    static let terminating: Set<String> = ["reap", "adopt", "sendToBackground", "quiescentRestart",
                                           "stopEverything", "backgroundAll", "logout",
                                           "job.stop", "job.rm", "job.respawn"]

    /// `@unchecked Sendable` is sound because both mutable fields are read and written only inside
    /// `lock`, this instance's private `NSLock`; that lock is the serialising mechanism.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var registered = 0

        func note(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        func noteRegistration() { lock.lock(); registered += 1; lock.unlock() }
        var actions: [String] { lock.lock(); defer { lock.unlock() }; return names }
        var registrations: Int { lock.lock(); defer { lock.unlock() }; return registered }
    }

    private let inner: any AppFleet
    private let log: Log

    init(inner: any AppFleet, log: Log) {
        self.inner = inner
        self.log = log
    }

    static func name(of action: LifecycleAction) -> String {
        switch action {
        case .open: "open"
        case .send: "send"
        case .reap: "reap"
        case .adopt: "adopt"
        case .sendToBackground: "sendToBackground"
        case .fork: "fork"
        case .quiescentRestart: "quiescentRestart"
        case .stopEverything: "stopEverything"
        case .backgroundAll: "backgroundAll"
        case .logout: "logout"
        case .reopen: "reopen"
        case .answer: "answer"
        }
    }

    // MARK: - AppFleet

    func start() async { await inner.start() }
    func shutdown() async { await inner.shutdown() }

    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async {
        log.noteRegistration()
        await inner.register(key, cwd: cwd, recent: recent)
    }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        log.note(Self.name(of: action))
        return try await inner.perform(action, on: key)
    }

    func performJob(_ verb: JobVerb, _ short: JobShort) async throws {
        log.note("job.\(verb)")
        try await inner.performJob(verb, short)
    }

    func adoptTrace() {}

    nonisolated var updates: AsyncStream<ChannelState> { inner.updates }

    func state(of key: ChannelKey) async -> ChannelState? { await inner.state(of: key) }
    func states() async -> [ChannelState] { await inner.states() }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { await inner.preconditions(for: key) }
    func route(_ text: String, on key: ChannelKey) async -> Routed { await inner.route(text, on: key) }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        try await inner.send(request, on: key)
    }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome {
        try await inner.run(strategy, arguments: arguments, on: key, ui: ui)
    }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest {
        log.note("openInTerminal")
        return try await inner.openInTerminal(key)
    }
    func attach(_ job: JobShort) async throws -> PaneRequest { try await inner.attach(job) }
    func logs(_ job: JobShort) async throws -> PaneRequest { try await inner.logs(job) }
    func paneExited(_ exit: PaneExit) async { await inner.paneExited(exit) }
    func jobs() async -> [JobEntry] { await inner.jobs() }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { await inner.isDormantEligible(key) }
    func declineProjectServers(_ names: [String], project: URL) async throws {
        try await inner.declineProjectServers(names, project: project)
    }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {
        await inner.acceptProjectServers(servers, project: project)
    }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { await inner.events(of: key) }
}

// MARK: - The pseudo-terminal child

/// A `claude` on a pty, started by this test and stopped by it. Never a session in the user's
/// terminal. Ported in shape from C4's G5, which is a test target and exports nothing.
///
/// `posix_spawn` rather than `Process`, so the test owns the child outright and can wait on the pid
/// it started.
private final class PseudoTerminalChild {
    let pid: pid_t
    private let master: Int32
    private var reaped = false
    private let drain: Thread

    struct Failure: Error { let message: String }

    init(executable: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw Failure(message: "could not open a pseudo-terminal for the foreign-session scenario")
        }
        let slave = open(name, O_RDWR)
        guard slave >= 0 else { throw Failure(message: "could not open the pty slave") }
        defer { close(slave) }
        // A terminal of a real shape: the engine's renderer sizes itself from this on startup.
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in Int32(0)...Int32(2) { posix_spawn_file_actions_adddup2(&actions, slave, descriptor) }
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addchdir(&actions, cwd.path(percentEncoded: false))

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let path = executable.path(percentEncoded: false)
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for value in argv where value != nil { free(value) }
            for value in envp where value != nil { free(value) }
        }

        var spawned: pid_t = 0
        let code = posix_spawn(&spawned, path, &actions, &attributes, &argv, &envp)
        guard code == 0 else {
            close(master)
            throw Failure(message: "posix_spawn of the pty child failed with \(code)")
        }
        pid = spawned

        // The master end has to be read, continuously. A TUI writes its frame on every animation
        // tick, and a pty whose master nobody drains fills up and blocks the child's `write` — which
        // stalls it before it writes its registry record. Diagnosed live in C4: an undrained child
        // never appears under `sessions/`.
        let descriptor = master
        drain = Thread {
            var scratch = [UInt8](repeating: 0, count: 8192)
            while read(descriptor, &scratch, scratch.count) > 0 {}
        }
        drain.start()
    }

    /// Ends the child this test started, and nothing else: two interrupts, then `/exit`, then
    /// `SIGTERM`, then `SIGKILL`, each step waited out. Every one of them is aimed at the pid this
    /// object spawned.
    func stop() {
        guard !reaped else { return }
        reaped = true
        defer { close(master) }
        write("\u{03}", count: 1)
        write("\u{03}", count: 1)
        if waitFor(seconds: 3) { return }
        write("/exit\r", count: 6)
        if waitFor(seconds: 3) { return }
        kill(pid, SIGTERM)
        if waitFor(seconds: 3) { return }
        kill(pid, SIGKILL)
        _ = waitFor(seconds: 3)
    }

    private func write(_ text: String, count: Int) {
        _ = text.withCString { Darwin.write(master, $0, count) }
    }

    private func waitFor(seconds: Int) -> Bool {
        for _ in 0..<(seconds * 20) {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(50_000)
        }
        return false
    }
}
