import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// Contract Y1's `decision` row: one decision, as the channel's list draws it.
///
/// It reads **`row.item`** and switches on it (spec D1). `row.summary` is a 140-character
/// flattening and no card can be drawn from one; the row carries the item precisely so this
/// builder does not have to.
///
/// **Actions are not here yet, and that is a dependency rather than a choice.**
/// `DecisionCardView` needs the request's `ChannelKey` and the channel's `DecisionAnswering`,
/// and a row builder is handed neither: per-row capabilities travel in C6.1's
/// `TimelineRenderContext` environment value (spec D1), which is not on `main`. Reaching
/// `ChannelContext.links` or the timeline registry some other way would be the second
/// capability route C5's `HostLinkRouter` exists to prevent, so this row draws what the item
/// states — its title, what it is about, and D12's reading of its state — and the answering
/// affordance arrives with that value. Activity and the Thread tab already answer the same
/// request through the same `DecisionAnswering`, so no decision is unanswerable meanwhile.
struct DecisionRowView: View {

    let row: TimelineRow

    /// What a decision the engine is still waiting on reads while this row cannot answer it.
    static let pendingReading = "Waiting for an answer."

    var body: some View {
        switch row.item {
        case .decision(let item):
            content(for: DecisionCard(item), title: item.title)
        default:
            // The registry only routes `.decision` here, so this is unreachable in the app. It
            // draws the placeholder rather than nothing, for the same reason the registry's
            // default does: a row that vanishes is a row nobody can see is missing.
            PlaceholderRowView(row: row)
        }
    }

    @ViewBuilder
    private func content(for card: DecisionCard, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Text(card.summaryLine)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            // D12's four inert readings come from the card itself; a decision still waiting has
            // no reading, and says so in one line rather than offering an action it cannot send.
            Text(card.reading(inStaleOverlay: false)?.text ?? Self.pendingReading)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
