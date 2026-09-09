import Foundation
import ClaudeWire
import FleetKit

/// The Agents tab's read of C3's `AgentRunTree`, derived from a `ChannelTimeline` in one pass.
///
/// **Derived, never stored.** The tree is C3's, reduced by the wire reducer and published on
/// `ChannelTimeline.agents`; this value is recomputed from a published timeline rather than kept
/// beside it, because a copy this leaf held could drift from the items its nodes point at. It is
/// the same discipline C6.1's `TimelineNeighbourhood` follows and for the same reason.
///
/// **Three states, not two** (child spec D10). A channel with no runs and a channel whose fold has
/// not been built are different facts, and a two-case enum would force one of them to lie. Since the
/// C3 corrective the second is no longer "this channel has no wire": `ChannelTimeline.agents` is nil
/// only *before* `open` builds the reducer, and non-nil afterwards for every channel kind — an
/// archived or foreign channel is fed from the `.meta.json` sidecars beside its transcript and has
/// the same tree the same corpus produces live. So the third state is the pre-open one, and a user
/// told "no agent runs" while the channel is still opening has been told something not yet known.
struct AgentRunRead: Hashable, Sendable {

    enum State: Hashable, Sendable {
        /// The channel has a tree and it holds runs. `roots` is `AgentRunTree.roots` — the nodes no
        /// source gave a parent, in first-`task_started` order.
        case tree(roots: [AgentRunID])
        /// The channel has a tree and it is empty.
        case noRuns
        /// `ChannelTimeline.agents` is nil: this channel's fold has not been built yet, so nothing
        /// has read its runs — neither the wire's task frames nor the sidecars on disk. It is the
        /// state of a channel the host has no model for and of one whose `open` has not returned.
        case notOpened
    }

    let state: State

    private let contents: [AgentRunID: AgentNodeContent]
    private let childIDs: [AgentRunID: [AgentRunID]]
    private let parentIDs: [AgentRunID: AgentRunID]

    /// One pass over the tree and the overlay's decisions. Nothing else on the timeline is read.
    init(timeline: ChannelTimeline) {
        guard let tree = timeline.agents else {
            state = .notOpened
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
        // C3's registry mirror, as the nodes' backgrounding eligibility and nothing else. §8.8 offers
        // *Move to background* only while a run is in the foreground and the mirror knows it, and the
        // mirror is the only thing that can answer that. It travels on `ChannelTimeline`, in the same
        // snapshot as the tree and the items, so a node's offer cannot come from a publish the rows
        // around it never saw.
        let mirror = timeline.registry
        for (id, node) in tree.nodes {
            // Whether this run's sources disagreed about its parent, read off the answers each
            // source gave rather than off `conflicts` — that value is a list of sentences naming two
            // task ids apiece (§11), and what the node needs is the fact.
            let answers = tree.parentAnswers[id] ?? [:]
            contents[id] = AgentNodeContent(node: node,
                                            entry: mirror.entries[id],
                                            isParked: tree.isParked(id),
                                            waitingCount: waiting[id] ?? 0,
                                            parentDisputed: Set(answers.values).count > 1)
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

    /// The two things this read is derived from. Everything else on the timeline — the items, the
    /// streaming preview — is read by the transcript pane and never by the tree.
    struct Source: Equatable, Sendable {
        let agents: AgentRunTree?
        let decisions: [RequestID: DecisionItem]
        /// The registry mirror's third of the read — **as `TaskCardEligibility` and never as the
        /// mirror itself** (contract Y2, tracker 321's rule).
        ///
        /// `RegistryEntry.lastFrameAt` is stamped by every `task_progress` heartbeat, so a key over
        /// the whole mirror would rebuild the tree's read several times a second for a chatty agent
        /// and change nothing a node draws. `TaskCardEligibility` is the middle the task card
        /// already settled on: a run appearing, finishing, being moved to the background or losing
        /// its tool-use id changes it, and a heartbeat does not. Reusing that value rather than
        /// writing a second one is what keeps the two hosts' answers from drifting apart.
        ///
        /// **What it cannot see is one id being replaced by another**, since the value carries
        /// whether a run is eligible and not which block names it. Nothing publishes that state on
        /// its own — a re-engaged run is a fresh `task_started` and moves the instant beside it —
        /// so it is a gap in the key rather than a wrong answer, and it is tracker 178 — closing it
        /// means widening a value another host owns.
        let eligibility: TaskCardEligibility

        init(_ timeline: ChannelTimeline) {
            agents = timeline.agents
            decisions = timeline.overlay.decisions
            eligibility = TaskCardEligibility(timeline.registry)
        }
    }

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

    /// The requests the engine is waiting on **for one run** (child spec D6, item 52).
    ///
    /// `DecisionItem.agentID` is set by the wire reducer from the request payload, so this one
    /// expression is the node's cards live and from disk — a filter over C3's overlay, never a
    /// reduction of this leaf's own (§7.3).
    ///
    /// Only `.pending`: a settled request is a reading and not a card to answer, and the node's
    /// waiting badge counts the same set. Ordered by the item's own instant, with the request id
    /// breaking a tie, because a dictionary has no order and a node whose two cards swapped places
    /// between two body evaluations would move the button under the user's cursor.
    static func decisions(of run: AgentRunID, in timeline: ChannelTimeline) -> [DecisionItem] {
        timeline.overlay.decisions.values
            .filter { $0.agentID == run && $0.state == .pending }
            .sorted { ($0.timestamp ?? .distantPast, $0.requestID.rawValue)
                        < ($1.timestamp ?? .distantPast, $1.requestID.rawValue) }
    }
}

/// One channel's read, rebuilt when the tree moved and not when the channel merely streamed
/// (child spec D7).
///
/// The read walks every node, sanitises four wire strings per node and counts the overlay's pending
/// decisions. A panel body evaluates on every streaming delta — thirty a second, none of which
/// changes a run — and the tree view asks for the read more than once per evaluation, so what a
/// delta cost grew with the number of runs in the channel and with how often the pane was drawn.
///
/// Keyed on `AgentRunRead.Source`: the tree and the decisions, the two values the read is derived
/// from, and not the whole timeline — a key that included the items would rebuild on exactly the
/// deltas this exists to ignore. It is `TimelineNeighbourhoodCache`'s shape (C6.1) for
/// `TimelineNeighbourhood`'s reason.
@MainActor
final class AgentRunReadCache {

    /// How many reads this cache has had to build. Counted for the reason C6.1 counts its own: a
    /// cost nothing can read is a cost nothing can hold.
    private(set) var builds = 0

    private var key: AgentRunRead.Source?
    private var cached = AgentRunRead(timeline: ChannelTimeline())

    /// Drops the held read, so the next access builds one from the timeline as it now stands.
    ///
    /// The one caller is §8.4's `{backgrounded: false}` arm: the engine has said the registry row the
    /// panel was reading is stale, and the cache's key cannot see that — the reply is not a publish.
    /// Nothing is fetched, because the read is derived; what changes is that the derivation stops
    /// being answered from a snapshot the engine has contradicted.
    func invalidate() { key = nil }

    func read(of timeline: ChannelTimeline) -> AgentRunRead {
        let key = AgentRunRead.Source(timeline)
        if let held = self.key, held == key { return cached }
        cached = AgentRunRead(timeline: timeline)
        self.key = key
        builds += 1
        return cached
    }
}
