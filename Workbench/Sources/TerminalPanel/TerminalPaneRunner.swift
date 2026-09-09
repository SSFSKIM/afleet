// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import FleetKit
import Foundation
import PanelHostAPI

/// X5's side of the pane seam: a request and the context of the channel it belongs to, handed to
/// that channel's session.
///
/// It owns nothing and spawns nothing. The context names the channel — the request does not, and
/// no channel is recoverable from a `.attach`, `.logs`, `.command` or `.shell` request — so the
/// runner's whole job is to turn that name into the session that will hold the pane and report its
/// exit.
public struct TerminalPaneRunner: PaneRunning {
    private let registry: TerminalSessionRegistry

    public init(registry: TerminalSessionRegistry) {
        self.registry = registry
    }

    public func run(_ request: PaneRequest, in context: ChannelContext) async {
        await MainActor.run {
            registry.session(for: context).run(request)
        }
    }
}
