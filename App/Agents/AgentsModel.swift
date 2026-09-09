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
/// **The read is derived on demand and never stored.** `read` recomputes from the channel model's
/// published `ChannelTimeline`, which is what `@Observable` invalidates on; a cached copy here would
/// be a second version of C3's tree with nothing keeping the two together.
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

    /// Which nodes are disclosed. Per channel, so a tree opened in one channel does not collapse
    /// because another channel's was.
    var expanded: Set<AgentRunID> = []

    init(channel: ChannelKey, timelines: @escaping TimelineReach, store: AgentSelectionStore) {
        self.channel = channel
        self.timelines = timelines
        self.store = store
    }

    /// The tree, as this pane reads it. A channel with no model has no fold and therefore no tree,
    /// which is `.noWire` — the same answer the read gives for a channel whose fold has none.
    var read: AgentRunRead {
        AgentRunRead(timeline: timelines(channel) ?? ChannelTimeline())
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
}
