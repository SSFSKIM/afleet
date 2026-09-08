import Foundation
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI

/// The capabilities a `ChannelContext` needs so C6.2's `StrategyUI` conformance can be driven
/// without a panel host: everything answers and does nothing, except the link router, which records.
///
/// They live here rather than being borrowed from `PanelHostTests` because that file's are `private`
/// to it, and a shared one would have two leaves editing the same support file in parallel.
struct NullComposerScopedStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

struct NullComposerRecentURLFeed: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}

/// Records what the composer handed the channel's link-routing capability.
///
/// It records the link and the destination and never the context it was reached through: an
/// assertion over an aggregate holding a `ChannelContext` would print an environment on failure
/// (§11).
actor RecordingLinkRouter: LinkRouterCapability {
    private(set) var opened: [WorkspaceLink] = []
    private(set) var destinations: [LinkDestination] = []
    /// How many targets were registered here. A count; nothing in this leaf registers one.
    private(set) var registered = 0

    func register(_ target: LinkTarget) async { registered += 1 }
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        opened.append(link)
        destinations.append(destination)
    }

    /// Every opened link that is a `.url`, as its absolute string. A string rather than the link, so
    /// a failure prints one invented URL and not a link enum's whole payload.
    var openedURLs: [String] {
        opened.compactMap { if case .url(let url) = $0 { url.absoluteString } else { nil } }
    }
}

enum ComposerContextFixtures {

    /// A context over the stubs above, carrying the recording link router. Everything is invented and
    /// nothing is written (X9).
    static func context(_ key: ChannelKey, links: RecordingLinkRouter) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: URL(fileURLWithPath: "/invented/project"),
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh",
                                                        capturedAt: Date(timeIntervalSince1970: 0),
                                                        mode: .login),
                       store: NullComposerScopedStore(),
                       links: links,
                       recentURLs: NullComposerRecentURLFeed(),
                       reportPaneExit: { _ in })
    }
}
