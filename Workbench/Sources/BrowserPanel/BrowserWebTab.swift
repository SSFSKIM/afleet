import AppKit
import Foundation
import Observation
import WebKit

/// What the chrome draws: the six `WKWebView` properties a URL bar, a progress line and a
/// back/forward pair need, mirrored out of KVO into observable state.
///
/// It is a separate type from the tab on purpose. The tab is an `NSObject` because WebKit's
/// delegates are `@objc` protocols; observation is a property of the state, and keeping the two
/// apart means the chrome depends on six values rather than on a delegate.
@Observable
@MainActor
public final class BrowserChromeState {

    public internal(set) var url: URL?
    public internal(set) var title: String?
    public internal(set) var estimatedProgress: Double = 0
    public internal(set) var canGoBack = false
    public internal(set) var canGoForward = false
    public internal(set) var isLoading = false

    public init() {}
}

/// One web view, its two delegates, and its chrome state.
///
/// The delegates are a **thin adapter** and nothing else: they translate WebKit's navigation action
/// into this module's own `NavigationRequest` and do what `NavigationPolicy.decide` says. No WebKit
/// type appears in the policy's signature, which is what makes the policy exhaustively testable —
/// grounding probe 3 measured that a synthesised DOM click reaches `decidePolicyFor` with no
/// modifier flags and not as `.linkActivated`, so a Cmd-click test driven through a real web view
/// would be a test that cannot fail.
///
/// Both ways out of the panel are injected. The external opener defaults to
/// `NSWorkspace.shared.open`, and no test is ever given that default: a test that launched a browser
/// would open a window on somebody's screen. `openInNewPanelTab` is filled by the model at M4; until
/// then it is a closure the caller supplies.
@MainActor
public final class BrowserWebTab: NSObject {

    /// Hands a URL to the system — the user's real browser, or whichever application claims the
    /// scheme. Injected, always.
    public typealias ExternalOpener = @Sendable (URL) -> Void

    /// Asks the owner to open a new tab in this panel on that URL. `target="_blank"` and
    /// `window.open` are ordinary browsing, not an escape; making them a Safari window would make
    /// half the web unusable in the panel (Q11).
    public typealias NewPanelTabRequest = @Sendable (URL) -> Void

    /// A navigation that went nowhere, and why. The panel shows the reasons that are not
    /// `isDiagnosticOnly` and logs the rest; the URL is passed for the log line's sake and is never
    /// published by the reason itself.
    public typealias RefusalReport = @Sendable (NavigationPolicy.Reason, URL) -> Void

    public let id: UUID
    public let webView: WKWebView
    public let chrome = BrowserChromeState()

    /// Called when a navigation finishes or fails. The model commits the URL and title to the
    /// persisted tab set from here at M4; the tests wait on it, so no wait in this leaf is a sleep.
    public var navigationDidSettle: (@MainActor (BrowserWebTab) -> Void)?

    private let openExternally: ExternalOpener
    private let openInNewPanelTab: NewPanelTabRequest
    private let report: RefusalReport
    private var observations: [NSKeyValueObservation] = []

    /// The production default: the user's own browser, or the application that claims the scheme.
    /// Only reachable when `NavigationPolicy` returned `.openExternally`, which `javascript:`,
    /// `data:` and `file:` never do (D29, Q10).
    public static let systemOpener: ExternalOpener = { url in
        MainActor.assumeIsolated {
            _ = NSWorkspace.shared.open(url)
        }
    }

    public init(id: UUID = UUID(),
                factory: BrowserWebViewFactory,
                openExternally: @escaping ExternalOpener = BrowserWebTab.systemOpener,
                openInNewPanelTab: @escaping NewPanelTabRequest,
                report: @escaping RefusalReport = { _, _ in }) {
        self.id = id
        self.webView = factory.makeWebView()
        self.openExternally = openExternally
        self.openInNewPanelTab = openInNewPanelTab
        self.report = report
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeChrome()
    }

    // MARK: What the chrome can ask for

    /// Loads `url` as a URL bar entry — a user gesture, and answered by the same policy a link is
    /// (D29: one rule, in one place).
    public func navigate(to url: URL) {
        act(on: NavigationPolicy.decide(.urlBarEntry(url)), for: url) { [webView] in
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func reload() { webView.reload() }

    // MARK: The chrome state

    /// Mirrors the six KVO properties. `.initial` so a tab that is handed a web view mid-load does
    /// not start out claiming an empty URL and no progress.
    private func observeChrome() {
        let chrome = chrome
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.url = view.url }
            },
            webView.observe(\.title, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.title = view.title }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.estimatedProgress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { chrome.isLoading = view.isLoading }
            },
        ]
    }

    // MARK: The one place a decision is acted on

    private func act(on decision: NavigationPolicy.Decision,
                     for url: URL,
                     allow: () -> Void) {
        switch decision {
        case .allow: allow()
        case .openExternally(let target): openExternally(target)
        case .newPanelTab(let target): openInNewPanelTab(target)
        case .refuse(let reason): report(reason, url)
        }
    }

    /// What WebKit is told, for a decision. A named function rather than an expression inside the
    /// delegate, because it is the one thing about the adapter a test cannot otherwise read: every
    /// scheme the policy refuses is also one WebKit would decline to load, so "the tab did not move"
    /// cannot tell a `.cancel` from an `.allow`, and `WKNavigationAction` cannot be constructed to
    /// ask the delegate directly (measured: it traps).
    static func answer(to decision: NavigationPolicy.Decision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow: .allow
        case .openExternally, .newPanelTab, .refuse: .cancel
        }
    }

    /// WebKit's navigation action, as the value types the policy is written over.
    ///
    /// `isUserInitiated` is the one judgement here. WebKit publishes no "a person did this" flag, so
    /// it is read from the navigation type: a link activation and a form submission are things a
    /// person did, and everything else — a redirect, a `location =`, an app-initiated load — is not.
    /// A URL bar entry does not come through here at all; it is built by
    /// `NavigationRequest.urlBarEntry`.
    private static func request(from action: WKNavigationAction, url: URL) -> NavigationRequest {
        let type: BrowserNavigationType = switch action.navigationType {
        case .linkActivated: .linkActivated
        case .formSubmitted: .formSubmitted
        case .backForward: .backForward
        case .reload: .reload
        case .formResubmitted: .formResubmitted
        default: .other
        }
        var modifiers: BrowserModifierFlags = []
        if action.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if action.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if action.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if action.modifierFlags.contains(.control) { modifiers.insert(.control) }

        let byHand = type == .linkActivated || type == .formSubmitted || type == .formResubmitted
        return NavigationRequest(url: url,
                                 navigationType: type,
                                 modifierFlags: modifiers,
                                 hasTargetFrame: action.targetFrame != nil,
                                 isUserInitiated: byHand)
    }
}

// MARK: - The adapter

extension BrowserWebTab: WKNavigationDelegate {

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let decision = NavigationPolicy.decide(Self.request(from: navigationAction, url: url))
        // The handler is called before anything else happens, so no branch below can leave WebKit
        // waiting on a decision it was already owed.
        decisionHandler(Self.answer(to: decision))
        act(on: decision, for: url, allow: {})
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationDidSettle?(self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationDidSettle?(self)
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        navigationDidSettle?(self)
    }
}

extension BrowserWebTab: WKUIDelegate {

    /// `target="_blank"` and `window.open`. Returning `nil` is what tells WebKit no window was
    /// made; the URL becomes a new tab in this panel instead (Q11, and the half grounding probe 3
    /// confirmed does arrive headlessly).
    ///
    /// The policy answers here too, so a `window.open('javascript:…')` is refused by the same branch
    /// that refuses a typed one.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        var request = Self.request(from: navigationAction, url: url)
        // WebKit only asks this question when there is no frame to load into, whatever the action
        // reports.
        request.hasTargetFrame = false
        act(on: NavigationPolicy.decide(request), for: url, allow: { openInNewPanelTab(url) })
        return nil
    }
}
