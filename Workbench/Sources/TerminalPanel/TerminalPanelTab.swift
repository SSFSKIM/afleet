// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import Foundation
import PanelHostAPI
import SwiftUI

/// The Terminal tab, as X7's host sees it (spec Design §1).
///
/// It owns nothing. The channel's panes live in a `TerminalPanelSession` the registry vends, so
/// that the host rendering this tab and the pane runner answering an X5 request always hold the
/// same object — a second session would report an exit for panes the first one is holding.
@MainActor
public final class TerminalPanelTab: PanelTab {

    public let id: PanelTabID = .terminal
    /// From the id's own defaults, because a second spelling of a panel's name is a name that
    /// drifts.
    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    private let registry: TerminalSessionRegistry

    public init(registry: TerminalSessionRegistry) {
        self.registry = registry
    }

    /// Every channel has a directory and an environment, which is everything a terminal needs.
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        registry.session(for: context)
    }

    /// Renders the channel's panes, and takes the one moment a session can be sure of to read its
    /// W6 document: `restoreOnce()` is idempotent, so this is the first render and no other. A
    /// session made by the pane runner for a channel no window was showing has had no render
    /// before this one, which is why the restore is asked for here and not at construction.
    ///
    /// `surface` says which window is asking (X7, amended at C7.6's merge). It reaches the pane's
    /// view because the two windows over one popped-out tab draw the **same** session and the same
    /// pane: the claim that decides which of them holds the surface is keyed by the host that
    /// registered it, and giving each surface its own subtree identity is what stops SwiftUI
    /// handing one window's host state to the other's (spec Design §8).
    public func makeView(session: any PanelTabSession, context: ChannelContext,
                         surface: PanelSurface) -> AnyView {
        guard let session = session as? TerminalPanelSession else { return AnyView(EmptyView()) }
        session.restoreOnce()
        return AnyView(TerminalPanelView(session: session, surface: surface).id(surface))
    }
}
