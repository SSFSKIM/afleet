import Foundation
import AfleetCore
import PanelHostAPI
import Workbench

/// The routing seam every `ChannelContext` carries (spec §7, C7's binding W5), and the app's one
/// adapter onto the registry.
///
/// **There is never a second registry.** C5 shipped this holding its own `[LinkTarget]` because
/// `LinkRouting` did not exist yet, and wrote into its own source that when that module landed
/// this would delegate rather than a second registry coming into being. C7.2's `LinkRouter` is
/// that module, and this is the hand-over: registration, withdrawal, resolution and the fallback
/// all live on the actor now, and the array is gone (C7.2 Design §4, contract X7's 2026-09-07
/// amendment).
///
/// **What stays here is pop-out**, because it is the one part of routing that is the host's and
/// not the registry's: `.newWindow` — which is what Cmd-click maps to — has to pop the target's
/// tab out *before* the target delivers, a tab cannot pop itself out, and a stored host hook on
/// an actor the host owns would be a retain cycle. So this holds the weak host reference and
/// hands the pop-out to `LinkRouter.open(_:from:prepare:)` per call, which runs it after the
/// target is resolved and before the target is delivered to.
@MainActor
final class HostLinkRouter: LinkRouterCapability {

    /// The host, for the pop-out. Weak because the host owns this object.
    weak var host: PanelHostModel?

    /// The one registry. Its fallbacks were given at construction and are not reachable from here.
    private let router: LinkRouter

    /// Where the no-channel diagnostic goes. Held as well as handed to the router because the
    /// branch below is the host's and not the registry's. The message names the link kind and
    /// never the link, so no path, no session id and no title reaches a log (§11).
    private let diagnostic: @Sendable (String) -> Void

    /// The production fallbacks are the defaults, so `PanelHostModel` constructs this with no
    /// arguments and a test injects an opener that does not open a browser window.
    init(externalOpener: @escaping @Sendable (URL) -> Void = LinkRouter.systemOpener,
         diagnostic: @escaping @Sendable (String) -> Void = LinkRouter.logDiagnostic) {
        self.router = LinkRouter(externalOpener: externalOpener, diagnostic: diagnostic)
        self.diagnostic = diagnostic
    }

    /// How many targets are registered, for a diagnostic line. A count, never a tab set (§11).
    /// `async` because the count lives on the actor now.
    var targetCount: Int {
        get async { await router.targetCount }
    }

    // MARK: - LinkRouterCapability

    func register(_ target: LinkTarget) async {
        await router.register(target)
    }

    /// Drops every target this tab registered, so a target never outlives the tab that registered
    /// it. `PanelHost.unregister(_:)` awaits this.
    func unregister(tab: PanelTabID) async {
        await router.unregister(tab: tab)
    }

    /// Delegates resolution, the fallback and delivery, contributing the pop-out as `prepare`.
    ///
    /// The destination reaches the handler because C7's W5 says so: a handler given only the link
    /// cannot tell an in-panel open from a popped-out one, and a host that hard-coded
    /// `.currentPanel` would satisfy every routing test and drop that distinction at integration.
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        await router.open(link, from: destination) { target, destination in
            guard destination == .newWindow else { return }
            if let host = self.host, let channel = host.selectedChannel {
                host.popOut(target.tab, channel: channel)
            } else {
                // The handler is still told `.newWindow` afterwards, so it would render for a
                // window that was never opened. Nothing here can open one — the host's notion of
                // the current channel is the only channel this capability has, and there is none
                // when the window is on Activity — so the mismatch is reported rather than
                // hidden. `LinkRouterCapability.open(_:from:)` carrying the channel would remove
                // the case altogether, and that is an X7 amendment: see this child's Parent
                // revisions.
                self.diagnostic("a new-window link had no channel to pop its tab out for")
            }
        }
    }
}
