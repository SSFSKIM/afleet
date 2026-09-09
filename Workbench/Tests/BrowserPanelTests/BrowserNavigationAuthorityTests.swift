import Foundation
import WebKit
import XCTest
@testable import BrowserPanel

/// C7.6, the D38/D39 fix wave: **what authorises leaving the app**, against real `WKWebView`s.
///
/// R2 found that the navigation *type* was being read as proof of a user gesture. It is not one.
/// WebKit classifies a form submission as `.formSubmitted` whether a person pressed the button or a
/// script called `requestSubmit()`; the same classification reaches a subframe; and a server
/// redirect reuses the action that triggered it, so a URL a person never saw can arrive still
/// wearing the click that started the hop. Every case below is a page making the app do something,
/// with no person involved at any point.
///
/// The external opener is injected in every test and asserted **not** called. Nothing here may reach
/// `NSWorkspace`, and nothing here reaches the network: every host is loopback and every URL that is
/// not is invented (`example.invalid`).
@MainActor
final class BrowserNavigationAuthorityTests: XCTestCase {

    private static let mailtoTarget = "mailto:someone@example.invalid"

    // MARK: The pages

    /// A form whose action is a non-web scheme, submitted by script the moment the page parses.
    /// `requestSubmit()` and `submit()` are separate pages because they are separate WebKit paths:
    /// `requestSubmit()` runs the submit event and validation, `submit()` skips both.
    private static func formPage(action: String, submittedBy call: String) -> String {
        """
        <html><head><title>Form host</title></head><body>
        <form id="f" action="\(action)" method="get"><input name="x" value="1"></form>
        <script>document.getElementById('f').\(call)</script>
        </body></html>
        """
    }

    private func startServer() async throws -> LoopbackHTTPServer {
        let running = try LoopbackHTTPServer(
            pages: [
                "/idle": "<html><head><title>Idle</title></head><body>x</body></html>",
                "/form-requestsubmit": Self.formPage(action: Self.mailtoTarget,
                                                     submittedBy: "requestSubmit()"),
                "/form-submit": Self.formPage(action: Self.mailtoTarget, submittedBy: "submit()"),
                "/form-in-frame": Self.formPage(action: Self.mailtoTarget,
                                                submittedBy: "requestSubmit()"),
                "/iframe-host": """
                    <html><head><title>Frame host</title></head><body>
                    <iframe id="inner" src="/form-in-frame"></iframe>
                    </body></html>
                    """,
                "/link-to-redirect": """
                    <html><head><title>Link host</title></head><body>
                    <a id="out" href="/redirect-to-app-scheme">out</a>
                    </body></html>
                    """,
                "/form-to-redirect": Self.formPage(action: "/redirect-to-app-scheme",
                                                   submittedBy: "requestSubmit()"),
                // `void(...)` deliberately: a `javascript:` URL whose expression evaluates to a
                // string *replaces the document* with that string, which would wipe the title this
                // test reads. Measured — the first cut of this test failed on an empty title, not
                // on a refusal.
                "/self-javascript": """
                    <html><head><title>Not executed</title></head><body>
                    <script>location.href = "javascript:void(document.title='executed')"</script>
                    </body></html>
                    """,
                "/self-data": """
                    <html><head><title>Still here</title></head><body>
                    <script>location.href = 'data:text/html,<h1>inlined</h1>'</script>
                    </body></html>
                    """,
            ],
            redirects: ["/redirect-to-app-scheme": Self.mailtoTarget])
        try await running.start()
        return running
    }

    // MARK: The injected seams

    /// Every way out of the panel, recorded, with one expectation fulfilled by *whichever* of them
    /// the tab reaches first. Waiting on the refusal alone would make a wrong implementation fail at
    /// the deadline rather than at the assertion, which is twenty seconds of nothing per test.
    private final class NavigationSeams: @unchecked Sendable {
        private let lock = NSLock()
        private var externallyOpened: [URL] = []
        private var newPanelTabs: [URL] = []
        private var refusals: [NavigationPolicy.Reason] = []
        private var waiters: [XCTestExpectation] = []

        var opened: [URL] { lock.lock(); defer { lock.unlock() }; return externallyOpened }
        var newTabs: [URL] { lock.lock(); defer { lock.unlock() }; return newPanelTabs }
        var refused: [NavigationPolicy.Reason] { lock.lock(); defer { lock.unlock() }; return refusals }

        private func settle() {
            lock.lock()
            let waiting = waiters
            lock.unlock()
            for waiter in waiting { waiter.fulfill() }
        }

        var openExternally: @Sendable (URL) -> Void {
            { [self] url in
                lock.lock(); externallyOpened.append(url); lock.unlock()
                settle()
            }
        }
        var openInNewPanelTab: @Sendable (URL) -> Void {
            { [self] url in
                lock.lock(); newPanelTabs.append(url); lock.unlock()
                settle()
            }
        }
        var report: @Sendable (NavigationPolicy.Reason, URL) -> Void {
            { [self] reason, _ in
                lock.lock(); refusals.append(reason); lock.unlock()
                settle()
            }
        }

        /// Fulfilled by the first decision the tab acts on, whatever it is.
        func fulfillOnAnyDecision(_ expectation: XCTestExpectation) {
            expectation.assertForOverFulfill = false
            lock.lock()
            let already = !externallyOpened.isEmpty || !newPanelTabs.isEmpty || !refusals.isEmpty
            waiters.append(expectation)
            lock.unlock()
            if already { expectation.fulfill() }
        }
    }

    private func makeTab() -> (BrowserWebTab, NavigationSeams) {
        let seams = NavigationSeams()
        let tab = BrowserWebTab(factory: BrowserWebViewFactory(allowsInspection: { false }),
                                openExternally: seams.openExternally,
                                openInNewPanelTab: seams.openInNewPanelTab,
                                report: seams.report)
        return (tab, seams)
    }

    /// Loads `path`, waits for the first decision the tab acts on, and asserts the app was not made
    /// to launch anything. The shape every case below shares.
    private func assertNoExternalOpen(loading path: String,
                                      on server: LoopbackHTTPServer,
                                      _ what: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async -> NavigationSeams {
        let (tab, seams) = makeTab()
        let decided = expectation(description: "\(what) reaches a decision")
        seams.fulfillOnAnyDecision(decided)
        tab.navigate(to: server.url(path))
        await fulfillment(of: [decided], timeout: Self.webDeadline)
        XCTAssertTrue(seams.opened.isEmpty,
                      "\(what): page content must never reach the external opener",
                      file: file, line: line)
        XCTAssertEqual(seams.refused.last, .externalSchemeFromPageContent("mailto"),
                       "\(what): the refusal names the scheme", file: file, line: line)
        return seams
    }

    // MARK: F1 — a form submission is not a user gesture

    /// `requestSubmit()` from script, with nobody at the keyboard. WebKit reports `.formSubmitted`
    /// for it exactly as it does for a pressed button, which is why the type could never have been
    /// the authorisation.
    func testAScriptedFormSubmissionToANonWebSchemeOpensNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        _ = await assertNoExternalOpen(loading: "/form-requestsubmit",
                                       on: server,
                                       "a scripted requestSubmit() to mailto:")
    }

    /// The other submit path: `form.submit()` skips the submit event and validation entirely.
    func testTheOtherScriptedFormSubmitPathAlsoOpensNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        _ = await assertNoExternalOpen(loading: "/form-submit",
                                       on: server,
                                       "a scripted form.submit() to mailto:")
    }

    /// The same submission from inside a subframe. WebKit classifies a subframe's navigation the
    /// same way, so a page that could not do this itself could have done it through an iframe.
    func testAFormSubmissionFromInsideASubframeOpensNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        _ = await assertNoExternalOpen(loading: "/iframe-host",
                                       on: server,
                                       "a subframe submitting to mailto:")
    }

    // MARK: F1 — a server redirect carries the triggering action with it

    /// A form submission to an ordinary loopback path, which the server answers with a `302` into a
    /// non-web scheme. The user consented to a page on `127.0.0.1`; nothing about that consents to
    /// launching a mail client.
    func testAServerRedirectOutOfASubmissionOpensNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let seams = await assertNoExternalOpen(loading: "/form-to-redirect",
                                               on: server,
                                               "a 302 out of a form submission")
        XCTAssertTrue(seams.newTabs.isEmpty)
    }

    /// The same redirect out of a clicked link. Probe 3 measured that a synthesised click does not
    /// reach the delegate as `.linkActivated`, so this case cannot prove the *type* was reused — it
    /// proves the destination is refused however the hop is classified, which is the claim that has
    /// to hold.
    func testAServerRedirectOutOfAClickedLinkOpensNothing() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()

        await navigating(tab, "the link page loads") { tab.navigate(to: server.url("/link-to-redirect")) }
        let decided = expectation(description: "the redirected navigation reaches a decision")
        seams.fulfillOnAnyDecision(decided)
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('out').click(); null")
        await fulfillment(of: [decided], timeout: Self.webDeadline)

        XCTAssertTrue(seams.opened.isEmpty, "a redirect is not a gesture")
        XCTAssertEqual(seams.refused.last, .externalSchemeFromPageContent("mailto"))

        // Measured, and the reason this wait exists: at the instant the decision fires, `url` is the
        // *provisional* one — the refused `mailto:` — and it returns to the page that is actually
        // showing a moment later. Reading it synchronously here made this assertion fail against the
        // fixed code, which would have been the test blaming the fix.
        let settled = chromeReaches(tab.chrome, "the chrome is back on the page that is showing") {
            $0.url == server.url("/link-to-redirect")
        }
        await fulfillment(of: [settled], timeout: Self.webDeadline)
    }

    // MARK: The authority that survives

    /// The URL bar is a native action page content cannot reach, and it is the only thing left that
    /// can hand a non-web scheme to the system. Removing this would be removing the feature.
    func testTheURLBarStillReachesTheExternalOpenerForANonWebScheme() {
        let (tab, seams) = makeTab()
        let mail = URL(string: Self.mailtoTarget)!
        tab.navigate(to: mail)
        XCTAssertEqual(seams.opened, [mail])
        XCTAssertTrue(seams.refused.isEmpty)
        XCTAssertNil(tab.webView.url, "the tab itself did not move")
    }

    /// The other surviving form, at the policy where a real modifier flag can be represented: a
    /// Cmd-click on an ordinary web URL. It is not tested through a web view because a synthesised
    /// click carries no modifier flags into the delegate (probe 3), and faking an `NSEvent` would be
    /// faking the very fact under test.
    func testACommandClickOnAWebURLStillLeavesForTheSystemBrowser() {
        let page = URL(string: "https://example.invalid/page")!
        let request = NavigationRequest(url: page,
                                        navigationType: .linkActivated,
                                        modifierFlags: .command,
                                        hasTargetFrame: true,
                                        origin: .pageContent)
        XCTAssertEqual(NavigationPolicy.decide(request), .openExternally(page),
                       "opening a web URL in the user's own browser is not a privileged operation")
    }

    // MARK: F2 and D39 — what WebKit actually does with javascript: and data:

    /// The pinned reality behind D39, not an aspiration. WebKit's policy checker executes a
    /// page-originated `javascript:` URL **without** dispatching the navigation-policy callback, so
    /// the deny-list never sees it. What the page gains by doing so is nothing: the code runs in the
    /// page's own origin, exactly as a `<script>` tag already could, and there is no bridge to reach
    /// — `testPageContentCanReachNoScriptMessageHandler` proves `window.webkit` does not exist.
    ///
    /// If a later WebKit starts dispatching this navigation for policy, this test goes red on the
    /// title, which is the notice D39 wants.
    func testAPageOriginatedJavascriptURLExecutesWithoutReachingTheDelegate() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()

        let executed = chromeReaches(tab.chrome, "the page's own title changes") { $0.title == "executed" }
        await navigating(tab, "the page loads") { tab.navigate(to: server.url("/self-javascript")) }
        await fulfillment(of: [executed], timeout: Self.webDeadline)

        XCTAssertTrue(seams.refused.isEmpty,
                      "measured: no navigation-policy callback is dispatched for this at all")
        XCTAssertTrue(seams.opened.isEmpty, "and nothing leaves the app either way")
        XCTAssertEqual(tab.webView.url, server.url("/self-javascript"),
                       "the page's own origin, unchanged — a javascript: URL is not a document")
    }

    /// The `data:` half of the same question, and it goes the other way: a top-level page-originated
    /// `data:` navigation **is** dispatched for policy, so the deny-list refuses it and the page
    /// stays where it was. Recorded next to the `javascript:` case because the contrast is the
    /// whole of D39 — one of the two schemes is enforceable at this seam and the other is not.
    func testATopLevelPageOriginatedDataURLIsDispatchedForPolicyAndRefused() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (tab, seams) = makeTab()

        let decided = expectation(description: "the data: navigation reaches a decision")
        seams.fulfillOnAnyDecision(decided)
        tab.navigate(to: server.url("/self-data"))
        await fulfillment(of: [decided], timeout: Self.webDeadline)

        XCTAssertEqual(seams.refused, [.executableOrInlineContent("data")])
        XCTAssertTrue(seams.opened.isEmpty)
        XCTAssertEqual(tab.webView.url, server.url("/self-data"))
    }
}
