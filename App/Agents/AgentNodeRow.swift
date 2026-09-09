import Foundation
import SwiftUI
import FleetKit

/// One run, as a row of the Agents tree (root §8.8).
///
/// Everything it draws is already sanitised: `AgentNodeContent` strips at the boundary where the
/// content is built, once, and this row inherits the value rather than remembering to ask (D11).
///
/// **A parked run is not a completed one** (child spec D13). C3's `isParked` is "this run is not
/// running and a child of it is" — the run's own work is over and the branch is not — and a row that
/// showed *Completed* for it would tell the user a branch had finished while work continued under
/// it. Parking is therefore read before the status, not beside it.
///
/// The elapsed span is `ElapsedTicker`'s and is not computed here: a row that read the clock would
/// put the tick back on the tree (D7).
struct AgentNodeRow: View {

    let content: AgentNodeContent
    let isSelected: Bool
    let disclosure: Disclosure
    let toggle: @MainActor () -> Void
    let select: @MainActor () -> Void
    /// What §8.8 lets the user do to this run, drawn under the **open** node (gate G3). Nil for a
    /// pane with no lifecycle behind it, and then no row offers anything.
    var actions: AgentNodeActions?
    /// Where this run's transcript is (child spec D12). Read from the tree by the outline, because
    /// the path is composed from the tree's current slug and a row that held one could go stale.
    var transcriptURL: URL?
    /// The cards the engine is waiting on for this run, already built through C6.3's component
    /// (item 52). Empty for a node nothing is waiting on, and for a pane with no answering object.
    var decisions: AgentNodeDecisions?

    /// What became of the messages already relayed to this run (item 51). Empty for a run nothing
    /// was ever sent to, which is every run until the user sends one.
    var relays: [AgentRelayReading] = []

    /// Whether this row's branch can be opened, and whether it is.
    enum Disclosure: Hashable, Sendable { case leaf, expanded, collapsed }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            disclosureControl
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.title(content))
                        .fontWeight(.medium)
                    Text(Self.statusLabel(content))
                        .foregroundStyle(.secondary)
                    if let model = content.model {
                        Text(model).foregroundStyle(.secondary)
                    }
                    if content.startedCount > 1 {
                        Text("Started \(content.startedCount)×").foregroundStyle(.secondary)
                    }
                    if content.waitingCount > 0 {
                        Text("\(content.waitingCount) waiting")
                    }
                    // The run is drawn under the parent the tree holds — first-source-wins is C3's
                    // and a surface does not overturn it — and the disagreement is drawn beside it
                    // rather than hidden (child spec D1). It names neither parent: the run is where
                    // the user is looking and the sentence is a report (§11).
                    if let disputed = Self.parentNotice(content) {
                        Text(disputed).foregroundStyle(.secondary)
                    }
                    ElapsedTicker(origin: content.elapsedOrigin, endedAt: content.endedAt)
                        .foregroundStyle(.secondary)
                }
                if let activity = content.activityLine, !activity.isEmpty {
                    Text(activity).foregroundStyle(.secondary).lineLimit(1)
                }
                if isSelected, let actions {
                    AgentNodeActionBar(content: content, actions: actions, transcriptURL: transcriptURL,
                                       relays: relays)
                }
                // Drawn on **every** node the engine is waiting on and not only the open one: the
                // badge beside the title says a run is blocked, and a card the user has to open a
                // node to find is one they will not find.
                if let decisions {
                    decisions
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(max(0, content.depth - 1)) * 14)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { select() }
    }

    @ViewBuilder
    private var disclosureControl: some View {
        switch disclosure {
        case .leaf:
            Image(systemName: "circle.fill").opacity(0).imageScale(.small)
        case .expanded:
            Button { toggle() } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
        case .collapsed:
            Button { toggle() } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
    }

    /// The agent's own type when it named one, else the errand it was given. Both are sanitised.
    static func title(_ content: AgentNodeContent) -> String {
        if let type = content.agentType, !type.isEmpty { return type }
        return content.description
    }

    /// What a node says when its parent sources disagreed, or nil when they did not (child spec
    /// D1). Static and pure, so the disagreement a node draws is assertable without a render pass.
    static func parentNotice(_ content: AgentNodeContent) -> String? {
        content.parentDisputed ? disputedParent : nil
    }

    /// The sentence itself. One string, so this row and a test name the same one.
    static let disputedParent = "Parent disputed"

    /// Parked before completed, and a word for each of C3's four statuses. Static and pure, so the
    /// sentence a node draws is assertable without a render pass.
    static func statusLabel(_ content: AgentNodeContent) -> String {
        if content.isParked { return "Parked" }
        switch content.status {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}
