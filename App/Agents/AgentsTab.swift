import AppKit
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
    /// X5, for the node actions of §8.8 (contract Y5). Nil before a launch reaches a workspace: a
    /// pane that reads runs and offers no action on them is the honest state for a tab with no fleet
    /// behind it, and it is the state each action's own guard already answers for.
    private let lifecycle: (any LifecycleAPI)?
    /// Where *Copy agent id* writes (child spec D12). The general board in the app; a suite hands in
    /// a named one, because a test that took the user's clipboard while it ran would be a side effect
    /// nobody asked for.
    private let pasteboard: NSPasteboard
    /// How a decision answered on a node reaches the channel's fold (contract Y7). Two closures over
    /// the app's one `ChannelTimelineRegistry`, the shape `ThreadTab` takes and for its reason: the
    /// engine sends **no frame back for an answer**, so `HostSignal.decisionAnswered` on the fold is
    /// the only thing that can move the item out of `.pending`, and a second registry here would be
    /// the duplicate-capability path the C6 cut exists to prevent.
    private let fold: ChannelFold
    /// The app's **one** reservation set, `AppModel.decisions`. A set of this panel's own would let
    /// a card answered here and the same card answered in Activity both reach the wire, and the
    /// second would come back `decisionGone` — an error about afleet's bookkeeping dressed as an
    /// error about the engine.
    private let reservations: DecisionReservations

    init(timelines: @escaping AgentsModel.TimelineReach, selection: AgentSelectionStore,
         lifecycle: (any LifecycleAPI)? = nil, pasteboard: NSPasteboard = .general,
         fold: ChannelFold = ChannelFold(), reservations: DecisionReservations = DecisionReservations()) {
        self.timelines = timelines
        self.selection = selection
        self.lifecycle = lifecycle
        self.pasteboard = pasteboard
        self.fold = fold
        self.reservations = reservations
    }

    /// Available for every channel (child spec D10). A channel with no runs and a channel whose
    /// tree is nil are both states this pane states in words; a tab that disappeared for them would
    /// leave the user with no way to ask, and no way to be told which of the two is true.
    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        // The link router is the **channel's own** — X7 hands a tab its capabilities through the
        // context, and *Open transcript file* raises a `.file` link on it (child spec D12).
        AgentsModel(channel: context.key, timelines: timelines, store: selection,
                    actions: lifecycle.map {
                        AgentNodeActions(lifecycle: $0, channel: context.key, links: context.links,
                                         pasteboard: pasteboard)
                    },
                    answering: lifecycle.map(makeAnswering))
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

    /// The object a decision card's answer leaves by, built per session and wired to the two things
    /// it must not own (contract Y7).
    ///
    /// The reservation set is the **app's** and is handed in; the raise is this channel's fold. Both
    /// are ways for the mount to be silently wrong — a private set disables only this surface's
    /// buttons, and a raise that went nowhere leaves the card reading `.pending` for ever with every
    /// other assertion green. It is C6.1's `makeAnswering()` shape, on this leaf's own seam.
    private func makeAnswering(_ lifecycle: any LifecycleAPI) -> DecisionAnswering {
        let answering = DecisionAnswering(lifecycle: lifecycle, reservations: reservations)
        answering.raise = { [fold] key, signal in await fold.raise(key, signal) }
        return answering
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

/// What the panel draws: the run tree, and the selected run's transcript beside it (root §8.8).
///
/// Split rather than stacked, and resizable, because the two halves are read at different widths:
/// the tree is a list of short rows and the transcript is C6.1's message list, which is the same
/// content the channel column draws. `HSplitView` holds no state this leaf has to carry — what
/// survives a channel switch is on the session, which the host retains.
struct AgentsPanelView: View {

    let model: AgentsModel
    /// Which window surface this instance is being drawn on (X7). Not read yet — this panel
    /// describes a view rather than owning one — and carried so the seam exists where C7.6 put it.
    let surface: PanelSurface

    var body: some View {
        HSplitView {
            AgentTreeView(model: model)
                .frame(minWidth: 200)
            AgentTranscriptPane(model: model)
                .frame(minWidth: 240)
        }
    }
}