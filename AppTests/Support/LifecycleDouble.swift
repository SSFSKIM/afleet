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

    /// What the next `perform` does. A queue, so a test can stage a refusal followed by a success and
    /// see which one a surface that retried would have reached.
    private var outcomes: [Result<ChannelState, LifecycleError>] = []
    private var fallback: Result<ChannelState, LifecycleError>?
    private(set) var performed: [ChannelKey] = []
    private var roster: [JobEntry] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Driving it

    func stage(_ outcome: Result<ChannelState, LifecycleError>) { outcomes.append(outcome) }
    /// The answer every `perform` gets once the staged queue is empty.
    func always(_ outcome: Result<ChannelState, LifecycleError>) { fallback = outcome }
    func setJobs(_ jobs: [JobEntry]) { roster = jobs }
    nonisolated func emit(_ state: ChannelState) { continuation.yield(state) }
    nonisolated func finish() { continuation.finish() }

    var performCount: Int { performed.count }

    // MARK: - LifecycleAPI

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        performed.append(key)
        let outcome = outcomes.isEmpty ? fallback : outcomes.removeFirst()
        guard let outcome else { unreachable("perform with no staged outcome") }
        return try outcome.get()
    }

    func jobs() async -> [JobEntry] { roster }
    func states() async -> [ChannelState] { [] }
    func state(of key: ChannelKey) async -> ChannelState? { nil }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey, ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async {}
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("LifecycleDouble.\(member) is not part of the fleet browser's surface")
    }
}

/// An `AppFleet` for the composition root, whose `updates` the test can push through. Used where the
/// launch needs a fleet and the *registration* is recorded somewhere else.
actor FleetDouble: AppFleet {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    private(set) var started = false
    private(set) var registrations: [ChannelKey] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() async { started = true }
    func shutdown() async { continuation.finish() }
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async { registrations.append(key) }
    nonisolated func emit(_ state: ChannelState) { continuation.yield(state) }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func paneExited(_ exit: PaneExit) async {}
    func isDormantEligible(_ key: ChannelKey) async -> Bool { false }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState { unreachable("perform") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
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

// MARK: - Values the sidebar tests build

enum SidebarFixtures {
    /// Invented throughout. No identifier here comes from any real home (§11).
    static func session(_ nibble: String) -> SessionID {
        SessionID("\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)-\(nibble)\(nibble)\(nibble)\(nibble)-4\(nibble)\(nibble)\(nibble)-8\(nibble)\(nibble)\(nibble)-\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)\(nibble)")!
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
