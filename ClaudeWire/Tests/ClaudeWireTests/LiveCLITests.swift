import XCTest
import AfleetCore
import ClaudeWire
import WireTestSupport

// MARK: - the config-home witness

/// Records what exists under a directory tree and reports what changed between two readings.
///
/// This exists to make parent X9 executable: afleet never writes under a Claude Code config home, and only the
/// spawned `claude` may. A live test proves its own half of that by taking a reading before it does anything,
/// a second reading immediately before the child is launched, and asserting the two are identical — everything
/// the test itself does happens inside that window.
///
/// The witness is deliberately a plain value with no XCTest in it, so `ConfigHomeWitnessTests` below can
/// exercise it against a scratch directory of its own on every run, including runs with no live CLI.
struct ConfigHomeWitness: Sendable {
    let root: URL

    struct Stamp: Hashable, Sendable { var size: Int; var modified: Date }

    struct Difference: Hashable, Sendable {
        var created: Set<String> = []
        var modified: Set<String> = []
        var deleted: Set<String> = []
        var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
        var summary: String {
            "created \(created.sorted()), modified \(modified.sorted()), deleted \(deleted.sorted())"
        }
    }

    /// Every regular file under `root`, keyed by its path relative to `root`. Hidden files are included —
    /// `.credentials.json` is the whole point of the tree — and unreadable subtrees are skipped rather than
    /// aborting the walk, so a reading is always comparable with another taken the same way.
    func read() -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [], errorHandler: { _, _ in true }) else { return out }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            out[relative] = Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        return out
    }

    /// Top-level names the engine is known to write under a config home.
    ///
    /// Restored from the plan, which asserted every child-created path falls under a named prefix; an earlier
    /// revision of this file replaced that with "the child wrote something" and a `print`, which is a weaker
    /// claim and was a substitution made in a comment rather than as a decision. The set is the union of the
    /// plan's list and the directories C1's scratch config home actually carries, and it is deliberately a
    /// *top-level* rule: a path appearing under a name nobody has seen the engine write is the shape an
    /// afleet-side write would take, and failing on it is the intended outcome, not a maintenance burden.
    static let engineWrittenNames: Set<String> = [
        "projects", "sessions", "todos", "statsig", "shell-snapshots", "debug", "plugins", "cache",
        "backups", "daemon", "file-history", "jobs", "plans", "session-env", "ide", "logs", "history",
        ".claude.json", ".credentials.json", ".last-cleanup", ".last-update-result.json",
        "daemon.log", "history.jsonl", "settings.json",
    ]

    /// Every path in `difference` whose first component is not a name the engine writes.
    static func unexplained(_ difference: Difference) -> [String] {
        (difference.created.union(difference.modified).union(difference.deleted))
            .filter { !engineWrittenNames.contains($0.split(separator: "/").first.map(String.init) ?? $0) }
            .sorted()
    }

    static func difference(from before: [String: Stamp], to after: [String: Stamp]) -> Difference {
        var d = Difference()
        d.created = Set(after.keys).subtracting(before.keys)
        d.deleted = Set(before.keys).subtracting(after.keys)
        d.modified = Set(before.keys).intersection(after.keys).filter { before[$0] != after[$0] }
        return d
    }
}

// MARK: - the live-budget signal

/// What a zero-cost `get_usage` read says about whether a model turn will actually reach a model.
///
/// The gate below must skip its one inference-dependent test when the shared account's window is spent, and it
/// must decide that from a *live* reading rather than from a date written into the source. A hard-coded cutoff
/// stops testing the moment it passes and says nothing when it does, which is precisely the silent-green
/// failure this gate exists to catch.
///
/// Shape taken from the recorded response in `Fixtures/zero-cost/frames.ndjson`: `rate_limits` carries one
/// object per window (`five_hour`, `seven_day`, a set of codenamed windows, most of them `null`) each with a
/// `utilization` percentage, plus a `limits` array of `{kind, percent, ...}` entries. Every window carrying a
/// number is read, not a chosen few, so a window this code has never heard of still counts.
struct LiveBudgetReading: Equatable {
    /// Window name → utilisation percentage, for every window at or above 100.
    var spent: [String: Double] = [:]
    /// Every window this reading actually looked at. Asserted against, so "checked nothing" cannot pass as "fine".
    var examined: Set<String> = []
    /// The engine's own statement that windows apply at all. False for an API-key account with no subscription window.
    var rateLimitsAvailable = false

    var isSpent: Bool { !spent.isEmpty }
    var reason: String {
        spent.sorted { $0.key < $1.key }.map { "\($0.key) at \(Int($0.value))%" }.joined(separator: ", ")
    }

    /// Reads the `response` object of a `get_usage` control response.
    static func read(getUsage response: JSONValue) -> LiveBudgetReading {
        var r = LiveBudgetReading()
        r.rateLimitsAvailable = response["rate_limits_available"]?.boolValue ?? false
        guard let limits = response["rate_limits"]?.objectValue else { return r }
        for (name, window) in limits where name != "limits" {
            guard let percent = number(window["utilization"]) else { continue }
            r.examined.insert(name)
            if percent >= 100 { r.spent[name] = percent }
        }
        for entry in limits["limits"]?.arrayValue ?? [] {
            guard let percent = number(entry["percent"]) else { continue }
            let name = "limits/" + (entry["kind"]?.stringValue ?? "?")
            r.examined.insert(name)
            if percent >= 100 { r.spent[name] = percent }
        }
        return r
    }

    /// The second live signal: a `rate_limit_event` frame the engine emits when it refuses a turn outright.
    ///
    /// `status` alone decides it. `overageStatus` does **not**: a live run on 2026-09-05 observed
    /// `{"status": "allowed", "overageStatus": "rejected", "overageDisabledReason": "org_level_disabled",
    /// "rateLimitType": "five_hour"}` on a turn that ran to completion — overage means buying credits past the
    /// plan, and an organisation that has switched that off refuses the overage, not the turn.
    /// `Fixtures/rate-limited-turn` records a genuinely refused turn as `status: "rejected"`.
    static func rejects(rateLimitInfo info: JSONValue) -> Bool {
        info["status"]?.stringValue == "rejected"
    }

    private static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .integer(let i)?: Double(i)
        case .number(let d)?: d
        default: nil
        }
    }
}

// MARK: - always-on tests for the two pieces of machinery above

/// The witness and the budget reader are the two things the live gate's verdicts rest on, so they are proven
/// here — on every run, with no CLI and no account — rather than being trusted because a live run went green.
final class LiveGateMachineryTests: XCTestCase {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-witness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: dir.appendingPathComponent(".hidden"))
        try Data("two".utf8).write(to: dir.appendingPathComponent("nested/file.txt"))
        return dir
    }

    func testWitnessReadsEveryRegularFileIncludingHiddenOnes() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(Set(ConfigHomeWitness(root: dir).read().keys), [".hidden", "nested/file.txt"])
    }

    func testWitnessSeesCreationModificationAndDeletionAndNothingWhenNothingHappens() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let witness = ConfigHomeWitness(root: dir)
        let before = witness.read()

        XCTAssertTrue(ConfigHomeWitness.difference(from: before, to: witness.read()).isEmpty,
                      "an untouched tree reported a difference")

        try Data("three".utf8).write(to: dir.appendingPathComponent("nested/new.txt"))
        XCTAssertEqual(ConfigHomeWitness.difference(from: before, to: witness.read()),
                       .init(created: ["nested/new.txt"], modified: [], deleted: []))

        // Same length, different bytes, and an explicitly moved timestamp: size alone would miss this, so the
        // witness has to be reading the modification date too.
        try Data("ONE".utf8).write(to: dir.appendingPathComponent(".hidden"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: dir.appendingPathComponent(".hidden").path)
        XCTAssertEqual(ConfigHomeWitness.difference(from: before, to: witness.read()),
                       .init(created: ["nested/new.txt"], modified: [".hidden"], deleted: []))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("nested/file.txt"))
        XCTAssertEqual(ConfigHomeWitness.difference(from: before, to: witness.read()),
                       .init(created: ["nested/new.txt"], modified: [".hidden"], deleted: ["nested/file.txt"]))
    }

    /// The recorded `get_usage` response of `Fixtures/zero-cost`, trimmed to the keys the reader looks at and
    /// with the codenamed windows kept exactly as recorded — the point is that a window nobody named still
    /// gets examined.
    private func recordedUsage(sevenDay: String = "55", fiveHour: String = "15", weeklyScoped: String = "60") -> JSONValue {
        let json = """
        {"session": {"total_cost_usd": 0},
         "subscription_type": "<subscription_type>",
         "rate_limits_available": true,
         "rate_limits": {
           "five_hour": {"utilization": \(fiveHour), "resets_at": "2026-09-04T14:39:59.985088+00:00"},
           "seven_day": {"utilization": \(sevenDay), "resets_at": "2026-09-08T02:59:59.985109+00:00"},
           "seven_day_opus": null, "tangelo": null, "iguana_necktie": null,
           "nimbus_quill": {"utilization": 0, "resets_at": null},
           "extra_usage": {"is_enabled": false, "utilization": null},
           "limits": [
             {"kind": "session", "group": "session", "percent": \(fiveHour), "severity": "normal"},
             {"kind": "weekly_all", "group": "weekly", "percent": \(sevenDay), "severity": "normal"},
             {"kind": "weekly_scoped", "group": "weekly", "percent": \(weeklyScoped), "severity": "normal"}
           ]}}
        """
        return try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// The set the reader examined must equal the set that should have been examined — every window carrying a
    /// number. `seven_day_opus`, `tangelo` and `iguana_necktie` are `null` and `extra_usage.utilization` is
    /// `null`, so those are absent by design and their absence is asserted, not assumed.
    func testBudgetReaderExaminesEveryNumberedWindowAndNoOther() {
        let r = LiveBudgetReading.read(getUsage: recordedUsage())
        XCTAssertEqual(r.examined, ["five_hour", "seven_day", "nimbus_quill",
                                    "limits/session", "limits/weekly_all", "limits/weekly_scoped"])
        XCTAssertTrue(r.rateLimitsAvailable)
        XCTAssertFalse(r.isSpent, "a window at 55% read as spent: \(r.reason)")
    }

    func testBudgetReaderReportsEachExhaustedWindowByName() {
        XCTAssertEqual(LiveBudgetReading.read(getUsage: recordedUsage(sevenDay: "100")).spent,
                       ["seven_day": 100, "limits/weekly_all": 100])
        XCTAssertEqual(LiveBudgetReading.read(getUsage: recordedUsage(fiveHour: "100")).spent,
                       ["five_hour": 100, "limits/session": 100])
        XCTAssertEqual(LiveBudgetReading.read(getUsage: recordedUsage(weeklyScoped: "100.0")).spent,
                       ["limits/weekly_scoped": 100])
    }

    /// A response the reader cannot understand must not read as "plenty left".
    func testBudgetReaderTreatsAnAbsentRateLimitsBlockAsNothingExamined() {
        let r = LiveBudgetReading.read(getUsage: .object(["rate_limits_available": .bool(false)]))
        XCTAssertEqual(r.examined, [])
        XCTAssertFalse(r.rateLimitsAvailable)
    }

    /// The allowlist: engine-written names pass, anything else is named. This is the assertion that stands in
    /// for policing the window in which afleet and the child run concurrently, so it has to be able to fail.
    func testTheAllowlistNamesPathsTheEngineIsNotKnownToWrite() {
        let engineOnly = ConfigHomeWitness.Difference(
            created: ["projects/-tmp-x/abc.jsonl", "session-env/x.json", "shell-snapshots/snapshot-zsh-1.sh"],
            modified: [".claude.json", "history.jsonl"],
            deleted: ["statsig/statsig.cached.evaluations.1"])
        XCTAssertEqual(ConfigHomeWitness.unexplained(engineOnly), [])

        let withAfleetWrites = ConfigHomeWitness.Difference(
            created: ["projects/-tmp-x/abc.jsonl", "afleet/channels.json"],
            modified: [".claude.json", "settings.local.json"],
            deleted: ["fleet-state.db"])
        XCTAssertEqual(ConfigHomeWitness.unexplained(withAfleetWrites),
                       ["afleet/channels.json", "fleet-state.db", "settings.local.json"])
    }

    // MARK: the guard driven through a real ClaudeProcess, against the stand-in

    /// Spawns the protocol stand-in — never the installed CLI — so the budget guard is exercised end to end
    /// without an account. Zero live cost: the stand-in reaches no model.
    private func standIn(scenario: String) throws -> (ClaudeProcess, URL) {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var variables = ProcessInfo.processInfo.environment
        variables["SCRIPTED_CLAUDE_SCENARIO"] = scenario
        let env = ResolvedEnvironment(variables: variables, shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
        let launch = LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: cwd, session: .new(SessionID()))
        return (ClaudeProcess(epoch: .first, launch: launch, environment: env,
                              configHome: ConfigHome(root: cwd.appendingPathComponent("cfg"), source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: cwd, tools: [SendUserFileTool()]),
                              diagnostics: NullDiagnostics(), capture: nil), cwd)
    }

    /// The primary signal, read the way the live gate reads it: a `get_usage` control request over the wire,
    /// decoded, handed to the reader. Both verdicts, so a reader that never reports "spent" fails.
    func testTheBudgetReaderRunsOverTheWireAndReportsBothVerdicts() async throws {
        for (percentage, expected) in [("11", [:] as [String: Double]),
                                       ("100", ["seven_day": 100.0, "limits/weekly_all": 100.0])] {
            let (process, cwd) = try standIn(scenario: "usage:\(percentage)")
            defer { try? FileManager.default.removeItem(at: cwd) }
            _ = try await process.spawn()
            let reading = LiveBudgetReading.read(getUsage: try await process.request(GetUsage(), timeout: .seconds(10)))
            await process.terminate()
            XCTAssertTrue(reading.rateLimitsAvailable)
            XCTAssertEqual(reading.examined, ["five_hour", "seven_day", "nimbus_quill", "limits/session", "limits/weekly_all"],
                           "the reader examined a different set of windows over the wire than it does in memory")
            XCTAssertEqual(reading.spent, expected, "seven_day at \(percentage)% read as \(reading.spent)")
        }
    }

    /// The secondary signal, likewise: a `rate_limit_event` frame decoded off a real stream and handed to
    /// `rejects(rateLimitInfo:)`. Both shapes the corpus carries, so the reading that cost a turn — an allowed
    /// turn whose organisation has overage switched off — is caught here rather than live.
    func testTheRateLimitEventReachesTheGuardThroughTheTransport() async throws {
        for (scenario, refuses) in [("rate_limit:allowed", false), ("rate_limit:rejected", true)] {
            let (process, cwd) = try standIn(scenario: scenario)
            defer { try? FileManager.default.removeItem(at: cwd) }
            let collector = LiveEventLog()
            Task { for await event in process.events { await collector.append(event) } }
            _ = try await process.spawn()
            _ = try await process.send(UserInput(text: "go"))
            let events = await collector.wait(upTo: .seconds(10)) { events in
                events.contains { if case .frame(.result, _) = $0 { return true }; return false }
            }
            await process.terminate()

            let infos = events.compactMap { if case .frame(.rateLimitEvent(let e), _) = $0 { return e.rateLimitInfo }; return nil }
            XCTAssertEqual(infos.count, 1, "\(scenario): expected one rate_limit_event, saw \(infos.count)")
            let info = try XCTUnwrap(infos.first)
            XCTAssertEqual(info["overageStatus"]?.stringValue, "rejected",
                           "\(scenario): both shapes carry overageStatus rejected; that is the point of the pair")
            XCTAssertEqual(LiveBudgetReading.rejects(rateLimitInfo: info), refuses, "\(scenario): \(info)")
        }
    }

    /// Both real shapes: the refusal recorded in `Fixtures/rate-limited-turn`, and the allowed turn observed
    /// live on 2026-09-05 whose `overageStatus` is `rejected` because the organisation disabled overage.
    /// Reading the second as a refusal is what made a live run throw away a completed turn's evidence.
    func testRateLimitEventRejectionIsRecognisedAndOverageStatusIsNot() {
        let refusedTurn = JSONValue.object(["status": .string("rejected"), "rateLimitType": .string("seven_day"),
                                            "overageStatus": .string("rejected"),
                                            "overageDisabledReason": .string("out_of_credits")])
        let allowedTurnWithOverageOff = JSONValue.object(["status": .string("allowed"), "rateLimitType": .string("five_hour"),
                                                          "overageStatus": .string("rejected"),
                                                          "overageDisabledReason": .string("org_level_disabled")])
        let plainAllowed = JSONValue.object(["status": .string("allowed"), "rateLimitType": .string("seven_day")])
        XCTAssertTrue(LiveBudgetReading.rejects(rateLimitInfo: refusedTurn))
        XCTAssertFalse(LiveBudgetReading.rejects(rateLimitInfo: allowedTurnWithOverageOff),
                       "overageStatus is about buying credits past the plan, not about whether the turn ran")
        XCTAssertFalse(LiveBudgetReading.rejects(rateLimitInfo: plainAllowed))
    }
}

// MARK: - G3

/// A live precondition that could not be met, reported as a failure rather than a skip.
struct LiveGateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Collects everything a live process emits so a test can wait on a predicate rather than shaping a task group
/// around one event.
actor LiveEventLog {
    private(set) var events: [WireEvent] = []
    func append(_ e: WireEvent) { events.append(e) }
    /// Returns as soon as `predicate` holds, or at the deadline; the caller inspects what was collected either way.
    func wait(upTo deadline: Duration, until predicate: @Sendable ([WireEvent]) -> Bool) async -> [WireEvent] {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if predicate(events) { return events }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return events
    }
}

/// Runs the real shell but adds variables (ZDOTDIR) to its environment.
struct EnvironmentOverridingRunner: ProcessRunner {
    let extra: [String: String]
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        try await FoundationProcessRunner().run(executable, arguments: arguments, environment: environment.merging(extra) { $1 }, timeout: timeout)
    }
}

/// G3: the only place this package speaks to the installed `claude`.
///
/// The gate is two halves on purpose. Everything except one test is inference-free — a handshake, a version
/// check, an environment capture, a termination — and runs whenever the scratch config home is logged in.
/// The single turn-dependent test asks a model to call the host tool, and it is guarded by a live reading of
/// the account's usage windows rather than by a date.
///
/// Every test skips with a named reason when its precondition is absent, so a fresh checkout with no scratch
/// config home is green rather than red.
final class LiveCLITests: XCTestCase {
    static let scratchHome = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
    private var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["AFLEET_LIVE_CLI"] == "1" else {
            throw XCTSkip("set AFLEET_LIVE_CLI=1 to run against the installed CLI")
        }
    }

    /// Nothing here creates, edits or deletes anything under the scratch home; the check is a read.
    private func requireLoggedInScratchHome() throws {
        let markers = [".credentials.json", "credentials.json", ".claude.json"]
        guard markers.contains(where: { FileManager.default.fileExists(atPath: Self.scratchHome.appendingPathComponent($0).path) }) else {
            throw XCTSkip("scratch config home has no login; run: CLAUDE_CONFIG_DIR=\(Self.scratchHome.path) claude")
        }
    }

    private func resolvedBinary() async throws -> (ResolvedEnvironment, URL) {
        let env = await EnvironmentResolver().resolve(shell: loginShell)
        let binary = try XCTUnwrap(BinaryLocator.locate(in: env, override: nil), "claude not found on the login PATH")
        return (env, binary)
    }

    private func temporaryWorkingDirectory() throws -> URL {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("afleet live test\n".utf8).write(to: cwd.appendingPathComponent("hello.txt"))
        return cwd
    }

    // MARK: the inference-free half

    /// Polls `mcp_status` until the named server is connected, and fails with the last reading if it never is.
    /// Zero cost: `mcp_status` is a control request, not a turn.
    private func awaitMCPServer(named name: String, on process: ClaudeProcess, within deadline: Duration) async throws -> JSONValue {
        let start = ContinuousClock.now
        var last: JSONValue = .null
        while ContinuousClock.now - start < deadline {
            last = try await process.request(MCPStatus(), timeout: .seconds(30))
            if let server = last["mcpServers"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name }),
               server["status"]?.stringValue == "connected" {
                return server
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Thrown, not `XCTFail` followed by an `XCTSkip` to leave the function. `XCTFail` does not end a test,
        // so that pairing recorded a failure *and* a skip, and XCTest's summary line reported the skip — which
        // is the one distinction this gate exists to keep: a test that could not run must never look like a
        // test that passed.
        throw LiveGateFailure("the \(name) MCP server never reached connected within \(deadline); last mcp_status: \(last)")
    }

    /// The installed build is accepted and a fabricated older one is refused, both through the same gate.
    ///
    /// The installed version is asserted `>=` the baseline rather than equal to it: the baseline names the
    /// version the protocol evidence was recorded against, and patch releases land between recordings.
    func testVersionGateAcceptsTheInstalledBuildAndRefusesAFabricatedOlderOne() async throws {
        let (resolvedEnv, binary) = try await resolvedBinary()

        let calls = ScriptedRunner.Recorder()
        let real = VersionGate(runner: RecordingPassThroughRunner(inner: FoundationProcessRunner(), calls: calls))
        guard case .accepted(let installed) = await real.check(binary: binary, environment: resolvedEnv) else {
            return XCTFail("the installed claude was refused by VersionGate")
        }
        // Without this the verdict could have come from a runner that was never asked anything.
        XCTAssertEqual(calls.invocations, [["--version"]])
        XCTAssertGreaterThanOrEqual(installed, ProtocolBaseline.baseline,
                                    "installed \(installed) is older than the protocol baseline \(ProtocolBaseline.baseline)")

        // Derived from the baseline, so it cannot rot into a version that is no longer below it.
        let base = ProtocolBaseline.baseline
        XCTAssertGreaterThan(base.patch, 0, "the fabricated-older string below is derived by decrementing the patch")
        let older = "\(base.major).\(base.minor).\(base.patch - 1) (Claude Code)"
        guard case .tooOld(let reported, let against) = await gate(reporting: older).check(binary: binary, environment: resolvedEnv) else {
            return XCTFail("VersionGate accepted a fabricated \(older)")
        }
        XCTAssertEqual(reported, SemanticVersion(major: base.major, minor: base.minor, patch: base.patch - 1))
        XCTAssertEqual(against, base)

        guard case .accepted = await gate(reporting: "\(base.major + 1).0.0 (Claude Code)").check(binary: binary, environment: resolvedEnv) else {
            return XCTFail("VersionGate refused a fabricated newer build")
        }
    }

    private func gate(reporting output: String) -> VersionGate {
        VersionGate(runner: ScriptedRunner(outputs: [.init(stdout: Data(output.utf8), stderr: Data(), exitCode: 0, timedOut: false)],
                                           calls: .init()))
    }

    /// The login shell's PATH really is captured, and a `CLAUDE_CONFIG_DIR` exported by a shell profile really
    /// does become `ConfigHome.root` with `source == .environment`.
    ///
    /// A `ZDOTDIR` with its own `.zshrc` stands in for the user's file so the test never edits `~/.zshrc`.
    /// `/tmp/afleet-live-cfg` is a name, never a directory: `ConfigHome.derive` is a pure function over the
    /// captured variables and nothing here creates it.
    func testEnvironmentResolverReturnsTheLoginPathAndHonoursConfigDirFromAShellProfile() async throws {
        let real = await EnvironmentResolver().resolve(shell: loginShell)
        XCTAssertNotEqual(real.mode, .processFallback, "login shell capture failed; check the rc file for prompts that block -i")
        XCTAssertTrue(real.path.contains { $0.hasSuffix("/bin") }, "captured PATH has no bin directory: \(real.path)")
        // Otherwise the assertion below could pass on the outer environment's value rather than on the one the
        // stand-in profile exports.
        XCTAssertNotEqual(real.variables["CLAUDE_CONFIG_DIR"], "/tmp/afleet-live-cfg")

        let zdot = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-zdot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zdot) }
        try Data("export CLAUDE_CONFIG_DIR=/tmp/afleet-live-cfg\n".utf8).write(to: zdot.appendingPathComponent(".zshrc"))

        let captured = await EnvironmentResolver(runner: EnvironmentOverridingRunner(extra: ["ZDOTDIR": zdot.path])).resolve(shell: "/bin/zsh")
        XCTAssertNotEqual(captured.mode, .processFallback, "the stand-in profile's capture fell through the ladder")
        let home = ConfigHome.derive(from: captured)
        XCTAssertEqual(home.root.path, "/tmp/afleet-live-cfg")
        XCTAssertEqual(home.source, .environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/afleet-live-cfg"), "derive must not create the directory it names")
    }

    /// Spawn, handshake, the host tool as the engine reports it, `end_session`, and the proof that the test
    /// wrote nothing under the scratch config home. No prompt is sent, so this reaches no model and costs
    /// nothing beyond the process itself.
    func testHandshakeUnderTheScratchConfigHomeExposesTheHostToolAndTheTestWritesNothing() async throws {
        try requireLoggedInScratchHome()
        let witness = ConfigHomeWitness(root: Self.scratchHome)

        // Taken before this test does anything else. Everything the test itself does happens between here and
        // the reading just before `spawn()`.
        let atStart = witness.read()
        XCTAssertFalse(atStart.isEmpty, "the witness read no files at all under \(Self.scratchHome.path)")
        XCTAssertTrue(atStart.keys.contains(".credentials.json"),
                      "the witness did not see the hidden credentials file, so its reading is not comparable")

        let (env, binary) = try await resolvedBinary()
        let cwd = try temporaryWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let beforeSpawn = witness.read()
        let bySetup = ConfigHomeWitness.difference(from: atStart, to: beforeSpawn)
        XCTAssertTrue(bySetup.isEmpty, "X9: the test's own setup touched the config home — \(bySetup.summary)")

        var launch = LaunchConfiguration(binary: binary, cwd: cwd, session: .new(SessionID()), model: "haiku",
                                         permissionMode: .default, settingSources: [], strictMCPConfig: true)
        launch.configHomeOverride = Self.scratchHome
        let diagnostics = TerminationLog()
        let process = ClaudeProcess(epoch: .first, launch: launch, environment: env,
                                    configHome: ConfigHome(root: Self.scratchHome, source: .environment),
                                    mcpServer: AfleetMCPServer(serverVersion: ProtocolBaseline.afleetVersion, cwd: cwd, tools: [SendUserFileTool()]),
                                    diagnostics: diagnostics, capture: nil)
        let log = LiveEventLog()
        Task { for await ev in process.events { await log.append(ev) } }

        _ = try await process.spawn()

        // The engine's namespaced tool list lives only in `system/init`, which no session emits before its first
        // turn. `mcp_status` is the zero-cost equivalent for the claim this inference-free half makes: the
        // in-process server is connected and offers exactly the host tool. Shape from `Fixtures/zero-cost`.
        //
        // Polled, not asked once. The engine drives its own JSON-RPC handshake against this server after
        // startup — `Fixtures/zero-cost` records `initialize`, `notifications/initialized` and `tools/list`
        // arriving around 0.9 s in — and now that `spawn()` returns on the initialize response alone, a single
        // immediate `mcp_status` beats it and comes back `{"mcpServers": []}`. That happened on a live run.
        let afleet = try await awaitMCPServer(named: "afleet", on: process, within: .seconds(30))
        XCTAssertEqual(afleet["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["send_user_file"],
                       "mcp_status listed a different tool set for the afleet server: \(afleet)")

        let binaryVersion = try await process.request(GetBinaryVersion(), timeout: .seconds(30))
        let reported = try XCTUnwrap(SemanticVersion(parsing: binaryVersion["version"]?.stringValue ?? ""),
                                     "get_binary_version returned \(binaryVersion)")
        XCTAssertGreaterThanOrEqual(reported, ProtocolBaseline.baseline)

        await process.terminate()
        // Waited for, not read at once: `terminate()` returns when the actor has observed the exit, but the
        // `.exited` event travels the channel to the collector afterwards. Reading immediately observed an
        // empty log on a live run.
        let events = await log.wait(upTo: .seconds(10)) { $0.contains { if case .exited = $0 { return true }; return false } }

        // end_session ended it: had it not, `terminate()` would have escalated and the steps would include SIGTERM.
        XCTAssertEqual(diagnostics.steps, ["end_session", "stdin_close_requested"], "termination escalated past end_session")
        let exits = events.compactMap { if case .exited(let s, _) = $0 { return s }; return nil }
        XCTAssertEqual(exits.count, 1, "expected exactly one exit event, saw \(exits)")
        XCTAssertEqual(exits.first?.isClean, true, "session did not exit cleanly: \(String(describing: exits.first))")

        let afterChild = witness.read()
        let byChild = ConfigHomeWitness.difference(from: beforeSpawn, to: afterChild)
        print("[G3] the spawned claude touched \(byChild.created.count) new, \(byChild.modified.count) modified, \(byChild.deleted.count) deleted paths under the scratch config home")
        XCTAssertFalse(byChild.isEmpty, "the child wrote nothing under the scratch config home, so CLAUDE_CONFIG_DIR may not have reached it")
        // The window from `spawn()` to the exit belongs to the child and to this test at the same time — they
        // run concurrently, so no reading can separate them by time. The allowlist separates them by shape
        // instead: everything that moved sits under a name the engine writes, and an afleet-side write would
        // not.
        XCTAssertEqual(ConfigHomeWitness.unexplained(byChild), [], "paths moved under names the engine is not known to write")

        // The tail the allowlist cannot cover: everything this test does after the child is gone. Nothing here
        // is concurrent with anything, so this window is attributable to afleet alone and must be empty.
        XCTAssertTrue(ConfigHomeWitness.difference(from: afterChild, to: witness.read()).isEmpty,
                      "X9: this test wrote under the config home after the child exited")
    }

    // MARK: the turn-dependent half

    /// The one test that needs a model. Guarded by a live `get_usage` reading taken on the session itself —
    /// zero cost, no inference — and by the `rate_limit_event` the engine emits if it refuses the turn anyway.
    /// There is no retry: the account is shared, so one turn is one chance and a failure is reported as a
    /// failure rather than spent again.
    func testAModelTurnInvokesSendUserFileWhenTheAccountHasBudget() async throws {
        try requireLoggedInScratchHome()
        let witness = ConfigHomeWitness(root: Self.scratchHome)
        let atStart = witness.read()
        XCTAssertFalse(atStart.isEmpty, "the witness read no files at all under \(Self.scratchHome.path)")

        let (env, binary) = try await resolvedBinary()
        let cwd = try temporaryWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let beforeSpawn = witness.read()
        let bySetup = ConfigHomeWitness.difference(from: atStart, to: beforeSpawn)
        XCTAssertTrue(bySetup.isEmpty, "X9: the test's own setup touched the config home — \(bySetup.summary)")

        let sessionID = SessionID()
        var launch = LaunchConfiguration(binary: binary, cwd: cwd, session: .new(sessionID), model: "haiku",
                                         permissionMode: .default, settingSources: [], strictMCPConfig: true)
        launch.configHomeOverride = Self.scratchHome
        let process = ClaudeProcess(epoch: .first, launch: launch, environment: env,
                                    configHome: ConfigHome(root: Self.scratchHome, source: .environment),
                                    mcpServer: AfleetMCPServer(serverVersion: ProtocolBaseline.afleetVersion, cwd: cwd, tools: [SendUserFileTool()]),
                                    diagnostics: NullDiagnostics(), capture: nil)
        let log = LiveEventLog()
        let permissionsAsked = ToolNameLog()
        // `InboundPolicy` surfaces `can_use_tool` rather than answering it, so a host that does not answer
        // leaves the turn parked forever — `Fixtures/send-user-file` records one such prompt for this very
        // tool. Everything is allowed rather than only the host tool: a denial would derail the one turn this
        // test is allowed to spend, and what the model reached for is recorded and asserted on below instead.
        Task { [permissionsAsked] in
            for await ev in process.events {
                await log.append(ev)
                guard case .request(let request) = ev, case .canUseTool(let ask) = request.payload else { continue }
                permissionsAsked.add(ask.toolName)
                try? await process.answer(request.id, .permission(.allow(updatedInput: ask.input, updatedPermissions: nil, classification: nil)))
            }
        }

        _ = try await process.spawn()
        // Nothing asserts the tool list here: the handshake does not carry one. `system/init` opens the turn,
        // and it is read off the event stream below — which is also the amended G3 acceptance text.
        //
        // The server must be connected before the prompt goes out, or the turn is spent on a session with no
        // host tool to call. This is a wait, not an assertion about the engine's speed.
        _ = try await awaitMCPServer(named: "afleet", on: process, within: .seconds(30))

        let usage = LiveBudgetReading.read(getUsage: try await process.request(GetUsage(), timeout: .seconds(30)))
        guard usage.rateLimitsAvailable, !usage.examined.isEmpty else {
            await process.terminate()
            throw XCTSkip("get_usage reported no usage windows (rate_limits_available=\(usage.rateLimitsAvailable), examined=\(usage.examined.sorted())); refusing to spend a turn blind")
        }
        if usage.isSpent {
            await process.terminate()
            throw XCTSkip("live signal: the account's usage window is spent — \(usage.reason)")
        }

        _ = try await process.send(UserInput(text: """
            Call the mcp__afleet__send_user_file tool exactly once with files ["hello.txt"] and status "normal", \
            then reply with the single word done.
            """))

        // One turn, one chance. The wait ends on the result frame or on the exit, whichever comes first.
        let events = await log.wait(upTo: .seconds(180)) { events in
            events.contains { if case .frame(.result, _) = $0 { return true }; if case .exited = $0 { return true }; return false }
        }
        await process.terminate()

        // Read before anything is asserted. A genuinely refused turn is a budget outcome, not a defect, and a
        // test that asserts first and skips second records both — the failure the summary shows and the skip it
        // reports are then in disagreement about what happened.
        let rejection = events.compactMap { event -> JSONValue? in
            guard case .frame(.rateLimitEvent(let e), _) = event, LiveBudgetReading.rejects(rateLimitInfo: e.rateLimitInfo) else { return nil }
            return e.rateLimitInfo
        }.first
        if let rejection {
            throw XCTSkip("live signal: the engine rejected the turn — rate_limit_event \(rejection)")
        }

        // G3, amended: the first turn's system/init lists the host tool, observed on the event stream.
        // One, for *this* launch: one prompt, no subagent, no session relocation. `system/init` is not
        // one-per-turn in general — `nested-depth-2` records three against one inbound user frame,
        // `session-mirror-relocation` five against four, `explore-depth-1` and `background-shell` two against
        // one. Subagents and relocation each add their own. Read the count as narrow, not as the rule.
        let inits = events.compactMap { if case .frame(.system(.initialize(let i)), _) = $0 { return i }; return nil }
        XCTAssertEqual(inits.count, 1, "expected exactly one system/init for this one-prompt, no-subagent turn, saw \(inits.count)")
        if let systemInit = inits.first {
            XCTAssertTrue(systemInit.tools.contains("mcp__afleet__send_user_file"),
                          "system/init.tools does not list the host tool: \(systemInit.tools)")
            XCTAssertEqual(systemInit.sessionID, sessionID.description)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(SemanticVersion(parsing: systemInit.claudeCodeVersion)), ProtocolBaseline.baseline)
        }

        print("[G3] the turn asked permission for \(permissionsAsked.names.sorted())")
        XCTAssertTrue(permissionsAsked.names.contains("mcp__afleet__send_user_file"),
                      "the model never asked to use the host tool; it asked for \(permissionsAsked.names.sorted())")

        let invocations = events.compactMap { if case .hostToolInvoked(let i, _) = $0 { return i }; return nil }
        XCTAssertEqual(invocations.count, 1, "expected exactly one host tool invocation, saw \(invocations)")
        guard case .sentFile(let paths, _, let status, _) = try XCTUnwrap(invocations.first) else {
            return XCTFail("host tool invocation was not a sentFile: \(invocations)")
        }
        XCTAssertEqual(paths.map(\.lastPathComponent), ["hello.txt"])
        XCTAssertEqual(status, "normal")

        let results = events.compactMap { if case .frame(.result(let r), _) = $0 { return r }; return nil }
        XCTAssertEqual(results.count, 1, "expected exactly one result frame, saw \(results.count)")
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.isError, "the turn ended with an error result: \(String(describing: result.result))")
        XCTAssertGreaterThan(result.numTurns, 0)

        // The transcript the engine wrote proves the override reached the child: this session's id, under the
        // scratch home, in a tree the test never touched.
        let afterChild = witness.read()
        let byChild = ConfigHomeWitness.difference(from: beforeSpawn, to: afterChild)
        let transcripts = byChild.created.filter { $0.hasPrefix("projects/") && $0.hasSuffix("/\(sessionID).jsonl") }
        XCTAssertEqual(transcripts.count, 1, "expected one transcript for session \(sessionID) under projects/, created: \(byChild.created.sorted())")
        XCTAssertEqual(ConfigHomeWitness.unexplained(byChild), [], "paths moved under names the engine is not known to write")
        XCTAssertTrue(ConfigHomeWitness.difference(from: afterChild, to: witness.read()).isEmpty,
                      "X9: this test wrote under the config home after the child exited")
    }
}

/// The tool names the engine asked permission for, in a box the event-consuming task can write to.
final class ToolNameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String> = []
    var names: Set<String> { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ name: String) { lock.lock(); stored.insert(name); lock.unlock() }
}

/// Wraps a real runner so a test can assert the gate actually invoked it, and with what.
struct RecordingPassThroughRunner: ProcessRunner {
    let inner: any ProcessRunner
    let calls: ScriptedRunner.Recorder
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        calls.add(arguments, environment: environment)
        return try await inner.run(executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}

/// Keeps just the termination escalation steps, so a test can assert `end_session` was enough.
/// Synchronous under a lock rather than an actor: `record` is not async, and a step recorded through a detached
/// task could still be in flight when the assertion reads the list.
final class TerminationLog: DiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var steps: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ event: DiagnosticEvent) {
        guard case .terminateEscalated(let step, _) = event else { return }
        lock.lock(); recorded.append(step); lock.unlock()
    }
}
