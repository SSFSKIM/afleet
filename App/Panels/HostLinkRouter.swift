import Foundation
import AppKit
import OSLog
import AfleetCore
import PanelHostAPI

/// The app's single link registry, and the routing seam every `ChannelContext` carries
/// (spec §7, C7's binding W5).
///
/// **Routing is the host's and not the tab's**, because `.newWindow` — which is what Cmd-click maps
/// to — has to pop the target's tab out *before* the target delivers, and a tab cannot pop itself
/// out. So this holds a weak reference back to the host and does the pop-out first.
///
/// **There is never a second registry.** When C7.2's `LinkRouting` target lands its reusable one,
/// this delegates to it rather than a second registry coming into being; the hand-over is recorded
/// as a Revision Note on the C7 spec.
@MainActor
final class HostLinkRouter: LinkRouterCapability {

    /// The host, for the pop-out. Weak because the host owns this object.
    weak var host: PanelHostModel?

    /// What an unhandled `.url` falls back to. A seam because the production value opens a browser
    /// window, which a test must not do.
    var openExternally: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Where the fallback's diagnostic goes for every link kind that is not a `.url`. The message
    /// names the kind and never the link, so no path, no session id and no title reaches a log
    /// (§11).
    var diagnostic: @MainActor (String) -> Void = { HostLinkRouter.log.notice("\($0, privacy: .public)") }

    private static let log = Logger(subsystem: "com.afleet.app", category: "panel-links")

    private var targets: [LinkTarget] = []

    /// How many targets are registered, for a diagnostic line. A count, never a tab set (§11).
    var targetCount: Int { targets.count }

    // MARK: - LinkRouterCapability

    func register(_ target: LinkTarget) async {
        targets.append(target)
    }

    /// Drops every target this tab registered, so a target never outlives the tab that registered
    /// it. `PanelHost.unregister(_:)` awaits this.
    func unregister(tab: PanelTabID) async {
        targets.removeAll { $0.tab == tab }
    }

    /// Finds the most specific registered target, pops its tab out first when the destination is
    /// `.newWindow`, and then delivers **both** the link and the destination.
    ///
    /// The destination goes to the handler because C7's W5 says so: a handler given only the link
    /// cannot tell an in-panel open from a popped-out one, and a host that hard-coded
    /// `.currentPanel` would satisfy every routing test and drop that distinction at integration.
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        guard let target = mostSpecific(for: link) else {
            fallback(link)
            return
        }
        if destination == .newWindow {
            if let host, let channel = host.selectedChannel {
                host.popOut(target.tab, channel: channel)
            } else {
                // The handler is still told `.newWindow` below, so it would render for a window
                // that was never opened. Nothing here can open one — the host's notion of the
                // current channel is the only channel this capability has, and there is none when
                // the window is on Activity — so the mismatch is reported rather than hidden.
                // `LinkRouterCapability.open(_:from:)` carrying the channel would remove the case
                // altogether, and that is an X7 amendment: see this child's Parent revisions.
                diagnostic("a new-window link had no channel to pop its tab out for")
            }
        }
        await target.open(link, destination)
    }

    // MARK: - Picking

    /// Highest `specificity` wins; ties break by `PanelTabID`'s canonical order, so the choice is
    /// total and does not depend on registration order.
    private func mostSpecific(for link: WorkspaceLink) -> LinkTarget? {
        let handling = targets.filter { $0.handles(link) }
        return handling.min { left, right in
            if left.specificity != right.specificity { return left.specificity > right.specificity }
            return Self.order(left.tab) < Self.order(right.tab)
        }
    }

    private static func order(_ id: PanelTabID) -> Int {
        PanelTabID.allCases.firstIndex(of: id) ?? PanelTabID.allCases.count
    }

    /// C7's W5 rule, restated here because C5 ships before C7.2 exists: a `.url` nobody claimed
    /// goes to the system, and every other kind is a diagnostic line.
    private func fallback(_ link: WorkspaceLink) {
        switch link {
        case .url(let url):
            openExternally(url)
        case .file:
            diagnostic("no panel target for a file link")
        case .diff:
            diagnostic("no panel target for a diff link")
        case .commit:
            diagnostic("no panel target for a commit link")
        case .pullRequest:
            diagnostic("no panel target for a pull-request link")
        case .command:
            diagnostic("no panel target for a command link")
        }
    }
}
