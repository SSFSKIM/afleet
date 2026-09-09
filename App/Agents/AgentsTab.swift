import Foundation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// The Agents tab (root §8.8, contract Y3), registered under `.agents` where the lifecycle first
/// exists.
///
/// **A plain registration, not a handover.** `PlaceholderTab.id` is `.thread` alone and a repo-wide
/// search finds no other registration of `.agents`, so nothing holds the id and the
/// `unregister`-then-`register` pair the Thread tab needs has nothing to unregister here. Y3's "the
/// same way as `.thread`" is wrong on the facts and this leaf's `[parent-impact]` records why. It
/// still runs in `performLaunch`, for Y3's *second* reason: the lifecycle exists nowhere earlier.
///
/// **The tab holds only what is app-scoped, and holds none of it as a reference it could duplicate.**
/// The one `ChannelTimelineRegistry` is reached through an injected closure and the selection store
/// is handed in; nothing here constructs either. A panel holding its host is a retain path, X7 hands
/// panels capabilities rather than the host, and `Mirror` does not descend into a capture — which is
/// what makes "this tab stores no host and no registry" a thing a test can prove.
@MainActor
final class AgentsTab: PanelTab {

    let id: PanelTabID = .agents
    var title: String { id.defaultTitle }
    var systemImage: String { id.defaultSystemImage }

    private let timelines: AgentsModel.TimelineReach
    private let selection: AgentSelectionStore

    init(timelines: @escaping AgentsModel.TimelineReach, selection: AgentSelectionStore) {
        self.timelines = timelines
        self.selection = selection
    }

    /// Available for every channel (child spec D10). A channel with no runs and a channel whose
    /// tree is nil are both states this pane states in words; a tab that disappeared for them would
    /// leave the user with no way to ask, and no way to be told which of the two is true.
    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        AgentsModel(channel: context.key, timelines: timelines, store: selection)
    }

    func makeView(session: any PanelTabSession, context: ChannelContext,
                  surface: PanelSurface) -> AnyView {
        guard let view = panelView(session: session, surface: surface) else { return AnyView(EmptyView()) }
        return AnyView(view)
    }

    /// The same view, before it is erased. `makeView` has to answer `AnyView`, and an `AnyView` is
    /// not a thing a test can ask which surface it was built for — C7.6's seam, for its reason.
    func panelView(session: any PanelTabSession, surface: PanelSurface) -> AgentsPanelView? {
        guard let model = session as? AgentsModel else { return nil }
        return AgentsPanelView(model: model, surface: surface)
    }

    // MARK: - The command link (child spec D15, tracker 207)

    /// The Agents tab's claim on `WorkspaceLink.command("agents")`, X10's `.native` destination that
    /// nothing has answered until now — `/agents` typed in the composer answers with a diagnostic.
    ///
    /// **Registered with the tab and never with a session**, the Browser's and Files' rule: a
    /// session is built lazily for rendering, so a link raised before anyone opened the tab would
    /// otherwise resolve to nothing. Selecting the tab is the whole of what it does — the panel then
    /// draws whichever channel the window is on, which is what "open the Agents panel" means.
    ///
    /// `selectTab` is injected for the reason `BrowserLinkTargets.TabRequest` is: `PanelHost.select`
    /// is the host's and a target holding the host is a retain path.
    nonisolated static let commandDestination = "agents"

    /// Higher than the Browser's page claim because this is a claim on one exact command string
    /// rather than on a class of links; nothing else in the app claims a `.command` at all.
    nonisolated static let specificity = 50

    func linkTargets(through selectTab: @escaping @MainActor @Sendable () -> Void) -> [LinkTarget] {
        [LinkTarget(tab: .agents, specificity: Self.specificity,
                    handles: { link in
                        if case .command(let name) = link { name == Self.commandDestination } else { false }
                    },
                    open: { _, _ in selectTab() })]
    }
}

/// What the panel draws. Task 3 replaces this body with the run tree and its two empty states; the
/// three cases are named here because the tab's registration and this leaf's states land together.
struct AgentsPanelView: View {

    let model: AgentsModel
    /// Which window surface this instance is being drawn on (X7). Not read yet — this panel
    /// describes a view rather than owning one — and carried so the seam exists where C7.6 put it.
    let surface: PanelSurface

    var body: some View {
        switch model.read.state {
        case .tree(let roots):
            VStack(alignment: .leading) {
                Text("^[\(roots.count) run](inflect: true)")
                selectionLine
            }
        case .noRuns:
            Text("No agent runs in this channel.")
        case .noWire:
            Text("This channel's agent runs are not visible: the run tree is built from a live session's frames, and this channel has none.")
        }
    }

    /// What the pane has open. A run id is **drawable** and never printable (§11): it is shown here
    /// and stated in no report. A run the tree does not hold is said so rather than selected
    /// (child spec D5).
    @ViewBuilder
    private var selectionLine: some View {
        switch model.selection {
        case .run:
            if let run = model.selectedRun { Text(verbatim: run).monospaced() }
        case .unknownRun:
            Text("That agent run is not in this channel's tree.")
        case .none:
            EmptyView()
        }
    }
}
