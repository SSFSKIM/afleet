import Foundation
import SwiftUI
import FleetKit

public enum PanelHostError: Error, Hashable, Sendable {
    case duplicateTab(PanelTabID)
    case noPaneRunner(PanelTabID)
}

/// The panel-tab host. C5's app shell implements it; C6 and the C7 leaves register into it.
@MainActor public protocol PanelHost: AnyObject {
    func register(_ tab: any PanelTab) throws
    /// Removes a registered tab, releases every session it held, and calls
    /// `LinkRouterCapability.unregister(tab:)` so no link target outlives it. A later child replaces a
    /// placeholder by unregistering it and then registering its own tab for the same id;
    /// without this, `register`'s duplicate check would make the seven ids permanently
    /// first-come, and C6 could never register Thread over C5's placeholder.
    func unregister(_ id: PanelTabID)
    func registerPaneRunner(_ runner: any PaneRunning, for tab: PanelTabID)
    /// Registered tabs that report themselves available for this channel, in PanelTabID order.
    func available(for context: ChannelContext) -> [PanelTabID]
    var selected: PanelTabID? { get }
    func select(_ id: PanelTabID)
    /// Cmd+1…7: 1-based over `available(for:)`, so Cmd+1 is the first tab the user can see.
    func selectIndex(_ index: Int)
    func popOut(_ id: PanelTabID, channel: ChannelKey)
    /// The tab's session for this channel, created on first use and retained thereafter, so
    /// panes and editors survive switching away and back (C7's acceptance). The host also gives
    /// each (tab, channel) a stable SwiftUI identity so the subtree is not rebuilt from scratch.
    func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession
    func view(for id: PanelTabID, context: ChannelContext) -> AnyView
    /// X5's pane request, delivered to the registered runner unchanged, `id` included.
    func run(_ request: PaneRequest) async throws
}

// Link opening is deliberately NOT a `PanelHost` member: it lives on `LinkRouterCapability`,
// which the host implements and hands into every `ChannelContext`, so a tab holds one routing
// seam rather than two. The host is still what routes — `.newWindow` pops a tab out before the
// target delivers, and a tab cannot pop itself out — but it does so through that conformance.
