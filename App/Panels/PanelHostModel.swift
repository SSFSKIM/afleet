import Foundation
import Observation
import OSLog
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

    /// How many channels may hold sessions before the least recently rendered ones are released.
    ///
    /// C4's live-process cap of six plus room for the pop-outs and the recently visited. Advisory:
    /// a measured reason to change it is a Revision Note, not an edit. The alternative — retaining
    /// a session per channel browsed — accumulates one per channel across a three-thousand-channel
    /// config home, each potentially holding a PTY.
    static let channelCapacity = 16

    /// How many URLs a context's feed republishes on each timeline change.
    static let recentURLLimit = 100

    /// Where the host's own diagnostics go. Every message names a fact and never a tab, a channel,
    /// a session id or a path (§11).
    private static let log = Logger(subsystem: "com.afleet.app", category: "panel-host")

    private(set) var selected: PanelTabID?

    /// The popped-out windows, in the order they were popped. Every channel named here is exempt
    /// from LRU eviction: a window on screen must not lose the state it is drawing.
    private(set) var poppedOut: [PoppedOutPanel] = []

    /// The pop-out most recently asked for, which is how a `.newWindow` link delivery finds the
    /// channel *its own* window was opened for. `HostLinkRouter` captures that channel when the
    /// action is taken and pops out with it immediately before the delivery; the main window is
    /// free to move to another channel in between, so the delivery cannot ask what is selected
    /// now. Read against `poppedOut`, which is what makes a closed window's channel stop counting.
    /// `ObservationIgnored` because nothing draws it — the array above is the observable state.
    @ObservationIgnored private(set) var lastPopOut: PoppedOutPanel?

    /// The channel the main window is looking at, which is exempt from eviction however long ago
    /// it was last rendered. The panel column sets it; a headless host has none.
    private(set) var selectedChannel: ChannelKey?

    /// The tabs the main window can currently show, in canonical order, for the menu that carries
    /// Cmd+1…7.
    ///
    /// **Presentation only, and never a second source of truth for what an index names.** The
    /// shortcut still resolves through `selectIndex(_:in:)` against the context the panel column
    /// holds — that is why the context is a parameter of that member rather than state kept here —
    /// and this exists so the label the menu writes beside Cmd+2 is the tab Cmd+2 actually selects.
    /// Empty when the window is on Activity or on a channel with no context, where the shortcut has
    /// nothing to select and the menu correctly offers nothing.
    private(set) var mainWindowTabs: [PanelTabID] = []

    /// The one link registry in the running app (spec §7, C7's W5). The host hands *this* object
    /// into every `ChannelContext`, so a tab holds one routing seam rather than two, and when
    /// C7.2's `LinkRouting` target lands its reusable registry this delegates to it rather than a
    /// second registry coming into being.
    @ObservationIgnored let links = HostLinkRouter()

    /// How a popped-out window is actually opened. Set by the panel column, which is the only place
    /// SwiftUI's `openWindow` action is reachable from; nil in a headless test, where the pop-out
    /// registry is the whole of the observable behaviour.
    @ObservationIgnored var presentWindow: (@MainActor (PoppedOutPanel) -> Void)?

    /// Called immediately after a tab builds a session, so composition can connect two sessions of
    /// **one channel** to each other. The host itself reads nothing from it and keeps no strong
    /// reference on its behalf.
    ///
    /// It exists because X7 gives a tab a `ChannelContext` and no host, so a tab cannot tell the
    /// app that a channel now has a session — and the pairing C7.7's Design §8 asks for (the
    /// Source Control panel's branch reaching that channel's GitHub tab) has no other moment it
    /// can be made at. Whoever sets it holds its sessions weakly.
    @ObservationIgnored var didMakeSession:
        (@MainActor (PanelTabID, ChannelContext, any PanelTabSession) -> Void)?

    /// One (tab, channel) pair: the session cache's key and the rendered subtree's SwiftUI identity.
    struct SessionSlot: Hashable {
        let tab: PanelTabID
        let channel: ChannelKey
    }

    @ObservationIgnored private var tabs: [PanelTabID: any PanelTab] = [:]
    @ObservationIgnored private var runners: [PanelTabID: any PaneRunning] = [:]
    @ObservationIgnored private var sessions: [SessionSlot: any PanelTabSession] = [:]
    /// Which generation of each id the host currently holds. Bumped by every `register`.
    ///
    /// **Ownership of the host's state is the host's own fact.** A teardown suspends inside
    /// `unregister(_:)` while the link registry drains, and by the time it resumes the id may
    /// belong to a replacement — but only a *host* registration can have made that so. A verdict
    /// from the link registry says who owns a `LinkTarget`, which is not the same question: a
    /// panel may register a target during the drain without any tab changing hands (spec §3,
    /// 2026-09-08 final wave).
    @ObservationIgnored private var generations: [PanelTabID: Int] = [:]
    /// The generation each withdrawal in flight captured at entry, by tab. An array because two
    /// withdrawals of one id may overlap.
    ///
    /// It is also what makes a registration over a *withdrawing* owner legal: that owner is on its
    /// way out, and only its own generation may be taken from it.
    @ObservationIgnored private var withdrawing: [PanelTabID: [Int]] = [:]
    /// The channels that hold sessions, least recently rendered first. The eviction order.
    @ObservationIgnored private var recency: [ChannelKey] = []
    /// The working directory each channel was last rendered with, so a popped-out window can
    /// rebuild a context for a channel the main window has moved off.
    @ObservationIgnored private var cwds: [ChannelKey: URL] = [:]
    /// One context per channel, rebuilt when the channel's working directory changes. Cached so the
    /// main window and a popped-out window hand a tab the *same* capabilities — in particular the
    /// same `RecentURLFeed` instance — rather than two feeds over one timeline.
    @ObservationIgnored private var contexts: [ChannelKey: ChannelContext] = [:]

    @ObservationIgnored private var workspace: Workspace?
    @ObservationIgnored private var timelines: ChannelTimelineRegistry?
    @ObservationIgnored private var lifecycle: (any LifecycleAPI)?

    init() {
        links.host = self
    }

    // MARK: - The workspace

    /// Binds the host to the workspace a launch reached and to the app's one timeline registry.
    ///
    /// Every session and every context built over the previous workspace is released: *Check again*
    /// runs the whole launch again, and a pane holding the store and fleet of a workspace nothing
    /// else refers to is a leak with a PTY in it.
    ///
    /// `lifecycle` is the seam pane exits leave through. Production passes nil and gets
    /// `workspace.fleet`; a test passes a double, which is the only way an exit's journey can be
    /// asserted on.
    func attach(to workspace: Workspace, timelines: ChannelTimelineRegistry,
                lifecycle: (any LifecycleAPI)? = nil) {
        self.workspace = workspace
        self.timelines = timelines
        self.lifecycle = lifecycle ?? workspace.fleet
        sessions = [:]
        recency = []
        cwds = [:]
        contexts = [:]
        poppedOut = []
        selectedChannel = nil
    }

    // MARK: - Registration and order

    /// Takes the id, refusing a second live holder — and **accepting a holder that is on its way
    /// out**.
    ///
    /// X7's handover is `await unregister(id)` and then `register(replacement)`, and the withdrawal
    /// it awaits can take arbitrarily long: it returns only once no delivery for the tab is still
    /// in flight. A registration that arrives while that drain is running is the same handover with
    /// the two halves overlapped, and refusing it would make the handover's success depend on
    /// whether a link happened to be in flight.
    ///
    /// It succeeds rather than waits because `PanelHost.register` is X7's **synchronous** member:
    /// waiting would mean making it `async`, an X7 signature change with no caller asking for it.
    /// So the outgoing owner's release is ordered *before* this registration completes instead —
    /// otherwise the replacement would inherit the retired tab's sessions and its pane runner — and
    /// the generation bump tells the withdrawal still draining that the id is no longer its own to
    /// release.
    func register(_ tab: any PanelTab) throws {
        if tabs[tab.id] != nil {
            guard withdrawing[tab.id, default: []].contains(generations[tab.id] ?? 0) else {
                throw PanelHostError.duplicateTab(tab.id)
            }
            release(tab.id)
        }
        generations[tab.id, default: 0] += 1
        tabs[tab.id] = tab
    }

    /// **Awaits** the withdrawal of the tab's link targets, and only then drops the tab and releases
    /// every session it held for every channel.
    ///
    /// The await is load-bearing rather than incidental. This is the handover path — a later child
    /// takes an id C5's placeholder holds by unregistering and then registering — and a withdrawal
    /// that landed after the replacement's registration would delete the *replacement's* target,
    /// because withdrawal is keyed by a tab id both tabs share.
    ///
    /// **The withdrawal goes first**, which is the other half of the same guarantee. The registry
    /// returns from `unregister(tab:)` once no delivery for that tab is in flight, so everything
    /// after this line runs with no handler for the tab running or about to start. Releasing the
    /// tab and its sessions first and awaiting afterwards freed the main actor in between, and a
    /// delivery the registry had already committed would then read a tab and sessions this method
    /// had torn down (contract X7's 2026-09-06 amendment; tracker 97).
    ///
    /// **And what decides whether it releases is the host's own generation, not the registry's
    /// verdict.** The registry answers for the epoch this teardown opened in the *link* registry,
    /// where a panel registering a target during the drain is enough to make the answer
    /// `superseded` — and a `LinkTarget` changing hands is no evidence that a tab, a pane runner or
    /// a session did. Only a host `register` moves those, and that is exactly what the generation
    /// records. The verdict is still worth a log line, because a target registered against a tab
    /// this teardown is about to release is a thing worth seeing (spec §3, 2026-09-08 final wave).
    func unregister(_ id: PanelTabID) async {
        let generation = generations[id] ?? 0
        withdrawing[id, default: []].append(generation)
        let verdict = await links.withdraw(tab: id)
        if let index = withdrawing[id]?.firstIndex(of: generation) {
            withdrawing[id]?.remove(at: index)
            if withdrawing[id]?.isEmpty ?? false { withdrawing[id] = nil }
        }
        if verdict == .superseded {
            // Named without the tab, the channel or the session (§11).
            Self.log.notice("a tab withdrawal was superseded in the link registry")
        }
        // A replacement registered while this was draining already released what this would have.
        guard (generations[id] ?? 0) == generation else { return }
        release(id)
    }

    /// Everything the host holds for one tab id: the tab itself, its pane runner, its sessions in
    /// every channel, its pop-outs and the selection if it was on it.
    ///
    /// Its two callers are the two halves of the handover — the teardown that still owns the id,
    /// and the registration that takes it from a teardown still draining.
    private func release(_ id: PanelTabID) {
        tabs[id] = nil
        runners[id] = nil
        for slot in sessions.keys where slot.tab == id { sessions[slot] = nil }
        forgetChannelsWithNoSessions()
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

    /// Whether anything holds this id right now. A pop-out for a tab nobody holds draws an empty
    /// window, so the routing pop-out asks before it presents one.
    func isRegistered(_ id: PanelTabID) -> Bool { tabs[id] != nil }

    func select(_ id: PanelTabID) {
        guard tabs[id] != nil, selected != id else { return }
        selected = id
    }

    /// The tab Cmd+N names for this channel, or nil when the index is past what the channel can
    /// show.
    ///
    /// `selectIndex(_:in:)` is this plus the host-owned selection. The panel column also returns
    /// the chosen id to its shortcut caller, so both paths use this one indexing operation.
    func tab(at index: Int, in context: ChannelContext) -> PanelTabID? {
        let ids = available(for: context)
        guard index >= 1, index <= ids.count else { return nil }
        return ids[index - 1]
    }

    /// Cmd+1…7, one-based over `available(for:)` so Cmd+1 is the first tab the user can see. An
    /// index outside the set changes nothing: a key combination is not an assertion.
    func selectIndex(_ index: Int, in context: ChannelContext) {
        guard let id = tab(at: index, in: context) else { return }
        select(id)
    }

    /// The panel column reports what it is showing, so the menu above the window can name the tabs
    /// its shortcuts select. Called from a `task(id:)` rather than from `body`, because this one is
    /// observed and writing it during a view evaluation is the shape that invalidates mid-update.
    func mainWindowShows(_ ids: [PanelTabID]) {
        guard ids != mainWindowTabs else { return }
        mainWindowTabs = ids
    }

    // MARK: - Pop-out

    /// Records the window and asks for it. **Idempotent per (tab, channel)**: the entry is recorded
    /// once, and `presentWindow` is SwiftUI's `openWindow(value:)`, which is keyed by that same
    /// value — a second call for a window already on screen brings it forward rather than opening a
    /// second one. So the same tab in the same channel can never become two windows, which is what
    /// the routing rule above it depends on when a link is prepared and then delivered.
    /// Whether the host can still resolve this channel, which is exactly what a popped-out
    /// window's scene asks it for. `releaseChannel(_:)` and `attach(to:…)` take it away, and a
    /// window presented for a channel this answers no for draws the missing-channel placeholder —
    /// so the routing pop-out asks before it presents one.
    func canResolveChannel(_ key: ChannelKey) -> Bool {
        contexts[key] != nil || cwds[key] != nil
    }

    func popOut(_ id: PanelTabID, channel: ChannelKey) {
        let entry = PoppedOutPanel(tab: id, channel: channel)
        if !poppedOut.contains(entry) { poppedOut.append(entry) }
        lastPopOut = entry
        presentWindow?(entry)
    }

    /// The window closed. Its channel loses its eviction exemption; its session is not released
    /// here, because the main window may be drawing the same channel.
    func closePopOut(_ entry: PoppedOutPanel) {
        poppedOut.removeAll { $0 == entry }
        evictIfNeeded()
    }

    // MARK: - Sessions

    func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession {
        remember(context)
        let slot = SessionSlot(tab: id, channel: context.key)
        if let existing = sessions[slot] { return existing }
        guard let tab = tabs[id] else { return UnregisteredTabSession() }
        let made = tab.makeSession(for: context)
        sessions[slot] = made
        didMakeSession?(id, context, made)
        evictIfNeeded()
        return made
    }

    func view(for id: PanelTabID, context: ChannelContext, surface: PanelSurface) -> AnyView {
        guard let tab = tabs[id] else { return AnyView(EmptyView()) }
        let session = session(for: id, context: context)
        // A stable identity per (tab, channel), so an unrelated re-render of the column does not
        // discard the subtree and take the tab's `@State` with it.
        return AnyView(tab.makeView(session: session, context: context, surface: surface)
            .id(SessionSlot(tab: id, channel: context.key)))
    }

    /// How many sessions are live, for a diagnostic line and for the bound's own test. A count,
    /// never a key (§11).
    var liveSessionCount: Int { sessions.count }

    /// How many channels hold at least one session.
    var liveChannelCount: Int { Set(sessions.keys.map(\.channel)).count }

    /// The channel left the index (`IndexDelta.removed`). Its sessions go at once rather than
    /// waiting for LRU pressure. Pop-out membership invalidates any window drawing it,
    /// replacing its retained panel view with the missing-channel placeholder.
    ///
    /// `FleetCoordinator` calls this, which is the seam the composition root already drives; a host
    /// released only from a test would leave production accumulating sessions for channels that no
    /// longer exist.
    func releaseChannel(_ key: ChannelKey) {
        releaseSessions(of: key)
        poppedOut.removeAll { $0.channel == key }
        if selectedChannel == key { selectedChannel = nil }
    }

    /// The main window moved to this channel. Exempts it from eviction; nil when the window is
    /// showing Activity or no channel at all.
    func focusChannel(_ key: ChannelKey?) {
        selectedChannel = key
    }

    private func remember(_ context: ChannelContext) {
        cwds[context.key] = context.cwd
        recency.removeAll { $0 == context.key }
        recency.append(context.key)
    }

    /// Releases the least recently rendered channels until the bound is met, skipping the selected
    /// channel and every popped-out one. If the exempt channels alone exceed the bound, nothing is
    /// released: a window on screen keeps what it is drawing.
    private func evictIfNeeded() {
        var live = Set(sessions.keys.map(\.channel))
        guard live.count > Self.channelCapacity else { return }
        var exempt = Set(poppedOut.map(\.channel))
        if let selectedChannel { exempt.insert(selectedChannel) }
        for key in recency {
            guard live.count > Self.channelCapacity else { break }
            guard !exempt.contains(key), live.contains(key) else { continue }
            releaseSessions(of: key)
            live.remove(key)
        }
    }

    /// Everything the host holds for one channel: its sessions, its place in the eviction order,
    /// and the context it was rendering with.
    ///
    /// **The context goes too.** It holds the channel's `TimelineRecentURLFeed`, which holds that
    /// channel's `ChannelTimelineModel`, so a cache that bounded the sessions at sixteen and kept
    /// every context would still accumulate one timeline model per channel browsed — the
    /// unbounded growth the bound exists to prevent, one indirection further out. Its callers are
    /// both channel-level: LRU pressure, which never touches an exempt channel, and a channel
    /// leaving the index. `unregister` releases one tab's slots itself and does not come here,
    /// because another tab may still be rendering the same channel.
    private func releaseSessions(of key: ChannelKey) {
        for slot in sessions.keys where slot.channel == key { sessions[slot] = nil }
        recency.removeAll { $0 == key }
        contexts[key] = nil
        cwds[key] = nil
    }

    /// Keeps the eviction order to the channels that still hold something.
    private func forgetChannelsWithNoSessions() {
        let live = Set(sessions.keys.map(\.channel))
        recency.removeAll { !live.contains($0) }
    }

    // MARK: - The channel context

    /// The context for a channel the host is rendering, recording the working directory so a
    /// popped-out window can rebuild it later.
    func context(for key: ChannelKey, cwd: URL) -> ChannelContext? {
        if let cached = contexts[key], cached.cwd == cwd { return cached }
        cwds[key] = cwd
        guard let built = makeContext(key: key, cwd: cwd) else { return nil }
        contexts[key] = built
        return built
    }

    /// The context for a channel by key alone — the popped-out scene's resolution. Nil for a
    /// channel this host has never rendered, which is what a window outliving its channel gets.
    func context(for key: ChannelKey) -> ChannelContext? {
        if let cached = contexts[key] { return cached }
        guard let cwd = cwds[key] else { return nil }
        return context(for: key, cwd: cwd)
    }

    private func makeContext(key: ChannelKey, cwd: URL) -> ChannelContext? {
        guard let workspace, let timelines, let lifecycle else { return nil }
        return ChannelContext(key: key,
                              session: key.session,
                              cwd: cwd,
                              environment: workspace.environment,
                              store: WorkbenchScopedStore(store: workspace.store),
                              links: links,
                              recentURLs: TimelineRecentURLFeed(registry: timelines, key: key,
                                                                limit: Self.recentURLLimit),
                              reportPaneExit: { exit in await lifecycle.paneExited(exit) })
    }

    // MARK: - The pane seam

    /// X5's request, delivered to the registered runner **unchanged, `id` included**, in the context
    /// of the channel the caller named (X7 as amended 2026-09-09, C7.4's `[parent-impact]`).
    ///
    /// The host neither edits a request nor constructs an exit: C4 accepts an exit only when its
    /// `request.id` is the one it is waiting on, so a host that minted a fresh id would have every
    /// exit discarded and nothing would say why.
    ///
    /// **The channel comes from the caller and never from `selectedChannel`.** Every caller of this
    /// method already holds the channel it is acting on — the header's *Open in terminal*, C6.3's
    /// trust banner, the sidebar's job rows — and each of them suspends before it arrives here:
    /// `openInTerminal` awaits a whole ownership handoff, which is long enough for the user to move
    /// the window to another channel. A host reading its own focus would hand the runner the context
    /// of whichever channel the user had drifted to, and the pane would open there while X5 waited
    /// on an exit from the channel it had released.
    ///
    /// **The runner is looked up before the context is resolved**, so a window that has no Terminal
    /// leaf registered yet still says exactly that (item 47's stated degradation) rather than
    /// reporting a channel it could in fact resolve.
    func run(_ request: PaneRequest, for channel: ChannelKey) async throws {
        let tab = runners[.terminal] != nil ? PanelTabID.terminal
            : PanelTabID.allCases.first(where: { runners[$0] != nil })
        guard let tab, let runner = runners[tab] else {
            await discharge(request)
            throw PanelHostError.noPaneRunner(.terminal)
        }
        // Resolved before anything moves: a selection changed for a pane that then never started
        // would leave the window showing an empty panel and the user nothing to read.
        guard let context = context(for: channel) else {
            await discharge(request)
            throw PanelHostError.noChannelContext
        }
        // Selecting or creating the Terminal tab is spec §7's wording; a runner registered for a
        // tab that is not registered runs without a selection moving.
        select(tab)
        await runner.run(request, in: context)
    }

    /// A request that cannot be run is **reported as an exit with code 127**, and only then does
    /// `run(_:for:)` throw.
    ///
    /// C7.4's Design §2 already fixes 127 for the other half of this: a spawn that never executed
    /// is reported as a `PaneExit` because C4 is waiting on that id and a hatch whose pane never
    /// started would leave its channel released for ever. A request that never reaches a pane at
    /// all is the same fact one step earlier — X5 has installed `pendingHatch`, which only a
    /// matching `paneExited` clears, and no pane exists for anyone else to report. So the two
    /// places carry one rule: whoever refuses the request discharges it.
    ///
    /// The throw is unchanged, and deliberately so: the caller's banner is what tells the user,
    /// and this is only what stops the channel being stranded behind it.
    private func discharge(_ request: PaneRequest) async {
        guard let lifecycle else { return }
        await lifecycle.paneExited(PaneExit(request: request, code: 127, observedAt: Date()))
    }
}

/// What `session(for:context:)` answers for a tab that is not registered.
///
/// The protocol's return is not optional, because every caller that has a tab has a session; a
/// caller that asks for one the host never heard of gets an object with nothing in it rather than
/// a trap, since the panel column can ask during the frame in which a tab is being handed over.
private final class UnregisteredTabSession: PanelTabSession {}
