import Foundation

/// How a navigation reached the policy. This module's own enum, not `WKNavigationType`, so the
/// policy is a pure function and the `WKNavigationDelegate` is an adapter onto it.
public enum BrowserNavigationType: Sendable, Equatable {
    case linkActivated
    case formSubmitted
    case backForward
    case reload
    case formResubmitted
    /// Everything else WebKit reports: a redirect, a `location =`, an app-initiated load.
    case other
}

/// The modifier keys held during a navigation. This module's own set, not `NSEvent`'s, for the
/// same reason.
public struct BrowserModifierFlags: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = BrowserModifierFlags(rawValue: 1 << 0)
    public static let shift = BrowserModifierFlags(rawValue: 1 << 1)
    public static let option = BrowserModifierFlags(rawValue: 1 << 2)
    public static let control = BrowserModifierFlags(rawValue: 1 << 3)
}

/// Where a navigation came from — the only thing in this module that carries authority (D38).
///
/// The distinction is unforgeable, which is the whole point of it. `.urlBar` is a native action on
/// afleet's own chrome; nothing a page can execute reaches it. Everything WebKit hands the
/// navigation delegate is `.pageContent`, whatever WebKit calls it: a link activation, a form
/// submission a script made with `requestSubmit()`, the same from a subframe, and a server redirect
/// that reuses the action which triggered it.
public enum NavigationOrigin: Sendable, Equatable {
    /// Something inside a rendered page produced this. It authorises nothing.
    case pageContent
    /// The user typed this into afleet's URL bar and submitted it.
    case urlBar
}

/// One navigation, reduced to what the decision depends on.
public struct NavigationRequest: Sendable, Equatable {

    public var url: URL

    /// How WebKit classified the navigation. **Diagnostic, plus the Cmd-click reading below, and
    /// never an authorisation** (D38): WebKit's classification says what kind of navigation this is,
    /// not that a person made it. A script's `requestSubmit()` is `.formSubmitted`; a redirect
    /// arrives wearing the `.linkActivated` that triggered it.
    public var navigationType: BrowserNavigationType

    /// The modifier keys WebKit reported. Real ones: a synthesised click produces none (probe 3),
    /// so `.command` here means an `NSEvent` existed. They are read only for a URL the panel could
    /// have rendered itself, so they can never carry a non-web scheme out of the app.
    public var modifierFlags: BrowserModifierFlags

    /// False when WebKit reports no target frame — `target="_blank"`, `window.open`. Q11 makes
    /// that a new panel tab rather than a new application window.
    public var hasTargetFrame: Bool

    /// The one authorising input. Defaults to `.pageContent`, so a call site that forgets to say
    /// grants nothing.
    public var origin: NavigationOrigin

    public init(url: URL,
                navigationType: BrowserNavigationType,
                modifierFlags: BrowserModifierFlags,
                hasTargetFrame: Bool,
                origin: NavigationOrigin = .pageContent) {
        self.url = url
        self.navigationType = navigationType
        self.modifierFlags = modifierFlags
        self.hasTargetFrame = hasTargetFrame
        self.origin = origin
    }

    /// A URL the user typed into afleet's own URL bar and submitted — the one native action page
    /// content cannot reach, and therefore the one thing that still authorises handing a non-web
    /// scheme to the system (D38).
    public static func urlBarEntry(_ url: URL) -> NavigationRequest {
        NavigationRequest(url: url,
                          navigationType: .other,
                          modifierFlags: [],
                          hasTargetFrame: true,
                          origin: .urlBar)
    }
}

/// What may load in the panel, what leaves it, and what does neither — Q10 and Q11, as one pure
/// function.
///
/// The shape is deliberate. Grounding probe 3 measured that a synthesised DOM click carries no
/// modifier flags into `decidePolicyFor` and does not arrive as `.linkActivated` at all, so a test
/// that drove this through a real `WKWebView` could not fail. Keeping the decision here, over value
/// types, is what makes root §17.7 satisfiable for the gestures that matter most.
public enum NavigationPolicy {

    public enum Reason: Sendable, Equatable {

        /// A `file:` URL. Reading the user's disk is the Files tab's job, with its viewers and its
        /// rules; a browser panel that rendered local files from links is a capability nothing
        /// asked for.
        case localFile

        /// A scheme the panel cannot render, arriving from inside a rendered page. Refused, always
        /// (D38): a page cannot make afleet launch an application, by link, by form, by subframe,
        /// by redirect or by script. The scheme is named because a diagnostic that cannot say which
        /// scheme was refused is not one.
        ///
        /// There is no gesture to check for here, which is why this is not called one. WebKit's
        /// navigation type is a classification, not an authentication: a script's `requestSubmit()`
        /// is reported as `.formSubmitted` exactly as a pressed button is, the classification is the
        /// same in a subframe, and a server redirect reuses the action that triggered it — so a
        /// clicked `https:` link can arrive here as `.linkActivated` at a `mailto:` nobody ever saw.
        case externalSchemeFromPageContent(String)

        /// No scheme at all, or an `about:` URL that is not `about:blank`.
        case unsupportedURL

        /// A `javascript:` or `data:` URL. Refused, and never handed to the system opener (D29).
        ///
        /// **What this enforces, exactly** (D39, narrowing D29's wording to what is true). The URL
        /// bar refuses both, which is the case that matters: a `javascript:` URL typed or pasted
        /// into an address bar executes in the origin of the page the user is *reading*, and that is
        /// the classic self-XSS. Any navigation WebKit dispatches for policy is refused, which
        /// covers the top-level `data:` case — measured: a page navigating itself to a `data:` URL
        /// does reach the delegate and is refused here.
        ///
        /// **What it does not enforce, and why that is acceptable.** WebKit executes a
        /// *page-originated* `javascript:` URL without dispatching the navigation-policy callback at
        /// all, so this branch never sees it (measured on this runtime, pinned by
        /// `BrowserNavigationAuthorityTests`). The page gains nothing by it: the code runs in that
        /// page's own origin, which a `<script>` tag already granted it, and there is no bridge to
        /// reach — no script message handler is registered, so `window.webkit` does not exist. The
        /// remedy would be disabling content JavaScript, which would break every dev server and the
        /// pull-request page this panel exists for; it is rejected.
        ///
        /// Handing either scheme to `NSWorkspace.shared.open` is not safety, only someone else's
        /// problem — so this case sits above every other branch, and the scheme is named because a
        /// diagnostic that cannot say what was refused is not one.
        case executableOrInlineContent(String)

        /// Whether this refusal is a log line rather than something the user is shown. The two
        /// cases differ: a `file:` link is a thing the user clicked and is owed an answer about,
        /// while a page redirecting itself to an app scheme is a thing the user never asked for
        /// and a notice about it would be the page writing into afleet's chrome.
        public var isDiagnosticOnly: Bool {
            switch self {
            case .localFile: false
            case .externalSchemeFromPageContent: true
            case .unsupportedURL: true
            // Shown, for the same reason `file:` is: the common source is the user's own URL bar,
            // and a bar that swallows what was typed without a word is a bar that looks broken.
            case .executableOrInlineContent: false
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Load it in the tab that asked.
        case allow
        /// Cancel it here and hand the URL to the system opener.
        case openExternally(URL)
        /// Cancel it here and open a new tab in this panel on that URL.
        case newPanelTab(URL)
        /// Cancel it, and do nothing but say why.
        case refuse(Reason)
    }

    /// Schemes the panel renders. `about` is qualified below: only `about:blank`.
    private static let renderableSchemes: Set<String> = ["http", "https", "about"]

    /// Schemes refused everywhere, before any gesture is read (D29). See
    /// `Reason.executableOrInlineContent` for why neither may become `.openExternally` either.
    private static let deniedSchemes: Set<String> = ["javascript", "data"]

    public static func decide(_ request: NavigationRequest) -> Decision {
        guard let scheme = request.url.scheme?.lowercased() else {
            return .refuse(.unsupportedURL)
        }

        // The deny-list is read first, so that no later branch — the gesture gate, `_blank`, a
        // Cmd-click — can turn one of these two into a load or into an `NSWorkspace` call.
        if deniedSchemes.contains(scheme) {
            return .refuse(.executableOrInlineContent(scheme))
        }

        // The scheme is settled before any gesture is, so that a `_blank` or a Cmd-click cannot be
        // the thing that gets a non-web URL past the gate.
        if scheme == "file" {
            return .refuse(.localFile)
        }
        // D38. A scheme the panel cannot render leaves the app only when the URL bar sent it —
        // a native action page content cannot reach. The navigation type is not consulted, because
        // it authenticates nothing: WebKit reports a scripted `requestSubmit()` as `.formSubmitted`,
        // reports a subframe's navigation the same way, and reuses the triggering action across a
        // server redirect.
        guard renderableSchemes.contains(scheme) else {
            return request.origin == .urlBar
                ? .openExternally(request.url)
                : .refuse(.externalSchemeFromPageContent(scheme))
        }
        if scheme == "about", request.url.absoluteString.lowercased() != "about:blank" {
            return .refuse(.unsupportedURL)
        }

        // Q11. Everything below this line is a URL the panel could have rendered itself — `http`,
        // `https` or `about:blank` — so the worst a forged one can achieve is a web page in the
        // user's own browser, which is not a privileged operation. That is why D38 leaves this
        // branch reading the navigation type at all, and why it is safe that a synthesised click
        // can reach it: the flags are real (probe 3 measured that a synthetic click carries none),
        // and the scheme was settled above.
        //
        // Cmd is read only on a link activation: a page that redirects itself while the user
        // happens to be holding Cmd has not asked for anything.
        if request.navigationType == .linkActivated, request.modifierFlags.contains(.command) {
            return .openExternally(request.url)
        }
        if !request.hasTargetFrame {
            return .newPanelTab(request.url)
        }
        return .allow
    }
}
