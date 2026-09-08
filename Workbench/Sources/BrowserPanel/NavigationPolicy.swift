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

/// One navigation, reduced to what the decision depends on.
public struct NavigationRequest: Sendable, Equatable {

    public var url: URL
    public var navigationType: BrowserNavigationType
    public var modifierFlags: BrowserModifierFlags

    /// False when WebKit reports no target frame — `target="_blank"`, `window.open`. Q11 makes
    /// that a new panel tab rather than a new application window.
    public var hasTargetFrame: Bool

    /// True only when a real user event produced this load: a click, or the URL bar. A redirect
    /// and a script-initiated load are false, and that is the gate a non-web scheme has to pass
    /// before the app will hand it to the system (Q10).
    public var isUserInitiated: Bool

    public init(url: URL,
                navigationType: BrowserNavigationType,
                modifierFlags: BrowserModifierFlags,
                hasTargetFrame: Bool,
                isUserInitiated: Bool) {
        self.url = url
        self.navigationType = navigationType
        self.modifierFlags = modifierFlags
        self.hasTargetFrame = hasTargetFrame
        self.isUserInitiated = isUserInitiated
    }

    /// A URL the user typed and submitted. Q10 names the URL bar as a user gesture alongside
    /// `.linkActivated`, so the bar's adapter goes through here rather than assembling the flags
    /// itself at each call site.
    public static func urlBarEntry(_ url: URL) -> NavigationRequest {
        NavigationRequest(url: url,
                          navigationType: .other,
                          modifierFlags: [],
                          hasTargetFrame: true,
                          isUserInitiated: true)
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

        /// A scheme the panel cannot render, arriving without a user gesture. Dropped, so a page
        /// cannot make afleet launch an application by navigating itself. The scheme is named
        /// because a diagnostic that cannot say which scheme was refused is not one.
        case schemeNeedsAUserGesture(String)

        /// No scheme at all, or an `about:` URL that is not `about:blank`.
        case unsupportedURL

        /// A `javascript:` or `data:` URL, from any source at all — the URL bar, a link, a redirect
        /// or a script-initiated load. Refused, and never handed to the system opener (D29).
        ///
        /// A `javascript:` URL loaded into a tab executes **in the current page's origin**, which is
        /// exactly how an address bar becomes a script injection: anything that can put a string in
        /// front of the bar can then run code as the page the user is reading. A `data:` URL renders
        /// attacker-controlled markup in an origin the user reads as the panel's own, which is the
        /// same trick with the payload inlined instead of typed.
        ///
        /// Handing either to `NSWorkspace.shared.open` is not safety, only someone else's problem —
        /// so this case sits above the gesture gate rather than beside it, and the scheme is named
        /// because a diagnostic that cannot say what was refused is not one.
        case executableOrInlineContent(String)

        /// Whether this refusal is a log line rather than something the user is shown. The two
        /// cases differ: a `file:` link is a thing the user clicked and is owed an answer about,
        /// while a page redirecting itself to an app scheme is a thing the user never asked for
        /// and a notice about it would be the page writing into afleet's chrome.
        public var isDiagnosticOnly: Bool {
            switch self {
            case .localFile: false
            case .schemeNeedsAUserGesture: true
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
        guard renderableSchemes.contains(scheme) else {
            return request.isUserInitiated
                ? .openExternally(request.url)
                : .refuse(.schemeNeedsAUserGesture(scheme))
        }
        if scheme == "about", request.url.absoluteString.lowercased() != "about:blank" {
            return .refuse(.unsupportedURL)
        }

        // Q11. Cmd is read only on a link activation: a page that redirects itself while the user
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
