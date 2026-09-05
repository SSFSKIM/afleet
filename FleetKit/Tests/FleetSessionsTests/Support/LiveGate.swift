import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

// MARK: - the gate's preconditions

/// G5's entry conditions, in one place: the two environment flags, the scratch config home, and the reason each
/// absence is reported with. Every live scenario begins here, so a checkout with no scratch home is green rather
/// than red.
enum LiveGate {

    /// The one config home G5 runs under. Read by the witness and handed to every child; **never written** by this
    /// process (parent X9). The spawned `claude` writes here and that is what the allowlist is about.
    static let scratchHome = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")

    static func skipUnlessLive() throws {
        guard ProcessInfo.processInfo.environment["AFLEET_LIVE_CLI"] == "1" else {
            throw XCTSkip("set AFLEET_LIVE_CLI=1 to run against the installed CLI")
        }
        let markers = [".credentials.json", "credentials.json", ".claude.json"]
        guard markers.contains(where: {
            FileManager.default.fileExists(atPath: scratchHome.appending(path: $0).path(percentEncoded: false))
        }) else {
            throw XCTSkip("scratch config home has no login; run: CLAUDE_CONFIG_DIR=\(scratchHome.path) claude")
        }
    }

    static func skipUnlessTurns() throws {
        guard ProcessInfo.processInfo.environment["AFLEET_LIVE_CLI_TURNS"] == "1" else {
            throw XCTSkip("set AFLEET_LIVE_CLI_TURNS=1 to let this scenario spend model turns")
        }
    }

    /// The spec's allowlist (*The write allowlist, widened*), as the spec spells it: a directory carries its
    /// trailing slash and a file does not. `unexplained(_:)` matches on the first path component, so the trailing
    /// slash is documentation rather than syntax — the set is pinned by
    /// `testTheAllowlistNamesNothingTheEngineIsNotKnownToWrite` so an addition is deliberate.
    ///
    /// Two names are here that the spec's list does not carry: `daemon.lock` and `daemon.status.json`. The gate
    /// named them itself on its first live run — the background daemon writes both beside `daemon/` and
    /// `daemon.log` while it is up and removes them when it exits — which is precisely the outcome the allowlist
    /// exists to produce. They are engine writes of the same subsystem as the two names the spec already lists,
    /// so they are added here and the addition is flagged for the spec.
    static let engineWrittenPaths: Set<String> = [
        "sessions/", "projects/", "tasks/", "jobs/", "daemon/", "daemon.log", "daemon.lock", "daemon.status.json",
        "history.jsonl", ".claude.json",
        "shell-snapshots/", "session-env/", "file-history/", "statsig/", "cache/", "todos/", "debug/", "plugins/",
        "backups/", "plans/", "ide/", "logs/", "history/", ".credentials.json", ".last-cleanup",
        ".last-update-result.json", "settings.json",
    ]

    /// The allowlist's first components, which is what a reading is compared against.
    private static let allowedComponents: Set<String> = Set(engineWrittenPaths.map {
        $0.hasSuffix("/") ? String($0.dropLast()) : $0
    })

    /// Every relative path in `difference` whose first component matches no entry of the allowlist, sorted.
    ///
    /// An unexplained path fails the gate with its name, because either the allowlist or the never-write claim is
    /// wrong and both deserve a look.
    static func unexplained(_ difference: ConfigHomeWitness.Difference) -> [String] {
        difference.created.union(difference.modified).union(difference.deleted)
            .filter { !allowedComponents.contains($0.split(separator: "/").first.map(String.init) ?? $0) }
            .sorted()
    }
}

// MARK: - the config-home witness

/// Records what exists under a directory tree and reports what changed between two readings.
///
/// Copied in shape from `ClaudeWire/Tests/ClaudeWireTests/LiveCLITests.swift`, which is a test target and exports
/// nothing. The allowlist itself is *not* copied: C4's is the widened one above.
struct ConfigHomeWitness: Sendable {
    let root: URL

    struct Stamp: Hashable, Sendable { var size: Int; var modified: Date }

    struct Difference: Hashable, Sendable {
        var created: Set<String> = []
        var modified: Set<String> = []
        var deleted: Set<String> = []
        var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
        /// Counts only. A reading names relative paths when it fails; a routine line names how many moved.
        var summary: String { "created \(created.count), modified \(modified.count), deleted \(deleted.count)" }
    }

    /// Every regular file under `root`, keyed by its path relative to `root`. Hidden files are included and an
    /// unreadable subtree is skipped rather than aborting the walk, so any two readings are comparable.
    func read() -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                        errorHandler: { _, _ in true }) else { return out }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            out[relative] = Stamp(size: values.fileSize ?? 0,
                                  modified: values.contentModificationDate ?? .distantPast)
        }
        return out
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
/// Copied verbatim in shape from `ClaudeWire/Tests/ClaudeWireTests/LiveCLITests.swift` (`LiveBudgetReading`), which
/// is a test target and exports nothing. The reasoning behind reading *every* numbered window, and behind
/// `rejects(rateLimitInfo:)` looking at `status` alone, is recorded there.
struct LiveBudgetReading: Equatable, Sendable {
    /// Window name → utilisation percentage, for every window at or above 100.
    var spent: [String: Double] = [:]
    /// Every window this reading actually looked at, so "checked nothing" cannot pass as "fine".
    var examined: Set<String> = []
    /// The engine's own statement that windows apply at all.
    var rateLimitsAvailable = false
    /// `session.total_cost_usd` of the same answer: a `get_usage` read carries the session's cost too.
    var sessionCostUSD: Double = 0

    var isSpent: Bool { !spent.isEmpty }
    var reason: String {
        spent.sorted { $0.key < $1.key }.map { "\($0.key) at \(Int($0.value))%" }.joined(separator: ", ")
    }

    static func read(getUsage response: JSONValue) -> LiveBudgetReading {
        var r = LiveBudgetReading()
        r.rateLimitsAvailable = response["rate_limits_available"]?.boolValue ?? false
        r.sessionCostUSD = number(response["session"]?["total_cost_usd"]) ?? 0
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

    /// The engine refusing a turn outright. `status` alone decides it; `overageStatus` does not.
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

// MARK: - the launch ledger

/// Every `LaunchConfiguration` the suite's process factory sees, decorated with the cap and the model the running
/// scenario declared, and counted so a launch that slipped past the decoration can be named.
///
/// A `ProcessFactory` is a synchronous, non-isolated closure, so this cannot live inside the budget actor. It is a
/// single-owner box whose state is reachable only through the lock below.
final class LaunchLedger: @unchecked Sendable {   // `lock` serialises every field
    private let lock = NSLock()
    private var cap: Int?
    private var model: String?
    private var fresh: Set<SessionID> = []
    private var decorated = 0
    private var bypassed = 0

    /// What the scenario about to run wants on every launch the fleet makes for it. `model` nil leaves the launch's
    /// own (a zero-turn scenario never reaches a model, so it pins none).
    ///
    /// `freshSessions` are the session ids this scenario is opening for the first time. `Fleet` composes every
    /// launch as `--resume`, which is right for the channels it re-opens and wrong for a session that does not
    /// exist yet; the factory is the seam, so the rewrite to `--session-id` happens here rather than in the facade.
    func expect(maxTurns: Int, model: String?, freshSessions: Set<SessionID> = []) {
        lock.lock(); defer { lock.unlock() }
        cap = maxTurns; self.model = model; fresh = freshSessions
    }

    /// The scenario is over: nothing may launch until the next `expect`.
    func stopExpecting() {
        lock.lock(); defer { lock.unlock() }
        cap = nil; model = nil; fresh = []
    }

    /// Applies the running scenario's cap and model, or counts a bypass and changes nothing.
    func decorate(_ launch: LaunchConfiguration) -> LaunchConfiguration {
        lock.lock(); defer { lock.unlock() }
        guard let cap else { bypassed += 1; return launch }
        var out = launch
        out.maxTurns = cap
        if let model { out.model = model }
        if case .resume(let id, false) = out.session, fresh.contains(id) { out.session = .new(id) }
        decorated += 1
        return out
    }

    var counts: (decorated: Int, bypassed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (decorated, bypassed)
    }
}

// MARK: - the suite's one budget

/// The whole suite's model-turn and wall-time accounting, and the lock that makes G5's scenarios run one at a time.
///
/// A scenario runs inside `run(turns:wallTime:)`. The call reserves both ceilings **synchronously**, in its first
/// slice on this actor and before it waits for the lock, so two scenarios started together cannot both believe the
/// budget is free; a request that would cross a ceiling is an `XCTSkip` naming what is already spent. Callers are
/// then serialised through a continuation queue, so an `await` inside one body never lets another body start.
actor LiveBudget {

    /// The pre-turn usage read, injected so the budget's own unit test spends no process. Production passes the
    /// zero-cost `ClaudeProcess` probe in `LiveFleetTests`.
    typealias UsageProbe = @Sendable () async -> LiveBudgetReading?

    let turnCeiling: Int
    let wallCeiling: Duration
    private let probe: UsageProbe?

    /// Applied by the process factory; asserted by `assertEveryLaunchWasDecorated`.
    nonisolated let launches = LaunchLedger()

    private var turnsReserved = 0
    private var wallReserved = Duration.zero
    private var costUSD: Double = 0
    private var startedAt: ContinuousClock.Instant?
    private var probedOnce = false
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Every usage window read during the run, for the report.
    private(set) var readings: [LiveBudgetReading] = []

    init(turnCeiling: Int = 4, wallCeiling: Duration = .seconds(600), probe: UsageProbe? = nil) {
        self.turnCeiling = turnCeiling; self.wallCeiling = wallCeiling; self.probe = probe
    }

    // MARK: running a scenario

    /// `body` runs in the caller's isolation: `enter` and `leave` carry all of this actor's state, so the closure
    /// never has to be `Sendable` and a scenario can drive its own locals.
    @discardableResult
    nonisolated func run<T>(turns: Int, wallTime: Duration, _ body: () async throws -> T) async throws -> T {
        try await enter(turns: turns, wallTime: wallTime)
        do {
            let value = try await body()
            await leave()
            return value
        } catch {
            await leave()
            throw error
        }
    }

    private func enter(turns: Int, wallTime: Duration) async throws {
        // Reserved here, before any await: a second caller that arrives while this one is queued must already see
        // these turns as spent.
        guard turnsReserved + turns <= turnCeiling else {
            throw XCTSkip("live budget: \(turnsReserved) turns already spent of \(turnCeiling)")
        }
        guard wallReserved + wallTime <= wallCeiling else {
            throw XCTSkip("live budget: \(wallReserved) wall time already reserved of \(wallCeiling)")
        }
        turnsReserved += turns
        wallReserved += wallTime
        if startedAt == nil { startedAt = ContinuousClock.now }

        await acquire()

        // C2's reading, before the first scenario of the run and before every turn-spending one.
        guard let probe, turns > 0 || !probedOnce else { return }
        probedOnce = true
        guard let reading = await probe() else { return }
        readings.append(reading)
        guard turns > 0 else { return }
        if !reading.rateLimitsAvailable || reading.examined.isEmpty {
            refund(turns: turns, wallTime: wallTime)
            throw XCTSkip("""
                get_usage reported no usage windows (rate_limits_available=\(reading.rateLimitsAvailable), \
                examined=\(reading.examined.sorted())); refusing to spend a turn blind
                """)
        }
        if reading.isSpent {
            refund(turns: turns, wallTime: wallTime)
            throw XCTSkip("live signal: the account's usage window is spent — \(reading.reason)")
        }
    }

    private func refund(turns: Int, wallTime: Duration) {
        turnsReserved -= turns
        wallReserved -= wallTime
        release()
    }

    private func leave() { release() }

    private func acquire() async {
        guard occupied else { occupied = true; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty { occupied = false; return }
        waiters.removeFirst().resume()
    }

    /// How many turns are reserved right now. Read by the budget's own unit test, which has to know that two
    /// concurrent callers have both reserved before it issues the third.
    func reservedTurns() -> Int { turnsReserved }

    // MARK: launches

    /// The decoration every launch of this suite carries: an explicit `--max-turns`, and the haiku pin on a
    /// turn-spending scenario. `--max-turns` caps agentic turns inside one prompt rather than prompts, so the
    /// budget cannot derive it and each scenario states it.
    nonisolated func launch(_ config: LaunchConfiguration, maxTurns: Int, model: String? = nil,
                            freshSessions: Set<SessionID> = []) -> LaunchConfiguration {
        launches.expect(maxTurns: maxTurns, model: model, freshSessions: freshSessions)
        return launches.decorate(config)
    }

    /// No launch of this scenario slipped past the ledger.
    nonisolated func assertEveryLaunchWasDecorated(file: StaticString = #filePath, line: UInt = #line) {
        let counts = launches.counts
        XCTAssertEqual(counts.bypassed, 0,
                       "\(counts.bypassed) launch(es) reached the engine without an explicit --max-turns",
                       file: file, line: line)
    }

    // MARK: cost

    /// Every `result` frame a scenario's channels observed contributes its `total_cost_usd`.
    func add(cost: Double) { costUSD += cost }

    var totalCostUSD: Double { costUSD }

    var summary: String {
        let elapsed = startedAt.map { ContinuousClock.now - $0 } ?? .zero
        let counts = launches.counts
        return """
            budget.summary: turns used \(turnsReserved) of \(turnCeiling); \
            total_cost_usd \(String(format: "%.6f", costUSD)); \
            wall time \(elapsed) of \(wallCeiling); \
            launches decorated \(counts.decorated), bypassed \(counts.bypassed)
            """
    }

    /// A zero-turn launch emits no `result` frame, so its cost is witnessed rather than assumed.
    ///
    /// Two readings of the same fact, because they are two different answers. `get_session_cost` returns a rendered
    /// text block (`Fixtures/zero-cost` frame 16: `"Total cost:            $0.0000\n…"`), which is what the CLI puts
    /// on screen; the number the spec names, `session.total_cost_usd`, lives in `get_usage`'s answer (frame 26).
    /// Both are asked and both must read zero.
    @discardableResult
    nonisolated func witnessZeroCost(_ handle: any ProcessHandle, label: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws -> Double {
        let rendered = try await handle.request(GetSessionCost(), timeout: .seconds(30))
        let text = rendered["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("$0.0000"),
                      "\(label): get_session_cost did not read zero", file: file, line: line)
        let usage = LiveBudgetReading.read(getUsage: try await handle.request(GetUsage(), timeout: .seconds(30)))
        XCTAssertEqual(usage.sessionCostUSD, 0,
                       "\(label): session.total_cost_usd was not zero", file: file, line: line)
        print("[G5] \(label): get_session_cost reads zero, session.total_cost_usd = \(usage.sessionCostUSD)")
        return usage.sessionCostUSD
    }
}

// MARK: - small live helpers

/// Collects everything a channel emits so a scenario can wait on a predicate rather than shaping a task group
/// around one event. Its own actor so the collecting task and the asserting one never race.
actor LiveEventLog {
    private(set) var events: [WireEvent] = []
    func append(_ event: WireEvent) { events.append(event) }

    /// Returns as soon as `predicate` holds, or at the deadline; the caller inspects what was collected either way.
    @discardableResult
    func wait(upTo deadline: Duration, until predicate: @Sendable ([WireEvent]) -> Bool) async -> [WireEvent] {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if predicate(events) { return events }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return events
    }
}

/// The handles the live factory built, in spawn order.
final class LiveHandles: @unchecked Sendable {   // `lock` serialises `built`
    private let lock = NSLock()
    private var built: [LiveProcessHandle] = []
    func append(_ handle: LiveProcessHandle) { lock.lock(); built.append(handle); lock.unlock() }
    var all: [LiveProcessHandle] { lock.lock(); defer { lock.unlock() }; return built }
    var latest: LiveProcessHandle? { lock.lock(); defer { lock.unlock() }; return built.last }
}

/// The real directory runner, with every argv it was asked to run recorded so a scenario can assert that adoption
/// really ran `stop` and that *Send to background* really ran `--bg --resume`.
struct RecordingDirectoryRunner: DirectoryProcessRunner {
    let inner: FoundationDirectoryRunner
    let calls: Recorder

    final class Recorder: @unchecked Sendable {   // `lock` serialises `recorded`
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var invocations: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
        func add(_ arguments: [String]) { lock.lock(); recorded.append(arguments); lock.unlock() }
        /// Whether some recorded call began with exactly these tokens.
        func ran(_ prefix: [String]) -> Bool {
            invocations.contains { $0.count >= prefix.count && Array($0.prefix(prefix.count)) == prefix }
        }
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String],
             timeout: Duration) async throws -> ProcessOutput {
        calls.add(arguments)
        return try await inner.run(executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String], cwd: URL,
             timeout: Duration) async throws -> ProcessOutput {
        calls.add(arguments)
        return try await inner.run(executable, arguments: arguments, environment: environment, cwd: cwd,
                                   timeout: timeout)
    }
}

/// A live precondition that could not be met: a failure, never a skip.
struct LiveGateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
