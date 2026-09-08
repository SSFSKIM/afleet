// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import FleetKit
import Foundation

/// One persisted pane: W6 asks for "pane count and cwd overrides", and that is the whole record.
/// Nothing about a pane's purpose, its request or its process is written down, because none of it
/// could be honoured at restore (see ``TerminalPanelState``).
public struct PersistedPane: Codable, Hashable, Sendable {
    /// The directory the pane was opened in, or `nil` for one that took the channel's own.
    public var cwd: String?

    public init(cwd: String? = nil) {
        self.cwd = cwd
    }
}

/// The Terminal panel's W6 document, and the one key it lives under.
///
/// **Only shell panes are persisted.** Restoring an X5-originated pane at launch would be the
/// panel spawning `claude` on its own initiative, which W8 forbids in as many words, and a
/// restored `.attach` or `.logs` pane would name a job that may be gone. So a channel whose panes
/// were all X5's restores to one shell pane, which is what a Terminal tab looks like when you
/// open it.
///
/// This key has exactly one writer — the channel's own session — so the read-modify-write merge
/// W6's 2026-09-09 amendment exists for is not needed here.
public struct TerminalPanelState: Codable, Hashable, Sendable {
    /// Bumped when the shape below changes. A document carrying any other value is not read; see
    /// `TerminalPanelSession.restore()` for why that is a restore and not a throw.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var panes: [PersistedPane]
    public var selected: Int?

    public init(schemaVersion: Int = TerminalPanelState.currentSchemaVersion,
                panes: [PersistedPane],
                selected: Int?) {
        self.schemaVersion = schemaVersion
        self.panes = panes
        self.selected = selected
    }

    /// W6's key: `panel.terminal.<configHomeHash>.<sessionId>`, in the `workbench` namespace the
    /// host already bound the store to. A panel cannot name a namespace at all, so the key is the
    /// only thing this leaf spells.
    public static func storeKey(for channel: ChannelKey) -> String {
        "panel.terminal.\(configHomeHash(channel.configHome)).\(channel.session.description)"
    }

    /// The first 12 lowercase hex characters of SHA-256 over the config home's path.
    ///
    /// Deliberately the same spelling as ClaudeWire's `RawCapture.configHomeHash`, so one hash
    /// never appears in the tree under two spellings. It is re-implemented rather than called
    /// because contract X1 forbids Workbench importing ClaudeWire; what holds the two together is
    /// a literal vector pinned in `TerminalPanelStateTests`, which fails if either side moves.
    public static func configHomeHash(_ configHome: URL) -> String {
        String(ContentHash.sha256Hex(Data(configHome.path.utf8)).prefix(12))
    }
}
