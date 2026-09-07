import Foundation
import Observation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// One popped-out panel window, and the value its `WindowGroup` is keyed by (spec §7).
///
/// It carries the tab and the channel and **not** the `ChannelContext`, which holds capabilities
/// that are not `Codable`. The scene resolves the context from the host by this key, which is also
/// what keeps a popped-out window on the channel it was popped from when the main window moves on.
struct PoppedOutPanel: Codable, Hashable, Sendable {
    let tab: PanelTabID
    let channel: ChannelKey
}

/// Contract X7's host: the app's only conformance to `PanelHost` (spec §7).
///
/// **What it retains is the session, not the view.** SwiftUI owns `@State`, `@StateObject` and
/// representable coordinators through the rendered hierarchy and tears them down when a subtree
/// unmounts, so caching an `AnyView` value would preserve nothing. The host holds one
/// `PanelTabSession` per (tab, channel), hands it back on every render, and gives each pair a
/// stable SwiftUI identity so an unrelated re-render does not discard the subtree. A tab puts its
/// PTY, its panes and its open buffers there.
///
/// **What releases a session is one of three things, and origin is not among them.** Sixteen
/// channels of LRU pressure, the tab being unregistered, and the channel leaving the index. The
/// `.archived` origin is deliberately *not* a trigger: it is the ordinary origin of a registered
/// channel with no live process, so evicting on it would destroy nearly every channel's state at
/// once. Nothing in this type reads a `ChannelOrigin` at all, which is what makes that structural.
@MainActor
@Observable
final class PanelHostModel: PanelHost {

    private(set) var selected: PanelTabID?

    /// The popped-out windows, in the order they were popped. Every channel named here is exempt
    /// from LRU eviction: a window on screen must not lose the state it is drawing.
    private(set) var poppedOut: [PoppedOutPanel] = []

    /// How a popped-out window is actually opened. Set by the panel column, which is the only place
    /// SwiftUI's `openWindow` action is reachable from; nil in a headless test, where the pop-out
    /// registry is the whole of the observable behaviour.
    @ObservationIgnored var presentWindow: (@MainActor (PoppedOutPanel) -> Void)?

    /// One (tab, channel) pair: the session cache's key and the rendered subtree's SwiftUI identity.
    struct SessionSlot: Hashable {
        let tab: PanelTabID
        let channel: ChannelKey
    }

    @ObservationIgnored private var tabs: [PanelTabID: any PanelTab] = [:]
    @ObservationIgnored private var runners: [PanelTabID: any PaneRunning] = [:]
    init() {}

    // MARK: - Registration and order

    func register(_ tab: any PanelTab) throws {
        guard tabs[tab.id] == nil else { throw PanelHostError.duplicateTab(tab.id) }
        tabs[tab.id] = tab
    }

    /// Drops the tab.
    ///
    /// It is `async` because contract X7 declares it so: the deliverable that gives the host its
    /// link registry adds the **awaited** withdrawal of the tab's targets here, and the await is
    /// load-bearing on the handover path this method exists for.
    func unregister(_ id: PanelTabID) async {
        tabs[id] = nil
        runners[id] = nil
        poppedOut.removeAll { $0.tab == id }
        if selected == id { selected = nil }
    }

    func registerPaneRunner(_ runner: any PaneRunning, for tab: PanelTabID) {
        runners[tab] = runner
    }

    /// The registered tabs this channel can show, in `PanelTabID`'s canonical order whatever order
    /// they were registered in.
    func available(for context: ChannelContext) -> [PanelTabID] {
        PanelTabID.allCases.filter { id in
            guard let tab = tabs[id] else { return false }
            return tab.isAvailable(in: context)
        }
    }

    /// The registered tab's own title, or the id's default when nothing holds the id. The tab bar
    /// draws this, so a child that takes an id over C5's placeholder is named by its own title
    /// rather than by the one the placeholder had.
    func title(for id: PanelTabID) -> String {
        tabs[id]?.title ?? id.defaultTitle
    }

    /// The registered tab's own SF Symbol, on the same terms as `title(for:)`.
    func systemImage(for id: PanelTabID) -> String {
        tabs[id]?.systemImage ?? id.defaultSystemImage
    }

    func select(_ id: PanelTabID) {
        guard tabs[id] != nil else { return }
        selected = id
    }

    /// Cmd+1…7, one-based over `available(for:)` so Cmd+1 is the first tab the user can see. An
    /// index outside the set changes nothing: a key combination is not an assertion.
    func selectIndex(_ index: Int, in context: ChannelContext) {
        let ids = available(for: context)
        guard index >= 1, index <= ids.count else { return }
        select(ids[index - 1])
    }

    // MARK: - Pop-out

    func popOut(_ id: PanelTabID, channel: ChannelKey) {
        let entry = PoppedOutPanel(tab: id, channel: channel)
        if !poppedOut.contains(entry) { poppedOut.append(entry) }
        presentWindow?(entry)
    }

    // MARK: - Sessions

    /// The tab's session for this channel.
    ///
    /// Contract X7 requires the host to *retain* one of these per (tab, channel) and hand it back
    /// on every render; the cache that does so is the next deliverable. Here the tab is simply
    /// asked for one, which satisfies the protocol and preserves nothing across a channel switch.
    func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession {
        guard let tab = tabs[id] else { return UnregisteredTabSession() }
        return tab.makeSession(for: context)
    }

    func view(for id: PanelTabID, context: ChannelContext) -> AnyView {
        guard let tab = tabs[id] else { return AnyView(EmptyView()) }
        let session = session(for: id, context: context)
        // A stable identity per (tab, channel), so an unrelated re-render of the column does not
        // discard the subtree and take the tab's `@State` with it.
        return AnyView(tab.makeView(session: session, context: context)
            .id(SessionSlot(tab: id, channel: context.key)))
    }

    // MARK: - The pane seam

    /// X5's request, delivered to the registered runner **unchanged, `id` included**.
    ///
    /// The host neither edits a request nor constructs an exit: C4 accepts an exit only when its
    /// `request.id` is the one it is waiting on, so a host that minted a fresh id would have every
    /// exit discarded and nothing would say why.
    func run(_ request: PaneRequest) async throws {
        let tab = runners[.terminal] != nil ? PanelTabID.terminal
            : PanelTabID.allCases.first(where: { runners[$0] != nil })
        guard let tab, let runner = runners[tab] else { throw PanelHostError.noPaneRunner(.terminal) }
        // Selecting or creating the Terminal tab is spec §7's wording; a runner registered for a
        // tab that is not registered runs without a selection moving.
        if tabs[tab] != nil { selected = tab }
        await runner.run(request)
    }
}

/// What `session(for:context:)` answers for a tab that is not registered.
///
/// The protocol's return is not optional, because every caller that has a tab has a session; a
/// caller that asks for one the host never heard of gets an object with nothing in it rather than
/// a trap, since the panel column can ask during the frame in which a tab is being handed over.
private final class UnregisteredTabSession: PanelTabSession {}
