import Foundation
import SwiftUI
import FleetKit

/// The channel's agent runs, drawn (root §8.8): one row per task id, nested under the run that
/// spawned it, with the two empty states worded apart.
///
/// **One row per task id, however many times the engine restarts it.** That is C3's rule, enforced
/// in `AgentRunTree.apply(taskStarted:at:)`, and this view inherits it by drawing the tree rather
/// than the frames: a re-armed id is one row whose `startedCount` moved and whose elapsed origin did
/// not.
///
/// **The nesting is the tree's, not the depth's.** `spawn_depth` says how deep a run is and cannot
/// say *under which* run, so two unrelated depth-2 runs are indistinguishable by it. The parent link
/// comes from C3's two-step join (and, once a metadata source exists, from that); this view reads
/// `children(of:)` and the depth only indents.
struct AgentTreeView: View {

    let model: AgentsModel

    var body: some View {
        let read = model.read
        switch read.state {
        case .tree:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.visibleRows(read: read, collapsed: model.collapsed), id: \.id) { row in
                        AgentNodeRow(content: row.content,
                                     isSelected: model.selectedRun == row.id,
                                     disclosure: row.disclosure,
                                     toggle: { model.toggle(row.id) },
                                     select: { model.select(row.id) })
                            .id(Self.identity(of: row.id))
                    }
                }
                .padding(8)
            }
        case .noRuns:
            AgentTreeEmptyState(sentence: AgentTreeEmptyState.noRuns)
        case .noWire:
            AgentTreeEmptyState(sentence: AgentTreeEmptyState.noWire)
        }
    }

    /// One drawn row: the node, whether its branch can be opened, and whether it is.
    struct Row: Identifiable, Hashable, Sendable {
        let id: AgentRunID
        let content: AgentNodeContent
        let disclosure: AgentNodeRow.Disclosure
    }

    /// The rows the outline shows, depth-first from `roots` in the tree's own order, skipping the
    /// descendants of a branch the user closed.
    ///
    /// Pure and static, so the shape of the outline is assertable without a render pass — which is
    /// what lets a test say "the depth-2 node is *under* the depth-1 node" rather than "both are
    /// somewhere on screen".
    ///
    /// A branch is open unless the user closed it: a tree that arrived collapsed would hide the
    /// nesting that is the whole reason this surface exists. The cycle guard is not decoration —
    /// `AgentRunTree.link` refuses to parent a node to itself, but nothing in it refuses a longer
    /// cycle, and an outline that met one would recurse until the stack ran out.
    static func visibleRows(read: AgentRunRead, collapsed: Set<AgentRunID>) -> [Row] {
        var rows: [Row] = []
        var seen: Set<AgentRunID> = []
        func walk(_ id: AgentRunID) {
            guard let content = read.content(of: id), seen.insert(id).inserted else { return }
            let children = read.children(of: id)
            let disclosure: AgentNodeRow.Disclosure =
                children.isEmpty ? .leaf : (collapsed.contains(id) ? .collapsed : .expanded)
            rows.append(Row(id: id, content: content, disclosure: disclosure))
            guard disclosure == .expanded else { return }
            for child in children { walk(child) }
        }
        for root in read.roots { walk(root) }
        return rows
    }

    /// The SwiftUI identity of a run's row. A task id is drawable and never printable (§11): it
    /// keys the row here and is stated in no report.
    static func identity(of run: AgentRunID) -> String { "agent-run:\(run)" }
}

/// The two states a tree with nothing to draw is in, worded apart (child spec D10).
///
/// "No runs" and "we cannot see the runs" are different facts. The tree is wire-fed — every archived
/// and every foreign channel has none at all — and a user told the first when the second is true has
/// been misinformed about their own history. The sentences are values so both this view and a test
/// name the same one.
struct AgentTreeEmptyState: View {

    let sentence: String

    static let noRuns = "No agent runs in this channel."

    static let noWire = "This channel's agent runs cannot be shown: the run tree is built from a "
        + "live session's frames, and this channel is being read from its transcript alone."

    var body: some View {
        VStack {
            Text(sentence)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
