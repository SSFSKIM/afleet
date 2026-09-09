import Foundation
import AfleetCore
import PanelHostAPI

/// The Browser's two claims on the link registry: `.url` and `.pullRequest` (contract W5).
///
/// **Registered once, when the app registers the tab** (Q4). `LinkRouter` keys registrations by
/// `PanelTabID` and `unregister(tab:)` drops all of a tab's targets together, so registering per
/// channel would put N indistinguishable targets in the registry for one tab, all tying on
/// specificity. The `LinkRouterCapability` on a `ChannelContext` is the same object for every
/// channel, so registering through the first context would be registering globally anyway — which
/// is why it is done explicitly at tab registration, where it reads as what it is.
///
/// **What the two destinations mean** (Q1, ruled at the gate). `.currentPanel` opens the page in
/// the Browser tab and asks the host to show that tab. `.newWindow` — what Cmd-click maps to — is
/// the user's **own browser**, through the injected opener: the panel already pops out from its own
/// control, so a pop-out costs the user nothing to reach, while getting a URL into a real browser
/// with its profiles, extensions and password manager has no other affordance. Both targets
/// therefore decline X7's pop-out: a host that popped one anyway would present an afleet window
/// *and* a browser window for one click.
public enum BrowserLinkTargets {

    /// The Browser's claim on a link, low by design.
    ///
    /// A page is what the Browser is *for*, so it claims `.url` and `.pullRequest`; but a panel
    /// that knows more about a particular link than "it is a page" should win, and does so by
    /// registering higher. C7.7's source-control panel is the expected case for `.pullRequest`.
    public static let specificity = 10

    /// Asks the host to show the Browser tab. `PanelHost.select(_:)` is main-actor and the app owns
    /// the host, so it reaches a package module as an injected closure rather than as a reference:
    /// a panel holding its host is a retain path, and X7 hands panels capabilities, not the host.
    public typealias TabRequest = @MainActor @Sendable () -> Void

    /// The two targets, in registration order.
    ///
    /// `openExternally` is injected — always — so that no test launches a browser; the production
    /// value is `BrowserWebTab.systemOpener`, the same seam the panel's own external navigations
    /// take.
    @MainActor
    public static func make(model: BrowserModel,
                            pullRequests: PullRequestURLResolver,
                            selectBrowserTab: @escaping TabRequest,
                            openExternally: @escaping BrowserWebTab.ExternalOpener
                                = BrowserWebTab.systemOpener) -> [LinkTarget] {
        [
            LinkTarget(tab: .browser, specificity: specificity, popsOutForNewWindow: false,
                       handles: { link in if case .url = link { true } else { false } },
                       open: { link, destination in
                           guard case .url(let url) = link else { return }
                           await deliver(url, to: destination, model: model,
                                   selectBrowserTab: selectBrowserTab,
                                   openExternally: openExternally)
                       }),
            LinkTarget(tab: .browser, specificity: specificity, popsOutForNewWindow: false,
                       handles: { link in if case .pullRequest = link { true } else { false } },
                       open: { link, destination in
                           guard case .pullRequest(let number) = link else { return }
                           // What the panel was showing when the link was clicked. `gh` is a
                           // process, so what follows can take as long as one, and the request has
                           // to be able to tell that the panel moved on while it ran (D61).
                           let made = await model.currentNavigationGeneration
                           switch await pullRequests.resolve(number) {
                           case .resolved(let url):
                               await deliver(url, to: destination, model: model,
                                       selectBrowserTab: selectBrowserTab,
                                       openExternally: openExternally,
                                       supersededSince: made)
                           case .failed(let error):
                               // The row is the panel's, so the panel is what the user is shown —
                               // but only when the link was going there anyway. A Cmd-click that
                               // failed does not seize the panel the user was reading.
                               if destination == .currentPanel { selectBrowserTab() }
                               model.reportLinkError(error)
                           case .cancelled:
                               break
                           }
                       }),
        ]
    }

    /// The one place a resolved page is acted on, so both targets answer a destination the same
    /// way and a later edit cannot make them differ.
    ///
    /// **A routed URL is untrusted content, and it is decided as a link.** `WorkspaceLink.url`
    /// carries whatever the message it came from contained, and nothing between a timeline row and
    /// this function checks a scheme — `ComposerModel.open(url:)` parses and no more. So the URL
    /// goes through the one `NavigationPolicy` with `origin: .pageContent`, which is what it is:
    /// `javascript:` and `data:` are refused before any other branch reads them, `file:` and every
    /// other scheme the panel cannot render are refused rather than handed to `NSWorkspace`, and
    /// the destination decides only what an *allowed* URL does. Forwarding unchecked gave a routed
    /// link the URL bar's authority — the one native action page content is not supposed to reach
    /// (D38) — on the panel side, and a direct `NSWorkspace` call on the pop-out side.
    ///
    /// `.newWindow` is read as the Cmd-click it is: the same policy, with `.command` held, which
    /// answers `.openExternally` for exactly the URLs the panel would have been willing to render
    /// itself and refuses the rest. So the pop-out opens externally only what the policy would.
    @MainActor
    /// `supersededSince` is the navigation generation the request was made at, for a request that
    /// had to wait for an answer before it could act; `nil` for one that did not wait at all.
    private static func deliver(_ url: URL, to destination: LinkDestination, model: BrowserModel,
                                selectBrowserTab: TabRequest,
                                openExternally: BrowserWebTab.ExternalOpener,
                                supersededSince generation: Int? = nil) async {
        let request = NavigationRequest(url: url,
                                        navigationType: .linkActivated,
                                        modifierFlags: destination == .newWindow ? [.command] : [],
                                        hasTargetFrame: true,
                                        origin: .pageContent)
        switch NavigationPolicy.decide(request) {
        case .allow:
            selectBrowserTab()
            // Behind the restoration, always: a link can arrive before the panel has ever been
            // drawn, and a tab opened in front of an unfinished read is a tab that read discards
            // (A1). `openRouted` is idempotent once the restore has run.
            await model.openRouted(url, in: .currentTab, supersededSince: generation)
        case .openExternally(let target):
            // Nothing about the panel changes: the page is going somewhere else, and a tab opened
            // here as well would leave the user with the same page twice.
            openExternally(target)
        case .newPanelTab(let target):
            selectBrowserTab()
            await model.openRouted(target, in: .newTab, supersededSince: generation)
        case .refuse(let reason):
            // The row is the panel's, so a link that was going there anyway shows the panel; a
            // Cmd-click that was refused does not seize the panel the user is reading. `report`
            // is silent for the refusals the user never asked for, which is the same rule the
            // navigation delegate takes.
            if destination == .currentPanel { selectBrowserTab() }
            model.report(reason)
        }
    }
}
