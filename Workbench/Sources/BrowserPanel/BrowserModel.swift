import Foundation
import Observation
import PanelHostAPI
import WebKit

/// One tab of the shared set, as the panel holds it.
///
/// The web view is **lazy** and that is Q7: a relaunch restores the whole set but loads only the
/// selected tab, so an unselected tab is a URL and a persisted title and no `WKWebView` at all
/// until the user first selects it. A ten-tab restore that fired ten requests at whatever those
/// hosts are would be a surprising thing for an app to do on launch.
@Observable
@MainActor
public final class BrowserLiveTab: Identifiable {

    public let id: UUID

    /// The page this tab is on, or `nil` for a tab the user opened and has not navigated. A tab
    /// with no URL has no page to restore, so it is not in the document (D34).
    public internal(set) var url: URL?

    /// The last title the page reported, or the persisted one for a tab that has not loaded yet.
    public internal(set) var title: String

    /// `nil` until this tab is first selected.
    public internal(set) var web: BrowserWebTab?

    /// What the tab strip draws. A tab that has neither a title nor a URL is a new tab, and saying
    /// so is better than an empty strip item the user cannot aim at.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        if let url { return url.absoluteString }
        return "New Tab"
    }

    init(id: UUID = UUID(), url: URL?, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// The window-wide tab set: the live tabs, their order, the selection, and every operation the
/// chrome performs on them (Q5).
///
/// **One instance per `BrowserTab`, which the app registers once** (Q20). It is owned by the tab
/// and never by a `PanelTabSession`, of which X7 creates one per (tab, channel). That is what makes
/// root item 39 — open a page, switch channels and back, unchanged — structural rather than lucky:
/// there is no code path on which a channel switch could produce a second web view, because there
/// is one place a web view can be created and a session is not it.
///
/// It owns the `BrowserTabStore` and drives Q6's persistence: a structural change (a tab opened,
/// closed, reordered or selected) writes at once, and a URL or title arriving from a settled
/// navigation goes through the store's trailing window.
@Observable
@MainActor
public final class BrowserModel {

    /// Where the user asked a URL to go.
    public enum OpenDestination: Sendable, Equatable {
        case currentTab
        case newTab

        /// Quick-open's Enter and Cmd-Enter (Q8). The mapping is here, and not spelled out at the
        /// keyboard shortcut, so that what the sheet does with a modifier is a thing a test can
        /// fail on rather than a thing SwiftUI does off-screen.
        public static func quickOpenSubmission(commandHeld: Bool) -> OpenDestination {
            commandHeld ? .newTab : .currentTab
        }
    }

    public private(set) var tabs: [BrowserLiveTab] = []
    public private(set) var selectedID: UUID?

    /// Which surface the web views are attached to (Q5).
    ///
    /// An `NSView` has one superview, so the same `WKWebView` cannot be rendered in the main panel
    /// and in a popped-out Browser window at once. The views follow the pop-out, and the surface
    /// they left draws a short state instead of a second, silently different browser. One web view
    /// per surface was rejected: two loads of every page, two sets of scroll and form state, and a
    /// "shared browser" that is not one. X7's `PanelSurface` is what makes the two surfaces
    /// distinguishable at all (D52).
    public private(set) var attachedTo: PanelSurface = .panel

    /// A refusal the user is owed an answer about — a `file:` link, a `javascript:` or `data:` URL
    /// — as one line of copy. Cleared by the next navigation the panel accepts.
    public internal(set) var notice: String?

    /// What the URL bar says under itself when what was typed is not a URL. Q9's row 6; there is no
    /// web-search fallback and there must never be one.
    public internal(set) var urlBarMessage: String?

    /// The tab-set document's own trouble, mirrored out of the store so the panel can show a row.
    public private(set) var storeError: BrowserTabStoreError?

    /// A link the panel could not open: a pull request with no channel, in no repository, with no
    /// `gh`, or with a `gh` that is not signed in (Q2, §10). It is a **row**, never an exception —
    /// a link that fails to resolve must not take the channel down — and it is cleared by the next
    /// navigation the panel accepts, like every other notice here.
    public private(set) var linkError: BrowserLinkError?

    /// Called after the model has taken a settled navigation's URL and title. It exists so no wait
    /// in this leaf's tests is a sleep, and so a later surface can follow navigations without the
    /// model growing a listener list (D32's shape, one level up).
    public var didSettleNavigation: (@MainActor (BrowserLiveTab) -> Void)?

    private let store: BrowserTabStore
    private let factory: BrowserWebViewFactory
    private let openExternally: BrowserWebTab.ExternalOpener

    /// The one restoration, shared by every caller. See `restore`.
    private var restoreTask: Task<Void, Never>?

    /// Set once the persisted set has been installed. What `restoreTask` alone cannot say is
    /// whether the read has *landed*, which is the difference between a mutation that may run now
    /// and one that has to wait (D57).
    private var isRestored = false

    /// Mutations deferred behind the restoration, in the order they were made. A chain and not a
    /// task apiece: two controls used in the same breath must reach the set in the order the user
    /// used them, and joining the same task twice promises nothing about which continuation runs
    /// first.
    private var gateChain: Task<Void, Never>?

    /// Persistence runs in order behind this chain. The store is an actor and each commit is a hop,
    /// so two commits spawned independently could reach it in either order — and the one that lost
    /// would be the panel's truth.
    private var persistChain: Task<Void, Never> = Task {}

    /// How many pieces of work this model has ever enqueued behind either chain: a mutation
    /// deferred by `gated`, and a commit appended by `commit`. A drain reads it before it suspends
    /// and again when it wakes, because neither chain it sampled is necessarily the chain it will
    /// find on the other side of the suspension: see `isQuiescent(since:)`.
    private var enqueuedWork = 0

    /// How many times the user has changed what "the current tab" means or what it is showing: a
    /// tab selected, opened, closed, or navigated from the URL bar. A request that has to leave the
    /// main actor before it can act reads this first and offers it back when it returns, and a
    /// value that has moved is the whole of "somebody got there while I was away" (D61).
    ///
    /// It is not a version of the tab set. `performRestore` does not touch it — the restoration is
    /// not something the user did, and a link that arrived before the read is still meant for the
    /// tab the read produces (A1).
    private var navigationGeneration = 0

    /// What the user's next action would supersede. Read by a caller that is about to suspend.
    var currentNavigationGeneration: Int { navigationGeneration }

    /// How many gated mutations are still waiting to run. It is what keeps the order the user made
    /// them in across the restoration boundary: while any of them is queued, one made *after* the
    /// restoration landed has to queue too, or it would overtake them (D59).
    private var gatedOperationsOutstanding = 0

    public init(store: BrowserTabStore,
                factory: BrowserWebViewFactory,
                openExternally: @escaping BrowserWebTab.ExternalOpener = BrowserWebTab.systemOpener) {
        self.store = store
        self.factory = factory
        self.openExternally = openExternally
    }

    // MARK: What the chrome reads

    public var selected: BrowserLiveTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    /// The six values the URL bar, the progress line and the back/forward pair need, or `nil` when
    /// no tab is loaded.
    public var chrome: BrowserChromeState? { selected?.web?.chrome }

    /// No tabs at all: the panel draws its empty state.
    public var isEmpty: Bool { tabs.isEmpty }

    /// Whether `surface` is the one that draws the web views right now (Q5). The other surface
    /// draws the short "Showing in the Browser window" state and a control that brings them back.
    public func rendersWebViews(on surface: PanelSurface) -> Bool {
        attachedTo == surface
    }

    /// Moves the web views to `surface`. The "Bring them back here" control, and the one place the
    /// attachment is chosen deliberately rather than by a window appearing or going away.
    public func attach(to surface: PanelSurface) {
        panelLeftHoldingPages = false
        attachedTo = surface
    }

    /// Every surface drawing this panel right now, oldest first. It is what makes "a surface that
    /// is actually on screen" answerable at all: the pages have to go somewhere when the one
    /// holding them goes away, and `.panel` is a guess rather than an answer (D58).
    private var liveSurfaces: [PanelSurface] = []

    /// Set when the main panel goes away *holding* the pages and they move to a surface that is
    /// still drawing. It is what tells a panel that is coming back from a channel switch apart
    /// from one that never had them (D61).
    ///
    /// Cleared by anything that claims the pages deliberately — a window appearing, or the "Bring
    /// them back here" control — because the panel takes back what it was holding and never what
    /// something else has asked for since.
    private var panelLeftHoldingPages = false

    /// A surface began drawing this panel.
    ///
    /// **A pop-out claims the web views; the main panel does not.** The panel is on screen for as
    /// long as the window is, so a panel that claimed on appearance would take the views back from
    /// a pop-out window the moment anything re-rendered the column — which is the whole of what a
    /// pop-out is for. The pop-out is the deliberate act, so it is the one that moves them. Two
    /// pop-outs are two windows and two claimants, and the newest one is the one the user just
    /// asked for.
    /// **The one thing the panel does claim is what it was holding when it went away** (D61).
    /// `PanelHostModel.view` keys the subtree by (tab, channel), so a channel switch destroys this
    /// panel's surface and builds another one in its place — a disappearance and an appearance,
    /// not a re-render. The departing panel hands the pages to a pop-out that is still drawing, so
    /// without this a channel switch silently undid the user's own "Bring them back here" and left
    /// the main panel on the "elsewhere" placeholder for the rest of the session.
    public func surfaceAppeared(_ surface: PanelSurface) {
        liveSurfaces.removeAll { $0 == surface }
        liveSurfaces.append(surface)
        guard surface != .panel else {
            guard panelLeftHoldingPages else { return }
            panelLeftHoldingPages = false
            attachedTo = .panel
            return
        }
        panelLeftHoldingPages = false
        attachedTo = surface
    }

    /// A surface stopped drawing this panel — a window closed, or the panel column switched to
    /// another tab. If it was holding the web views they move to a surface that is still drawing,
    /// newest first, and to the main panel when none is (D58).
    ///
    /// Handing them unconditionally back to `.panel` is what stranded them: the panel is one of the
    /// surfaces that can go away, and a window plainly on screen was left drawing the "elsewhere"
    /// state with no way back but the user's own hand.
    public func surfaceDisappeared(_ surface: PanelSurface) {
        liveSurfaces.removeAll { $0 == surface }
        guard attachedTo == surface else { return }
        let next = liveSurfaces.last ?? .panel
        // Remembered only when the pages actually leave: a panel that goes away with nothing else
        // on screen keeps them, and has nothing to take back.
        if surface == .panel, next != .panel { panelLeftHoldingPages = true }
        attachedTo = next
    }

    // MARK: Restore (Q7)

    /// Reads the persisted set and builds the tabs, loading **only** the selected one.
    ///
    /// **One restoration, and every caller joins it.** The panel is rendered once per channel and
    /// every one of them asks; a routed link asks too, before it touches the set. A guard that
    /// merely returned early would let the second caller run *in front of* the read the first is
    /// still waiting on — and this method replaces the whole tab set, so whatever that caller did
    /// would be thrown away, or would publish a set the store never saw. The task is what makes
    /// "already restoring" and "restored" the same answer to a caller.
    public func restore() async {
        await restoring().value
    }

    private func restoring() -> Task<Void, Never> {
        if let restoreTask { return restoreTask }
        let task = Task { @MainActor in await self.performRestore() }
        restoreTask = task
        return task
    }

    private func performRestore() async {
        // Installed before the read, so the row the panel shows follows every write from here on
        // and not only the ones a commit happened to sample (D50).
        await store.observeErrors { [weak self] error in
            await MainActor.run { self?.storeError = error }
        }
        let set = await store.load()
        storeError = await store.lastError
        // A persisted destination the policy will not load in the panel is dropped rather than
        // dispatched: `activate` navigates with the URL bar's authority, and a restore must not
        // mint the strongest authority in this design (D48). The tab stays, so the set the user
        // left behind is still the set that comes back.
        let restored = set.tabs.map {
            BrowserLiveTab(id: $0.id, url: Self.destinationForPanel($0.url), title: $0.title)
        }
        // Nothing has touched this set: every mutation the panel can make waits for this method
        // (see `gated`), which is what lets it replace `tabs` whole (D49, D57).
        tabs = restored
        isRestored = true
        guard let index = set.selection, restored.indices.contains(index) else { return }
        selectedID = restored[index].id
        activate(restored[index])
    }

    /// Runs `operation` once the restoration has landed **and every mutation made before it has
    /// run**, or now if there is neither to wait for.
    ///
    /// **Every mutation that can enqueue persistence goes through here, not only the routed one.**
    /// `performRestore` replaces the tab set whole, so a mutation made in front of the read it is
    /// waiting on is a mutation the read throws away — in memory and, through the structural write
    /// it enqueued, on disk as well. The user's `+` is as fast as a link (D57).
    ///
    /// **The restoration landing does not open a door beside the queue** (D59). `performRestore`
    /// installs the set and marks itself restored before the operations suspended behind it resume,
    /// so a gate that asked only "has the read landed" would run a mutation made *after* it in
    /// front of ones made before — a routed open of the current tab navigating the restored
    /// selection before an earlier New Tab had run, which puts the link in the wrong tab. While any
    /// mutation is still queued, a new one queues behind it; the queue drains in the order the user
    /// made them, and only an empty queue is passed straight through.
    ///
    /// *The controls are not disabled instead.* A disabled tab strip would flicker for the length
    /// of one store read on every channel switch, and it would drop a keystroke rather than delay
    /// it: deferring keeps the user's action, which is the honest half of the two.
    private func gated(_ operation: @escaping @MainActor () -> Void) {
        // Closed is closed (D61): after the quit drain nothing may enqueue work the drain cannot
        // have waited for.
        guard !isClosed else { return }
        guard !isRestored || gatedOperationsOutstanding > 0 else { return operation() }
        // **A mutation nobody has restored for starts the restoration.** Joining one that has
        // already been asked for is not enough: the first thing a mutation does is enqueue a
        // structural write, so a set mutated in front of the read has already replaced the
        // document the read was about to return — the saved tabs are gone from disk before
        // anything in memory could put them back (measured; wave A found the same shape on the
        // routed path). Restoration is therefore the first thing that happens to this set, from
        // whichever door the mutation came through.
        let restoration = restoring()
        let previous = gateChain
        gatedOperationsOutstanding += 1
        enqueuedWork += 1
        gateChain = Task { @MainActor in
            if let previous {
                await previous.value
            } else {
                await restoration.value
            }
            operation()
            self.gatedOperationsOutstanding -= 1
        }
    }

    /// Opens `url` on behalf of a `LinkTarget`, behind the restoration.
    ///
    /// A link can arrive before the Browser tab has ever been drawn, so this is the entry point
    /// that orders the two: a structural write made in front of an unfinished read is a write the
    /// read then overwrites, in memory and on disk both (A1).
    ///
    /// **It takes the same queue as the panel's own controls and not a second waiter on the
    /// restoration** (D59). Awaiting the read on its own account would put this link in a race with
    /// every mutation already queued behind that read, and the loser is decided by which
    /// continuation the runtime resumes first. It joins at the back of the queue, where it was made,
    /// and returns when the queue has run that far — which is what a routing target awaits.
    /// **A request that had to wait for an answer does not take a tab the user has since aimed**
    /// (D61). `supersededSince` is the navigation generation the request was made at — the
    /// `.pullRequest` route reads it before it runs `gh`, which is a process and can take as long
    /// as one. If the user selected another tab, opened one, closed one or submitted a URL while
    /// that ran, `.currentTab` no longer means the tab the click was made in, and navigating it
    /// would replace a page the user just chose and persist the replacement. The click is still
    /// honoured, in a tab of its own: a page the user asked for is not something to discard.
    ///
    /// The comparison is made where the operation runs and not where it is enqueued, so a mutation
    /// still queued behind the restoration counts exactly like one that has already run.
    func openRouted(_ url: URL, in destination: OpenDestination,
                    supersededSince generation: Int? = nil) async {
        gated {
            let superseded = generation.map { $0 != self.navigationGeneration } ?? false
            self.performOpen(url, in: superseded ? .newTab : destination)
        }
        await gateChain?.value
    }

    // MARK: The operations

    /// Opens a tab, selects it, and loads `url` if there is one. `nil` is the `+` control and Cmd-T.
    public func openNewTab(url: URL?) {
        gated { self.insertNewTab(url: url) }
    }

    /// `openNewTab` once the restoration has landed. It answers the tab it made, which the gated
    /// entry point cannot: a deferred call has no tab to hand back yet.
    @discardableResult
    func insertNewTab(url: URL?) -> BrowserLiveTab {
        // The tab remembers only a destination the policy loads here (D48). `activate` navigates
        // to whatever it remembers, so anything else would be persisted and then dispatched again
        // at the next launch with the URL bar's authority behind it.
        let tab = BrowserLiveTab(url: url.flatMap(Self.destinationForPanel), title: "")
        tabs.append(tab)
        selectedID = tab.id
        navigationGeneration += 1
        clearNotices()
        activate(tab)
        // A destination the tab does not keep is still answered — refused with a notice, or handed
        // to the system opener — exactly once, and by the same policy.
        if let url, tab.url == nil { tab.web?.navigate(to: url) }
        persistStructure()
        return tab
    }

    /// The destination a tab may remember: one `NavigationPolicy` loads in the panel, and nothing
    /// else. `nil` for a URL the policy refuses or hands to the system.
    static func destinationForPanel(_ url: URL) -> URL? {
        NavigationPolicy.decide(.urlBarEntry(url)) == .allow ? url : nil
    }

    public func open(_ url: URL, in destination: OpenDestination) {
        gated { self.performOpen(url, in: destination) }
    }

    private func performOpen(_ url: URL, in destination: OpenDestination) {
        switch destination {
        case .newTab:
            insertNewTab(url: url)
        case .currentTab:
            guard let tab = selected else {
                insertNewTab(url: url)
                return
            }
            clearNotices()
            activate(tab)
            navigationGeneration += 1
            // Set before the load, so a page that never finishes still leaves the tab pointing at
            // what the user asked for; the settled navigation corrects it either way. Only if the
            // policy loads it here, though — a refused or externally-opened destination leaves the
            // tab where it was rather than becoming what a relaunch dispatches (D48).
            if let kept = Self.destinationForPanel(url) { tab.url = kept }
            tab.web?.navigate(to: url)
            persistEdit()
        }
    }

    public func select(_ id: UUID) {
        gated { self.performSelect(id) }
    }

    private func performSelect(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        navigationGeneration += 1
        activate(tab)
        persistStructure()
    }

    public func close(_ id: UUID) {
        gated { self.performClose(id) }
    }

    private func performClose(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        navigationGeneration += 1
        if selectedID == id {
            // The tab that took the closed one's position, or the last one if it was the last.
            let next = min(index, tabs.count - 1)
            selectedID = tabs.indices.contains(next) ? tabs[next].id : nil
            if let tab = selected { activate(tab) }
        }
        persistStructure()
    }

    /// Moves the tab at `origin` so that it sits at `destination` in the resulting order.
    public func move(from origin: Int, to destination: Int) {
        gated { self.performMove(from: origin, to: destination) }
    }

    private func performMove(from origin: Int, to destination: Int) {
        guard tabs.indices.contains(origin), tabs.indices.contains(destination), origin != destination
        else { return }
        let tab = tabs.remove(at: origin)
        tabs.insert(tab, at: destination)
        persistStructure()
    }

    public func goBack() { selected?.web?.goBack() }
    public func goForward() { selected?.web?.goForward() }
    public func reload() { selected?.web?.reload() }

    /// What the toolbar's one round control does, decided here rather than at the control: the
    /// button's label already says "stop" while a page is loading, and which of the two actions
    /// that label stands for is a thing a test can fail on.
    public func reloadOrStop() {
        if chrome?.isLoading == true {
            selected?.web?.stopLoading()
        } else {
            reload()
        }
    }

    /// The URL bar's entry path: Q9's table, then `NavigationPolicy` (D29 — the bar parses, the
    /// policy decides). A string that is not a URL goes nowhere and says so.
    public func submitURLBar(_ raw: String) {
        switch URLInput.normalize(raw) {
        case .empty:
            urlBarMessage = nil
        case .notAURL:
            urlBarMessage = "That is not a URL."
        case .url(let url):
            urlBarMessage = nil
            open(url, in: .currentTab)
        }
    }

    /// Returns once every commit made so far has reached the store. Nothing in the panel needs
    /// this; a test that must tell "the coalescer is holding this edit" from "the edit has not
    /// arrived yet" does, and a seam is cheaper than a sleep (D24's reasoning, one level up).
    func persistenceSettled() async {
        // The gate first: a mutation waiting on the restoration has not made its commit yet, so a
        // settle that looked only at the chain would answer about the commits before it.
        await gateChain?.value
        await persistChain.value
    }

    /// Writes whatever the coalescer is holding, now. The panel calls this when it is going away,
    /// so a title that arrived in the last half-second is not the one thing a relaunch forgets.
    ///
    /// **It is a drain and not a sequence of waits**, and it is the store's drain one level up.
    /// Each wait below is a suspension and this actor is free during them: a mutation deferred at
    /// the gate, and a commit appended to the persistence chain, can both arrive while this call is
    /// asleep. A commit that arrives there has *not* reached the store — it waits for its
    /// predecessor first — so the store's own drain finds nothing pending and nothing in flight and
    /// returns, and a flush that took that for an answer would return in front of it. `QuitGuard`
    /// drains exactly once, so what this returns in front of is what G3 loses at quit.
    public func flush() async {
        while true {
            let observed = enqueuedWork
            // The gate first: a mutation waiting on the restoration has not made its commit yet, so
            // a flush that waited only on the chain would write the set from before the last thing
            // the user did (D57).
            await gateChain?.value
            await persistChain.value
            await store.flushPendingEdits()
            if isQuiescent(since: observed) { return }
        }
    }

    /// **Closes this panel to new persistence work, and then drains what is left** (D61).
    ///
    /// What `QuitGuard` calls, and the reason `flush` alone was not enough: the drain returns, and
    /// the app then awaits `shutdownForQuit()`, which suspends several times. `trackChrome` is
    /// running through all of it — a page's title reaches the web view runloop turns after its
    /// navigation settles — so an edit submitted after the drain sat in the coalescer's trailing
    /// window until the process exited under it. A drain is a moment, and a moment cannot be the
    /// last word while the thing it drains is still accepting work.
    ///
    /// Closing before draining, and not draining twice: a second drain is the same moment again,
    /// one suspension later, and the work that outruns the first outruns the second for exactly the
    /// same reason. What is refused after this is a mutation the user cannot see the result of —
    /// the app is on its way out — and refusing it is what makes the document the app leaves behind
    /// the one the drain wrote.
    public func closeForQuit() async {
        isClosed = true
        await flush()
    }

    /// Set by `closeForQuit`, never cleared: the process is exiting, and a panel that reopened
    /// would be a panel writing behind the drain that closed it.
    public private(set) var isClosed = false

    /// The condition a drain returns on: nothing has been enqueued since `observed` was read, so
    /// the two chains this call just waited out are still the whole of them and the store has been
    /// drained behind them. Anything else means work arrived while it was suspended, and a drain
    /// that has not seen a piece of work cannot have waited for it.
    private func isQuiescent(since observed: Int) -> Bool {
        enqueuedWork == observed
    }

    // MARK: The one place a web view is created

    private func activate(_ tab: BrowserLiveTab) {
        guard tab.web == nil else { return }
        let web = BrowserWebTab(id: tab.id,
                                factory: factory,
                                openExternally: openExternally,
                                openInNewPanelTab: { [weak self] url in
                                    MainActor.assumeIsolated { self?.openNewTab(url: url) }
                                },
                                report: { [weak self] reason, _ in
                                    MainActor.assumeIsolated { self?.report(reason) }
                                })
        web.navigationDidSettle = { [weak self] settled in
            self?.settled(settled)
        }
        tab.web = web
        trackChrome(web)
        if let url = tab.url { web.navigate(to: url) }
    }

    /// A navigation finished or failed: what the page ended up on becomes the tab's, and the
    /// settle callback fires.
    private func settled(_ web: BrowserWebTab) {
        recordPageState(web)
        guard let tab = tabs.first(where: { $0.id == web.id }) else { return }
        didSettleNavigation?(tab)
    }

    /// Follows the chrome's URL and title, re-arming after every change.
    ///
    /// **`didFinish` is not when the title is known.** A page's `title` reaches the web view some
    /// runloop turns after the navigation settles, so a model that committed only at the settle
    /// would persist every page under the title of the one before it — measured, and the reason
    /// this exists rather than a single commit in `settled`. Q6 already expects several commits per
    /// navigation; that is what the store's trailing window is for.
    private func trackChrome(_ web: BrowserWebTab) {
        withObservationTracking {
            _ = web.chrome.url
            _ = web.chrome.title
        } onChange: { [weak self, weak web] in
            Task { @MainActor in
                guard let self, let web else { return }
                self.recordPageState(web)
                self.trackChrome(web)
            }
        }
    }

    /// The URL and title the page is on, into the tab and through Q6's trailing window.
    private func recordPageState(_ web: BrowserWebTab) {
        guard let tab = tabs.first(where: { $0.id == web.id }) else { return }
        var changed = false
        if let url = web.chrome.url, url != tab.url {
            tab.url = url
            changed = true
        }
        if let title = web.chrome.title, title != tab.title {
            tab.title = title
            changed = true
        }
        guard changed else { return }
        persistEdit()
    }

    /// Records a link the panel could not open. Called by `BrowserLinkTargets`; the row it sets is
    /// the whole of what a failed `.pullRequest` lookup does to the app (§10).
    func reportLinkError(_ error: BrowserLinkError) {
        linkError = error
    }

    /// Every line the panel shows under the URL bar, dropped together. A navigation the panel
    /// accepted answers all of them at once, and a notice left behind by an earlier link would read
    /// as being about the page now on screen.
    private func clearNotices() {
        notice = nil
        urlBarMessage = nil
        linkError = nil
    }

    private func report(_ reason: NavigationPolicy.Reason) {
        guard !reason.isDiagnosticOnly else { return }
        notice = Self.copy(for: reason)
    }

    /// What the panel shows about a load that ended without a page, or `nil` when the selected tab
    /// is not on one. Derived from the selected tab's chrome rather than stored, so it follows the
    /// selection and is cleared by that tab's next navigation without anything having to remember
    /// to clear it (§10 — a failed load is ordinary, so it is a row and never an alert).
    public var loadFailureMessage: String? {
        chrome?.failure.map(Self.copy(for:))
    }

    /// One line for each way a load can end without a page. It names what happened and never the
    /// URL, for the reason every other line in this panel does not.
    static func copy(for failure: BrowserLoadFailure) -> String {
        switch failure {
        case .cannotConnect:
            "That page could not be loaded: nothing answered."
        case .hostNotFound:
            "That page could not be loaded: the address has no host."
        case .insecureConnection:
            "That page could not be loaded: its connection could not be secured."
        case .timedOut:
            "That page took too long to answer."
        case .other:
            "That page could not be loaded."
        }
    }

    /// What the panel shows about the tab-set document, or `nil` when there is nothing to say.
    ///
    /// A panel-local state and not an alert (§10): the tabs still work, and what the user needs to
    /// know is that they are not being kept.
    public var storeErrorMessage: String? {
        storeError.map(Self.copy(for:))
    }

    /// One line for each way the document can be trouble. It names a kind and never a path, a key
    /// or an underlying error, for the reason `BrowserTabStoreError` itself does.
    static func copy(for error: BrowserTabStoreError) -> String {
        switch error {
        case .documentFromANewerBuild:
            "A newer version of afleet saved these tabs. Nothing opened here is being saved."
        case .documentUnreadable:
            "The saved tabs could not be read, so this window started empty."
        case .writeFailed:
            "These tabs are not being saved right now."
        }
    }

    /// One line for a refusal the user is owed an answer about. It names the scheme and never the
    /// URL: a diagnostic is allowed to say what happened, not to publish what it happened to.
    static func copy(for reason: NavigationPolicy.Reason) -> String {
        switch reason {
        case .localFile:
            "Local files open in the Files tab."
        case .executableOrInlineContent(let scheme):
            "A \(scheme): URL cannot be opened here."
        case .externalSchemeFromPageContent(let scheme):
            "A \(scheme): URL cannot be opened here."
        case .unsupportedURL:
            "That URL cannot be opened here."
        }
    }

    // MARK: Persistence (Q6)

    /// The document this set would be persisted as.
    ///
    /// A tab with no URL is skipped: it has no page to restore. The selection then has to land on
    /// something that survived, so it clamps back onto the last persisted tab before it — the same
    /// rule D23 applies to the dropped prefix, and for the same reason: reopening on *a* page beats
    /// reopening on none.
    func snapshot() -> BrowserTabSet {
        var persisted: [PersistedTab] = []
        var selection: Int?
        for tab in tabs {
            guard let url = tab.url else {
                if tab.id == selectedID { selection = max(0, persisted.count - 1) }
                continue
            }
            if tab.id == selectedID { selection = persisted.count }
            persisted.append(PersistedTab(id: tab.id, url: url, title: tab.title))
        }
        guard !persisted.isEmpty else { return .empty }
        return BrowserTabSet(tabs: persisted, selection: min(selection ?? 0, persisted.count - 1))
    }

    private func persistStructure() {
        commit { store, set in await store.commitStructuralChange(set) }
    }

    private func persistEdit() {
        commit { store, set in await store.commitEdit(set) }
    }

    private func commit(_ body: @escaping @Sendable (BrowserTabStore, BrowserTabSet) async -> Void) {
        // The barrier's other door, and the one the finding is about: `recordPageState` reaches
        // this directly from `trackChrome`, with no gate in front of it (D61).
        guard !isClosed else { return }
        let set = snapshot()
        let store = store
        enqueuedWork += 1
        persistChain = Task { [previous = persistChain] in
            await previous.value
            await body(store, set)
            let error = await store.lastError
            await MainActor.run { self.storeError = error }
        }
    }
}
