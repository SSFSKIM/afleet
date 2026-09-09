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
    /// The teardown a release started. Held rather than dropped — a task nobody accounts for is a
    /// child nobody accounts for — and awaited by ``settleRelease()``.
    private var releasing: Task<Void, Never>?

    public init() {}

    /// Drops every session and ends the panes they held.
    ///
    /// `AppModel.bindWorkspace` calls it, because that is the event that rebuilds the host's
    /// contexts: a session kept across it holds the previous workspace's store and its
    /// `reportPaneExit`, so its panes would write where nothing reads and report exits to a
    /// lifecycle nobody is listening to, and no owner would be left to close their children.
    ///
    /// The map is emptied at once, so the next `session(for:)` cannot be handed a released
    /// session; the panes are torn down in a task, because closing one suspends.
    ///
    /// A channel *removed* from the fleet is not this event and is not handled here: reaching it
    /// needs a seam on the host that this wave does not add, and it is filed as tech debt.
    public func release() {
        let released = entries.values.compactMap(\.session)
        entries.removeAll()
        endPanes(of: released)
    }

    /// How many panes still hold a live child, per channel — a value, taken now, with no lifecycle
    /// in it at all.
    ///
    /// It exists because §7.4's *Quit* is built from the fleet, and a shell pane has no fleet entry:
    /// a pane running a command is afleet's own child (§7.8 is about a session in the user's own
    /// terminal, which no pane ever holds), and the exit closes its pty descriptor whether or not
    /// anybody was told. So the quit clause asks here, beside the fleet's own "busy", and the two
    /// facts stay separate — a pane is not folded into the fleet and does not become a channel's
    /// business.
    ///
    /// Channels with nothing live are left out, so an empty answer means exactly "no pane holds a
    /// child". Counts and keys only; no title and no command line (§11).
    public func livePanes() -> [LivePaneCount] {
        entries.compactMap { key, entry in
            guard let session = entry.session else { return nil }
            let live = session.panes.filter(\.hasLiveChild).count
            guard live > 0 else { return nil }
            return LivePaneCount(key: key, panes: live)
        }
    }

    /// Returns once a release's pane teardown has landed. Tests await it; nothing in the app does.
    public func settleRelease() async {
        await releasing?.value
    }

    /// The channel's session, made on first ask. A caller holds the returned reference, which is
    /// what keeps a freshly made, still-empty session alive long enough to be given a pane.
    public func session(for context: ChannelContext) -> TerminalPanelSession {
        if let existing = entries[context.key]?.session {
            if Self.isSameWorld(existing.context, context) { return existing }
            // The channel is the same and its world is not. Handing this one back would place a
            // pane in the previous workspace's session, whose `reportPaneExit` reaches a lifecycle
            // nobody is listening to — the exit C4 is waiting on would simply never arrive.
            entries[context.key] = nil
            endPanes(of: [existing])
        }
        let session = TerminalPanelSession(context: context)
        let key = context.key
        session.paneCountDidChange = { [weak self] session in
            self?.updateRetention(of: session, for: key)
        }
        entries[key] = Entry(session: session, retained: nil)
        // Whatever teardown is in flight — the replacement started above, or a release — is work
        // this session's document read has to stand behind. The teardown writes nothing itself;
        // what it settles are the writes the session it is ending had already scheduled.
        session.precedingWork = releasing
        return session
    }

    /// Whether two contexts for one channel came from the same workspace.
    ///
    /// Asked of the store, which is the part of a context this leaf holds on to and the part a
    /// rebind replaces along with the `reportPaneExit` beside it — a closure, and so not a thing
    /// that can be compared at all. A store that is a value rather than an object has no identity
    /// to compare either, and answers "the same" rather than answering falsely: every store the
    /// app and its tests bind is a reference type, and `AppModel.bindWorkspace` releasing the
    /// registry is what this check stands behind, not in front of.
    private static func isSameWorld(_ held: ChannelContext, _ asked: ChannelContext) -> Bool {
        guard let held = identity(of: held.store), let asked = identity(of: asked.store) else {
            return true
        }
        return held == asked
    }

    private static func identity(of store: any ScopedStore) -> ObjectIdentifier? {
        guard type(of: store) is AnyClass else { return nil }
        return ObjectIdentifier(store as AnyObject)
    }

    /// Ends every pane of the sessions handed in, chained behind whatever teardown is already
    /// running so two releases cannot close one session's panes at once.
    private func endPanes(of sessions: [TerminalPanelSession]) {
        guard !sessions.isEmpty else { return }
        let previous = releasing
        releasing = Task { @MainActor in
            await previous?.value
            for session in sessions { await session.tearDown() }
        }
    }

    private func updateRetention(of session: TerminalPanelSession, for key: ChannelKey) {
        guard entries[key]?.session === session else { return }
        entries[key]?.retained = session.panes.isEmpty ? nil : session
    }
}

/// One channel's still-running panes, as ``TerminalSessionRegistry/livePanes()`` reports them.
///
/// A value and not a session reference: the one caller outside this leaf is a quit dialog deciding
/// whether to ask, and handing it a live object would let it reach a pane's lifecycle from a place
/// that has no business ending one.
public struct LivePaneCount: Sendable, Hashable {
    public let key: ChannelKey
    /// How many of that channel's panes still hold a child. Never zero — a channel with none is
    /// simply absent from the answer.
    public let panes: Int

    public init(key: ChannelKey, panes: Int) {
        self.key = key
        self.panes = panes
    }
}
