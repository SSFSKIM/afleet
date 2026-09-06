import Foundation
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI
import SwiftUI

/// X7's shape, pinned. Four assertions, each about a decision four other children inherit:
/// the closed tab set and its order, that every case carries user-visible copy, that
/// `ChannelContext` carries exactly the approved members and no lifecycle object, and that
/// every one of those members actually reads back through a stub.
final class ProtocolShapeTests: XCTestCase {

    func testCanonicalOrderIsTheSevenOfX7() {
        XCTAssertEqual(PanelTabID.allCases.map(\.rawValue),
                       ["thread", "agents", "files", "sourceControl", "terminal", "browser", "github"],
                       "the assertion is on the full ordered array, not on the count, because a "
                       + "reordering with no case added is the regression that matters")
    }

    func testEveryTabIDHasATitleAndAnImage() {
        XCTAssertFalse(PanelTabID.allCases.isEmpty)
        for id in PanelTabID.allCases {
            XCTAssertFalse(id.defaultTitle.isEmpty, "case \(id.rawValue) has an empty title")
            XCTAssertFalse(id.defaultSystemImage.isEmpty, "case \(id.rawValue) has an empty system image")
        }
        let titles = Set(PanelTabID.allCases.map(\.defaultTitle))
        XCTAssertEqual(titles.count, PanelTabID.allCases.count, "two cases share a title")
    }

    /// Equality, not containment. The point is that `lifecycle` is *absent*, and `ImportGraphTests`
    /// cannot catch its addition: `PanelHostAPI` already imports FleetKit, whose umbrella exposes
    /// `LifecycleAPI`, so `let lifecycle: any LifecycleAPI` needs no new import and would leave
    /// every other test green.
    func testChannelContextExposesExactlyTheApprovedMembers() async {
        let context = await Self.makeContext().context
        let labels = Set(Mirror(reflecting: context).children.compactMap(\.label))
        XCTAssertEqual(labels,
                       ["key", "session", "cwd", "environment", "store", "links", "recentURLs", "reportPaneExit"],
                       "ChannelContext's member set changed")
    }

    func testEveryChannelContextMemberReadsBack() async throws {
        let fixture = await Self.makeContext()
        let context = fixture.context

        XCTAssertEqual(context.key, fixture.key)
        XCTAssertEqual(context.session, fixture.key.session)
        XCTAssertEqual(context.cwd, fixture.cwd)
        XCTAssertEqual(context.environment, fixture.environment)

        try await context.store.write("panel-scoped-value", key: "last-open")
        let readBack = try await context.store.read(String.self, key: "last-open")
        XCTAssertEqual(readBack, "panel-scoped-value")
        let storedKeys = try await context.store.keys()
        XCTAssertEqual(storedKeys, ["last-open"])

        let link = WorkspaceLink.url(URL(string: "https://example.invalid/x7")!)
        await context.links.open(link, from: .newWindow)
        let delivered = await fixture.router.delivered
        XCTAssertEqual(delivered.count, 1, "the registered target was not reached")
        XCTAssertEqual(delivered.first?.0, link)
        XCTAssertEqual(delivered.first?.1, .newWindow)

        let recent = await context.recentURLs.current(limit: 10)
        // The floor: the expected list is non-empty, so this is not comparing two empty collections.
        XCTAssertFalse(fixture.seen.isEmpty)
        XCTAssertEqual(recent, fixture.seen)

        await context.reportPaneExit(fixture.paneExit)
        let exits = await fixture.exits.recorded
        XCTAssertEqual(exits, [fixture.paneExit])
    }

    /// `LinkRouterCapability.unregister(tab:)` is the counterpart `PanelHost.unregister(_:)` calls.
    /// Without it a `LinkTarget` would outlive the tab that registered it, keep winning the
    /// specificity contest and deliver into a tab that is gone. The floor is that delivery is
    /// proven to work first, so the second assertion is not a pair of empty collections.
    func testAWithdrawnTabsLinkTargetNoLongerDelivers() async {
        let fixture = await Self.makeContext()
        let link = WorkspaceLink.url(URL(string: "https://example.invalid/withdrawn")!)

        await fixture.context.links.open(link, from: .currentPanel)
        var delivered = await fixture.router.delivered
        XCTAssertEqual(delivered.count, 1, "the registered target was not reached to begin with")

        await fixture.context.links.unregister(tab: .browser)
        await fixture.context.links.open(link, from: .currentPanel)
        delivered = await fixture.router.delivered
        XCTAssertEqual(delivered.count, 1, "a withdrawn tab's target still delivered")
    }

    /// The handover `PanelHost.unregister(_:)` exists for: a later child takes an id C5 holds a
    /// placeholder under. Because `unregister` **awaits** the link-target withdrawal instead of
    /// spawning it, the withdrawal cannot land after the replacement's registration and delete the
    /// new tab's target. Against the spawn-and-return shape a synchronous member would force, the
    /// link reaches nobody and this fails.
    @MainActor func testAReplacementTabsLinkTargetSurvivesTheHandover() async throws {
        let fixture = await Self.makeContext()
        let router = fixture.router
        let host = StubHost(router: router, context: fixture.context)
        let link = WorkspaceLink.url(URL(string: "https://example.invalid/handover")!)

        let placeholder = StubTab(id: .thread, mark: "placeholder", router: router)
        try host.register(placeholder)
        await router.register(placeholder.target)
        await fixture.context.links.open(link, from: .currentPanel)
        let afterFirstOpen = await router.deliveredMarks
        XCTAssertEqual(afterFirstOpen, ["placeholder"], "the placeholder never received a link")

        // The handover, in the order a later child performs it.
        await host.unregister(.thread)
        let replacement = StubTab(id: .thread, mark: "replacement", router: router)
        try host.register(replacement)
        await router.register(replacement.target)

        await fixture.context.links.open(link, from: .currentPanel)
        let afterHandover = await router.deliveredMarks
        XCTAssertEqual(afterHandover, ["placeholder", "replacement"],
                       "the withdrawal landed after the replacement registered and deleted its target")
    }

    // MARK: - Stubs

    /// A tab that carries the `LinkTarget` it registers, so the handover above can tell which of
    /// two tabs sharing one id a link reached.
    @MainActor final class StubTab: PanelTab {
        let id: PanelTabID
        let mark: String
        let target: LinkTarget

        init(id: PanelTabID, mark: String, router: StubRouter) {
            self.id = id
            self.mark = mark
            self.target = LinkTarget(tab: id, specificity: 10, handles: { _ in true },
                                     open: { link, destination in await router.deliver(link, destination, mark) })
        }

        var title: String { id.defaultTitle }
        var systemImage: String { id.defaultSystemImage }
        func isAvailable(in context: ChannelContext) -> Bool { true }
        func makeSession(for context: ChannelContext) -> any PanelTabSession { StubSession() }
        func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView { AnyView(EmptyView()) }
    }

    @MainActor final class StubSession: PanelTabSession {}

    /// The minimum conformance the ordering test needs. Everything not on the handover path is
    /// the smallest answer that satisfies the protocol; Task 7 owns the real host.
    @MainActor final class StubHost: PanelHost {
        private let router: StubRouter
        /// The channel currently on screen. `selectIndex(_:)` is 1-based over `available(for:)`,
        /// which needs a context, and the real host has one at that point for the same reason.
        private let context: ChannelContext
        private var tabs: [PanelTabID: any PanelTab] = [:]
        private(set) var selected: PanelTabID?

        init(router: StubRouter, context: ChannelContext) {
            self.router = router
            self.context = context
        }

        func register(_ tab: any PanelTab) throws {
            guard tabs[tab.id] == nil else { throw PanelHostError.duplicateTab(tab.id) }
            tabs[tab.id] = tab
        }

        /// Awaited, not spawned. This is the whole point of the member being `async`.
        func unregister(_ id: PanelTabID) async {
            tabs[id] = nil
            await router.unregister(tab: id)
        }

        func registerPaneRunner(_ runner: any PaneRunning, for tab: PanelTabID) {}
        func available(for context: ChannelContext) -> [PanelTabID] {
            PanelTabID.allCases.filter { tabs[$0]?.isAvailable(in: context) == true }
        }
        func select(_ id: PanelTabID) { selected = id }
        /// 1-based over `available(for:)`, not over `allCases` and not over everything registered,
        /// so Cmd+1 is the first tab the user can actually see.
        func selectIndex(_ index: Int) {
            let visible = available(for: context)
            guard index >= 1, index <= visible.count else { return }
            selected = visible[index - 1]
        }
        func popOut(_ id: PanelTabID, channel: ChannelKey) {}
        func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession { StubSession() }
        func view(for id: PanelTabID, context: ChannelContext) -> AnyView { AnyView(EmptyView()) }
        func run(_ request: PaneRequest) async throws { throw PanelHostError.noPaneRunner(.terminal) }
    }

    struct Fixture: Sendable {
        let context: ChannelContext
        let key: ChannelKey
        let cwd: URL
        let environment: ResolvedEnvironment
        let seen: [SeenURL]
        let paneExit: PaneExit
        let router: StubRouter
        let exits: ExitRecorder
    }

    /// Invented identifiers only; nothing here is read from a real config home, and nothing is written to disk.
    static func makeContext() async -> Fixture {
        let key = ChannelKey(configHome: URL(filePath: "/invented/config-home"),
                             session: SessionID(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!))
        let cwd = URL(filePath: "/invented/workspace")
        let environment = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: "/bin/zsh",
                                              capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                              mode: .processFallback)
        let stream = LogicalStream(configHome: key.configHome, sessionID: key.session, name: .main)
        let item = ItemID(stream: stream, key: "invented-record-1")
        let seen = [SeenURL(url: URL(string: "https://example.invalid/seen")!,
                            firstSeen: item, firstSeenAt: nil, lastSeen: item, lastSeenAt: nil)]
        let request = PaneRequest(executable: URL(filePath: "/invented/bin/claude"), arguments: ["--help"],
                                  cwd: cwd, environment: [:], purpose: .shell)
        let paneExit = PaneExit(request: request, code: 0, observedAt: Date(timeIntervalSince1970: 1_700_000_001))

        let router = StubRouter()
        await router.register(LinkTarget(tab: .browser, specificity: 1, handles: { _ in true },
                                         open: { link, destination in await router.deliver(link, destination) }))
        let exits = ExitRecorder()
        let context = ChannelContext(key: key, session: key.session, cwd: cwd, environment: environment,
                                     store: StubStore(), links: router, recentURLs: StubFeed(seen: seen),
                                     reportPaneExit: { await exits.record($0) })
        return Fixture(context: context, key: key, cwd: cwd, environment: environment, seen: seen,
                       paneExit: paneExit, router: router, exits: exits)
    }

    actor StubStore: ScopedStore {
        private var storage: [String: Data] = [:]
        func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
            guard let data = storage[key] else { return nil }
            return try JSONDecoder().decode([T].self, from: data).first
        }
        func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
            storage[key] = try JSONEncoder().encode([value])
        }
        func remove(key: String) async throws { storage[key] = nil }
        func keys() async throws -> [String] { storage.keys.sorted() }
    }

    struct StubFeed: RecentURLFeed {
        let seen: [SeenURL]
        func current(limit: Int) async -> [SeenURL] { Array(seen.prefix(limit)) }
        var updates: AsyncStream<[SeenURL]> {
            let seen = seen
            return AsyncStream { continuation in
                continuation.yield(seen)
                continuation.finish()
            }
        }
    }

    actor StubRouter: LinkRouterCapability {
        private var targets: [LinkTarget] = []
        private(set) var delivered: [(WorkspaceLink, LinkDestination)] = []
        func register(_ target: LinkTarget) async { targets.append(target) }
        func unregister(tab: PanelTabID) async { targets.removeAll { $0.tab == tab } }
        func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
            guard let target = targets.filter({ $0.handles(link) }).max(by: { $0.specificity < $1.specificity })
            else { return }
            await target.open(link, destination)
        }
        func deliver(_ link: WorkspaceLink, _ destination: LinkDestination) { delivered.append((link, destination)) }
        /// Which tab each delivery reached, in order, so the handover test can name the winner.
        private(set) var deliveredMarks: [String] = []
        func deliver(_ link: WorkspaceLink, _ destination: LinkDestination, _ mark: String) {
            delivered.append((link, destination))
            deliveredMarks.append(mark)
        }
    }

    actor ExitRecorder {
        private(set) var recorded: [PaneExit] = []
        func record(_ exit: PaneExit) { recorded.append(exit) }
    }
}
