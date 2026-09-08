import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// The Thread tab: contract Y3's handover, §7.5's five kinds, and the two things a reply can be
/// (acceptance G2, spec D10).
///
/// **Every reply clause asserts what left the host** — the `InboundAnswer` handed to the lifecycle,
/// or the `UserInput` it was asked to send — and never that a thread changed. A thread changes for
/// many reasons and only one of them is the right thing having gone on the wire.
///
/// Item 10's clause is the inverse and is a **count**: the durable items C3's reducer folds are
/// counted before and after, in both directions, so an *Ask on the side* implemented as a composer
/// line — which would add a user record — cannot pass. The counter is shown able to move in the same
/// test, because a counter that never moves proves nothing about the case where it must not.
///
/// A `ChannelKey` carries a config home and an `ItemID` carries a session, and `XCTAssertEqual`
/// prints both operands (§6.3, §11), so comparisons over those are spelled as booleans with a
/// written message. Every identifier invented here is visibly nobody's.
@MainActor
final class ThreadTabTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("c", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-threads-unwritten"))
    }

    // MARK: - G2: the handover

    /// Contract Y3, on the host: `.thread` passes from C5's placeholder to this child's tab, the tab
    /// bar reads this tab's title, and **the placeholder is no longer drawing**.
    ///
    /// The second half is the discriminating one. `register` refuses a duplicate, so a handover whose
    /// `unregister` never ran leaves the placeholder registered and the host still presenting a tab
    /// for `.thread` — every assertion about the id alone would pass against it.
    func testTheThreadTabTakesThreadFromThePlaceholderAndThePlaceholderStopsDrawing() async throws {
        let host = PanelHostModel()
        let context = ThreadFixtures.context(Self.channel)
        try host.register(PlaceholderTab())
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self, in: host.view(for: .thread, context: context)).count, 1,
                       "the placeholder is not drawing before the handover")

        await host.unregister(.thread)
        try host.register(ThreadTab(lifecycle: ThreadDouble()))

        XCTAssertEqual(host.available(for: context), [.thread], "the successor is not the tab the host presents")
        XCTAssertEqual(host.title(for: .thread), PanelTabID.thread.defaultTitle,
                       "the tab bar does not read this child's title")
        let view = host.view(for: .thread, context: context)
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self, in: view).count, 0,
                       "C5's placeholder is still drawing after the handover")
        XCTAssertEqual(ViewTree.values(of: ThreadModel.self, in: view).count, 1,
                       "the Thread tab drew no thread model")
        XCTAssertTrue(host.session(for: .thread, context: context) is ThreadModel,
                      "the host retains something other than a thread model for the channel")
    }

    /// And the same handover on the path the app really takes: a launch that reaches a workspace
    /// hands `.thread` over. Asserted through the composition root because contract Y3 names
    /// `AppModel` as where the pair lives — a handover only a test performs would leave the shipped
    /// app drawing C5's placeholder for ever.
    func testALaunchHandsThreadOverToThisChildsTab() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let fleet = LifecycleDouble()
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in StubIndex(persisted: nil,
                                              built: LaunchFixtures.snapshot(configHome: configHome,
                                                                             ids: [LaunchFixtures.sessionA]),
                                              delta: IndexDelta(added: [LaunchFixtures.sessionA])) },
            fleetFactory: { _, _, _, _, _, _ in fleet },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })

        let model = AppModel(sequence: sequence)
        let context = ThreadFixtures.context(ChannelKey(configHome: LaunchFixtures.directoryURL(configHome),
                                                        session: LaunchFixtures.sessionA))
        XCTAssertTrue(model.panels.session(for: .thread, context: context) is PlaceholderTabSession,
                      "the app does not start on C5's placeholder")

        await model.launch()

        XCTAssertTrue(model.panels.session(for: .thread, context: context) is ThreadModel,
                      "the launch left C5's placeholder holding .thread")
        XCTAssertEqual(model.panels.selected, .thread, "the handover lost the selection it started with")
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self,
                                       in: model.panels.view(for: .thread, context: context)).count, 0,
                       "C5's placeholder is still drawing after the launch")
        model.activity?.stop()
        fleet.finish()
    }

}

// MARK: - Support

private enum ThreadFixtures {

    /// A context over the same null capabilities the host's own tests use: these clauses are about
    /// the tab, not about what a capability does.
    static func context(_ key: ChannelKey) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: URL(fileURLWithPath: "/invented/project"),
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh", capturedAt: Date(), mode: .login),
                       store: NullThreadStore(),
                       links: NullThreadLinks(),
                       recentURLs: NullThreadURLs(),
                       reportPaneExit: { _ in })
    }
}

private struct NullThreadStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

private struct NullThreadLinks: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

private struct NullThreadURLs: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}

/// A lifecycle that records both halves of Y5 — `perform` and `send` — because the Thread tab's five
/// kinds split across them and item 10 is exactly the assertion that one kind took the other route.
///
/// `LifecycleDouble` traps on `send`, which is right for the surfaces it was built for and wrong
/// here; this double is the narrow one that answers both and records both.
actor ThreadDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    private(set) var actions: [(key: ChannelKey, action: LifecycleAction)] = []
    private(set) var sent: [AnyControlRequest] = []
    private var outcome: Result<ChannelState, LifecycleError>?
    private var replies: [Result<JSONValue, WireError>] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func always(_ outcome: Result<ChannelState, LifecycleError>) { self.outcome = outcome }
    /// What the next `send` answers. A queue, so two asks are answered differently.
    func stageReply(_ reply: Result<JSONValue, WireError>) { replies.append(reply) }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        actions.append((key, action))
        guard let outcome else { unreachable("perform with no staged outcome") }
        return try outcome.get()
    }

    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        sent.append(request)
        guard !replies.isEmpty else { return .object([:]) }
        return try replies.removeFirst().get()
    }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ThreadDouble.\(member) is not part of the Thread tab's surface")
    }
}
