// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import FleetKit
import Foundation
import PanelHostAPI

/// The map from a channel to its `TerminalPanelSession`, because two owners need the same object
/// and neither of them can be the only one.
///
/// The host retains a session per (tab, channel) for rendering and evicts under a 16-channel LRU.
/// A `PaneRequest`, since X7's amendment, may name a channel the host is not rendering at all — so
/// a session has to exist before any render, and something has to hold it.
///
/// The rule: **strongly while a session has at least one pane, weakly otherwise.** That bounds
/// growth by live panes, which is the resource that actually costs something, rather than by
/// channels ever visited; and it means the host's LRU evicting a channel does not kill a user's
/// running shell. `session(for:)` is the one door — the tab's `makeSession(for:)` calls it too, so
/// the host and the runner always hold the same object.
@MainActor
public final class TerminalSessionRegistry {
    private struct Entry {
        weak var session: TerminalPanelSession?
        var retained: TerminalPanelSession?
    }

    private var entries: [ChannelKey: Entry] = [:]

    public init() {}

    /// The channel's session, made on first ask. A caller holds the returned reference, which is
    /// what keeps a freshly made, still-empty session alive long enough to be given a pane.
    public func session(for context: ChannelContext) -> TerminalPanelSession {
        if let existing = entries[context.key]?.session { return existing }
        let session = TerminalPanelSession(context: context)
        let key = context.key
        session.paneCountDidChange = { [weak self] session in
            self?.updateRetention(of: session, for: key)
        }
        entries[key] = Entry(session: session, retained: nil)
        return session
    }

    private func updateRetention(of session: TerminalPanelSession, for key: ChannelKey) {
        guard entries[key]?.session === session else { return }
        entries[key]?.retained = session.panes.isEmpty ? nil : session
    }
}
