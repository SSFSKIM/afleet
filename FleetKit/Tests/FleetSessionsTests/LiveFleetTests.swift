import Foundation
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// G5: the only place FleetKit speaks to the installed `claude`.
///
/// Every scenario runs behind the suite's one `LiveBudget` (`Support/LiveGate.swift`): serialised, with an explicit
/// `--max-turns` on every launch, the haiku pin on every turn-spending one, and hard ceilings of four model turns
/// and ten minutes for the whole suite. Three scenarios spend nothing and witness that with `get_session_cost`;
/// two spend two turns each and run only when `AFLEET_LIVE_CLI_TURNS=1` is also set. Two tests — the allowlist pin
/// and the budget's own concurrency proof — need no CLI at all and run on every checkout.
///
/// Nothing in this file writes under a config home. The scratch home is read by the witness and handed to every
/// child; the child writes, and the allowlist is the claim about what it may write.
final class LiveFleetTests: XCTestCase {

    // MARK: - Suite state

    /// One budget for the whole suite. Its usage probe is a zero-cost `ClaudeProcess`: a handshake, `get_usage`,
    /// `get_session_cost` asserted zero, and out.
    static let budget = LiveBudget(probe: { await LiveFleetTests.readUsage() })

    /// The suite-level witness reading, taken in class `setUp` and compared after every test — so a write between
    /// two scenarios is caught as surely as one inside a scenario.
    private static let suite = SuiteWitness()

    private final class SuiteWitness: @unchecked Sendable {   // `lock` serialises `reading`
        private let lock = NSLock()
        private var stored: [String: ConfigHomeWitness.Stamp] = [:]
        var reading: [String: ConfigHomeWitness.Stamp] {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static var isLive: Bool { ProcessInfo.processInfo.environment["AFLEET_LIVE_CLI"] == "1" }
    private static var witness: ConfigHomeWitness { ConfigHomeWitness(root: LiveGate.scratchHome) }

    override class func setUp() {
        super.setUp()
        suite.reading = witness.read()
    }

    override func tearDown() async throws {
        guard Self.isLive else { return }
        let difference = ConfigHomeWitness.difference(from: Self.suite.reading, to: Self.witness.read())
        let unexplained = LiveGate.unexplained(difference)
        XCTAssertTrue(unexplained.isEmpty, "suite witness: unexplained paths \(unexplained)")
        print("[G5] suite witness so far: \(difference.summary); \(await Self.budget.summary)")
    }

    // MARK: - Scenario 1: a foreign interactive session

    /// A `claude` the user started in a terminal is seen, reported with its own record's presence, and archived
    /// when it ends. It is never sent a prompt, never adopted and never stopped by anything but this test, which
    /// started it.
    ///
    /// Deliberate break: filter registry records by `entrypoint == "sdk-cli"` in `FileHolderReader` → the
    /// interactive session is never detected and this fails at the five-second poll.
    func testAForeignInteractiveSessionIsDetectedWithinFiveSecondsAndArchivedWhenItEnds() async throws {
        try LiveGate.skipUnlessLive()
        let rig = try await LiveRig(budget: Self.budget)
        addTeardownBlock { await rig.shutdown() }

        try await Self.budget.run(turns: 0, wallTime: .seconds(60)) {
            let directory = try Self.trustedDirectory(0)
            let session = SessionID()
            let key = ChannelKey(configHome: LiveGate.scratchHome, session: session)
            // Registered before the child exists: the observer's vnode source fires the moment the record lands,
            // and a channel nobody registered is not one the fleet reports on. The id is the test's own, so the
            // record it finds can be checked against it.
            await rig.fleet.register(key, cwd: directory, recent: false)

            let child = try PseudoTerminalChild(executable: rig.binary,
                                                arguments: ["--session-id", session.description],
                                                environment: rig.childEnvironment.merging(
                                                    ["TERM": "xterm-256color"]) { $1 },
                                                cwd: directory)
            var stopped = false
            defer { if !stopped { child.stop() } }

            // The engine's own startup is not what the five seconds are about: the claim is that *afleet* reports
            // the session within five seconds of there being one to report. So the record is waited for first,
            // with a budget of its own, and the five seconds are measured from the moment it exists.
            let written = try await Self.poll(upTo: .seconds(30)) { Self.registryRecord(forPID: child.pid) }
            let record = try XCTUnwrap(written,
                                       "the pty child wrote no registry record under sessions/ within thirty seconds")
            XCTAssertEqual(record.sessionId, session.description,
                           "the record the fleet saw is not this test's own child's")

            let seen = try await Self.poll(upTo: .seconds(5)) { () -> ChannelState? in
                let state = await rig.fleet.state(of: key)
                guard state?.origin == .foreignLive(.usersTerminal) else { return nil }
                return state
            }
            if seen == nil {
                let last = await rig.fleet.state(of: key)
                let holders = last?.observed.holders.map {
                    "pid \($0.pid) kind \($0.kind) sources \($0.sources.count) job \($0.isJob) own \($0.isOwnChild)"
                } ?? []
                XCTFail("""
                    no foreign live channel for the pty child within five seconds;                     origin \(String(describing: last?.origin)), holders \(holders)
                    """)
            }
            let state = try XCTUnwrap(seen, "no foreign live channel for the pty child within five seconds")
            XCTAssertEqual(state.key.session, session)
            XCTAssertTrue([.idle, .busy, .unknown].contains(state.presence)
                            || { if case .waiting = state.presence { return true }; return false }(),
                          "unexpected presence for a foreign live channel: \(state.presence)")

            child.stop()
            stopped = true

            let archived = try await Self.poll(upTo: .seconds(10)) { () -> Bool? in
                await rig.fleet.state(of: key)?.origin == .archived ? true : nil
            }
            XCTAssertEqual(archived, true, "the channel did not archive after the pty child exited")
        }
    }

    // MARK: - Scenario 2: an exec job

    /// An exec job is a job with no session at all, which is exactly why `jobs()` and `performJob` are keyed by
    /// short rather than by `ChannelKey`.
    ///
    /// Deliberate break: list only jobs that name a session in `Fleet.jobs()` → the exec job never appears.
    func testAnExecJobIsListedInJobsAndStopRemovesIt() async throws {
        try LiveGate.skipUnlessLive()
        let rig = try await LiveRig(budget: Self.budget)
        addTeardownBlock { await rig.shutdown() }

        try await Self.budget.run(turns: 0, wallTime: .seconds(45)) {
            let directory = try Self.trustedDirectory(0)
            let short = try await rig.verbs.backgroundExec("sleep 60", cwd: directory)
            var removed = false
            defer { if !removed { Task.detached { try? await rig.verbs.remove(short) } } }

            let entry = try await Self.poll(upTo: .seconds(10)) { () -> JobEntry? in
                await rig.fleet.jobs().first { $0.short == short }
            }
            let job = try XCTUnwrap(entry, "the exec job \(short.rawValue) never appeared in jobs()")
            // The delegated unknown: whether an exec job's `state.json` carries a `sessionId` at all. Recorded as
            // a boolean, never as the id.
            print("[G5] exec job carries a session id: \(job.sessionID != nil)")

            try await rig.fleet.performJob(.stop, short)
            let gone = try await Self.poll(upTo: .seconds(20)) { () -> Bool? in
                await rig.fleet.jobs().contains { $0.short == short } ? nil : true
            }
            XCTAssertEqual(gone, true, "the exec job \(short.rawValue) is still listed after stop")

            try await rig.verbs.remove(short)
            removed = true
        }
    }

    // MARK: - Scenario 3: a declined project server

    /// G3's engine-side proof, zero cost: the headless path promotes a pending project server and spawns its
    /// command, and a decline written through the §6.12 writer stops it.
    ///
    /// Deliberate break: skip the decline write → launch B spawns the marker too.
    func testADeclinedProjectServerIsNotSpawnedByTheEngine() async throws {
        try LiveGate.skipUnlessLive()
        let rig = try await LiveRig(budget: Self.budget)
        addTeardownBlock { await rig.shutdown() }

        try await Self.budget.run(turns: 0, wallTime: .seconds(60)) {
            let directory = try Self.trustedDirectory(3)
            let markerName = "marker-\(UUID().uuidString)"
            let marker = directory.appending(path: markerName)
            let mcpFile = directory.appending(path: ".mcp.json")
            let localSettings = directory.appending(path: ".claude/settings.local.json")
            defer {
                try? FileManager.default.removeItem(at: mcpFile)
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: directory.appending(path: ".claude"))
            }

            // stdio, because only a spawned command leaves a marker; an http or sse entry is listed and gated
            // identically, with nothing on disk to witness.
            let mcp = """
                {"mcpServers": {"marker": {"command": "/bin/sh", "args": ["-c", \
                "touch '\(marker.path(percentEncoded: false))'; exec sleep 30"]}}}
                """
            try Data(mcp.utf8).write(to: mcpFile)
            let projectBefore = Self.tree(under: directory)

            // Launch A: accepted through the store-only accept, so Task 7's consent gate does not stop it and the
            // marker proves the engine's own promotion rather than the gate's behaviour.
            let keyA = ChannelKey(configHome: LiveGate.scratchHome, session: SessionID())
            await rig.fleet.register(keyA, cwd: directory, recent: true)
            guard case .consentNeeded(let servers) = await rig.fleet.preconditions(for: keyA) else {
                throw LiveGateFailure("the project's marker server was not read as consent-needed")
            }
            XCTAssertEqual(servers.map(\.name), ["marker"])
            await rig.fleet.acceptProjectServers(servers, project: directory)

            let statusA = try await Self.launchAndWitness(rig: rig, key: keyA, cwd: directory, label: "launch A") {
                _ = try await Self.poll(upTo: .seconds(45)) { () -> Bool? in
                    FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) ? true : nil
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                          "the accepted project server was never spawned by the engine")
            try FileManager.default.removeItem(at: marker)

            // The decline outranks the recorded acceptance (Task 7's precedence).
            try await rig.fleet.declineProjectServers(["marker"], project: directory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: localSettings.path(percentEncoded: false)),
                          "the §6.12 write left no settings.local.json")

            let keyB = ChannelKey(configHome: LiveGate.scratchHome, session: SessionID())
            await rig.fleet.register(keyB, cwd: directory, recent: true)
            let statusB = try await Self.launchAndWitness(rig: rig, key: keyB, cwd: directory, label: "launch B") {
                // Nothing to wait for; the claim is an absence, so the wait is a fixed grace against the same
                // budget the promotion had in A.
                try? await Task.sleep(for: .seconds(10))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                           "the declined project server was spawned anyway")

            let projectAfter = Self.tree(under: directory)
            XCTAssertEqual(projectAfter.subtracting(projectBefore), [".claude/settings.local.json"],
                           "the project tree changed by more than the §6.12 write")

            // The answer's shape for a rejected server is unrecorded in the corpus, so this is a note, not an
            // assertion: counts and status words only.
            for (label, status) in [("launch A", statusA), ("launch B", statusB)] {
                print("[G5] \(label) mcp_status: \(Self.describe(status))")
            }
        }
    }

    // MARK: - Scenario 4: adoption, two turns

    /// *Adopt* stops the job, resumes the same session owned, and *Send to background* hands it back.
    ///
    /// Deliberate break: drop `verbs.stop` from `ChannelSupervisor.adopt` → the worker never leaves and the
    /// release wait times out into Contended.
    func testAdoptingAConversationJobResumesItOwnedAndSendsItBack() async throws {
        try LiveGate.skipUnlessLive()
        try LiveGate.skipUnlessTurns()
        let rig = try await LiveRig(budget: Self.budget)
        addTeardownBlock { await rig.shutdown() }

        try await Self.budget.run(turns: 2, wallTime: .seconds(180)) {
            let directory = try Self.trustedDirectory(0)
            // `claude --bg` forwards `--max-turns` (bundle 824274's forwarded-flag set), so the job the test
            // starts is capped exactly as every other launch of this suite is.
            _ = try await rig.runner.run(rig.binary,
                                         arguments: ["--bg", "--model", Self.haiku, "--max-turns", "1",
                                                     "Reply with exactly: pong"],
                                         environment: rig.childEnvironment, cwd: directory, timeout: .seconds(120))

            let started = try await Self.poll(upTo: .seconds(60)) { () -> JobEntry? in
                await rig.fleet.jobs().first { $0.sessionID != nil && $0.cwd?.lastPathComponent == directory.lastPathComponent }
            }
            let job = try XCTUnwrap(started, "the --bg conversation job never appeared in jobs()")
            let session = try XCTUnwrap(job.sessionID)
            let key = ChannelKey(configHome: LiveGate.scratchHome, session: session)
            await rig.fleet.register(key, cwd: directory, recent: true)
            let opened = await rig.fleet.events(of: key)
            let stream = try XCTUnwrap(opened, "the fleet has no channel for the adopted session")
            let log = LiveEventLog()
            let pump = Task { for await event in stream { await log.append(event) } }
            defer { pump.cancel() }
            _ = try await Self.poll(upTo: .seconds(20)) { () -> Bool? in
                await rig.fleet.state(of: key)?.origin == .backgroundJob ? true : nil
            }

            // The resume carries `--max-turns 1`: a resumed job may run a turn, which is the second reservation.
            _ = Self.budget.launch(LaunchConfiguration(binary: rig.binary, cwd: directory, session: .resume(session, fork: false)),
                                   maxTurns: 1, model: Self.haiku)
            let adopted = try await rig.fleet.perform(.adopt, on: key)

            XCTAssertTrue(rig.runner.calls.ran(["stop", job.short.rawValue]),
                          "adopt did not stop the job through the runner")
            let rosterAfterAdopt = await rig.fleet.jobs()
            XCTAssertFalse(rosterAfterAdopt.contains { $0.short == job.short },
                           "the adopted job is still on the roster")
            XCTAssertEqual(adopted.origin, .owned(.ready),
                           "adopt did not reach owned/ready; the post-handshake check found a holder")
            XCTAssertEqual(adopted.identity.resolved, session)

            let backgrounded = try await rig.fleet.perform(.sendToBackground, on: key)
            XCTAssertTrue(rig.runner.calls.ran(["--bg", "--resume", session.description]),
                          "send-to-background did not run --bg --resume")
            XCTAssertEqual(backgrounded.origin, .backgroundJob)
            let rosterAfterHandback = await rig.fleet.jobs()
            let handedBack = try XCTUnwrap(rosterAfterHandback.first { $0.sessionID == session },
                                           "no job on the roster for the session that was handed back")

            try await rig.fleet.performJob(.stop, handedBack.short)
            _ = try await Self.poll(upTo: .seconds(20)) { () -> Bool? in
                await rig.fleet.jobs().contains { $0.short == handedBack.short } ? nil : true
            }
            _ = try? await rig.verbs.remove(handedBack.short)
            _ = try? await rig.verbs.remove(job.short)

            let observed = await log.events
            for result in Self.results(in: observed) {
                XCTAssertNotEqual(result.subtype, "error_max_turns",
                                  "a turn ended at the --max-turns cap: result subtype error_max_turns")
                await Self.budget.add(cost: result.totalCostUSD)
            }
            Self.budget.assertEveryLaunchWasDecorated()
        }
    }

    // MARK: - Scenario 5: the composed turn

    /// One prompt that makes hooks, a background shell, a subagent and a relocation all write under the config
    /// home, with the witness read while the child is still live and again after it has ended.
    ///
    /// Deliberate break: remove `projects/` from `LiveGate.engineWrittenPaths` → the transcript is unexplained in
    /// the final reading. It is always written, which is what makes it the discriminating demonstration.
    ///
    /// The prompt opens with a `Write`, which the brief's did not. `Fixtures/background-shell` and
    /// `Fixtures/explore-depth-1` record **no** `can_use_tool` at all for a backgrounded Bash or for a Task
    /// subagent, while `Fixtures/notification-hook` records one for `Write`; the Notification hook fires only
    /// while an ask stays unanswered, so without a tool the engine actually asks about there is nothing to hold
    /// and the hook never arrives.
    func testTheWriteAllowlistHoldsAcrossHooksABackgroundShellASubagentAndRelocation() async throws {
        try LiveGate.skipUnlessLive()
        try LiveGate.skipUnlessTurns()
        let rig = try await LiveRig(budget: Self.budget)
        addTeardownBlock { await rig.shutdown() }

        try await Self.budget.run(turns: 2, wallTime: .seconds(240)) {
            let home = try Self.trustedDirectory(1)
            let elsewhere = try Self.trustedDirectory(2)
            let written = home.appending(path: "live-gate-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: written) }

            let before = Self.witness.read()
            XCTAssertFalse(before.isEmpty, "the witness read no files under the scratch config home")

            let session = SessionID()
            let key = ChannelKey(configHome: LiveGate.scratchHome, session: session)
            await rig.fleet.register(key, cwd: home, recent: true)
            let opened = await rig.fleet.events(of: key)
            let composedStream = try XCTUnwrap(opened, "the fleet has no channel for this session")
            let log = LiveEventLog()
            let driver = DecisionDriver(fleet: rig.fleet, key: key)
            let pump = Task {
                for await event in composedStream {
                    await log.append(event)
                    if case .request(let request) = event { await driver.handle(request) }
                }
            }
            defer { pump.cancel() }

            // Bash, Task, the subagent's own calls and the reply are agentic turns inside the one prompt.
            _ = Self.budget.launch(LaunchConfiguration(binary: rig.binary, cwd: home, session: .new(session)),
                                   maxTurns: 12, model: Self.haiku, freshSessions: [session])
            try await rig.fleet.perform(.open, on: key)

            // The Notification hook fires about ten seconds into an unanswered ask; the held permission is
            // released by the hook's arrival or by this deadline, whichever comes first.
            let deadline = Task { try? await Task.sleep(for: .seconds(25)); await driver.deadlineReached() }
            defer { deadline.cancel() }

            try await rig.fleet.perform(.send(UserInput(text: """
                Do exactly these four things in order and nothing else.
                1. Use the Write tool to create the file \(written.lastPathComponent) in the current directory \
                containing the single line: ok
                2. Use the Bash tool with run_in_background=true to run exactly: sleep 5
                3. Use the Task tool with the Explore subagent to list the files in the current directory.
                4. Reply with the single word: done
                """)), on: key)

            let firstTurn = await log.wait(upTo: .seconds(240)) { Self.results(in: $0).count >= 1 }
            XCTAssertGreaterThanOrEqual(Self.results(in: firstTurn).count, 1,
                                        "the prompt produced no result frame within four minutes")

            // The project rule forbids closing a channel over a running task, so the shell's notification and the
            // engine's automatic follow-up turn are waited for rather than cut off.
            let settled = await log.wait(upTo: .seconds(120)) { events in
                Self.results(in: events).count >= 2 && events.contains { event in
                    if case .frame(.system(.taskNotification), _) = event { return true }
                    return false
                }
            }

            // `/cd` into a second trusted directory. The request goes to the channel's own process: the facade has
            // no generic control-request door, and Task 8's strategy executor takes a supervisor this test cannot
            // reach through `Fleet`.
            let handle = try XCTUnwrap(rig.handles.latest, "the live factory built no handle for this channel")
            _ = try await handle.request(SetCwd(path: elsewhere.path(percentEncoded: false)), timeout: .seconds(60))

            // Read while the child is still running: its own `sessions/` record exists only for that long.
            let liveDifference = ConfigHomeWitness.difference(from: before, to: Self.witness.read())
            XCTAssertEqual(LiveGate.unexplained(liveDifference), [],
                           "live reading: paths moved under names the engine is not known to write")
            XCTAssertTrue(Self.touches(liveDifference, prefix: "sessions/"),
                          "the live reading saw no sessions/ record, so it was not looking at the child's tree")

            try await rig.fleet.perform(.reap, on: key)
            _ = await log.wait(upTo: .seconds(30)) { events in
                events.contains { if case .exited = $0 { return true }; return false }
            }

            let finalDifference = ConfigHomeWitness.difference(from: before, to: Self.witness.read())
            XCTAssertEqual(LiveGate.unexplained(finalDifference), [],
                           "final reading: paths moved under names the engine is not known to write")
            XCTAssertTrue(Self.touches(finalDifference, prefix: "projects/"),
                          "the final reading saw no transcript under projects/")
            print("[G5] composed live reading \(liveDifference.summary); final reading \(finalDifference.summary)")

            // What the one prompt actually did, from the channel's own events.
            let events = await log.events
            XCTAssertTrue(Self.hasTask(events, type: "local_bash"),
                          "no system/task_started with task_type local_bash: the background shell never ran")
            XCTAssertTrue(Self.hasTask(events, type: "local_agent"),
                          "no system/task_started with task_type local_agent: the subagent never ran")
            let hookIDs = await driver.hookCallbackIDs
            XCTAssertTrue(hookIDs.contains("afleet.notification"),
                          "no inbound hook_callback for afleet.notification: the Notification hook never fired")
            let answered = await driver.answered
            XCTAssertEqual(answered.first, "hook_callback",
                           "the held permission was answered before the hook; answers were \(answered)")

            _ = settled
            let results = Self.results(in: events)
            XCTAssertGreaterThanOrEqual(results.count, 2,
                                        "expected the prompt's result and the follow-up turn's, saw \(results.count)")
            for result in results {
                XCTAssertNotEqual(result.subtype, "error_max_turns",
                                  "a turn ended at the --max-turns cap: result subtype error_max_turns")
                XCTAssertFalse(result.isError, "a turn ended with an error result: \(result.subtype)")
                await Self.budget.add(cost: result.totalCostUSD)
            }
            Self.budget.assertEveryLaunchWasDecorated()
        }
    }

    // MARK: - The two tests that need no CLI

    /// The allowlist is exactly the spec's list, so an addition is deliberate.
    func testTheAllowlistNamesNothingTheEngineIsNotKnownToWrite() {
        XCTAssertEqual(LiveGate.engineWrittenPaths, [
            "sessions/", "projects/", "tasks/", "jobs/", "daemon/", "daemon.lock", "daemon.status.json",
            "todos/", "statsig/", "shell-snapshots/",
            "session-env/", "file-history/", "debug/", "plugins/", "cache/", "backups/", "plans/", "ide/",
            "logs/", "history/", ".claude.json", ".credentials.json", ".last-cleanup",
            ".last-update-result.json", "daemon.log", "history.jsonl", "settings.json",
        ])
        XCTAssertEqual(LiveGate.unexplained(.init(created: ["projects/-tmp-x/abc.jsonl", "afleet/channels.json"],
                                                  modified: [".claude.json", "settings.local.json"],
                                                  deleted: ["fleet-state.db"])),
                       ["afleet/channels.json", "fleet-state.db", "settings.local.json"])
    }

    /// The budget admits one scenario at a time and accounts a scenario's turns at call time, not at body start.
    ///
    /// Deliberate break: move the `turnsReserved += turns` in `LiveBudget.enter` to after `acquire()` → the third
    /// call is admitted, because the second one's turn is not yet on the books.
    func testTwoOverlappingScenariosRunOneAtATimeWithAtomicAccounting() async throws {
        let budget = LiveBudget(turnCeiling: 2, wallCeiling: .seconds(60))
        let trace = OverlapTrace()

        async let first: Void = budget.run(turns: 1, wallTime: .seconds(1)) {
            trace.entered("A")
            await trace.suspend("A")
            trace.left("A")
        }
        async let second: Void = budget.run(turns: 1, wallTime: .seconds(1)) {
            trace.entered("B")
            await trace.suspend("B")
            trace.left("B")
        }

        // Both reservations are on the books before the third call is issued; only one body is inside.
        let bothReserved = try await Self.poll(upTo: .seconds(5)) { () -> Bool? in
            await budget.reservedTurns() == 2 ? true : nil
        }
        XCTAssertEqual(bothReserved, true,
                       "both scenarios' turns were not reserved at call time; only one body has started")
        XCTAssertEqual(trace.inside, 1, "two bodies were inside the budget at once")

        do {
            try await budget.run(turns: 1, wallTime: .seconds(1)) { XCTFail("a third scenario was admitted") }
            XCTFail("the third scenario was not refused")
        } catch let skip as XCTSkip {
            XCTAssertTrue((skip.message ?? "").contains("2 turns already spent of 2"),
                          "the refusal did not name the spent turns: \(skip.message ?? "")")
        }

        // Which of the two `async let` calls wins the lock is the scheduler's business; that only one of them is
        // inside, and that the other starts only after it has returned, is the budget's.
        let firstIn = try XCTUnwrap(trace.order.first, "neither scenario entered the budget")
        let leader = String(firstIn.prefix(1))
        let follower = leader == "A" ? "B" : "A"

        trace.resume(leader)
        _ = try await Self.poll(upTo: .seconds(5)) { () -> Bool? in trace.entries.count == 2 ? true : nil }
        XCTAssertEqual(trace.inside, 1, "\(follower) entered before \(leader) had returned")
        trace.resume(follower)
        _ = try await first
        _ = try await second

        XCTAssertEqual(trace.order, ["\(leader) in", "\(leader) out", "\(follower) in", "\(follower) out"])
    }

    // MARK: - Helpers

    static let haiku = "claude-haiku-4-5-20251001"

    /// The zero-cost usage read the budget takes before the first scenario and before each turn-spending one.
    private static func readUsage() async -> LiveBudgetReading? {
        guard isLive, let resolved = try? await LiveRig.resolveBinary(), let directory = try? trustedDirectory(0)
        else { return nil }
        var launch = LaunchConfiguration(binary: resolved.binary, cwd: directory, session: .new(SessionID()),
                                         maxTurns: 1)
        launch.configHomeOverride = LiveGate.scratchHome
        let process = ClaudeProcess(epoch: .first, launch: launch, environment: resolved.environment,
                                    configHome: ConfigHome(root: LiveGate.scratchHome, source: .environment),
                                    mcpServer: AfleetMCPServer(serverVersion: FleetVersion.server, cwd: directory,
                                                               tools: [SendUserFileTool()]),
                                    diagnostics: NullDiagnostics(), capture: nil)
        guard (try? await process.spawn(handshakeTimeout: .seconds(60))) != nil else {
            await process.terminate()
            return nil
        }
        let answer = try? await process.request(GetUsage(), timeout: .seconds(30))
        let rendered = try? await process.request(GetSessionCost(), timeout: .seconds(30))
        await process.terminate()
        guard let answer else { return nil }
        let reading = LiveBudgetReading.read(getUsage: answer)
        XCTAssertEqual(reading.sessionCostUSD, 0, "the budget probe's own session cost was not zero")
        XCTAssertTrue((rendered?["text"]?.stringValue ?? "").contains("$0.0000"),
                      "the budget probe's get_session_cost did not read zero")
        print("""
            [G5] usage windows examined \(reading.examined.sorted()); spent \(reading.spent.isEmpty ? "none" : reading.reason)
            """)
        return reading
    }

    /// A handshake-only launch through the fleet: `--max-turns 1`, `mcp_status`, the zero-cost witness, then out.
    private static func launchAndWitness(rig: LiveRig, key: ChannelKey, cwd: URL, label: String,
                                         _ body: () async throws -> Void) async throws -> JSONValue {
        _ = budget.launch(LaunchConfiguration(binary: rig.binary, cwd: cwd, session: .new(key.session)),
                          maxTurns: 1, freshSessions: [key.session])
        try await rig.fleet.perform(.open, on: key)
        let handle = try XCTUnwrap(rig.handles.latest, "\(label): the live factory built no handle")
        try await body()
        let status = try await handle.request(MCPStatus(), timeout: .seconds(60))
        _ = try await budget.witnessZeroCost(handle, label: label)
        try await rig.fleet.perform(.reap, on: key)
        budget.assertEveryLaunchWasDecorated()
        return status
    }

    /// Server names and status words only; the corpus records no shape for a rejected server.
    private static func describe(_ status: JSONValue) -> String {
        let servers = status["mcpServers"]?.arrayValue ?? []
        let words = servers.map { "\($0["name"]?.stringValue ?? "?")=\($0["status"]?.stringValue ?? "?")" }
        return "\(servers.count) server(s): \(words.sorted().joined(separator: ", "))"
    }

    private static func results(in events: [WireEvent]) -> [ResultFrame] {
        events.compactMap { if case .frame(.result(let r), _) = $0 { return r }; return nil }
    }

    private static func hasTask(_ events: [WireEvent], type: String) -> Bool {
        events.contains { event in
            guard case .frame(.system(.taskStarted(let started)), _) = event else { return false }
            return started.taskType == type
        }
    }

    private static func touches(_ difference: ConfigHomeWitness.Difference, prefix: String) -> Bool {
        difference.created.union(difference.modified).union(difference.deleted).contains { $0.hasPrefix(prefix) }
    }

    /// The engine's registry record for a pid, read (never written) from the scratch home.
    private static func registryRecord(forPID pid: Int32) -> RegistryRecord? {
        let file = LiveGate.scratchHome.appending(path: "sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return RegistryRecord.decode(data)
    }

    /// Directories the scratch `.claude.json` already trusts, under `/private/tmp/afleet-fixtures/`, in a stable
    /// order. The test never writes trust; a directory the file names but that is gone is recreated, which is a
    /// write under `/private/tmp`, not under a config home.
    private static func trustedDirectory(_ index: Int) throws -> URL {
        let file = LiveGate.scratchHome.appending(path: ".claude.json")
        let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        let projects = document?["projects"] as? [String: Any] ?? [:]
        let trusted = projects.compactMap { path, value -> String? in
            guard let entry = value as? [String: Any], entry["hasTrustDialogAccepted"] as? Bool == true,
                  path.hasPrefix("/private/tmp/afleet-fixtures/") else { return nil }
            return path
        }.sorted()
        guard index < trusted.count else { throw XCTSkip("no trusted scratch directory at index \(index)") }
        let url = URL(filePath: trusted[index])
        if !FileManager.default.fileExists(atPath: trusted[index]) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Relative paths of every regular file under a project directory.
    private static func tree(under root: URL) -> Set<String> {
        Set(ConfigHomeWitness(root: root).read().keys)
    }

    /// Polls `body` on wall time until it answers non-nil or the deadline passes. Wall time is right here: this
    /// waits on the engine and on the filesystem, not on a lifecycle timer.
    private static func poll<T>(upTo deadline: Duration, every interval: Duration = .milliseconds(100),
                                _ body: () async throws -> T?) async throws -> T? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if let value = try await body() { return value }
            try? await Task.sleep(for: interval)
        }
        return try await body()
    }
}

// MARK: - The decision flow of the composed scenario

/// Rules the composed scenario's decisions: the first `can_use_tool` is held until the Notification hook's
/// callback arrives (or the scenario's deadline passes), the hook is answered first, the held permission second,
/// and everything after that at once.
private actor DecisionDriver {
    private let fleet: Fleet
    private let key: ChannelKey
    /// The subtypes answered, in the order they were answered.
    private(set) var answered: [String] = []
    /// Every `callback_id` the engine asked about.
    private(set) var hookCallbackIDs: [String] = []
    private var held: (id: RequestID, input: JSONValue)?
    private var hookArrived = false

    init(fleet: Fleet, key: ChannelKey) { self.fleet = fleet; self.key = key }

    func handle(_ request: InboundRequest) async {
        switch request.payload {
        case .hookCallback(let hook):
            hookCallbackIDs.append(hook.callbackID)
            await answerHook(request.id)
            guard hook.callbackID == "afleet.notification" else { return }
            hookArrived = true
            await releaseHeld()
        case .canUseTool(let ask):
            guard held == nil, !hookArrived else { return await allow(request.id, ask.input) }
            held = (request.id, ask.input)
        default:
            break
        }
    }

    /// The hook did not come; the held ask is released so the turn is not parked forever.
    func deadlineReached() async { await releaseHeld() }

    private func releaseHeld() async {
        guard let pending = held else { return }
        held = nil
        await allow(pending.id, pending.input)
    }

    private func allow(_ id: RequestID, _ input: JSONValue) async {
        answered.append("can_use_tool")
        _ = try? await fleet.perform(.answer(id, .permission(.allow(updatedInput: input, updatedPermissions: nil,
                                                                classification: nil))), on: key)
    }

    private func answerHook(_ id: RequestID) async {
        answered.append("hook_callback")
        _ = try? await fleet.perform(.answer(id, .hookContinue(HookOutput(fields: ["continue": .bool(true)]))), on: key)
    }
}

// MARK: - The budget's overlap trace

/// Who was inside the budget and when, for `testTwoOverlappingScenariosRunOneAtATimeWithAtomicAccounting`.
private final class OverlapTrace: @unchecked Sendable {   // `lock` serialises every field
    private let lock = NSLock()
    private var _order: [String] = []
    private var _inside = 0
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var resumed: Set<String> = []

    var order: [String] { lock.lock(); defer { lock.unlock() }; return _order }
    var inside: Int { lock.lock(); defer { lock.unlock() }; return _inside }
    var entries: [String] { order.filter { $0.hasSuffix(" in") } }

    func entered(_ name: String) { lock.lock(); _order.append("\(name) in"); _inside += 1; lock.unlock() }
    func left(_ name: String) { lock.lock(); _order.append("\(name) out"); _inside -= 1; lock.unlock() }

    func suspend(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if resumed.contains(name) { lock.unlock(); continuation.resume(); return }
            gates[name] = continuation
            lock.unlock()
        }
    }

    func resume(_ name: String) {
        lock.lock()
        resumed.insert(name)
        let gate = gates.removeValue(forKey: name)
        lock.unlock()
        gate?.resume()
    }
}

// MARK: - The live rig

/// A `Fleet` over the scratch config home, built the way production builds it: the real environment capture, the
/// installed binary, a real `FoundationDirectoryRunner` behind a recorder, and a factory that hands out the same
/// `LiveProcessHandle` production does — decorated with the running scenario's `--max-turns` and model.
private final class LiveRig: @unchecked Sendable {   // every stored value is set once, in `init`
    let environment: ResolvedEnvironment
    let binary: URL
    let configHome: ConfigHome
    let childEnvironment: [String: String]
    let fleet: Fleet
    let verbs: CLIVerbs
    let runner: RecordingDirectoryRunner
    let handles = LiveHandles()
    private let storeDirectory: URL
    private let diagnosticsDirectory: URL

    static func resolveBinary() async throws -> (environment: ResolvedEnvironment, binary: URL) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = await EnvironmentResolver().resolve(shell: shell)
        guard let binary = BinaryLocator.locate(in: environment, override: nil) else {
            throw LiveGateFailure("claude was not found on the login PATH")
        }
        return (environment, binary)
    }

    init(budget: LiveBudget) async throws {
        let resolved = try await Self.resolveBinary()
        environment = resolved.environment
        binary = resolved.binary
        configHome = ConfigHome(root: LiveGate.scratchHome, source: .environment)

        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        storeDirectory = temporary.appending(path: "afleet-c4-live-store-\(UUID().uuidString)")
        diagnosticsDirectory = temporary.appending(path: "afleet-c4-live-diag-\(UUID().uuidString)")
        // Outside every config home, and `FileStateStore` refuses it otherwise.
        let store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [LiveGate.scratchHome])

        runner = RecordingDirectoryRunner(inner: FoundationDirectoryRunner(),
                                          calls: RecordingDirectoryRunner.Recorder())
        let template = LaunchConfiguration(binary: binary, cwd: LiveGate.scratchHome, session: .new(SessionID()))
        childEnvironment = template.childEnvironment(over: environment, configHome: configHome)

        let sink = FileFleetDiagnostics(directory: diagnosticsDirectory)
        // Three minutes, not the twenty seconds a `CLIVerbs` defaults to. `claude --bg` returns in under a second
        // against a warm daemon, but the live gate watched it take ninety seconds while the daemon was booting and
        // several workers of earlier scenarios were still settling. The verb's own timeout is a production choice
        // and not this test's to make; the gate simply refuses to read that contention as a verb failure.
        verbs = CLIVerbs(runner: runner, binary: binary, configHome: configHome, environment: childEnvironment,
                         diagnostics: sink, timeout: .seconds(180))

        let built = handles
        let home = configHome
        let base = environment
        let factory: ProcessFactory = { epoch, launch in
            // The one place a scenario's `--max-turns` and haiku pin reach a launch the facade composed, and the
            // one place a launch that carries neither is counted.
            let decorated = budget.launches.decorate(launch)
            let capturing = CapturingDiagnostics(forwardingTo: NullDiagnostics())
            let process = ClaudeProcess(epoch: epoch, launch: decorated, environment: base, configHome: home,
                                        mcpServer: AfleetMCPServer(serverVersion: FleetVersion.server,
                                                                   cwd: decorated.cwd, tools: [SendUserFileTool()]),
                                        diagnostics: capturing, capture: nil)
            let handle = LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
            built.append(handle)
            return handle
        }

        fleet = Fleet(configHome: configHome, environment: environment, binary: binary, store: store,
                      diagnosticsDirectory: diagnosticsDirectory, factory: factory, runner: runner)
        await fleet.start()
    }

    func shutdown() async {
        await fleet.shutdown()
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: diagnosticsDirectory)
    }
}

// MARK: - The pseudo-terminal child

/// A `claude` on a pty, started by this test and stopped by it. Never a session in the user's terminal.
///
/// `posix_spawn` rather than `Process`, so the test owns the child outright and can wait on the pid it started.
private final class PseudoTerminalChild {
    let pid: pid_t
    private let master: Int32
    private var reaped = false
    private let drain: Thread

    init(executable: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw LiveGateFailure("could not open a pseudo-terminal for the foreign-session scenario")
        }
        let slave = open(name, O_RDWR)
        guard slave >= 0 else { throw LiveGateFailure("could not open the pty slave") }
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
            throw LiveGateFailure("posix_spawn of the pty child failed with \(code)")
        }
        pid = spawned

        // The master end has to be read, continuously. A TUI writes its frame on every animation tick, and a pty
        // whose master nobody drains fills up and blocks the child's `write` — which stalls it before it writes
        // its registry record. Diagnosed live: an undrained child never appears under `sessions/`.
        let descriptor = master
        drain = Thread {
            var scratch = [UInt8](repeating: 0, count: 8192)
            while read(descriptor, &scratch, scratch.count) > 0 {}
        }
        drain.start()
    }

    /// Ends the child this test started, and nothing else. `/exit` first, then two interrupts, then a signal to
    /// the pid — every step aimed at a pid this object owns.
    func stop() {
        guard !reaped else { return }
        reaped = true
        defer { close(master) }
        write(master, "\u{03}", count: 1)
        write(master, "\u{03}", count: 1)
        if waitFor(seconds: 3) { return }
        write(master, "/exit\r", count: 6)
        if waitFor(seconds: 3) { return }
        kill(pid, SIGTERM)
        if waitFor(seconds: 3) { return }
        kill(pid, SIGKILL)
        _ = waitFor(seconds: 3)
    }

    private func write(_ descriptor: Int32, _ text: String, count: Int) {
        _ = text.withCString { Darwin.write(descriptor, $0, count) }
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
