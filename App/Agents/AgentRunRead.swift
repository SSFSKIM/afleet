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
    private let parentIDs: [AgentRunID: AgentRunID]

    /// One pass over the tree and the overlay's decisions. Nothing else on the timeline is read.
    init(timeline: ChannelTimeline) {
        guard let tree = timeline.agents else {
            state = .noWire
            contents = [:]
            childIDs = [:]
            parentIDs = [:]
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
        var parentIDs: [AgentRunID: AgentRunID] = [:]
        contents.reserveCapacity(tree.nodes.count)
        childIDs.reserveCapacity(tree.nodes.count)
        for (id, node) in tree.nodes {
            contents[id] = AgentNodeContent(node: node,
                                            isParked: tree.isParked(id),
                                            waitingCount: waiting[id] ?? 0)
            childIDs[id] = tree.children(of: id)
            parentIDs[id] = node.parent
        }
        self.contents = contents
        self.childIDs = childIDs
        self.parentIDs = parentIDs
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

    /// The run's parents, nearest first. Empty for a root and for an id the tree does not hold.
    ///
    /// What it is for: a run reached from a chip has to be *visible* when the panel lands on it, and
    /// the branch above it may be one the user closed. The walk is cycle-guarded for the reason the
    /// outline's is — `AgentRunTree.link` refuses to parent a node to itself and refuses nothing
    /// longer, and a walk that met a longer cycle would not stop.
    func ancestors(of id: AgentRunID) -> [AgentRunID] {
        var found: [AgentRunID] = []
        var seen: Set<AgentRunID> = [id]
        var current = id
        while let parent = parentIDs[current], seen.insert(parent).inserted {
            found.append(parent)
            current = parent
        }
        return found
    }

    /// Whether this channel's tree holds the run. A chip clicked on a channel whose tree is nil
    /// resolves to nothing, and the pane says so rather than fabricating a selection (D5).
    func knows(_ id: AgentRunID) -> Bool { contents[id] != nil }

    /// One run's items: the channel's items whose provenance names this agent, in the timeline's
    /// own order.
    ///
    /// **A filter, never a reduction** (child spec D4, root §7.3). The wire reducer keeps one
    /// `ItemBuilder` per agent and stamps `Provenance.agentID` on every item of that stream, and
    /// the file half stamps the same field — so this one expression is the run's transcript live and
    /// from disk, and the items are C3's, unmodified.
    ///
    /// Static and pure so the transcript pane's contents are testable without a render pass.
    static func items(of run: AgentRunID, in timeline: ChannelTimeline) -> [TimelineItem] {
        timeline.items.filter { $0.provenance.agentID == run }
    }
}
