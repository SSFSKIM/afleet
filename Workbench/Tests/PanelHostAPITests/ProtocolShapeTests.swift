import Foundation
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI

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

    // MARK: - Stubs

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
        func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
            guard let target = targets.filter({ $0.handles(link) }).max(by: { $0.specificity < $1.specificity })
            else { return }
            await target.open(link, destination)
        }
        func deliver(_ link: WorkspaceLink, _ destination: LinkDestination) { delivered.append((link, destination)) }
    }

    actor ExitRecorder {
        private(set) var recorded: [PaneExit] = []
        func record(_ exit: PaneExit) { recorded.append(exit) }
    }
}
