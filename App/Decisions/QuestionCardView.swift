import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// One question the engine asked, decoded from `AskUserQuestion`'s input (anchor 9).
///
/// The option field is **`preview`, singular**. `Fixtures/ask-user-question` records it that way and
/// so does the schema at `cli.pretty.js:758385`; a card reading `previews` would render nothing and
/// nothing else about it would look wrong.
///
/// `kind`, `placeholder`, `min`, `max`, `step`, `defaultValue` and `unit` are the extended variant
/// behind `extendedQuestionsEnabled()` (`cli.pretty.js:758385–758461`). They are absent from every
/// recorded ask and from the fixture corpus, so the parse treats an absent `kind` as `.choice` — the
/// rendering §8.4 describes — and an unrecognised one as a text field, which is the only rendering
/// that can carry an answer for a kind this build has never seen.
struct QuestionPrompt: Hashable, Sendable, Identifiable {

    struct Option: Hashable, Sendable, Identifiable {
        var label: String
        var description: String?
        /// Singular. The engine sends one preview per option.
        var preview: String?
        var id: String { label }
    }

    /// The extended variant's per-question `kind`.
    enum Kind: Hashable, Sendable {
        case choice, text, number
        /// A spelling this build does not know. Rendered as a text field: a control the user can put
        /// an answer into beats a control that cannot be answered at all (§6.4).
        case unrecognised(String)
    }

    var question: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool
    var kind: Kind
    var placeholder: String?
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var defaultValue: JSONValue?
    var unit: String?

    /// The raw question text, which is the key the engine reads `answers` and `annotations` back by.
    var id: String { question }

    /// Every question in a `can_use_tool` input for `AskUserQuestion`, in the order the engine wrote
    /// them.
    static func list(in input: [String: JSONValue]) -> [QuestionPrompt] {
        (input["questions"]?.arrayValue ?? []).compactMap(Self.init(_:))
    }

    init?(_ value: JSONValue) {
        guard let question = value["question"]?.stringValue else { return nil }
        self.question = question
        header = value["header"]?.stringValue
        options = (value["options"]?.arrayValue ?? []).compactMap { option in
            guard let label = option["label"]?.stringValue else { return nil }
            return Option(label: label,
                          description: option["description"]?.stringValue,
                          preview: option["preview"]?.stringValue)
        }
        multiSelect = value["multiSelect"]?.boolValue ?? false
        switch value["kind"]?.stringValue {
        case nil, "choice": kind = .choice
        case "text": kind = .text
        case "number": kind = .number
        case .some(let other): kind = .unrecognised(other)
        }
        placeholder = value["placeholder"]?.stringValue
        minimum = value["min"]?.doubleValue
        maximum = value["max"]?.doubleValue
        step = value["step"]?.doubleValue
        defaultValue = value["defaultValue"]
        unit = value["unit"]?.stringValue
    }

    /// Whether the question is answered by picking options rather than by typing.
    var isChoice: Bool { if case .choice = kind { return true }; return false }
}

extension JSONValue {
    /// A schema or question number, whichever way the engine wrote it.
    var doubleValue: Double? {
        switch self {
        case .number(let d): d
        case .integer(let i): Double(i)
        default: nil
        }
    }
}

/// §8.4's question card: each option's label, description and preview side by side, multi-select
/// where the engine asked for it, *Other* for an answer no option carries, and one note field whose
/// text becomes the answer's `annotations` entry.
///
/// The answer is the mapping's: the whole input echoed back with `answers` keyed by raw question
/// text, and `annotations` written only where a note was typed (anchor 9 — the fixture records an
/// answer with no `annotations` key at all, which is legal).
struct QuestionCardView: View {

    /// What the user has said so far, before it becomes an answer.
    ///
    /// A reference rather than a `@State` value because the draft outlives one `body` evaluation and
    /// because a host — or a test — has to be able to read what the card would send without owning
    /// SwiftUI's storage. It holds nothing about the decision, only the half-written reply.
    @MainActor
    @Observable
    final class Draft {
        /// Chosen option labels, keyed by raw question text. A single-select question holds one.
        var picked: [String: [String]] = [:]
        /// *Other*, and the typed answer of a `text`, `number` or unrecognised kind.
        var typed: [String: String] = [:]
        /// The note that becomes `annotations[question].notes`.
        var notes: [String: String] = [:]
        init() {}
    }

    let card: DecisionCard
    let tool: CanUseToolRequest
    let presentation: DecisionCardView.Presentation
    let channel: ChannelKey
    let answering: DecisionAnswering

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

    var questions: [QuestionPrompt] { QuestionPrompt.list(in: tool.fields.inputObject) }

    private var isAnswering: Bool { answering.isAnswering(card.requestID) }

    // MARK: - The answer this card would send

    /// One response per question the user has said something about. A question left untouched
    /// carries no key, because a key with an empty value is an answer and silence is not.
    var responses: [QuestionResponse] {
        questions.compactMap { prompt in
            var selections: [String] = []
            if prompt.isChoice {
                selections = draft.picked[prompt.question] ?? []
                let other = draft.typed[prompt.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // A single-select question has one answer. *Other* and the options are two ways to
                // give it, not two halves of it: the engine joins a selection list with `", "`, so a
                // card that carried both would send a pair the user never chose. The controls keep
                // each other clear as they are used, and the assignment here is that invariant said
                // once more where the answer is built.
                if !other.isEmpty { selections = prompt.multiSelect ? selections + [other] : [other] }
            } else {
                // The extended variant's `defaultValue` is what the field opens with, so it is the
                // answer until the user types over it — a shown value the answer dropped would be a
                // card that lied about what it was about to send.
                let text = (draft.typed[prompt.question] ?? Self.initialText(prompt))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { selections = [text] }
            }
            // A note is something the user said about this question, so a question carrying only a
            // note is still a question the user answered. Dropping it here dropped its annotation
            // from the whole reply, and another question's answer made the send look complete.
            let note = draft.notes[prompt.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !selections.isEmpty || !note.isEmpty else { return nil }
            return QuestionResponse(question: prompt.question,
                                    selections: selections,
                                    annotation: note.isEmpty ? nil : .init(preview: nil, notes: note))
        }
    }

    // MARK: - Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            Text(tool.fields.title ?? tool.fields.displayName ?? tool.fields.toolName)
                .font(.body.weight(.semibold))
            ForEach(questions) { prompt in
                question(prompt)
            }
            Button("Send") { answering.send(.answerQuestion(responses), on: card, in: channel) }
                .disabled(isAnswering || responses.isEmpty)
            if let banner = answering.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One question, as the body builds it. Not private: `ForEach` stores its content closure rather
    /// than the views it makes, so this is the only handle a host — or a test — has on the controls
    /// the card actually draws for a question.
    @ViewBuilder
    func question(_ prompt: QuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header = prompt.header { Text(header).font(.caption).foregroundStyle(.secondary) }
            Text(prompt.question).font(.callout)
            if prompt.isChoice {
                ForEach(prompt.options) { option in
                    self.option(option, of: prompt)
                }
                TextField("Other", text: other(prompt))
            } else {
                typedField(prompt)
            }
            if presentation == .full {
                TextField("Add a note", text: binding(\.notes, prompt.question))
            }
        }
    }

    /// One option: the label as the control, its description and its singular preview beside it.
    /// Internal for the same reason `question(_:)` is.
    @ViewBuilder
    func option(_ option: QuestionPrompt.Option, of prompt: QuestionPrompt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button(option.label) { choose(option.label, of: prompt) }
                .disabled(isAnswering)
            VStack(alignment: .leading, spacing: 2) {
                if let description = option.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if let preview = option.preview {
                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if (draft.picked[prompt.question] ?? []).contains(option.label) {
                Text("Chosen").font(.caption)
            }
        }
    }

    /// The extended variant's non-choice renderings. An unrecognised `kind` lands here too, as a
    /// text field.
    @ViewBuilder
    private func typedField(_ prompt: QuestionPrompt) -> some View {
        switch prompt.kind {
        case .number:
            HStack(spacing: 6) {
                TextField(prompt.placeholder ?? "A number",
                          text: binding(\.typed, prompt.question, default: Self.initialText(prompt)))
                if let unit = prompt.unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
                if let range = Self.rangeLabel(prompt) {
                    Text(range).font(.caption).foregroundStyle(.secondary)
                }
            }
        default:
            TextField(prompt.placeholder ?? "Your answer",
                      text: binding(\.typed, prompt.question, default: Self.initialText(prompt)))
        }
    }

    /// What a number question's bounds read as, or nil when it declared none.
    static func rangeLabel(_ prompt: QuestionPrompt) -> String? {
        var parts: [String] = []
        if let minimum = prompt.minimum { parts.append("min \(Self.number(minimum))") }
        if let maximum = prompt.maximum { parts.append("max \(Self.number(maximum))") }
        if let step = prompt.step { parts.append("step \(Self.number(step))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A bound or a default as text. `Int64(_: Double)` traps outside its range and on a non-finite
    /// value, and `min`, `max`, `step` and `defaultValue` are numbers the engine wrote, so the
    /// conversion is guarded rather than trusted.
    private static func number(_ value: Double) -> String {
        ElicitationForm.spell(value, isInteger: false)
    }

    /// *Other*'s binding. Internal for the reason `question(_:)` is: SwiftUI stores the binding
    /// and not the edit made through it, so this is the only handle on what typing an alternative
    /// does to the draft.
    func other(_ prompt: QuestionPrompt) -> Binding<String> {
        let draft = draft
        return Binding(get: { draft.typed[prompt.question] ?? "" }, set: { text in
            draft.typed[prompt.question] = text
            guard !prompt.multiSelect,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            draft.picked[prompt.question] = []
        })
    }

    /// A single-select question holds one label; a multi-select toggles.
    private func choose(_ label: String, of prompt: QuestionPrompt) {
        var current = draft.picked[prompt.question] ?? []
        if prompt.multiSelect {
            if let index = current.firstIndex(of: label) { current.remove(at: index) } else { current.append(label) }
        } else {
            current = current == [label] ? [] : [label]
            draft.typed[prompt.question] = nil
        }
        draft.picked[prompt.question] = current
    }

    /// A text control's binding into one of the draft's two keyed stores. `default` is the extended
    /// variant's `defaultValue`, shown until the user types over it and read by `responses` through
    /// the same store, so the default is a real answer and not decoration.
    private func binding(_ store: ReferenceWritableKeyPath<Draft, [String: String]>, _ key: String,
                         default fallback: String = "") -> Binding<String> {
        let draft = draft
        return Binding(get: { draft[keyPath: store][key] ?? fallback },
                       set: { draft[keyPath: store][key] = $0 })
    }
}

extension QuestionCardView {
    /// The default a `text` or `number` question opens with, when the extended variant sent one.
    static func initialText(_ prompt: QuestionPrompt) -> String {
        switch prompt.defaultValue {
        case .string(let text): text
        case .integer(let value): String(value)
        case .number(let value): number(value)
        default: ""
        }
    }
}
