import SwiftUI
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// §8.4's plan-approval card: the plan the model wrote, and the three things a user can do with it.
///
/// Both approvals echo the whole plan input back as `updatedInput` and carry
/// `{type:"setMode", destination:"session", mode:<chosen>}` (anchor 8, `cli.pretty.js:14602`; the
/// `exit-plan-mode` fixture records the `acceptEdits` arm). The rejection is a denial carrying the
/// typed feedback. Every one of the three is the mapping's — this view chooses the action and
/// nothing else.
struct PlanCardView: View {

    let card: DecisionCard
    let tool: CanUseToolRequest
    let presentation: DecisionCardView.Presentation
    let channel: ChannelKey
    let answering: DecisionAnswering

    /// The half-written rejection. A reference for the same reason the question card's draft is one:
    /// what the card would send has to be readable without owning SwiftUI's storage.
    @MainActor
    @Observable
    final class Draft {
        var feedback: String = ""
        init() {}
    }

    @State private var draft: Draft

    init(card: DecisionCard, tool: CanUseToolRequest, presentation: DecisionCardView.Presentation,
         channel: ChannelKey, answering: DecisionAnswering, draft: Draft = Draft()) {
        self.card = card
        self.tool = tool
        self.presentation = presentation
        self.channel = channel
        self.answering = answering
        _draft = State(initialValue: draft)
    }

    /// The plan itself, as the engine wrote it. Markdown as text: the panel's renderer is C7.2's and
    /// a card that reformatted it here would be a second renderer.
    var plan: String { tool.fields.inputObject["plan"]?.stringValue ?? "" }

    /// What a rejection says when the user typed nothing. A rejection with an empty message tells
    /// the model nothing, and the engine forwards the message verbatim.
    static let unstatedRejection = "The user rejected this plan."

    var rejectionMessage: String {
        let typed = draft.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? Self.unstatedRejection : typed
    }

    private var isAnswering: Bool { answering.isAnswering(card.requestID) }

    private var feedbackBinding: Binding<String> {
        let draft = draft
        return Binding(get: { draft.feedback }, set: { draft.feedback = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            Text(tool.fields.displayName ?? tool.fields.toolName).font(.body.weight(.semibold))
            if presentation == .full, !plan.isEmpty {
                Text(plan).font(.callout).textSelection(.enabled)
            }
            if presentation == .full {
                TextField("Why not", text: feedbackBinding).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button("Approve") {
                    answering.send(.approvePlan(autoAcceptEdits: false), on: card, in: channel)
                }
                Button("Approve and auto-accept edits") {
                    answering.send(.approvePlan(autoAcceptEdits: true), on: card, in: channel)
                }
                Button("Reject with feedback") {
                    answering.send(.rejectPlan(feedback: rejectionMessage), on: card, in: channel)
                }
            }
            .disabled(isAnswering)
            if let banner = answering.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
