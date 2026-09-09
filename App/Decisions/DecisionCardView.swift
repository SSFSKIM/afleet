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
    /// Whether this is the card the user is acting on, among however many its host is drawing.
    /// Only an active card claims the keyboard default action; a host that draws a list of cards
    /// and has no notion of an active one passes nothing, and none of them claims it.
    let isActive: Bool
    let answering: DecisionAnswering
    /// Where a resolved refusal dialog's retracted uuids go (spec D11). A host with no list to
    /// filter passes none.
    let retraction: RetractionRegistry?
    /// Where the refusal dialog's *Edit the prompt* puts the prompt back (contract Y6's fourth
    /// site). A host with no composer passes none, and the answer still goes out.
    let composer: (any ComposerSite)?
    /// An override of the `system/model_consent_fallback` frame the card already carries, for a host
    /// that holds one the fold has not attached.
    ///
    /// **The card's own frame is the ordinary route** (`DecisionCard.consentFallback`, written by
    /// C3's fold): a parameter every host had to remember is a parameter most hosts would forget,
    /// and the card would then settle reading the wrong outcome. **Its absence is equally correct**
    /// — the engine emits nothing when provisioning succeeded (anchor 5) — so it changes what a
    /// settled card *reads* and never whether it settles.
    let consentFallback: ModelConsentFallback?

    init(card: DecisionCard,
         presentation: Presentation,
         in channel: ChannelKey,
         isStale: Bool = false,
         isActive: Bool = false,
         answering: DecisionAnswering,
         retraction: RetractionRegistry? = nil,
         composer: (any ComposerSite)? = nil,
         consentFallback: ModelConsentFallback? = nil) {
        self.card = card
        self.presentation = presentation
        self.channel = channel
        self.isStale = isStale
        self.isActive = isActive
        self.answering = answering
        self.retraction = retraction
        self.composer = composer
        self.consentFallback = consentFallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            if let reading = card.reading(inStaleOverlay: isStale, consentFallback: consentFallback) {
                Text(reading.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                live
            }
        }
    }

    /// A card the engine is still waiting on. Every modelled payload draws its own card; an
    /// unmodelled one renders its summary and offers nothing, for good (§6.3).
    @ViewBuilder
    private var live: some View {
        switch card.payload {
        case .permission(let tool):
            PermissionCardView(card: card,
                               tool: tool,
                               presentation: presentation,
                               channel: channel,
                               isActive: isActive,
                               answering: answering)
        case .question(let tool):
            QuestionCardView(card: card, tool: tool, presentation: presentation,
                             channel: channel, answering: answering)
        case .plan(let tool):
            PlanCardView(card: card, tool: tool, presentation: presentation,
                         channel: channel, answering: answering)
        case .elicitation(let request):
            ElicitationCardView(card: card, request: request, presentation: presentation,
                                channel: channel, answering: answering)
        case .dialog(let request):
            DialogCardView(card: card, request: request, presentation: presentation,
                           channel: channel, answering: answering, retraction: retraction,
                           composer: composer)
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
    ///
    /// `consentFallback` is the `system/model_consent_fallback` frame that followed an overage
    /// answer. Where one arrived it **is** the card's outcome, in the engine's own words; where none
    /// did, the card reads its own settled state instead. The engine emits nothing when
    /// provisioning succeeded (anchor 5), so a card that waited for the frame would hang on the
    /// successful path — which is why this only ever replaces the text of an already-settled card.
    func reading(inStaleOverlay stale: Bool,
                 consentFallback: ModelConsentFallback? = nil) -> DecisionReading? {
        if let frame = consentFallback ?? self.consentFallback, dialogKind == .overageConsent, state != .pending {
            return DecisionReading(text: frame.fields.content)
        }
        switch state {
        case .pending:
            return nil
        case .answered(let outcome):
            return DecisionReading(text: outcome)
        case .cancelled:
            return DecisionReading(text: "Answered elsewhere.")
        case .policyAnswered(let error):
            return DecisionReading(text: error)
        case .inert:
            return stale
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
