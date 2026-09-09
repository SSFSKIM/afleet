import Foundation
import Observation
import AfleetCore
import FleetKit
import PanelHostAPI

/// The Agents tab's session: one per (tab, channel), retained by the host (contract X7).
///
/// Everything per-channel lives here — which run is open, which nodes are disclosed — because
/// SwiftUI discards `@State` when a channel switch unmounts the subtree, and a pane that forgot the
/// run the user was reading on every switch would not be a panel at all. That is the whole reason
/// X7 has sessions.
///
/// **The read is derived from the published timeline and never held past it.** `read` is computed
/// from the channel model's published `ChannelTimeline`, which is what `@Observable` invalidates on;
/// a copy kept beside that timeline would be a second version of C3's tree with nothing keeping the
/// two together. What is kept is a cache keyed on the tree and the decisions themselves, so a read
/// is answered from the last one exactly while both stand still and is rebuilt the instant either
/// moves — which is holding the derivation, not the tree.
@MainActor
@Observable
final class AgentsModel: PanelTabSession {

    let channel: ChannelKey

    /// How this pane reads a channel's fold: the app's one `ChannelTimelineRegistry`, as a closure
    /// and not a reference.
    ///
    /// A panel holding a registry is the duplicate-capability path the C6 cut exists to prevent, and
    /// `Mirror` does not descend into a capture — which is what lets a test prove the tab holds
    /// neither a registry nor a host. It answers the *timeline* and not the model, because the
    /// timeline is the whole of what this pane reads and a closure that handed back the model would
    /// be handing back a second route to the fold. Observation still reaches through it: the closure
    /// is invoked while a body is being evaluated, so the `@Observable` read inside it is tracked
    /// exactly as a direct one would be.
    typealias TimelineReach = @MainActor (ChannelKey) -> ChannelTimeline?

    @ObservationIgnored private let timelines: TimelineReach
    @ObservationIgnored private let store: AgentSelectionStore
    /// The read, held only as long as the two values it is derived from stand still (child spec D7).
    @ObservationIgnored private let reads = AgentRunReadCache()

    /// The per-run transcript's renderer, and with it its table, its row heights and its scroll
    /// position (child spec D4). The **session** owns it and not the view: a SwiftUI view value
    /// preserves nothing across a body evaluation, and the host retains this session across a
    /// channel switch, which is what keeps the run the user was reading where they left it.
    ///
    /// It is not the channel column's renderer and could not be: two tables cannot share one
    /// controller's row heights and scroll position.
    @ObservationIgnored let transcript = NativeTimelineRenderer()

    /// The transcript's own folding and edit state, for the reason the channel column's are the
    /// column's: a cluster folded while it is off screen must still be folded when it scrolls back,
    /// and the row value that folded it has been discarded many times over by then. They are the
    /// pane's own rather than the channel's, because a fold is a property of the surface it was made
    /// on and the same item can be on screen in both.
    @ObservationIgnored let transcriptCollapse = TimelineCollapseState()
    @ObservationIgnored let transcriptEditing = TimelineEditState()

    /// Which branches the user has **closed**. Per channel, so a tree opened in one channel does
    /// not collapse because another channel's was.
    ///
    /// The closed set and not the open one: a tree arrives fully disclosed, because the nesting is
    /// the whole reason this surface exists, and a set of open ids would need seeding from a tree
    /// that has not been read yet.
    var collapsed: Set<AgentRunID> = []

    func toggle(_ run: AgentRunID) {
        if collapsed.contains(run) { collapsed.remove(run) } else { collapsed.insert(run) }
    }

    /// What a node's actions go out by (gate G3, contract Y5). Nil for a pane built before a launch
    /// reached a workspace: the tree still reads, and there is nothing to act on it with.
    ///
    /// `@ObservationIgnored` on the **reference**, which is not the same as ignoring the object: the
    /// actions are `@Observable` in their own right, so a body that reads a banner or an offer is
    /// invalidated by that object rather than by this session's own tracking.
    @ObservationIgnored let actions: AgentNodeActions?

    init(channel: ChannelKey, timelines: @escaping TimelineReach, store: AgentSelectionStore,
         actions: AgentNodeActions? = nil) {
        self.channel = channel
        self.timelines = timelines
        self.store = store
        self.actions = actions
        // §8.4's `{backgrounded: false}` arm: the engine has said the registry row the panel read is
        // stale, and a reply is not a publish — the cache's key cannot see it. Dropping the held read
        // is the whole of "refresh" for a derivation, and wiring it here is what stops the next body
        // being answered from the snapshot the engine has just contradicted.
        actions?.refresh = { [reads] in reads.invalidate() }
    }

    /// The tree, as this pane reads it. A channel with no model has no fold and therefore no tree,
    /// which is `.notOpened` — the same answer the read gives for a channel whose `open` has not
    /// built the reducer yet.
    var read: AgentRunRead {
        reads.read(of: timelines(channel) ?? ChannelTimeline())
    }

    /// What the pane has open, and why it has nothing open when it has nothing open.
    ///
    /// A run id the tree does not know is **not** silently dropped and **not** fabricated into a
    /// selection: a chip on a channel with no wire resolves to nothing today, and a pane that
    /// invented a node for it would be worse than one that said so (child spec D5).
    enum Selection: Hashable, Sendable {
        case none
        case run(AgentRunID)
        /// A run was asked for and this channel's tree does not hold it.
        case unknownRun
    }

    var selection: Selection {
        guard let run = store.selection(in: channel) else { return .none }
        return read.knows(run) ? .run(run) : .unknownRun
    }

    /// The run the pane has open, or nil for both of the other two cases.
    var selectedRun: AgentRunID? {
        if case .run(let run) = selection { return run }
        return nil
    }

    /// Opening a node from inside the pane writes the same store the chip's navigation does, so one
    /// channel has one open run however it was reached.
    func select(_ run: AgentRunID?) { store.select(run, in: channel) }

    /// What the per-run transcript is handed: the channel's own rows whose provenance names this
    /// run, in the timeline's order (child spec D4, gate G2).
    ///
    /// **The preview is not passed through.** `StreamingPreview` carries no agent attribution at all
    /// — the fold keeps one preview per channel and the reducer drops the stream event's
    /// `parent_tool_use_id` when it opens one — so a tail handed to a run's pane would be the main
    /// thread's words in the subagent's mouth. Nil is the honest answer until a preview can say
    /// whose it is; the gap is filed rather than guessed at.
    ///
    /// **Retracted rows are filtered here too.** A refusal dialog that settled on the channel took
    /// the frame back for the channel, and a run's transcript drawing it again would show a message
    /// the engine has said stopped being true (C6.3's D11). The registry is the **channel model's
    /// own**, handed in by the pane, because a second one would filter nothing; nil is "no channel
    /// model to ask", and then nothing is filtered rather than everything being dropped.
    func input(of run: AgentRunID, retainedBy retraction: RetractionRegistry?) -> TimelineRenderInput {
        let timeline = timelines(channel) ?? ChannelTimeline()
        let rows = AgentRunRead.items(of: run, in: timeline).map(TimelineRow.init)
        return TimelineRenderInput(rows: retraction.map { TimelineListView.retained(rows, by: $0) } ?? rows,
                                   preview: nil)
    }
}
