import Foundation
import AfleetCore
import FleetKit

/// Everything a panel tab is given about the channel it is rendering, and every capability it
/// is allowed to use. The host constructs one per channel and hands the same value to every tab.
///
/// It carries **no** `any LifecycleAPI`. That type's signature names `WireEvent`, a ClaudeWire
/// type, and parent contract X1 forbids Workbench from importing ClaudeWire; withholding it is
/// also what stops a panel from spawning `claude` for a session on its own initiative. Pane
/// exits leave through `reportPaneExit` instead. `ProtocolShapeTests` pins this member set
/// exactly, because FleetKit's umbrella already exposes `LifecycleAPI` and adding it here would
/// need no new import — the import test alone could not catch it.
public struct ChannelContext: Sendable {
    public let key: ChannelKey
    public let session: SessionID
    public let cwd: URL
    public let environment: ResolvedEnvironment
    public let store: any ScopedStore
    public let links: any LinkRouterCapability
    public let recentURLs: any RecentURLFeed
    public let reportPaneExit: @Sendable (PaneExit) async -> Void

    public init(key: ChannelKey, session: SessionID, cwd: URL, environment: ResolvedEnvironment,
                store: any ScopedStore, links: any LinkRouterCapability, recentURLs: any RecentURLFeed,
                reportPaneExit: @escaping @Sendable (PaneExit) async -> Void) {
        self.key = key
        self.session = session
        self.cwd = cwd
        self.environment = environment
        self.store = store
        self.links = links
        self.recentURLs = recentURLs
        self.reportPaneExit = reportPaneExit
    }
}
