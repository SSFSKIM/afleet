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
        VStack(alignment: .leading, spacing: 0) {
            if model.selection == .unknownRun { AgentUnknownRunNotice() }
            tree(read)
        }
    }

    @ViewBuilder
    private func tree(_ read: AgentRunRead) -> some View {
        switch read.state {
        case .tree:
            // The rows are built here and handed down as a value, not built inside the outline's
            // own body: what the panel is about to draw is then a value — the shape of the tree, its
            // order and its disclosure — rather than something only a rendered hierarchy knows.
            AgentOutline(model: model,
                         rows: Self.visibleRows(read: read, collapsed: model.collapsed,
                                                revealing: model.selectedRun))
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
    /// **A selected run is never hidden.** `revealing` is the run the panel is open on, and the
    /// branch above it is disclosed whatever the user closed — a chip click that selected a run
    /// inside a closed branch otherwise reports the run as open while the panel does not show it,
    /// which is a session that disagrees with its own screen.
    ///
    /// It is applied here, over the closed set, rather than by writing into it: the reveal is a
    /// consequence of what is selected and holds however the selection was reached — including the
    /// one that matters, a chip clicked before this pane's session existed — and the branch the user
    /// closed is still closed when they open something else.
    static func visibleRows(read: AgentRunRead, collapsed: Set<AgentRunID>,
                            revealing: AgentRunID? = nil) -> [Row] {
        let collapsed = revealing.map { collapsed.subtracting(read.ancestors(of: $0)) } ?? collapsed
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

/// The rows, drawn, with the open one brought into view.
///
/// Y4's sentence is that a chip click **lands on the run**. Disclosing the branch above it is half
/// of that and `AgentTreeView.visibleRows(read:collapsed:revealing:)` does it; the other half is the
/// row being where the user is looking, on a tree tall enough to have somewhere else to be. A
/// `scrollTo` for an identity no row pinned scrolls nothing, which is what a run the outline is not
/// drawing should do.
struct AgentOutline: View {

    let model: AgentsModel
    let rows: [AgentTreeView.Row]

    var body: some View {
        let selected = model.selectedRun
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        AgentNodeRow(content: row.content,
                                     isSelected: selected == row.id,
                                     disclosure: row.disclosure,
                                     toggle: { model.toggle(row.id) },
                                     select: { model.select(row.id) })
                            .id(AgentTreeView.identity(of: row.id))
                    }
                }
                .padding(8)
            }
            .onAppear { bring(selected, into: scroll) }
            .onChange(of: selected) { _, run in bring(run, into: scroll) }
        }
    }

    private func bring(_ run: AgentRunID?, into scroll: ScrollViewProxy) {
        guard let run else { return }
        scroll.scrollTo(AgentTreeView.identity(of: run), anchor: .center)
    }
}

/// A run was asked for and this channel's tree does not hold it (child spec D5).
///
/// The pane selects nothing **and says so**. A chip on an archived channel resolves to a run this
/// channel's tree has never held — tracker 187 — and the alternative to this sentence is a
/// fabricated selection, which would put a run's name over another run's transcript. Saying nothing
/// at all is the third alternative and is worse than either: the user clicked something and the
/// panel changed to an ordinary tree with no node open, which reads as a bug.
///
/// It is drawn **above** whatever the tree draws rather than instead of it, because the channel's
/// other runs are still there to open, and it names no run (§11: a task id is drawable here, but a
/// report is not a drawing and this sentence is a report).
struct AgentUnknownRunNotice: View {

    /// Stored rather than read from the static value at draw time, so the sentence the pane is
    /// about to draw is a value a test can find — the shape `AgentTreeEmptyState` takes beside it.
    var sentence: String = Self.sentence

    static let sentence = "That run is not in this channel's tree, so nothing is open."

    var body: some View {
        Text(sentence)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
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
