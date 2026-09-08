import WebKit

/// Builds the `WKWebView` every Browser tab is, and the one configuration every one of them shares
/// the shape of. It is a value, not a singleton, so a test can hand a tab a different inspection
/// policy without a global to reset afterwards.
///
/// Three decisions live here, and each is a security property rather than a convenience:
///
/// - **The website data store is `WKWebsiteDataStore.default()`, shared by every tab** (Q13). Item
///   28 opens a pull request page, and a private repository's PR behind an ephemeral store is a
///   sign-in wall on every click, forever. The store lives in the app's own container; nothing about
///   it touches Claude Code's config home (X9), and afleet holds no token of its own.
/// - **The user content controller is empty, and stays empty** (Q12). No `WKScriptMessageHandler`
///   is registered and no user script is injected, so nothing a page runs can call into the app and
///   no byte of afleet's is ever written into a page. The chrome reads KVO properties on this side
///   of the boundary instead. `BrowserWebTabTests` reads the configuration back and asks a loaded
///   page what `window.webkit.messageHandlers` holds, so a later convenience cannot add one quietly.
/// - **`isInspectable` comes from an injected policy** (Q15), never from a compile-time constant
///   here: the app passes `{ true }` under `#if DEBUG` and the Developer setting otherwise, and a
///   test passes whichever it is asserting.
public struct BrowserWebViewFactory: Sendable {

    /// Whether the Web Inspector may attach. Read once per web view, at construction.
    public typealias InspectionPolicy = @Sendable () -> Bool

    private let allowsInspection: InspectionPolicy

    /// The default is the closed one. A panel that shipped inspectable because nobody passed a
    /// policy would be the wrong way round.
    public init(allowsInspection: @escaping InspectionPolicy = { false }) {
        self.allowsInspection = allowsInspection
    }

    @MainActor
    public func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Fresh and empty, and named explicitly rather than left to the default, because "the
        // default happens to be empty" is not a thing a test can assert an intention about.
        configuration.userContentController = WKUserContentController()
        return configuration
    }

    @MainActor
    public func makeWebView() -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeConfiguration())
        view.isInspectable = allowsInspection()
        view.allowsBackForwardNavigationGestures = true
        return view
    }
}
