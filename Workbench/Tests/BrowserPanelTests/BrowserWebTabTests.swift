import Foundation
import WebKit
import XCTest
@testable import BrowserPanel

/// C7.6 milestone 3: the web tab, against **real** `WKWebView`s.
///
/// Grounding probe 1 measured that this works in a bare `swift test` process with no app bundle,
/// which is why layer 2 of Q17 is in the package suite rather than the app suite. Probe 3 measured
/// what does *not* work — a synthesised click carries no modifier flags and never arrives as
/// `.linkActivated` — so Cmd-click is not tested here at all: it is `NavigationPolicy`'s, where it
/// is a pure function and a test of it can fail.
///
/// Every host is loopback and every page is served by a server this file starts and stops. Nothing
/// reaches the network, and nothing launches a browser: the external opener is injected.
@MainActor
final class BrowserWebTabTests: XCTestCase {

    // MARK: What the tests are built from

    private static let firstPage = """
        <html><head><title>First page</title></head><body><h1 id="heading">one</h1></body></html>
        """
    private static let secondPage = """
        <html><head><title>Second page</title></head><body><h1>two</h1></body></html>
        """

    /// A running server with the two pages every navigation test uses, plus the pages the
    /// `target="_blank"` and `window.open` cases need.
    private func startServer() async throws -> LoopbackHTTPServer {
        let running = try LoopbackHTTPServer(pages: [
            "/one": Self.firstPage,
            "/two": Self.secondPage,
            "/opened": Self.secondPage,
            "/to-app-scheme": """
                <html><head><title>Redirecting</title></head><body>
                <script>location.href = 'mailto:someone@example.invalid'</script>
                </body></html>
                """,
            "/to-data-url": """
                <html><head><title>Redirecting</title></head><body>
                <script>location.href = 'data:text/html;base64,PGgxPmhpPC9oMT4='</script>
                </body></html>
                """,
            "/blank-link": """
                <html><head><title>Blank link</title></head><body>
                <a id="out" href="/opened" target="_blank">out</a>
                </body></html>
                """,
        ])
        try await running.start()
        return running
    }

    /// The tab under test, with every seam injected. `opened` and `newTabs` are what the security
    /// assertions read: nothing in this suite may reach `NSWorkspace`.
    private final class Seams: @unchecked Sendable {
        private let lock = NSLock()
        private var externallyOpened: [URL] = []
        private var newPanelTabs: [URL] = []
        private var refusals: [NavigationPolicy.Reason] = []

        var opened: [URL] { lock.lock(); defer { lock.unlock() }; return externallyOpened }
        var newTabs: [URL] { lock.lock(); defer { lock.unlock() }; return newPanelTabs }
        var refused: [NavigationPolicy.Reason] { lock.lock(); defer { lock.unlock() }; return refusals }

        var openExternally: @Sendable (URL) -> Void {
            { [self] url in lock.lock(); externallyOpened.append(url); lock.unlock() }
        }
        var openInNewPanelTab: @Sendable (URL) -> Void {
            { [self] url in
                lock.lock()
                newPanelTabs.append(url)
                let waiting = waiters
                lock.unlock()
                for waiter in waiting { waiter.fulfill() }
            }
        }

        /// An expectation fulfilled by the callback itself — the delegate event, never a poll.
        private var waiters: [XCTestExpectation] = []
        func fulfillOnNewPanelTab(_ expectation: XCTestExpectation) {
            expectation.assertForOverFulfill = false
            lock.lock()
            let already = !newPanelTabs.isEmpty
            waiters.append(expectation)
            lock.unlock()
            if already { expectation.fulfill() }
        }
        var report: @Sendable (NavigationPolicy.Reason, URL) -> Void {
            { [self] reason, _ in
                lock.lock()
                refusals.append(reason)
                let waiting = refusalWaiters
                lock.unlock()
                for waiter in waiting { waiter.fulfill() }
            }
        }

        private var refusalWaiters: [XCTestExpectation] = []
        func fulfillOnRefusal(_ expectation: XCTestExpectation) {
            expectation.assertForOverFulfill = false
            lock.lock()
            let already = !refusals.isEmpty
            refusalWaiters.append(expectation)
            lock.unlock()
            if already { expectation.fulfill() }
        }
    }

    private func makeTab(inspectable: Bool = false) -> (BrowserWebTab, Seams) {
        let seams = Seams()
        let tab = BrowserWebTab(factory: BrowserWebViewFactory(allowsInspection: { inspectable }),
                                openExternally: seams.openExternally,
                                openInNewPanelTab: seams.openInNewPanelTab,
                                report: seams.report)
        return (tab, seams)
    }

    // MARK: A page loads, and its title reaches the chrome

    func testAPageLoadsAndItsTitleReachesTheChromeState() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, _) = makeTab()

        let titled = chromeReaches(tab.chrome, "the title reaches the chrome") { $0.title == "First page" }
        await navigating(tab, "the first page loads") { tab.navigate(to: server.url("/one")) }
        await fulfillment(of: [titled], timeout: Self.webDeadline)

        XCTAssertEqual(tab.chrome.url, server.url("/one"))
        XCTAssertEqual(tab.chrome.title, "First page")
        XCTAssertEqual(server.requestCount(for: "/one"), 1)

        let quiet = chromeReaches(tab.chrome, "the load finishes") { $0.isLoading == false }
        await fulfillment(of: [quiet], timeout: Self.webDeadline)
    }

    /// The chrome reads a `loadHTMLString` page too — the cheaper half of Q17's layer 2, with no
    /// server at all.
    func testAnHTMLStringPageAlsoReachesTheChromeState() async throws {
        let (tab, _) = makeTab()
        let titled = chromeReaches(tab.chrome, "the title reaches the chrome") { $0.title == "Invented page" }
        await navigating(tab, "the string loads") {
            tab.webView.loadHTMLString("<html><head><title>Invented page</title></head><body>x</body></html>",
                                       baseURL: nil)
        }
        await fulfillment(of: [titled], timeout: Self.webDeadline)
    }

    // MARK: Back and forward

    func testCanGoBackAndForwardFollowATwoPageNavigationAndAGoBack() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, _) = makeTab()

        await navigating(tab, "the first page loads") { tab.navigate(to: server.url("/one")) }
        XCTAssertFalse(tab.chrome.canGoBack, "one page in the history is not a back entry")
        XCTAssertFalse(tab.chrome.canGoForward)

        let backAvailable = chromeReaches(tab.chrome, "back becomes available") { $0.canGoBack }
        await navigating(tab, "the second page loads") { tab.navigate(to: server.url("/two")) }
        await fulfillment(of: [backAvailable], timeout: Self.webDeadline)
        XCTAssertFalse(tab.chrome.canGoForward, "nothing has been gone back from yet")

        let returned = chromeReaches(tab.chrome, "the first page is showing again") {
            $0.url == server.url("/one")
        }
        await navigating(tab, "the back navigation settles") { tab.goBack() }
        await fulfillment(of: [returned], timeout: Self.webDeadline)

        let forwardAvailable = chromeReaches(tab.chrome, "forward becomes available") { $0.canGoForward }
        await fulfillment(of: [forwardAvailable], timeout: Self.webDeadline)
        XCTAssertFalse(tab.chrome.canGoBack, "the first page is the start of the history")

        let forwardAgain = chromeReaches(tab.chrome, "the second page is showing again") {
            $0.url == server.url("/two")
        }
        await navigating(tab, "the forward navigation settles") { tab.goForward() }
        await fulfillment(of: [forwardAgain], timeout: Self.webDeadline)
        XCTAssertTrue(tab.chrome.canGoBack)
    }

    // MARK: Reload

    /// The server counts, so "reload re-requested" is a fact about the wire and not about a method
    /// having been called. `Cache-Control: no-store` is what makes the count trustworthy.
    func testReloadReRequestsThePage() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, _) = makeTab()

        await navigating(tab, "the first page loads") { tab.navigate(to: server.url("/one")) }
        XCTAssertEqual(server.requestCount(for: "/one"), 1)

        await navigating(tab, "the reload settles") { tab.reload() }
        XCTAssertEqual(server.requestCount(for: "/one"), 2, "reload must reach the server again")
    }

    // MARK: Q12 — what page content gets to talk to

    /// Read back from the configuration, so a later convenience that injects a script has to change
    /// a red test to do it.
    func testTheConfigurationCarriesNoUserScripts() {
        let configuration = BrowserWebViewFactory().makeConfiguration()
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty,
                      "no user script is injected into a page, ever")
    }

    /// The message-handler half, asserted from inside a page. WebKit exposes no getter for the
    /// registered names, and `Object.getOwnPropertyNames(window.webkit.messageHandlers)` is empty
    /// either way — measured, when a mutation that registered a handler failed to redden it. What
    /// WebKit *does* do is create `window.webkit` at all only when at least one handler exists, so
    /// the honest assertion is the strongest one available: page content has no `window.webkit`, and
    /// therefore nothing in this app to call.
    func testPageContentCanReachNoScriptMessageHandler() async throws {
        let (tab, _) = makeTab()
        await navigating(tab, "the page loads") {
            tab.webView.loadHTMLString("<html><body>x</body></html>", baseURL: nil)
        }
        let surface = try await tab.webView.evaluateJavaScript("typeof window.webkit") as? String
        XCTAssertEqual(surface, "undefined",
                       "registering any script message handler would make window.webkit exist")
    }

    /// Q13: one shared, persistent data store for every tab, so a signed-in PR page stays signed in.
    func testEveryTabSharesThePersistentWebsiteDataStore() {
        let factory = BrowserWebViewFactory()
        let first = factory.makeConfiguration()
        let second = factory.makeConfiguration()
        XCTAssertTrue(first.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(second.websiteDataStore === first.websiteDataStore)
        XCTAssertTrue(first.websiteDataStore.isPersistent,
                      "an ephemeral store is a sign-in wall on every click, forever")
    }

    // MARK: Q15 — the inspector

    func testIsInspectableFollowsTheInjectedPolicy() {
        let allowed = BrowserWebViewFactory(allowsInspection: { true }).makeWebView()
        XCTAssertTrue(allowed.isInspectable)
        let denied = BrowserWebViewFactory(allowsInspection: { false }).makeWebView()
        XCTAssertFalse(denied.isInspectable)
    }

    func testTheInspectionPolicyIsReadAtConstructionAndNotAssumed() {
        let (inspectableTab, _) = makeTab(inspectable: true)
        XCTAssertTrue(inspectableTab.webView.isInspectable)
        let (plainTab, _) = makeTab()
        XCTAssertFalse(plainTab.webView.isInspectable)
    }

    // MARK: The policy, through the tab

    func testANavigationThePolicyRefusesDoesNotChangeTheURL() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()
        await navigating(tab, "the first page loads") { tab.navigate(to: server.url("/one")) }

        tab.navigate(to: URL(string: "file:///invented/notes.txt")!)
        XCTAssertEqual(tab.webView.url, server.url("/one"), "a refused navigation must not move the tab")
        XCTAssertEqual(seams.refused, [.localFile])
        XCTAssertTrue(seams.opened.isEmpty, "a refusal is not an excuse to launch something else")

        tab.navigate(to: URL(string: "javascript:alert(1)")!)
        XCTAssertEqual(tab.webView.url, server.url("/one"))
        XCTAssertEqual(seams.refused.last, .executableOrInlineContent("javascript"))
        XCTAssertTrue(seams.opened.isEmpty, "D29: neither scheme becomes someone else's problem")
        XCTAssertEqual(server.requests, ["/one"], "nothing refused reached the wire")
    }

    /// The URL bar is the one authority left for a non-web scheme (D38), and `navigate(to:)` is
    /// its adapter.
    func testAnExternalDecisionReachesTheInjectedOpener() async throws {
        let (tab, seams) = makeTab()
        let mail = URL(string: "mailto:someone@example.invalid")!
        tab.navigate(to: mail)
        XCTAssertEqual(seams.opened, [mail])
        XCTAssertNil(tab.webView.url, "the tab itself did not move")
        XCTAssertTrue(seams.newTabs.isEmpty)
    }

    // MARK: What the delegate tells WebKit

    /// `WKNavigationAction` traps when it is constructed outside WebKit (measured, when a subclass
    /// standing in for one killed the test process), so the answer the delegate hands WebKit is read
    /// from the mapping it uses. It is worth reading on its own: every scheme the policy refuses is
    /// also one WebKit would decline to load anyway, so no assertion about where the tab ended up
    /// can tell a `.cancel` from an `.allow`, and a delegate that allowed everything would otherwise
    /// pass every test in this file.
    func testOnlyAnAllowDecisionIsAllowedThroughToWebKit() {
        let page = URL(string: "https://example.invalid/page")!
        XCTAssertEqual(BrowserWebTab.answer(to: .allow), .allow)
        XCTAssertEqual(BrowserWebTab.answer(to: .openExternally(page)), .cancel)
        XCTAssertEqual(BrowserWebTab.answer(to: .newPanelTab(page)), .cancel)
        XCTAssertEqual(BrowserWebTab.answer(to: .refuse(.localFile)), .cancel)
        XCTAssertEqual(BrowserWebTab.answer(to: .refuse(.executableOrInlineContent("javascript"))), .cancel)
    }

    // MARK: The delegate's own refusal path

    /// Q10's rule, through WebKit rather than through `navigate(to:)`: a page cannot make afleet
    /// launch an application by navigating itself. Without this the delegate could hand WebKit
    /// `.allow` for everything and no test in this file would notice, because `navigate(to:)`
    /// decides before it loads.
    func testAPageThatRedirectsItselfToAnAppSchemeIsDroppedAndLaunchesNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()

        let refused = expectation(description: "the redirect is refused")
        seams.fulfillOnRefusal(refused)
        await navigating(tab, "the redirecting page loads") { tab.navigate(to: server.url("/to-app-scheme")) }
        await fulfillment(of: [refused], timeout: Self.webDeadline)

        XCTAssertEqual(seams.refused, [.externalSchemeFromPageContent("mailto")])
        XCTAssertTrue(seams.opened.isEmpty, "no gesture, no application launched")
        XCTAssertEqual(tab.webView.url, server.url("/to-app-scheme"))
    }

    /// D29 through the delegate: a page that navigates itself to a `data:` URL would otherwise be
    /// rendering attacker-controlled markup in an origin the user reads as the panel's own.
    func testAPageThatRedirectsItselfToADataURLIsRefused() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()

        let refused = expectation(description: "the data: URL is refused")
        seams.fulfillOnRefusal(refused)
        await navigating(tab, "the redirecting page loads") { tab.navigate(to: server.url("/to-data-url")) }
        await fulfillment(of: [refused], timeout: Self.webDeadline)

        XCTAssertEqual(seams.refused, [.executableOrInlineContent("data")])
        XCTAssertTrue(seams.opened.isEmpty)
        XCTAssertEqual(tab.webView.url, server.url("/to-data-url"), "the panel stayed where it was")
    }

    // MARK: Q11 — target=_blank and window.open

    func testATargetBlankLinkReachesTheNewPanelTabCallback() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()
        await navigating(tab, "the link page loads") { tab.navigate(to: server.url("/blank-link")) }

        let arrived = expectation(description: "the new-panel-tab callback receives the URL")
        seams.fulfillOnNewPanelTab(arrived)
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('out').click(); null")
        await fulfillment(of: [arrived], timeout: Self.webDeadline)

        XCTAssertEqual(seams.newTabs, [server.url("/opened")])
        XCTAssertTrue(seams.opened.isEmpty, "ordinary browsing is not an escape from the panel")
        XCTAssertEqual(tab.webView.url, server.url("/blank-link"), "the opener tab did not move")
    }

    func testWindowOpenReachesTheNewPanelTabCallback() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()
        await navigating(tab, "the first page loads") { tab.navigate(to: server.url("/one")) }

        let arrived = expectation(description: "the new-panel-tab callback receives the URL")
        seams.fulfillOnNewPanelTab(arrived)
        _ = try await tab.webView.evaluateJavaScript("window.open('/opened'); null")
        await fulfillment(of: [arrived], timeout: Self.webDeadline)

        XCTAssertEqual(seams.newTabs, [server.url("/opened")])
        XCTAssertTrue(seams.opened.isEmpty)
    }
}
