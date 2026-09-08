import Foundation
import XCTest
@testable import BrowserPanel

/// C7.6 milestone 2, second half: the ledger's Q10 scheme table and Q11's gestures.
///
/// The policy is a pure function over value types this module owns, not over `WKNavigationAction`,
/// for the reason grounding probe 3 measured: a synthesised DOM click carries no modifier flags and
/// never reaches `decidePolicyFor` as `.linkActivated`, so a test driven through WebKit would be a
/// test that cannot fail. The delegate is the adapter; this is the decision.
final class NavigationPolicyTests: XCTestCase {

    private static let page = URL(string: "https://example.invalid/page")!
    private static let insecurePage = URL(string: "http://127.0.0.1:8123/listing/")!
    private static let mail = URL(string: "mailto:someone@example.invalid")!
    private static let localFile = URL(string: "file:///invented/notes.txt")!

    /// The shape of an ordinary link click on a page that is already showing.
    private func click(_ url: URL,
                       modifiers: BrowserModifierFlags = [],
                       hasTargetFrame: Bool = true) -> NavigationRequest {
        NavigationRequest(url: url,
                          navigationType: .linkActivated,
                          modifierFlags: modifiers,
                          hasTargetFrame: hasTargetFrame,
                          isUserInitiated: true)
    }

    /// The shape of a load the page gave itself: a redirect, a `location =`, a meta refresh.
    private func scriptInitiated(_ url: URL, hasTargetFrame: Bool = true) -> NavigationRequest {
        NavigationRequest(url: url,
                          navigationType: .other,
                          modifierFlags: [],
                          hasTargetFrame: hasTargetFrame,
                          isUserInitiated: false)
    }

    // MARK: Q10 — which schemes load

    func testHTTPAndHTTPSAndAboutBlankLoadInThePanel() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(click(Self.insecurePage)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(click(URL(string: "about:blank")!)), .allow)
    }

    func testAnAboutURLOtherThanBlankDoesNotLoad() {
        XCTAssertEqual(NavigationPolicy.decide(click(URL(string: "about:srcdoc")!)),
                       .refuse(.unsupportedURL))
    }

    /// Q10: reading the user's disk is the Files tab's job, with Files' viewers and Files' rules.
    func testAFileURLIsRefusedAndPointsAtTheFilesTab() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.localFile)), .refuse(.localFile))
        XCTAssertEqual(NavigationPolicy.decide(scriptInitiated(Self.localFile)), .refuse(.localFile))
        XCTAssertEqual(NavigationPolicy.Reason.localFile.isDiagnosticOnly, false,
                       "the file case is shown to the user, not merely logged")
    }

    func testAnotherSchemeFromAUserGestureGoesToTheExternalOpener() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.mail)), .openExternally(Self.mail))
        let appScheme = URL(string: "x-apple-something://open")!
        XCTAssertEqual(NavigationPolicy.decide(click(appScheme)), .openExternally(appScheme))
    }

    /// The same URL, arriving without a gesture, must not launch an application.
    func testAnotherSchemeFromARedirectIsDropped() {
        XCTAssertEqual(NavigationPolicy.decide(scriptInitiated(Self.mail)),
                       .refuse(.schemeNeedsAUserGesture("mailto")))
        XCTAssertEqual(NavigationPolicy.Reason.schemeNeedsAUserGesture("mailto").isDiagnosticOnly, true,
                       "a page that navigated itself gets a diagnostic, not a notice")
    }

    func testAnotherSchemeFromAScriptInitiatedNewWindowIsAlsoDropped() {
        let request = scriptInitiated(URL(string: "x-apple-something://open")!, hasTargetFrame: false)
        XCTAssertEqual(NavigationPolicy.decide(request),
                       .refuse(.schemeNeedsAUserGesture("x-apple-something")),
                       "a missing target frame must not become a way past the gesture gate")
    }

    func testAURLWithNoSchemeIsRefused() {
        var request = click(Self.page)
        request.url = URL(string: "//example.invalid/relative")!
        XCTAssertEqual(NavigationPolicy.decide(request), .refuse(.unsupportedURL))
    }

    // MARK: D29 — the two schemes that are refused from every source

    private static let script = URL(string: "javascript:alert(1)")!
    private static let inlineDocument = URL(string: "data:text/html;base64,PGgxPmhpPC9oMT4=")!

    /// Every way a URL can arrive, so the assertion below is over the whole surface and not one
    /// branch of it: a click, a Cmd-click, a `_blank`, a redirect and the URL bar.
    private func everySource(_ url: URL) -> [NavigationRequest] {
        [click(url),
         click(url, modifiers: .command),
         click(url, hasTargetFrame: false),
         scriptInitiated(url),
         scriptInitiated(url, hasTargetFrame: false),
         .urlBarEntry(url)]
    }

    /// D29. A `javascript:` URL loaded into a tab executes in that page's origin — the classic way
    /// an address bar becomes a script injection — so it is refused before any gesture is read.
    func testAJavascriptURLIsRefusedFromEverySource() {
        for request in everySource(Self.script) {
            XCTAssertEqual(NavigationPolicy.decide(request), .refuse(.executableOrInlineContent("javascript")),
                           "a javascript: URL from \(request.navigationType) must never load")
        }
    }

    /// D29. A `data:` URL renders attacker-controlled markup in an origin the user reads as the
    /// panel's own.
    func testADataURLIsRefusedFromEverySource() {
        for request in everySource(Self.inlineDocument) {
            XCTAssertEqual(NavigationPolicy.decide(request), .refuse(.executableOrInlineContent("data")),
                           "a data: URL from \(request.navigationType) must never load")
        }
    }

    /// The load-bearing half of D29: handing either scheme to `NSWorkspace.shared.open` is not
    /// safety, only someone else's problem. Neither may ever come back as `.allow` or as
    /// `.openExternally`, however user-initiated the gesture that carried it.
    func testNeitherSchemeIsEverAllowedOrHandedToTheSystemOpener() {
        for url in [Self.script, Self.inlineDocument] {
            for request in everySource(url) {
                switch NavigationPolicy.decide(request) {
                case .refuse:
                    continue
                case .allow, .openExternally, .newPanelTab:
                    XCTFail("\(url.scheme ?? "?") escaped the policy as a non-refusal")
                }
            }
        }
    }

    /// The refusal is shown, not merely logged: the common source is the user's own URL bar, and a
    /// bar that swallows what was typed without a word is a bar that looks broken.
    func testTheRefusalIsShownToTheUser() {
        XCTAssertEqual(NavigationPolicy.Reason.executableOrInlineContent("javascript").isDiagnosticOnly, false)
    }

    // MARK: Q11 — the gestures

    func testCommandClickOnALinkGoesToTheExternalOpener() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, modifiers: .command)),
                       .openExternally(Self.page))
    }

    func testCommandClickLeavesTheAppEvenWhenTheLinkOpensANewWindow() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, modifiers: .command, hasTargetFrame: false)),
                       .openExternally(Self.page))
    }

    /// Q11: `.command` on anything that is not a link activation is an ordinary load. A page that
    /// redirects itself while the user happens to hold Cmd has not asked for a browser.
    func testCommandHeldDuringARedirectIsNotACommandClick() {
        var request = scriptInitiated(Self.page)
        request.modifierFlags = .command
        XCTAssertEqual(NavigationPolicy.decide(request), .allow)
    }

    func testShiftAndOptionClickCarryNoSpecialMeaning() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, modifiers: .shift)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, modifiers: .option)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, modifiers: [.shift, .option])), .allow)
    }

    /// `target="_blank"` and `window.open` — measured in grounding probe 3 as the half of Q11 that
    /// does reach the delegate headlessly.
    func testAMissingTargetFrameOpensANewPanelTab() {
        XCTAssertEqual(NavigationPolicy.decide(click(Self.page, hasTargetFrame: false)),
                       .newPanelTab(Self.page))
        XCTAssertEqual(NavigationPolicy.decide(scriptInitiated(Self.page, hasTargetFrame: false)),
                       .newPanelTab(Self.page),
                       "window.open is ordinary browsing, not an escape from the panel")
    }

    func testAScriptInitiatedLoadInTheSameFrameIsAllowed() {
        XCTAssertEqual(NavigationPolicy.decide(scriptInitiated(Self.page)), .allow)
    }

    func testBackForwardAndReloadAreAllowed() {
        for type in [BrowserNavigationType.backForward, .reload, .formSubmitted, .formResubmitted] {
            var request = click(Self.page)
            request.navigationType = type
            XCTAssertEqual(NavigationPolicy.decide(request), .allow, "\(type) must not be refused")
        }
    }

    // MARK: The URL bar as a gesture

    /// Q10 names the URL bar alongside `.linkActivated` as a user gesture, so the adapter that
    /// carries a typed URL into the policy marks it as one.
    func testAURLBarEntryIsAUserGesture() {
        let typed = NavigationRequest.urlBarEntry(Self.mail)
        XCTAssertTrue(typed.isUserInitiated)
        XCTAssertEqual(NavigationPolicy.decide(typed), .openExternally(Self.mail))
        XCTAssertEqual(NavigationPolicy.decide(.urlBarEntry(Self.page)), .allow)
    }
}
