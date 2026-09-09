import Foundation
import AfleetCore
import PanelHostAPI
import FleetKit
import Workbench

/// The app-side seam C7.7's two panels are built from: the pair of tabs `AppModel.init` registers,
/// and the one `.commit` target that has to exist before anything renders them (spec Design §2,
/// §7, §11; C7's W5).
///
/// It is a composition helper in `BrowserWiring`'s shape and holds no state: everything below is
/// constructed by `AppModel.init` and owned by the panel host from the moment it is registered.
///
/// **What crosses to the panel is a capability, not the app.** `SourceControlTabHost` is the
/// panel package's own two-method protocol — which channel a delivery belongs to, and bring the
/// tab forward — and that is all `SourceControlTab` can ask for; X7 gives a tab capabilities and
/// never the host (C7.5 took the same shape with `FilesTabHost`). The tab holds it **weakly**,
/// through its own `HostAnchor`, which is what keeps the registry the host owns from holding the
/// host: the host holds the panel host, the panel host holds the tab, and a strong hold back would
/// close that circle. The same rule governs any closure added here.
///
/// **The GitHub tab is handed nothing at all**, because it registers nothing: this leaf emits
/// `.pullRequest(number)` and lets C7.6's Browser resolve it (Design §9). Its runner and its
/// environment come from the `ChannelContext` X7 hands `makeSession`, per channel, which is also
/// where the Source Control tab's `git` environment comes from — X11's capture, and this file
/// names no binary and no `PATH`.
enum SourceControlWiring {

    /// The two tabs the app registers, built against the capability the app conforms to.
    ///
    /// Returned together because they are registered together and neither is useful alone: the
    /// GitHub tab reads the branch of the repository the Source Control tab shows, and a build
    /// that registered one would leave X7's Cmd+1…7 indexing over a tab set that is missing a
    /// member the tab bar draws.
    @MainActor
    static func makeTabs(host: any SourceControlTabHost) -> (sourceControl: SourceControlTab, github: GitHubTab) {
        (SourceControlTab(host: host), GitHubTab())
    }

    /// Registers the Source Control tab's `.commit` target, once (Design §7).
    ///
    /// It is registered **with the tab** rather than with the tab's first session: the host builds
    /// a session lazily, for rendering, so a `.commit` raised from a timeline row before anyone has
    /// looked at Source Control would otherwise find no target and take W5's fallback — which for
    /// a commit hash is nothing anyone can see. `SourceControlTab.registerLinkTargets(through:)`
    /// carries the once-only flag, so this is safe to call again and adds nothing.
    ///
    /// Spawned by the caller rather than awaited here, because `PanelHost.register` is X7's
    /// synchronous member and `LinkRouterCapability.register` is not — the registry is an actor —
    /// and the pair cannot both happen in an initialiser. That is safe for this target where it
    /// was not for the Browser's: a `WorkspaceLink` can only be opened through a `ChannelContext`,
    /// and no context exists until `bindWorkspace`.
    @MainActor
    static func registerLinkTargets(of tab: SourceControlTab, through links: any LinkRouterCapability) async {
        await tab.registerLinkTargets(through: links)
    }

    /// Connects the two tabs of one channel, in the one direction Design §8 names: the Source
    /// Control panel learns the branch on every read cycle and its watch reports a checkout made
    /// outside the app, and the GitHub tab re-reads on that.
    ///
    /// Without it `branchDidChange(to:)` has no caller and a retained GitHub tab shows the branch
    /// it first read until the user presses *Refresh*.
    ///
    /// **It is a link and not a reference.** `BranchChangeLink` holds both sessions weakly and
    /// resolves the GitHub side at delivery: X7 retains one session per (tab, channel) under an
    /// LRU, a channel may never have shown the GitHub tab at all, and a hold from one session to
    /// the other would make the pair evictable only together. Nothing is created here either — a
    /// branch change for a channel whose GitHub tab has never been visited spends no round trip.
    ///
    /// It is fed from the host's session-creation hook because X7 hands a tab a `ChannelContext`
    /// and no host, so a tab cannot say "this channel now has a session"; the app is the only
    /// place both halves are visible.
    @MainActor
    static func connectBranchChanges(through link: BranchChangeLink<ChannelKey>,
                                     on host: PanelHostModel) {
        host.didMakeSession = { [weak link] _, context, session in
            link?.sessionWasMade(session, for: context.key)
        }
    }
}
