import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// A `LifecycleAPI` the test drives: it answers `perform` with whatever the test set, records every
/// call, and publishes whatever the test pushes through `updates`.
///
/// It conforms to `LifecycleAPI` and **nothing else**. That is the point: `register` is `Fleet`'s
/// own API and is not a `LifecycleAPI` member, so this double is structurally incapable of recording
/// a registration and a test that needs one has to reach for `RegistrarDouble`.
///
/// Every member no test uses traps rather than returning a plausible value; a double that quietly
/// answers a question it was never designed to answer is how a test starts asserting against the
/// double instead of the code.
actor LifecycleDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation

    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    /// What the next `perform` does. A queue, so a test can stage a refusal followed by a success and
    /// see which one a surface that retried would have reached.
    private var outcomes: [Result<ChannelState, LifecycleError>] = []
    private var fallback: Result<ChannelState, LifecycleError>?
    private(set) var performed: [ChannelKey] = []
    /// Every action, with the channel it was performed on. `performed` records the key alone and
    /// predates Activity; answering has to be asserted on the *action*, because a decision row can
    /// disappear for the wrong reason and only the emitted answer says the engine was told.
    private(set) var actions: [(key: ChannelKey, action: LifecycleAction)] = []
    private var roster: [JobEntry] = []
    /// What `states()` and `state(of:)` answer. Empty by default, which is what the sidebar tests
    /// expect of a double that has never been told about a channel.
    private var table: [ChannelKey: ChannelState] = [:]
    /// The channels `events(of:)` will answer for, and every fan-out taken on each. A fresh stream
    /// per call and one `yield` to all of them, which is `Fleet.events(of:)`'s own contract.
    private var opened: Set<ChannelKey> = []
    private nonisolated let sink = EventSink()
    /// Every `events(of:)` call, in order, whatever it answered. Two consumers of one channel are
    /// legal and expected — the Activity pump takes one and `StreamIngestion` takes its own — so the
    /// only way to say which of them subscribed, and how often, is to count the calls.
    private(set) var eventSubscriptions: [ChannelKey] = []
    /// The spawn seam, wired where `Fleet` wires it: `perform(.open, on:)` builds a process through
    /// the factory. Nothing else in the lifecycle reaches a process, so a run in which this factory
    /// was never invoked is a run in which nothing was spawned.
    private var spawn: ProcessFactory?
    private var actionEvents: [WireEvent] = []
    private var performInterlude: (@Sendable () async -> Void)?
    func duringPerform(_ body: @escaping @Sendable () async -> Void) { performInterlude = body }
    /// Runs inside `states()`, once, before the sample is answered. `Fleet.states()` asks each
    /// supervisor in turn, so a state really can be published while the sample is being taken;
    /// this is the seam a test drives that interleaving through.
    private var statesInterlude: (@Sendable () async -> Void)?
    func duringStates(_ body: @escaping @Sendable () async -> Void) { statesInterlude = body }
    func emitDuringPerform(_ events: [WireEvent]) { actionEvents = events }

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Driving it

    func stage(_ outcome: Result<ChannelState, LifecycleError>) { outcomes.append(outcome) }
    /// The answer every `perform` gets once the staged queue is empty.
    func always(_ outcome: Result<ChannelState, LifecycleError>) { fallback = outcome }
    func setJobs(_ jobs: [JobEntry]) { roster = jobs }
    /// Installs the spawn seam. A test that asserts nothing spawned installs one and asserts it was
    /// never called.
    func setSpawn(_ factory: @escaping ProcessFactory) { spawn = factory }
    nonisolated func emit(_ state: ChannelState) { continuation.yield(state) }
    /// Publishes a roster the way `Fleet` publishes one: the full current list, on `jobUpdates`. It deliberately
    /// does **not** change what `jobs()` answers, so a surface that reads the stream and a surface that re-polls
    /// are told different things and a test can see which one the code under test believed.
    nonisolated func emitJobs(_ jobs: [JobEntry]) { jobContinuation.yield(jobs) }
    nonisolated func finish() { continuation.finish(); jobContinuation.finish() }

    var performCount: Int { performed.count }

    // MARK: - LifecycleAPI

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        performed.append(key)
        actions.append((key, action))
        await performInterlude?()
        // Like the supervisor: only current subscribers receive an event; no replay.
        for event in actionEvents { push(event, to: key) }
        actionEvents = []
        if case .open = action, let spawn {
            _ = spawn(.first, LaunchConfiguration(binary: URL(fileURLWithPath: "/invented/bin/claude"),
                                                  cwd: URL(fileURLWithPath: "/invented/project"),
                                                  session: .resume(key.session, fork: false)))
        }
        let outcome = outcomes.isEmpty ? fallback : outcomes.removeFirst()
        guard let outcome else { unreachable("perform with no staged outcome") }
        let state = try outcome.get()
        // The transition really happened as far as this double is concerned: a caller that answers
        // a decision and then asks what the channel looks like must not be told the old answer.
        table[state.key] = state
        return state
    }

    /// How many times `jobs()` was answered. The Background list is supposed to take one snapshot and then listen,
    /// so the count is the property: a second call means a surface went back to the CLI for something the stream
    /// had already told it.
    private(set) var jobsCalls = 0

    func jobs() async -> [JobEntry] {
        jobsCalls += 1
        return roster
    }

    func states() async -> [ChannelState] {
        let interlude = statesInterlude
        statesInterlude = nil
        await interlude?()
        return Array(table.values)
    }
    func state(of key: ChannelKey) async -> ChannelState? { table[key] }

    // MARK: - Driving the Activity surface

    /// Sets what `states()` and `state(of:)` answer, and publishes each one on `updates` so a model
    /// that listens rather than polls is fed the same way production feeds it.
    func setStates(_ states: [ChannelState]) {
        for state in states { table[state.key] = state }
    }

    /// Declares that this fleet owns a supervisor for the channel, so `events(of:)` answers with a
    /// stream rather than nil.
    func openEvents(of key: ChannelKey) { opened.insert(key) }

    /// How many fan-outs are live on one channel. Two is the shape the tap contract asks for: the
    /// Activity pump's and `StreamIngestion`'s.
    func fanOutCount(of key: ChannelKey) -> Int { sink.count(of: key) }

    func push(_ event: WireEvent, to key: ChannelKey) { sink.push(event, to: key) }

    /// The same enqueue without entering the actor.
    ///
    /// A test that has to leave frames *queued* — buffered on the stream and not yet folded by the
    /// consumer — cannot afford the suspension `await push(_:to:)` costs: the main actor is free
    /// while that call is in flight and the pump's own task takes it. This one is synchronous, so
    /// nothing runs between the enqueue and the next line of the test.
    nonisolated func enqueue(_ event: WireEvent, to key: ChannelKey) { sink.push(event, to: key) }

    func finishEvents(of key: ChannelKey) { sink.finish(key) }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID { unreachable("sendPrompt") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey, ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    /// What the next `attach` or `logs` answers, in order, and what each verb was asked for.
    ///
    /// One queue for both verbs, because what a caller does with the answer is the same in both
    /// cases and the *calls* are recorded separately: a surface that ran *Logs* through `attach` is
    /// caught by `attachedJobs` and `loggedJobs` disagreeing, not by which request came back.
    private var paneRequests: [Result<PaneRequest, LifecycleError>] = []
    private(set) var attachedJobs: [JobShort] = []
    private(set) var loggedJobs: [JobShort] = []

    func stagePane(_ outcome: Result<PaneRequest, LifecycleError>) { paneRequests.append(outcome) }

    func attach(_ job: JobShort) async throws -> PaneRequest {
        attachedJobs.append(job)
        return try takePane()
    }

    func logs(_ job: JobShort) async throws -> PaneRequest {
        loggedJobs.append(job)
        return try takePane()
    }

    /// Nothing staged is a refusal rather than a trap: a test that expects a verb never to be
    /// reached asserts on the two call lists, and a surface that reached it anyway must not end the
    /// suite before those assertions run.
    private func takePane() throws -> PaneRequest {
        guard !paneRequests.isEmpty else { throw LifecycleError.notOwned }
        return try paneRequests.removeFirst().get()
    }
    /// Every `PaneExit` the app forwarded, in order.
    ///
    /// Recorded rather than dropped because G4d's discriminating clause is the `request.id`: C4
    /// accepts an exit only when its id is the one it is waiting on, so a host that minted a fresh
    /// request would have every exit discarded and no other assertion would notice.
    private(set) var paneExits: [PaneExit] = []
    func paneExited(_ exit: PaneExit) async { paneExits.append(exit) }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { unreachable("liveTaskIDs") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }
    /// A fresh fan-out for a channel `openEvents(of:)` opened, and nil otherwise — which is
    /// `Fleet`'s own contract: nil for a key the fleet owns no supervisor for, and a new stream on
    /// every call for one it does.
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? {
        eventSubscriptions.append(key)
        guard opened.contains(key) else { return nil }
        let (stream, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        sink.add(continuation, for: key)
        return stream
    }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("LifecycleDouble.\(member) is not part of the fleet browser's surface")
    }
}

/// The event continuations `LifecycleDouble` hands out, held outside the actor.
///
/// `@unchecked Sendable` is sound because the one mutable field is read and written only between
/// `lock.lock()` and `lock.unlock()` of this instance's private `NSLock`; an
/// `AsyncStream.Continuation` is itself thread-safe and is yielded to outside the lock.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [ChannelKey: [AsyncStream<WireEvent>.Continuation]] = [:]

    func add(_ continuation: AsyncStream<WireEvent>.Continuation, for key: ChannelKey) {
        lock.lock(); defer { lock.unlock() }
        streams[key, default: []].append(continuation)
    }

    func count(of key: ChannelKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        return streams[key]?.count ?? 0
    }

    func push(_ event: WireEvent, to key: ChannelKey) {
        lock.lock()
        let continuations = streams[key] ?? []
        lock.unlock()
        for continuation in continuations { continuation.yield(event) }
    }

    func finish(_ key: ChannelKey) {
        lock.lock()
        let continuations = streams.removeValue(forKey: key) ?? []
        lock.unlock()
        for continuation in continuations { continuation.finish() }
    }
}

/// Records every `Fleet.create(_:)` the app makes, and answers each with a key of its own.
///
/// This double exists for `RegistrarDouble`'s reason: `create` is not on `LifecycleAPI`, so a
/// lifecycle double cannot see a creation at all, and "*New channel* minted exactly one channel,
/// with the request the sheet described" is not a claim any other seam could carry. It mints real
/// `SessionID`s so a caller can select the key it was handed, and remembers each request so a test
/// can assert on the isolation flag and the worktree name without reading a launch line.
actor CreatorDouble: ChannelCreating {

    private(set) var requests: [ChannelCreation] = []
    private(set) var keys: [ChannelKey] = []
    private let configHome: URL
    /// The ids handed out, in order. Empty means a fresh `SessionID` per call.
    private var scripted: [SessionID]

    init(configHome: URL, minting: [SessionID] = []) {
        self.configHome = configHome
        self.scripted = minting
    }

    func create(_ request: ChannelCreation) async -> ChannelKey {
        requests.append(request)
        let session = scripted.isEmpty ? SessionID() : scripted.removeFirst()
        let key = ChannelKey(configHome: configHome, session: session)
        keys.append(key)
        return key
    }

    var count: Int { requests.count }
}

/// An `AppFleet` for the composition root, whose `updates` the test can push through. Used where the
/// launch needs a fleet and the *registration* is recorded somewhere else.
actor FleetDouble: AppFleet {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation

    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation
    private(set) var started = false
    private(set) var registrations: [ChannelKey] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async { started = true }
    func shutdown() async { continuation.finish(); jobContinuation.finish() }
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async { registrations.append(key) }
    func create(_ request: ChannelCreation) async -> ChannelKey { unreachable("create") }
    nonisolated func emit(_ state: ChannelState) { continuation.yield(state) }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func paneExited(_ exit: PaneExit) async {}
    func isDormantEligible(_ key: ChannelKey) async -> Bool { false }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { [] }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState { unreachable("perform") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID { unreachable("sendPrompt") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey, ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("FleetDouble.\(member) is not part of the composition root's surface")
    }
}

/// A coordinator that records the composition root stopping it.
///
/// An explicit sequential workspace replacement stops the previous coordinator's browser loop.
/// Concurrent `AppModel.launch()` callers instead share one in-flight task; *Check again* is
/// the narrower sequential retry from setup/upgrade, where no workspace was built.
@MainActor
final class StoppableCoordinatorDouble: WorkspaceCoordinating {
    private(set) var stops = 0
    init() {}
    func snapshotAvailable(_ snapshot: IndexSnapshot, origin: SnapshotOrigin) async {}
    func indexChanged(_ delta: IndexDelta) async {}
    func stop() { stops += 1 }
}

// MARK: - Values the sidebar tests build

enum SidebarFixtures {
    /// Invented throughout. No identifier here comes from any real home (§11).
    ///
    /// `nibble` is one hex digit, repeated to fill a v4 UUID, so `session("1")` reads as one
    /// recognisable session everywhere it appears. The precondition is not decoration: a
    /// non-hex character makes `SessionID.init` return nil, and the force-unwrap that used to be
    /// here turned a one-character typo in a test into a crash that took the whole bundle down and
    /// reported as "Failing tests" with no assertion and no line number.
    static func session(_ nibble: String) -> SessionID {
        precondition(nibble.count == 1 && nibble.first!.isHexDigit,
                     "a session fixture's nibble must be a single hex digit; got \(nibble.count) character(s)")
        let repeated = String(repeating: nibble, count: 12)
        let head = String(repeating: nibble, count: 8)
        let block = String(repeating: nibble, count: 4)
        let three = String(repeating: nibble, count: 3)
        return SessionID("\(head)-\(block)-4\(three)-8\(three)-\(repeated)")!
    }

    static func state(_ key: ChannelKey, origin: ChannelOrigin, at moment: Date = Date()) -> ChannelState {
        ChannelState(key: key,
                     origin: origin,
                     desired: .none,
                     observed: HolderSet(holders: [], observedAt: moment),
                     identity: .known(key.session),
                     lastActivity: moment)
    }

    static func entry(_ id: SessionID, configHome: URL, cwd: String?, mtime: Date,
                      title: String = "invented title", entrypoint: String? = nil,
                      isSidechain: Bool = false, teamName: String? = nil,
                      continuedIn: SessionID? = nil) -> IndexEntry {
        IndexEntry(sessionID: id,
                   path: configHome.appending(path: "projects/invented/\(id).jsonl"),
                   slug: "invented",
                   cwd: cwd,
                   title: title,
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   mtime: mtime,
                   size: 1,
                   entrypoint: entrypoint,
                   isSidechain: isSidechain,
                   teamName: teamName,
                   continuedIn: continuedIn)
    }

    static func snapshot(configHome: URL, entries: [IndexEntry], builtAt: Date = Date()) -> IndexSnapshot {
        IndexSnapshot(configHome: configHome, builtAt: builtAt,
                      entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.sessionID, $0) }))
    }
}


/// A `ProcessHandle` that exists only to be *not* returned.
///
/// A `ProcessFactory` has to answer with one, so a test that asserts no process was ever built
/// still needs a conformance to hand back. Every member traps: reaching one of them would mean the
/// factory really did produce a process, and the assertion the factory exists for has already
/// failed by then.
final class NeverSpawnedHandle: ProcessHandle {
    let epoch: ProcessEpoch = .first
    var events: any AsyncSequence<WireEvent, Never> & Sendable { AsyncStream<WireEvent> { $0.finish() } }
    var childProcessIdentifier: Int32 { get async { unreachable("childProcessIdentifier") } }
    var sessionID: SessionID? { get async { unreachable("sessionID") } }
    func spawn(handshakeTimeout: Duration) async throws -> Handshake { unreachable("spawn") }
    func send(_ input: UserInput, uuid: UUID) async throws { unreachable("send") }
    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response { unreachable("request") }
    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue { unreachable("requestRaw") }
    func answer(_ id: RequestID, _ answer: InboundAnswer) async throws { unreachable("answer") }
    func terminate() async -> TerminationReport { unreachable("terminate") }

    private func unreachable(_ member: String) -> Never {
        fatalError("NeverSpawnedHandle.\(member): a test that asserts nothing spawned built a process")
    }
}

/// Counts the spawns a `ProcessFactory` was asked for.
///
/// `@unchecked Sendable` is sound because the one mutable field is `count`, read and written only
/// inside `lock`, this instance's private `NSLock`. A `ProcessFactory` is a synchronous,
/// non-isolated closure, so the counter cannot live on an actor.
final class SpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return invocations }

    var factory: ProcessFactory {
        { [self] _, _ in
            lock.lock(); invocations += 1; lock.unlock()
            return NeverSpawnedHandle()
        }
    }
}
