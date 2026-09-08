import Foundation
import SwiftUI
import FleetKit

public enum PanelHostError: Error, Hashable, Sendable {
    case duplicateTab(PanelTabID)
    case noPaneRunner(PanelTabID)
    /// The host holds no `ChannelContext` for the channel the caller named, so there is nothing to
    /// run the pane in. A channel the host has never rendered, or one that has left the index while
    /// the request was being prepared, arrives here.
    case noChannelContext
}

/// The panel-tab host. C5's app shell implements it; C6 and the C7 leaves register into it.
@MainActor public protocol PanelHost: AnyObject {
    func register(_ tab: any PanelTab) throws
    /// Removes a registered tab, releases every session it held, and calls
    /// `LinkRouterCapability.unregister(tab:)` so no link target outlives it. A later child replaces a
    /// placeholder by unregistering it and then registering its own tab for the same id;
    /// without this, `register`'s duplicate check would make the seven ids permanently
    /// first-come, and C6 could never register Thread over C5's placeholder.
    ///
    /// It is `async` because it **awaits** the link-target withdrawal rather than spawning it. A
    /// synchronous member could only spawn and return, and on the handover path above nothing
    /// would then order the withdrawal before the replacement's registration: landing second it
    /// would delete the *new* tab's target and links would silently stop arriving. Awaiting is
    /// what makes the guarantee above true — a registration issued after this returns cannot be
    /// undone by it.
    func unregister(_ id: PanelTabID) async
    func registerPaneRunner(_ runner: any PaneRunning, for tab: PanelTabID)
    /// Registered tabs that report themselves available for this channel, in PanelTabID order.
    func available(for context: ChannelContext) -> [PanelTabID]
    /// The main panel's selection, owned by the host rather than mirrored by the window.
    var selected: PanelTabID? { get }
    /// Synchronously selects a registered tab and invalidates the main panel's rendered selection.
    /// The next render shows that tab, or its unavailable placeholder for the current channel.
    /// An unregistered id is a no-op; selecting the current id is also a no-op. Pop-outs keep
    /// their own tab and channel. Callers need no separate window-selection write-back.
    func select(_ id: PanelTabID)
    /// Cmd+1…7: 1-based over `available(for: context)`, so Cmd+1 is the first tab the user can see.
    ///
    /// The context is a parameter rather than state the host keeps, so the index cannot resolve
    /// against a channel the user is not looking at. A host holding its own current channel
    /// would have two sources of truth — that one and the context the render path passes to
    /// `view(for:context:)` — with nothing saying who sets the first; the shortcut would then
    /// pick the wrong panel only when the two had diverged. Passing it makes that unrepresentable.
    func selectIndex(_ index: Int, in context: ChannelContext)
    func popOut(_ id: PanelTabID, channel: ChannelKey)
    /// The tab's session for this channel, created on first use and retained thereafter, so
    /// panes and editors survive switching away and back (C7's acceptance). The host also gives
    /// each (tab, channel) a stable SwiftUI identity so the subtree is not rebuilt from scratch.
    func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession
    func view(for id: PanelTabID, context: ChannelContext) -> AnyView
    /// X5's pane request, delivered to the registered runner unchanged, `id` included, in the
    /// context of the channel **the caller names**.
    ///
    /// The channel is a parameter because every caller already holds one: a header action, a trust
    /// banner and a sidebar row each act on a channel they were drawn for. Resolving it from the
    /// host's focus instead would be resolving it later than the decision was made — `openInTerminal`
    /// suspends across a whole ownership handoff, long enough for the user to select another channel
    /// — and the pane would then open in a channel X5 never released, while X5 waits on an exit from
    /// the one it did. There is no context-less form to fall back to, so no caller can reach that
    /// ambiguity at all.
    ///
    /// Throws `noChannelContext` when the host can resolve no context for that channel, having
    /// selected no tab and reached no runner.
    func run(_ request: PaneRequest, for channel: ChannelKey) async throws
}

// Link opening is deliberately NOT a `PanelHost` member: it lives on `LinkRouterCapability`,
// which the host implements and hands into every `ChannelContext`, so a tab holds one routing
// seam rather than two. The host is still what routes — `.newWindow` pops a tab out before the
// target delivers, and a tab cannot pop itself out — but it does so through that conformance.
