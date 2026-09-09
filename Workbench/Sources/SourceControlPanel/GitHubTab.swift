// SourceControlPanel: owned by C7.7. Design §2, §9, §11.
import Foundation
import SwiftUI
import PanelHostAPI

/// The GitHub tab (Design §2).
///
/// A tab that owns a model per channel and **registers nothing**: this leaf emits
/// `.pullRequest(number)` and lets C7.6's Browser resolve it, because W5 is binding that Browser
/// registers `.pullRequest` and a second registrant would win by specificity and then either
/// duplicate that resolution or hand the URL back (Design §9).
@MainActor
public final class GitHubTab: PanelTab {

    public let id: PanelTabID = .github
    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    public init() {}

    /// Available for every channel, including one in no repository — which renders this tab's own
    /// empty state. The reason is X7's Cmd+1…7 indexing, as for the Source Control tab (§11).
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    /// Builds the session and reads once for it. `appear()` is `async` and `makeSession` is not,
    /// so the read is spawned here; it is also where "first appearance of the tab for a channel"
    /// happens exactly once, because the host retains this session across the unmount and remount
    /// a channel switch causes (Design §8 — these are network round trips and there is no polling).
    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        let session = GitHubModel(context: context)
        Task { await session.appear() }
        return session
    }

    /// The surface is taken and named — X7 gives it no default — and not read: this tab describes
    /// a view rather than owning one (Design §11).
    public func makeView(session: any PanelTabSession, context: ChannelContext,
                         surface: PanelSurface) -> AnyView {
        guard let view = panelView(session: session, surface: surface) else {
            return AnyView(EmptyView())
        }
        return AnyView(view)
    }

    /// The same view, before it is erased — the seam C7.6's `BrowserTab` established, so that a
    /// test can ask what was made rather than hold an `AnyView`.
    func panelView(session: any PanelTabSession, surface: PanelSurface) -> GitHubPanelPlaceholder? {
        guard let session = session as? GitHubModel else { return nil }
        return GitHubPanelPlaceholder(session: session)
    }
}

/// **The seam T7 fills.** T7 owns `GitHubPanelView`; until it lands this is what the tab
/// describes, so the surface parameter is wired and asserted now and the view is invented once, by
/// the task that owns it. Nothing here draws.
struct GitHubPanelPlaceholder: View {
    let session: GitHubModel
    var body: some View { EmptyView() }
}
