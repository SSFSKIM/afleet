import Foundation
import FleetKit

/// The Agents tab's read of C3's `AgentRunTree`, derived from a `ChannelTimeline` in one pass.
///
/// **Derived, never stored.** The tree is C3's, reduced by the wire reducer and published on
/// `ChannelTimeline.agents`; this value is recomputed from a published timeline rather than kept
/// beside it, because a copy this leaf held could drift from the items its nodes point at. It is
/// the same discipline C6.1's `TimelineNeighbourhood` follows and for the same reason.
///
/// **Three states, not two** (child spec D10). A channel with no runs and a channel whose tree is
/// nil are different facts: the tree is wire-fed, so every archived and every foreign channel has
/// none at all, and a user told "no agent runs" when the truth is "we cannot see the runs" has been
/// misinformed. A two-case enum would force one of them to lie.
struct AgentRunRead: Hashable, Sendable {

    enum State: Hashable, Sendable {
        /// The channel has a tree and it holds runs. `roots` is `AgentRunTree.roots` — the nodes no
        /// source gave a parent, in first-`task_started` order.
        case tree(roots: [AgentRunID])
        /// The channel has a tree and it is empty.
        case noRuns
        /// `ChannelTimeline.agents` is nil: the tree is wire-fed and this channel has no wire.
        case noWire
    }

    let state: State

    private let contents: [AgentRunID: AgentNodeContent]
    private let childIDs: [AgentRunID: [AgentRunID]]

    /// One pass over the tree and the overlay's decisions. Nothing else on the timeline is read.
    init(timeline: ChannelTimeline) {
        guard let tree = timeline.agents else {
            state = .noWire
            contents = [:]
            childIDs = [:]
            return
        }
        // Pending decisions per run, counted once rather than per node: the overlay holds one
        // dictionary for the channel and a filter per node would walk it as many times as the tree
        // has runs.
        var waiting: [AgentRunID: Int] = [:]
        for decision in timeline.overlay.decisions.values {
            guard decision.state == .pending, let agent = decision.agentID else { continue }
            waiting[agent, default: 0] += 1
        }

        var contents: [AgentRunID: AgentNodeContent] = [:]
        var childIDs: [AgentRunID: [AgentRunID]] = [:]
        contents.reserveCapacity(tree.nodes.count)
        childIDs.reserveCapacity(tree.nodes.count)
        for (id, node) in tree.nodes {
            contents[id] = AgentNodeContent(node: node,
                                            isParked: tree.isParked(id),
                                            waitingCount: waiting[id] ?? 0)
            childIDs[id] = tree.children(of: id)
        }
        self.contents = contents
        self.childIDs = childIDs
        // `roots` and not the depth-1 nodes (child spec D8, tracker 13). The two agree on every
        // well-formed session and diverge for exactly one case: a nested run whose parent no source
        // answered for. Filtering to depth 1 would drop that run out of the tree entirely; taking
        // `roots` shows it at the top with its depth stated, which is the truth.
        self.state = tree.nodes.isEmpty ? .noRuns : .tree(roots: tree.roots)
    }

    /// The ordered top-level runs. Empty for both empty states, which is why `state` and not this is
    /// what a caller branches on.
    var roots: [AgentRunID] {
        if case .tree(let roots) = state { return roots }
        return []
    }

    func content(of id: AgentRunID) -> AgentNodeContent? { contents[id] }

    func children(of id: AgentRunID) -> [AgentRunID] { childIDs[id] ?? [] }

    /// Whether this channel's tree holds the run. A chip clicked on a channel whose tree is nil
    /// resolves to nothing, and the pane says so rather than fabricating a selection (D5).
    func knows(_ id: AgentRunID) -> Bool { contents[id] != nil }

}
