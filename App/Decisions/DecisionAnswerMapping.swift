import Foundation
import ClaudeWire
import FleetKit

/// Everything a user can click on a decision card.
///
/// The set is closed on purpose: it is the whole vocabulary the cards emit, and `answer(_:)` below
/// is the only place in this child that turns one into an `InboundAnswer`. An action that is not an
/// answer — the overage card's billing route — is in the set and maps to nil, so "every answer
/// comes from here" is checkable on the shape of the code and not only on its behaviour.
enum DecisionAction: Hashable, Sendable {

    // Permission.
    case allowOnce
    /// `destination` is the picker's choice, and nil when the card shows no picker (spec D5).
    case alwaysAllow(destination: PermissionUpdateDestination?)
    case deny(message: String)

    // Question.
    case answerQuestion([QuestionResponse])

    // Plan.
    case approvePlan(autoAcceptEdits: Bool)
    case rejectPlan(feedback: String)

    // Elicitation.
    case acceptElicitation(content: JSONValue)
    case declineElicitation
    case cancelElicitation

    // The refusal-fallback dialog.
    case retryOnFallbackModel
    case editPrompt
    case keepTheRefusal

    // The overage dialog.
    case useUsageCredits
    case switchToDefaultModel
    case notNow
    /// Not an answer: the payload carries no URL, so this opens a page and leaves the card pending
    /// (spec D7). It is in the set because the card offers it, and it maps to nil because nothing
    /// goes on the wire.
    case setUpUsageCredits

    /// Closing either dialog card.
    case closeDialog
}

/// One question's reply, keyed by the raw question text exactly as the engine wrote it — that key
/// is what the engine reads `answers` and `annotations` back by (anchor 9).
struct QuestionResponse: Hashable, Sendable {
    var question: String
    /// The chosen option labels, or the typed text of *Other*. A multi-select reply is one string
    /// on the wire; the engine joins with `", "` and so does this.
    var selections: [String]
    var annotation: Annotation?

    struct Annotation: Hashable, Sendable {
        var preview: String?
        var notes: String?
    }
}

extension DecisionCard {

    /// The one place this child constructs an `InboundAnswer`.
    ///
    /// A pure function over the card: no lifecycle, no channel, no view state, so the timeline and
    /// Activity cannot answer the same request two different ways. Nil means the action sends
    /// nothing — either because it is not an answer at all, or because it does not belong to the
    /// card in hand, which includes an action aimed at a dialog kind afleet never declared.
    func answer(_ action: DecisionAction) -> InboundAnswer? {
        switch action {
        case .allowOnce:
            guard case .permission = payload else { return nil }
            return .permission(.allow(updatedInput: nil, updatedPermissions: nil, classification: .userTemporary))

        case .alwaysAllow(let destination):
            guard case .permission(let tool) = payload, let offer = alwaysAllow else { return nil }
            let suggestions = tool.fields.permissionSuggestions ?? []
            let chosen = destination ?? offer.preselected
            let updates = chosen.map { target in suggestions.map { $0.filed(at: target) } } ?? suggestions
            return .permission(.allow(updatedInput: nil, updatedPermissions: updates, classification: .userPermanent))

        case .deny(let message):
            guard case .permission = payload else { return nil }
            return .permission(.deny(message: message, interrupt: false, classification: .userReject))

        case .answerQuestion(let responses):
            guard case .question(let tool) = payload else { return nil }
            return .permission(.allow(updatedInput: Self.echo(tool.fields.inputObject, answering: responses),
                                      updatedPermissions: nil, classification: .userTemporary))

        case .approvePlan(let autoAcceptEdits):
            guard case .plan(let tool) = payload else { return nil }
            let mode: PermissionMode = autoAcceptEdits ? .acceptEdits : .default
            // Spec D16: the plan approval is a decision a person made, so it carries its own
            // classification rather than leaving the engine to infer one from the destination of
            // whatever updates the answer happens to carry (`cli.pretty.js:735273`). Neither arm
            // persists a rule, so both are `.userTemporary`.
            return .permission(.allow(updatedInput: tool.fields.input,
                                      updatedPermissions: [.setMode(mode: mode, destination: .session)],
                                      classification: .userTemporary))

        case .rejectPlan(let feedback):
            guard case .plan = payload else { return nil }
            return .permission(.deny(message: feedback, interrupt: false, classification: .userReject))

        case .acceptElicitation(let content):
            guard case .elicitation = payload else { return nil }
            return .elicitation(.accept(content: content))

        case .declineElicitation:
            guard case .elicitation = payload else { return nil }
            return .elicitation(.decline)

        case .cancelElicitation:
            guard case .elicitation = payload else { return nil }
            return .elicitation(.cancel)

        case .retryOnFallbackModel:
            return dialogResult("retry_fallback", on: .refusalFallback)

        case .editPrompt:
            return dialogResult("edit_prompt", on: .refusalFallback)

        case .keepTheRefusal:
            return dialogResult("cancelled", on: .refusalFallback)

        case .useUsageCredits:
            // A bare wire reply never enables billing, so `consent` is offered only where the
            // engine says billing is already on (§8.4's *Result* column).
            guard overagesEnabled else { return nil }
            return dialogResult("consent", on: .overageConsent)

        case .switchToDefaultModel:
            return dialogResult("switch_default", on: .overageConsent)

        case .notNow:
            return dialogResult("cancelled", on: .overageConsent)

        case .setUpUsageCredits:
            return nil

        case .closeDialog:
            guard dialogKind != nil else { return nil }
            return .dialog(.cancelled)
        }
    }

    private func dialogResult(_ result: String, on expected: DialogKind) -> InboundAnswer? {
        guard dialogKind == expected else { return nil }
        return .dialog(.completed(result: .string(result)))
    }

    /// The answer's `updatedInput`: the whole input object the engine sent, plus `answers`, plus
    /// `annotations` when the user produced one (anchor 9 — `Fixtures/ask-user-question` records an
    /// answer with no `annotations`, which is legal, so the key is written only when it is fed).
    private static func echo(_ input: [String: JSONValue], answering responses: [QuestionResponse]) -> JSONValue {
        var object = input
        var answers: [String: JSONValue] = [:]
        var annotations: [String: JSONValue] = [:]
        for response in responses {
            answers[response.question] = .string(response.selections.joined(separator: ", "))
            guard let annotation = response.annotation else { continue }
            var fields: [String: JSONValue] = [:]
            if let preview = annotation.preview { fields["preview"] = .string(preview) }
            if let notes = annotation.notes { fields["notes"] = .string(notes) }
            guard !fields.isEmpty else { continue }
            annotations[response.question] = .object(fields)
        }
        object["answers"] = .object(answers)
        if !annotations.isEmpty { object["annotations"] = .object(annotations) }
        return .object(object)
    }
}
