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
                           switch await pullRequests.resolve(number) {
                           case .resolved(let url):
                               await deliver(url, to: destination, model: model,
                                       selectBrowserTab: selectBrowserTab,
                                       openExternally: openExternally)
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
    @MainActor
    private static func deliver(_ url: URL, to destination: LinkDestination, model: BrowserModel,
                                selectBrowserTab: TabRequest,
                                openExternally: BrowserWebTab.ExternalOpener) async {
        switch destination {
        case .currentPanel:
            selectBrowserTab()
            // Behind the restoration, always: a link can arrive before the panel has ever been
            // drawn, and a tab opened in front of an unfinished read is a tab that read discards
            // (A1). `openRouted` is idempotent once the restore has run.
            await model.openRouted(url, in: .currentTab)
        case .newWindow:
            // Nothing about the panel changes: the page is going somewhere else, and a tab opened
            // here as well would leave the user with the same page twice.
            openExternally(url)
        }
    }
}
