import Foundation
import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - Thinking, folded

/// What the disclosure says about a message's thinking (child spec §9).
struct ThinkingSummary: Equatable {

    /// The thinking blocks, in order, joined for the expanded body.
    var text: String

    /// How long the model thought, when both instants are known: the span from the item before this
    /// message to the message itself. Nil where the channel gives no earlier instant — the first
    /// message of a transcript has nothing to be measured from.
    var duration: TimeInterval?

    var blocks: Int

    /// `Thought for 4 seconds`, or `Thought` when nothing bounds the span.
    var title: String {
        guard let duration, duration >= 1 else { return "Thought" }
        return "Thought for \(Int(duration.rounded())) seconds"
    }
}

/// The collapsible over a message's thinking blocks.
///
/// **Its duration, and not a live token estimate.** The terminal also shows the running
/// `estimated_tokens` from `system/thinking_tokens` while a message streams. That frame has no home
/// in C3's model — `WireReducer.route(_ system:)` sends it to the `default:` arm, and neither
/// `Overlay` nor `StreamingPreview` carries a field for it — so after the architect's ruling removed
/// this leaf's own event subscription there is no route by which the estimate could reach the app at
/// all. That is tracker 127, and the honest thing is to render the duration and leave the estimate
/// to the corrective rather than to invent a number here.
struct ThinkingDisclosure: View {

    let id: ItemID
    let summary: ThinkingSummary

    @Environment(\.timelineContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                context?.collapse.toggle(id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text(summary.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(TextSanitiser.sanitise(summary.text))
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Folded by default: thinking is the part of a turn a reader opens deliberately.
    ///
    /// `TimelineCollapseState` records the ids the reader has **toggled away from the row's own
    /// default**, and both defaults in this leaf — thinking and clusters — are folded, so an id in
    /// the set is one the reader opened.
    private var isExpanded: Bool { context?.collapse.isCollapsed(id) ?? false }

    /// The summary of one message's thinking, or nil when it did none.
    static func summary(of item: AssistantMessageItem, in context: TimelineRenderContext) -> ThinkingSummary? {
        summary(of: item, since: context.neighbourhood.precedingTimestamps[item.id.key])
    }

    static func summary(of item: AssistantMessageItem, since: Date?) -> ThinkingSummary? {
        let blocks = MessageText.thinking(in: item.blocks)
        guard !blocks.isEmpty else { return nil }
        var duration: TimeInterval?
        if let since, let at = item.timestamp { duration = max(0, at.timeIntervalSince(since)) }
        return ThinkingSummary(text: blocks.joined(separator: "\n\n"), duration: duration, blocks: blocks.count)
    }
}
