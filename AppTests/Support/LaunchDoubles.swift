import Foundation
import XCTest
import ClaudeWire
import FleetKit
@testable import Afleet

/// Which seams a launch reached, in order. The whole point of `LaunchSequence` taking closures is
/// that a test can assert a call did **not** happen, so the log records names and never results.
///
/// `@unchecked Sendable` is sound here because the one mutable field is `names`, and every read and
/// every write of it happens between `lock.lock()` and `lock.unlock()` of this instance's private
/// `NSLock`. That lock is the serialising mechanism; the getter returns a copy.
final class SeamLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func note(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        names.append(name)
    }

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }

    func count(_ name: String) -> Int { entries.filter { $0 == name }.count }
    func reached(_ name: String) -> Bool { count(name) > 0 }
}

/// A fleet that records what it was told and spawns nothing.
///
/// Every `LifecycleAPI` member no test in this file calls traps rather than returning a plausible
/// value: a double that quietly answers a question it was never designed to answer is how a test
/// starts asserting against the double instead of the code.
actor StubFleet: AppFleet {
    nonisolated let updates: AsyncStream<ChannelState>
    private let continuation: AsyncStream<ChannelState>.Continuation
    private(set) var started = false
    private(set) var registrations: [ChannelKey] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async { started = true }
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async { registrations.append(key) }
    func shutdown() async { continuation.finish() }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { false }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func paneExited(_ exit: PaneExit) async {}
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws {}
    func declineProjectServers(_ names: [String], project: URL) async throws {}
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {}

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState { unreachable("perform") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey, ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("StubFleet.\(member) is not part of the composition root's surface")
    }
}

/// An index whose `build()` can be held open until the test lets it go.
///
/// The gate is an `AsyncStream` rather than a bare continuation so that a release issued before the
/// build reaches the gate is buffered rather than lost; the ordering test would otherwise deadlock
/// on its own scheduling.
actor StubIndex: IndexAccess {
    private let persisted: IndexSnapshot?
    private let built: IndexSnapshot
    private let blocks: Bool
    /// A real suspension inside `loadPersisted()`, standing in for the store read the production
    /// index does there.
    private let loadDelay: Duration
    private let gate: AsyncStream<Void>
    private nonisolated let gateContinuation: AsyncStream<Void>.Continuation
    private(set) var buildCount = 0
    private(set) var updated: [[URL]] = []
    private(set) var persistCount = 0
    private var delta: IndexDelta

    init(persisted: IndexSnapshot?, built: IndexSnapshot, blocks: Bool = false,
         loadDelay: Duration = .zero,
         delta: IndexDelta = IndexDelta(added: [], updated: [], removed: [], durationMs: 0)) {
        self.persisted = persisted
        self.built = built
        self.blocks = blocks
        self.loadDelay = loadDelay
        self.delta = delta
        (gate, gateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func loadPersisted() async throws -> IndexSnapshot? {
        if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
        return persisted
    }

    @discardableResult
    func build() async throws -> IndexSnapshot {
        buildCount += 1
        if blocks {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return built
    }

    func update(changed: [URL]) async -> IndexDelta {
        updated.append(changed)
        return delta
    }

    func persist() async throws { persistCount += 1 }
    func entry(_ id: SessionID) async -> IndexEntry? { built.entries[id] }
    var currentSnapshot: IndexSnapshot { built }

    /// Lets a blocked `build()` finish.
    nonisolated func releaseBuild() { gateContinuation.yield(()) }
}

/// A watcher the test feeds by hand.
///
/// `@unchecked Sendable` is sound here because the one mutable field is `starts`, read and written
/// only inside `lock`; the continuation is itself thread-safe.
final class StubWatcher: TranscriptWatching, @unchecked Sendable {
    let changes: AsyncStream<[URL]>
    private let continuation: AsyncStream<[URL]>.Continuation
    private let lock = NSLock()
    private var starts = 0

    init() {
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        starts += 1
    }

    func stop() { continuation.finish() }

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    func emit(_ paths: [URL]) { continuation.yield(paths) }
    func finish() { continuation.finish() }
}

/// The coordinator the composition root drives, recording each of the three points and signalling
/// each one as it arrives.
///
/// **Nothing here is polled.** An earlier version of these tests waited by re-reading the counts on
/// a ten-millisecond loop against a five-second budget, which makes the verdict depend on how much
/// of the machine the polling task got — a test that passes alone and fails on a loaded machine,
/// which is worse than a failing test because its failure reads as a product bug. The waits below
/// are fulfilled by the delivery itself, so on the passing path no wall clock is consulted at all.
/// The `timeout:` at each `fulfillment` call is a hang-guard three orders of magnitude above what
/// these tests take, there so a genuine regression is reported rather than hanging the suite.
@MainActor
final class RecordingCoordinator: WorkspaceCoordinating {
    private(set) var snapshots: [IndexSnapshot] = []
    private(set) var deltas: [IndexDelta] = []

    private var snapshotWaiters: [(needed: Int, expectation: XCTestExpectation)] = []
    private var deltaWaiters: [(needed: Int, expectation: XCTestExpectation)] = []

    init() {}

    private(set) var origins: [SnapshotOrigin] = []

    func snapshotAvailable(_ snapshot: IndexSnapshot, origin: SnapshotOrigin) async {
        snapshots.append(snapshot)
        origins.append(origin)
        Self.release(&snapshotWaiters, reached: snapshots.count)
    }

    func indexChanged(_ delta: IndexDelta) async {
        deltas.append(delta)
        Self.release(&deltaWaiters, reached: deltas.count)
    }

    /// Fulfilled the moment the `count`-th snapshot is handed over. Safe to create after the
    /// stimulus as well as before it: an already-satisfied count fulfils at once, so there is no
    /// ordering to lose.
    func expectSnapshots(_ count: Int) -> XCTestExpectation {
        Self.expect(count, in: &snapshotWaiters, have: snapshots.count, what: "snapshots")
    }

    /// Fulfilled the moment the `count`-th delta is handed over.
    func expectDeltas(_ count: Int) -> XCTestExpectation {
        Self.expect(count, in: &deltaWaiters, have: deltas.count, what: "deltas")
    }

    private static func expect(_ count: Int,
                               in waiters: inout [(needed: Int, expectation: XCTestExpectation)],
                               have: Int, what: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) \(what)")
        if have >= count {
            expectation.fulfill()
        } else {
            waiters.append((count, expectation))
        }
        return expectation
    }

    private static func release(_ waiters: inout [(needed: Int, expectation: XCTestExpectation)],
                                reached: Int) {
        for waiter in waiters where waiter.needed <= reached { waiter.expectation.fulfill() }
        waiters.removeAll { $0.needed <= reached }
    }
}

/// Batches a subscriber received, collected off whatever task read them, and signalled as they
/// arrive. Same reasoning as `RecordingCoordinator`: the delivery fulfils the wait, nothing polls.
actor BatchCollector {
    private(set) var batches: [[URL]] = []
    private var waiters: [(needed: Int, expectation: XCTestExpectation)] = []

    func append(_ batch: [URL]) {
        batches.append(batch)
        for waiter in waiters where waiter.needed <= batches.count { waiter.expectation.fulfill() }
        waiters.removeAll { $0.needed <= batches.count }
    }

    var count: Int { batches.count }

    /// Fulfilled the moment the `count`-th batch arrives.
    func expect(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) batches")
        if batches.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
        return expectation
    }
}

/// A `TimelineDiagnosticsSink` that forwards to another and signals the first `indexBuilt`.
///
/// The composition root issues the index build detached, so a test that reads what the build
/// reported has to wait for it. Waiting on this rather than re-reading the composer on a timer is
/// the same rule as everywhere else here: the thing that satisfies the wait is what ends it.
final class IndexBuildSignal: TimelineDiagnosticsSink, @unchecked Sendable {
    private let forward: any TimelineDiagnosticsSink
    let built = XCTestExpectation(description: "the index build reported")

    init(forwardingTo forward: any TimelineDiagnosticsSink) { self.forward = forward }

    func record(_ notice: TimelineNotice) {
        forward.record(notice)
        if case .indexBuilt = notice { built.fulfill() }
    }
}

/// The diagnostics composer a launch built, carried back out of the seam.
///
/// `@unchecked Sendable` is sound here because the one mutable field is written and read only
/// inside `lock`, this instance's private `NSLock`.
final class DiagnosticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: DiagnosticsComposer?

    init() {}

    func set(_ composer: DiagnosticsComposer) {
        lock.lock(); defer { lock.unlock() }
        storage = composer
    }

    var value: DiagnosticsComposer? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Shared helpers

enum LaunchFixtures {
    /// Invented throughout: no identifier here comes from any real home (parent §11).
    static let sessionA = SessionID("a1a1a1a1-1111-4111-8111-111111111111")!
    static let sessionB = SessionID("b2b2b2b2-2222-4222-8222-222222222222")!

    /// `ConfigHome.derive(from:)` re-makes the root with `URL(fileURLWithPath:)`, which stats the
    /// path and gives a directory the trailing slash a hand-built `appending(path:)` URL does not
    /// carry. A comparison has to go through the same call or it compares two spellings of one
    /// directory and fails on the slash.
    static func directoryURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path) }

    static func snapshot(configHome: URL, ids: [SessionID], builtAt: Date = Date()) -> IndexSnapshot {
        var entries: [SessionID: IndexEntry] = [:]
        for id in ids {
            entries[id] = IndexEntry(sessionID: id,
                                     path: configHome.appending(path: "projects/invented/\(id).jsonl"),
                                     slug: "invented",
                                     cwd: "/invented/project",
                                     title: "invented title",
                                     titleSource: .firstPrompt,
                                     preview: "invented preview",
                                     mtime: builtAt,
                                     size: 1)
        }
        return IndexSnapshot(configHome: configHome, builtAt: builtAt, entries: entries)
    }

    /// A resolved environment naming `configHome` through `CLAUDE_CONFIG_DIR`, so
    /// `ConfigHome.derive(from:)` reports `.environment`.
    static func environment(home: URL, configHome: URL, extra: [String: String] = [:]) -> ResolvedEnvironment {
        var variables = ["HOME": home.path,
                         "PATH": "/usr/bin:/bin",
                         "CLAUDE_CONFIG_DIR": configHome.path]
        for (key, value) in extra { variables[key] = value }
        return ResolvedEnvironment(variables: variables, shell: "/bin/zsh", capturedAt: Date(), mode: .login)
    }

    /// A minimal main transcript under `<configHome>/projects/<slug>/<sessionID>.jsonl`.
    /// Every byte is invented: no engine recording reaches this file (§11).
    @discardableResult
    static func transcript(in configHome: URL, slug: String, session: SessionID) throws -> URL {
        let directory = configHome.appending(path: "projects/\(slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = "00000000-0000-4000-8000-000000000001"
        let assistant = "00000000-0000-4000-8000-000000000002"
        let lines = [
            #"{"type":"user","sessionId":"\#(session)","uuid":"\#(user)","parentUuid":null,"isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"invented prompt"}}"#,
            #"{"type":"assistant","sessionId":"\#(session)","uuid":"\#(assistant)","parentUuid":"\#(user)","isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:01.000Z","message":{"id":"msg_invented","role":"assistant","content":[{"type":"text","text":"invented reply"}]}}"#,
            #"{"type":"last-prompt","sessionId":"\#(session)","leafUuid":"\#(user)","lastPrompt":"invented prompt"}"#,
        ]
        let file = directory.appending(path: "\(session).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    /// A recursive manifest of `root`: every path relative to it, with a directory's marker or a
    /// file's size and a stable digest of its bytes. Compared before and after a refusal, it is
    /// what proves the refusal wrote nothing (X9). Counts and digests rather than contents, so a
    /// failure message stays readable and carries no file's bytes.
    static func manifest(of root: URL) throws -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return []
        }
        // One directory has two spellings on macOS and which one the enumerator reports is not the
        // one the caller handed in: a temporary directory is `/var/folders/…` as
        // `FileManager.temporaryDirectory` gives it and as `resolvingSymlinksInPath()` returns it —
        // that call *removes* a leading `/private` rather than adding one — while the enumerator
        // reports `/private/var/folders/…`. Stripping only the first two spellings therefore
        // matched nothing at all and every line fell back to its absolute path, which left this
        // manifest's own guard clauses unable to fire. The `/private` spelling is the third.
        let spellings = Set([root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path])
        let prefixes = spellings.flatMap { [$0, "/private" + $0] }.sorted { $0.count > $1.count }
        var lines: [String] = []
        for case let url as URL in walk {
            let path = url.path
            let relative = prefixes.compactMap { path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil }.first ?? path
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                lines.append("d \(relative)")
            } else {
                let data = (try? Data(contentsOf: url)) ?? Data()
                lines.append("f \(relative) \(values.fileSize ?? -1) \(digest(data))")
            }
        }
        return lines.sorted()
    }

    /// FNV-1a, so the same bytes give the same short string in every process.
    private static func digest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The hang-guard every `fulfillment(of:timeout:)` in these tests uses.
    ///
    /// Not a threshold anything is expected to approach: these waits are fulfilled by the delivery
    /// they are waiting on, and the tests that use them run in hundredths of a second. Thirty
    /// seconds is there so a real regression — a batch that never arrives — is reported as a
    /// failure rather than hanging the suite until XCTest's own ten-minute limit.
    static let hangGuard: TimeInterval = 30

    /// The retired shape, kept for the three call sites in `ChannelRegistrarTests` that wait on a
    /// `@Observable` model with no signal to hook.
    ///
    /// Polling makes the verdict depend on how much of the machine the polling task got, which is
    /// what makes a test pass alone and fail on a loaded one. Every wait in `LaunchSequenceTests`
    /// and `SettingsReadoutTests` is now fulfilled by the delivery itself instead. These three
    /// cannot be until the thing they watch — Task 4's `FleetBrowserModel` — offers a signal, so
    /// the budget here matches the hang-guard rather than the five seconds it used to be.
    @MainActor
    static func wait(upTo timeout: Duration = .seconds(30), for condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// The same, for a condition that has to reach an actor.
    static func waitAsync(upTo timeout: Duration = .seconds(30), for condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

}
