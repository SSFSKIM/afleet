import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The `LifecycleAPI` C6.2's surfaces are driven through: it records **every** call in one ordered
/// log, answers what the test staged, and traps on everything outside the composer's and header's
/// surface.
///
/// A second double rather than an extension of C5's `LifecycleDouble`, and deliberately so. That one
/// traps on `route`, `send`, `run` and `openInTerminal` — the four members this leaf exists to
/// exercise — because C5's convention is that a double answers its own surface and nothing else, so
/// a test cannot drift into asserting against the double. Widening C5's would erase that signal for
/// the fleet browser's tests and would put three C6 leaves into one shared file.
///
/// **Ordering is the point.** Several of this leaf's gates are about sequence rather than presence:
/// the bypass gate must write, then restart, then set the mode, and a concurrent issue is a failure;
/// the edit path must reach `fork` only after a refused rewind and must never reach `rewind_files`.
/// A double that recorded per-member sets could not fail any of those, so every call appends to one
/// `calls` array and the assertions read it in order.
actor ComposerLifecycleDouble: LifecycleAPI {

    /// One recorded call. Values, never the objects: `StrategyUI` is a live view model and holding
    /// one here would let a test assert against the composer through its own double.
    enum Call: Sendable {
        case perform(ChannelKey, LifecycleAction)
        /// The prompt the composer sent. `sendPrompt` **is** this leaf's surface — the send path — so it
        /// is recorded like every other member and not trapped as C5's doubles trap it.
        case sendPrompt(ChannelKey, UserInput)
        case route(ChannelKey, String)
        /// X5's two settings members Task 11 added: the late surface's read of what the engine already
        /// reported, and the fleet's own answer to a setting that did not survive a restart. Recorded
        /// like every other member, because both are claims about *which* member a click reached — a
        /// correction that went out as a bare `set_permission_mode` leaves the channel connecting.
        case engineReports(ChannelKey)
        case resolveSetting(ChannelKey, name: String)
        /// The subtype and the payload exactly as they go to the wire.
        case send(ChannelKey, subtype: String, payload: JSONValue)
        case run(ChannelKey, RouteStrategy, arguments: [String])
        case openInTerminal(ChannelKey)
        case events(ChannelKey)
        case preconditions(ChannelKey)
        /// §7.4's busy question, asked of the fleet rather than of a surface. Recorded like every
        /// other member, so "the clause asked about exactly the owned channels" is a claim over the
        /// one ordered log and not over a counter of its own.
        case liveTaskIDs(ChannelKey)
        /// A write into afleet's own store, recorded **in the same ordered log** as the lifecycle
        /// calls. G5's ordering assertion spans all three of §8.6's steps — the store write, the
        /// restart and the mode switch — and two logs could not order the first against the other two.
        /// The namespace and the key, never the value.
        case storeWrite(StoreNamespace, key: String)

        /// The member's name, for a failure message that names a member and no value (§11).
        var member: String {
            switch self {
            case .perform: "perform"
            case .sendPrompt: "sendPrompt"
            case .route: "route"
            case .engineReports: "engineReports"
            case .resolveSetting: "resolveSetting"
            case .send: "send"
            case .run: "run"
            case .openInTerminal: "openInTerminal"
            case .events: "events"
            case .preconditions: "preconditions"
            case .liveTaskIDs: "liveTaskIDs"
            case .storeWrite: "store.write"
            }
        }
    }

    /// What a member answers when the test staged nothing for it.
    ///
    /// **Thrown, never trapped.** C5's convention is that a double traps on a member outside its surface, and that
    /// still holds below for `attach`, `jobs` and the rest. But an *unstaged* answer on a member that IS in the
    /// surface is a different thing: it is exactly what a "this must not happen" arm provokes, and a `fatalError`
    /// there takes the whole test bundle down with no assertion instead of failing the one test cleanly. Found at
    /// Task 1, where a mutation arm crashed the bundle rather than reporting the count it was written to report.
    /// The call is appended to `calls` before the throw, so the count a negative assertion reads is still right.
    enum StagingError: Error, Sendable { case nothingStaged(member: String) }

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    /// X5's roster feed, amended onto `LifecycleAPI` on `main` for tracker 77. Nothing in this leaf reads it; it is
    /// here because the protocol declares it.
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    /// Every call, in the order it arrived. The single source for every ordering assertion.
    private(set) var calls: [Call] = []

    /// Holds `perform` and `sendPrompt` open so a second caller can arrive while the first is still
    /// inside it. Without it no test can tell a composer that guards reentrancy from one that merely
    /// never overlaps, because an unheld double answers before the second call is ever made. Both
    /// members, because the send path is `sendPrompt` and the reentrancy guard is the send's.
    private var isPerformHeld = false
    private var heldCallers: [CheckedContinuation<Void, Never>] = []
    /// How many callers are suspended inside `perform` right now. A count, not a value (§11).
    private(set) var callersHeldInPerform = 0

    private var performOutcomes: [Result<ChannelState, LifecycleError>] = []
    private var performFallback: Result<ChannelState, LifecycleError>?
    /// The uuids `sendPrompt` answers, in order, and the fallback for a suite that stages no particular one.
    private var promptOutcomes: [Result<UUID, LifecycleError>] = []
    private var promptFallback: Result<UUID, LifecycleError>?
    /// Staged answers to `send`, keyed by subtype; a subtype with no answer staged returns `.null`,
    /// which is what an engine member with an empty success body sends (`rename_session`).
    private var sendAnswers: [String: Result<JSONValue, WireError>] = [:]
    /// Answers per subtype in order; the last stays once the queue is down to it.
    private var sendSequences: [String: [Result<JSONValue, WireError>]] = [:]
    private var resolveOutcome: Result<Void, LifecycleError> = .success(())
    private var routeOutcomes: [Routed] = []
    /// What the engine reported about itself, as the real fleet's `route` sees it. Without these the
    /// fallback below would route every line against the local table alone, and G1's terminal-only
    /// arm could not fail on a composer that ignored `terminal_slash_commands`.
    private var handshake: InitializeResponse?
    private var systemInit: SystemInitFields?
    private var runOutcomes: [Result<StrategyOutcome, LifecycleError>] = []
    private var paneRequest: Result<PaneRequest, LifecycleError>?
    private var preconditionVerdict: SpawnPrecondition = .ready
    /// What `liveTaskIDs(of:)` answers per channel; a key with nothing staged answers `[]`, which is
    /// the fleet's own answer for a channel it owns no supervisor for.
    private var liveTasks: [ChannelKey: [String]] = [:]
    private var table: [ChannelKey: ChannelState] = [:]
    private var opened: Set<ChannelKey> = []
    private nonisolated let sink = EventSink()

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Staging

    func stagePerform(_ outcome: Result<ChannelState, LifecycleError>) { performOutcomes.append(outcome) }
    func alwaysPerform(_ outcome: Result<ChannelState, LifecycleError>) { performFallback = outcome }
    func stageSendPrompt(_ outcome: Result<UUID, LifecycleError>) { promptOutcomes.append(outcome) }
    func alwaysSendPrompt(_ outcome: Result<UUID, LifecycleError>) { promptFallback = outcome }
    func stageRoute(_ routed: Routed) { routeOutcomes.append(routed) }
    func stageRun(_ outcome: Result<StrategyOutcome, LifecycleError>) { runOutcomes.append(outcome) }
    func stageSend(_ subtype: String, _ answer: Result<JSONValue, WireError>) { sendAnswers[subtype] = answer }
    /// Answers for one subtype **in order**, for an exchange whose second answer differs from its
    /// first: `set_cwd` answers `needs_trust` and then, for the call that carries the trust, `ok`. The
    /// last one staged answers every call after it, so a sequence never runs out mid-test.
    func stageSendSequence(_ subtype: String, _ answers: [Result<JSONValue, WireError>]) {
        sendSequences[subtype] = answers
    }
    func stageResolveSetting(_ outcome: Result<Void, LifecycleError>) { resolveOutcome = outcome }
    func stagePane(_ outcome: Result<PaneRequest, LifecycleError>) { paneRequest = outcome }
    /// The engine's own report, taken from the very events the composer is fed, so the double and the
    /// model under test cannot be told two different stories. Both are `WireEvent`s because neither
    /// `InitializeResponse`'s payload nor `SystemInitFields` can be constructed outside ClaudeWire.
    func stageEngineReport(handshake: WireEvent?, systemInitFrom: WireEvent?) {
        if case .handshakeCompleted(let shake, _)? = handshake { self.handshake = shake.initialize }
        if case .frame(.system(.initialize(let fields)), _)? = systemInitFrom { self.systemInit = fields.fields }
    }
    /// Every `perform` from here on records itself and then suspends, until `releasePerform()`.
    func holdPerform() { isPerformHeld = true }
    func releasePerform() {
        isPerformHeld = false
        let waiting = heldCallers
        heldCallers = []
        callersHeldInPerform = 0
        for caller in waiting { caller.resume() }
    }
    func stagePrecondition(_ verdict: SpawnPrecondition) { preconditionVerdict = verdict }
    /// Invented task ids for one channel. Ids, never a real one (§11).
    func stageLiveTasks(_ ids: [String], for key: ChannelKey) { liveTasks[key] = ids }
    /// Records one store write in the ordered log. Called by `RecordingBypassStore`, which wraps the
    /// real store rather than replacing it, so the bytes still go through `FileStateStore`.
    func noteStoreWrite(namespace: StoreNamespace, key: String) { calls.append(.storeWrite(namespace, key: key)) }
    func setStates(_ states: [ChannelState]) { for state in states { table[state.key] = state } }
    func openEvents(of key: ChannelKey) { opened.insert(key) }
    nonisolated func enqueue(_ event: WireEvent, to key: ChannelKey) { sink.push(event, to: key) }
    func finishEvents(of key: ChannelKey) { sink.finish(key) }
    nonisolated func emit(_ state: ChannelState) { continuation.yield(state) }
    nonisolated func finish() { continuation.finish(); jobContinuation.finish() }
    nonisolated func emitJobs(_ jobs: [JobEntry]) { jobContinuation.yield(jobs) }

    // MARK: - Reading the log

    /// The members called, in order. The spelling every ordering assertion uses, because it carries
    /// no value and so cannot print one on failure (§11).
    var memberSequence: [String] { calls.map(\.member) }

    /// The members called, in order, with a control request's **subtype** attached to it: `send`
    /// alone cannot tell `reload_skills` from `rename_session`, and the header's table is a claim
    /// about which subtype each action reaches. Still a member name and a subtype, and never a value.
    var labelledSequence: [String] {
        calls.map { call in
            if case .send(_, let subtype, _) = call { return "send:\(subtype)" }
            return call.member
        }
    }

    /// Every prompt sent through `sendPrompt`, in order. The send path's counterpart to `actions`.
    var prompts: [UserInput] {
        calls.compactMap { if case .sendPrompt(_, let input) = $0 { input } else { nil } }
    }

    /// How many `perform`s the log holds. A count and not the log's own length, because the log also
    /// carries the queries a pass makes on its way — `liveTaskIDs` among them — and an ordering
    /// assertion about terminations must not move when a query is added beside them.
    var performCount: Int { actions.count }

    /// Every action performed, in order.
    var actions: [LifecycleAction] {
        calls.compactMap { if case .perform(_, let action) = $0 { action } else { nil } }
    }

    /// Every control-request subtype sent, in order. `["rewind_files"]` being empty is how G4's
    /// "no file rewind" clause is asserted.
    var sentSubtypes: [String] {
        calls.compactMap { if case .send(_, let subtype, _) = $0 { subtype } else { nil } }
    }

    /// The payload of the first `send` of a subtype, for a test that asserts a request's shape.
    func payload(ofFirst subtype: String) -> JSONValue? {
        for case .send(_, let sent, let payload) in calls where sent == subtype { return payload }
        return nil
    }

    /// Every strategy run, in order.
    var strategies: [RouteStrategy] {
        calls.compactMap { if case .run(_, let strategy, _) = $0 { strategy } else { nil } }
    }

    // MARK: - LifecycleAPI

    func state(of key: ChannelKey) async -> ChannelState? { table[key] }
    func states() async -> [ChannelState] { Array(table.values) }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition {
        calls.append(.preconditions(key))
        return preconditionVerdict
    }

    func liveTaskIDs(of key: ChannelKey) async -> [String] {
        calls.append(.liveTaskIDs(key))
        return liveTasks[key] ?? []
    }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        calls.append(.perform(key, action))
        if isPerformHeld {
            callersHeldInPerform += 1
            await withCheckedContinuation { heldCallers.append($0) }
        }
        let outcome = performOutcomes.isEmpty ? performFallback : performOutcomes.removeFirst()
        guard let outcome else { throw StagingError.nothingStaged(member: "perform") }
        let state = try outcome.get()
        table[state.key] = state
        return state
    }

    /// `perform(.send)`'s path on the real facade, answering the uuid the supervisor minted. Held by
    /// `holdPerform()` on the same terms as `perform`, because the reentrancy guard under test is the
    /// send's and this is the member a send reaches.
    @discardableResult
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID {
        calls.append(.sendPrompt(key, input))
        if isPerformHeld {
            callersHeldInPerform += 1
            await withCheckedContinuation { heldCallers.append($0) }
        }
        let outcome = promptOutcomes.isEmpty ? promptFallback : promptOutcomes.removeFirst()
        guard let outcome else { throw StagingError.nothingStaged(member: "sendPrompt") }
        return try outcome.get()
    }

    /// What the fleet retains about a channel it owns a supervisor for, and nil for one it does not —
    /// `Fleet.engineReports(of:)`'s own contract. The values are the ones `stageEngineReport` staged,
    /// so the double cannot tell the surface one story and `route` another.
    func engineReports(of key: ChannelKey) async -> EngineReports? {
        calls.append(.engineReports(key))
        guard opened.contains(key) else { return nil }
        return EngineReports(handshake: handshake, systemInit: systemInit)
    }

    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        calls.append(.resolveSetting(key, name: name))
        try resolveOutcome.get()
    }

    func route(_ text: String, on key: ChannelKey) async -> Routed {
        calls.append(.route(key, text))
        // With nothing staged the double routes through C4's own `CommandRouter`, which is what
        // makes G1's enumeration over `RouterTable.local` a test of the composer's dispatch rather
        // than of a table the test rewrote. A test that needs a specific `Routed` stages one.
        if !routeOutcomes.isEmpty { return routeOutcomes.removeFirst() }
        return CommandRouter.route(text, handshake: handshake, systemInit: systemInit)
    }

    @discardableResult
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        calls.append(.send(key, subtype: request.subtype, payload: request.payload))
        if var queued = sendSequences[request.subtype], !queued.isEmpty {
            let answer = queued.count == 1 ? queued[0] : queued.removeFirst()
            sendSequences[request.subtype] = queued
            return try answer.get()
        }
        guard let staged = sendAnswers[request.subtype] else { return .null }
        return try staged.get()
    }

    @discardableResult
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome {
        calls.append(.run(key, strategy, arguments: arguments))
        guard !runOutcomes.isEmpty else { return .notARequest }
        return try runOutcomes.removeFirst().get()
    }

    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest {
        calls.append(.openInTerminal(key))
        guard let paneRequest else { throw StagingError.nothingStaged(member: "openInTerminal") }
        return try paneRequest.get()
    }

    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? {
        calls.append(.events(key))
        guard opened.contains(key) else { return nil }
        let (stream, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        sink.add(continuation, for: key)
        return stream
    }

    // Outside the composer's and the header's surface. Trapping rather than answering is C5's
    // convention and the reason this file exists beside `LifecycleDouble` rather than inside it.
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func jobs() async -> [JobEntry] { unreachable("jobs") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ComposerLifecycleDouble.\(member) is not part of the composer's or header's surface")
    }
}
