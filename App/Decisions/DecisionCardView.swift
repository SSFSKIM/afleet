import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// One decision, drawn. The same value, the same action set and the same `answer(_:)` in both of
/// its hosts — the timeline's column and Activity's row (contract Y2, spec §8.4).
///
/// The presentation changes the layout and nothing else. `.full` is the timeline's card: the
/// tool's input, the reason, the actions as a row of buttons and a field to say why not. `.compact`
/// is Activity's row affordance: the same actions, without the input rendering, because Activity is
/// a list of everything waiting across the fleet and a full card per row is a different surface.
/// No action exists in one presentation and not the other, which is what makes the same request
/// answered from either host produce the same bytes.
struct DecisionCardView: View {

    /// Which of the two hosts is drawing.
    enum Presentation: Sendable, Hashable { case full, compact }

    let card: DecisionCard
    let presentation: Presentation
    let channel: ChannelKey
    /// C3's overlay is stale — the process this decision belongs to has exited. It is the second
    /// half of D12's `.inert` reading and the card cannot derive it, because it is a property of
    /// the overlay and not of the item.
    let isStale: Bool
    let answering: DecisionAnswering

    init(card: DecisionCard,
         presentation: Presentation,
         in channel: ChannelKey,
         isStale: Bool = false,
         answering: DecisionAnswering) {
        self.card = card
        self.presentation = presentation
        self.channel = channel
        self.isStale = isStale
        self.answering = answering
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            if let reading = card.reading(inStaleOverlay: isStale) {
                Text(reading.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                live
            }
        }
    }

    /// A card the engine is still waiting on. The permission and question cards draw their own; the
    /// plan, elicitation and dialog cards are later deliverables and until then their kinds render
    /// their summary and offer nothing, which is what an unmodelled payload does for good (§6.3).
    @ViewBuilder
    private var live: some View {
        switch card.payload {
        case .permission(let tool):
            PermissionCardView(card: card,
                               tool: tool,
                               presentation: presentation,
                               channel: channel,
                               answering: answering)
        case .question(let tool):
            QuestionCardView(card: card, tool: tool, presentation: presentation,
                             channel: channel, answering: answering)
        default:
            Text(card.summaryLine)
                .font(presentation == .full ? .body : .callout)
        }
    }
}

/// What a card that is no longer waiting on the user reads (spec D12).
struct DecisionReading: Hashable, Sendable {
    var text: String
}

extension DecisionCard {

    /// D12's four inert readings, and the outcome of an answered card. Nil while the engine is
    /// still waiting, which is the only state with actions.
    ///
    /// `.inert` has **two** producers — `.exited` rewriting every pending decision, and an
    /// undeclared dialog kind left to the binary — and `overlay.stale` is what separates them. A
    /// card reading `.inert` alone would tell the user a live session had ended.
    func reading(inStaleOverlay stale: Bool) -> DecisionReading? {
        switch state {
        case .pending:
            nil
        case .answered(let outcome):
            DecisionReading(text: outcome)
        case .cancelled:
            DecisionReading(text: "Answered elsewhere.")
        case .policyAnswered(let error):
            DecisionReading(text: error)
        case .inert:
            stale
                ? DecisionReading(text: "This session ended.")
                : DecisionReading(text: "Left to the binary: afleet does not handle this kind.")
        }
    }

    /// One line naming what the card is about, for a kind this build draws no card for yet.
    var summaryLine: String {
        switch payload {
        case .permission(let tool), .question(let tool), .plan(let tool):
            tool.fields.displayName ?? tool.fields.toolName
        case .elicitation(let request):
            request.fields.title ?? request.fields.message
        case .dialog(let request):
            request.fields.dialogKind
        case .unmodelled:
            "A request this build does not model."
        }
    }
}
