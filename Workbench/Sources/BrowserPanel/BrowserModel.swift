import Foundation
import Observation
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

/// Which surface currently holds the web views.
///
/// An `NSView` has one superview, so the same `WKWebView` cannot be rendered in the main panel and
/// in a popped-out Browser window at once (Q5). The views follow the pop-out, and the surface they
/// left draws a short "Showing in the Browser window" state instead of a second, silently different
/// browser. One web view per surface was rejected: two loads of every page, two sets of scroll and
/// form state, and a "shared browser" that is not one.
public enum BrowserSurface: String, Sendable, Equatable, CaseIterable {
    case panel
    case poppedOutWindow
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
    public private(set) var attachedTo: BrowserSurface = .panel

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

    /// Persistence runs in order behind this chain. The store is an actor and each commit is a hop,
    /// so two commits spawned independently could reach it in either order — and the one that lost
    /// would be the panel's truth.
    private var persistChain: Task<Void, Never> = Task {}

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
    public func rendersWebViews(on surface: BrowserSurface) -> Bool {
        attachedTo == surface
    }

    public func attach(to surface: BrowserSurface) {
        attachedTo = surface
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
        tabs = set.tabs.map {
            BrowserLiveTab(id: $0.id, url: Self.destinationForPanel($0.url), title: $0.title)
        }
        guard let index = set.selection, tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
        activate(tabs[index])
    }

    /// Opens `url` on behalf of a `LinkTarget`, behind the restoration.
    ///
    /// A link can arrive before the Browser tab has ever been drawn, so this is the entry point
    /// that orders the two: a structural write made in front of an unfinished read is a write the
    /// read then overwrites, in memory and on disk both (A1).
    func openRouted(_ url: URL, in destination: OpenDestination) async {
        await restore()
        open(url, in: destination)
    }

    // MARK: The operations

    /// Opens a tab, selects it, and loads `url` if there is one. `nil` is the `+` control and Cmd-T.
    @discardableResult
    public func openNewTab(url: URL?) -> BrowserLiveTab {
        // The tab remembers only a destination the policy loads here (D48). `activate` navigates
        // to whatever it remembers, so anything else would be persisted and then dispatched again
        // at the next launch with the URL bar's authority behind it.
        let tab = BrowserLiveTab(url: url.flatMap(Self.destinationForPanel), title: "")
        tabs.append(tab)
        selectedID = tab.id
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
        switch destination {
        case .newTab:
            openNewTab(url: url)
        case .currentTab:
            guard let tab = selected else {
                openNewTab(url: url)
                return
            }
            clearNotices()
            activate(tab)
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
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        activate(tab)
        persistStructure()
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
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
        guard tabs.indices.contains(origin), tabs.indices.contains(destination), origin != destination
        else { return }
        let tab = tabs.remove(at: origin)
        tabs.insert(tab, at: destination)
        persistStructure()
    }

    public func goBack() { selected?.web?.goBack() }
    public func goForward() { selected?.web?.goForward() }
    public func reload() { selected?.web?.reload() }

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
        await persistChain.value
    }

    /// Writes whatever the coalescer is holding, now. The panel calls this when it is going away,
    /// so a title that arrived in the last half-second is not the one thing a relaunch forgets.
    public func flush() async {
        await persistChain.value
        await store.flushPendingEdits()
    }

    // MARK: The one place a web view is created

    private func activate(_ tab: BrowserLiveTab) {
        guard tab.web == nil else { return }
        let web = BrowserWebTab(id: tab.id,
                                factory: factory,
                                openExternally: openExternally,
                                openInNewPanelTab: { [weak self] url in
                                    MainActor.assumeIsolated { _ = self?.openNewTab(url: url) }
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
        let set = snapshot()
        let store = store
        persistChain = Task { [previous = persistChain] in
            await previous.value
            await body(store, set)
            let error = await store.lastError
            await MainActor.run { self.storeError = error }
        }
    }
}
