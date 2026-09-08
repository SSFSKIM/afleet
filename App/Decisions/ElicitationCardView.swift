import SwiftUI
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// The elicitation card, in both of the engine's modes (spec D8, anchor 10).
///
/// `mode: "url"` carries `url` and `elicitation_id` and **no schema**: the card is the server's name,
/// its message and the address to open — not a form. `mode: "form"` or absent renders
/// `requested_schema` over the stated subset. *Decline* and *Cancel* exist in **both** modes and
/// whatever the schema, because §6.4 makes an unanswerable request the one failure mode that must
/// not exist.
///
/// **The URL is drawn as selectable text and not as a link.** Opening it belongs to C5's
/// `HostLinkRouter` through the per-row capability C6.1's `TimelineRenderContext` carries, and that
/// value has not landed — no `EnvironmentKey` exists anywhere under `App/` yet. A card that reached
/// `ChannelContext.links` some other way would be the second link registry X7 exists to prevent, so
/// the address is shown in full and the user opens it, until the capability arrives.
struct ElicitationCardView: View {

    let card: DecisionCard
    let request: ElicitationRequest
    let presentation: DecisionCardView.Presentation
    let channel: ChannelKey
    let answering: DecisionAnswering

    /// The half-filled form. A reference for the same reason the other two cards' drafts are: what
    /// the card would send has to be readable without owning SwiftUI's storage.
    @MainActor
    @Observable
    final class Draft {
        /// What the user has said, keyed by property name. A key absent here falls back to the
        /// schema's own `default`, which is a real answer and not decoration.
        var values: [String: JSONValue] = [:]
        /// A raw field's text, kept as text so an unparseable draft is not thrown away mid-edit.
        var rawText: [String: String] = [:]
        /// A numeric field's text, for the same reason: a number is typed one character at a time
        /// and `1.`, `-` and `1e` are all states on the way to a value. Without it the control
        /// redrew whatever the draft could parse, so a half-typed number erased itself.
        var numberText: [String: String] = [:]
        /// The raw fields whose text was written as JSON and does not parse. They are neither a
        /// value nor an emptying: a syntax error is a field the user is still writing, and sending
        /// it as the literal text they typed would answer an object-shaped property with a string
        /// (scalpel-4#3). Accept waits.
        var malformed: Set<String> = []
        /// The properties the user **emptied**, which `values` cannot hold because an empty value is
        /// no value. Without it a cleared field is indistinguishable from an untouched one and the
        /// schema's default comes back — so deselecting the last default option reselected it and a
        /// defaulted text field could not be cleared at all.
        var cleared: Set<String> = []
        init() {}
    }

    @State private var draft: Draft

    init(card: DecisionCard, request: ElicitationRequest, presentation: DecisionCardView.Presentation,
         channel: ChannelKey, answering: DecisionAnswering, draft: Draft = Draft()) {
        self.card = card
        self.request = request
        self.presentation = presentation
        self.channel = channel
        self.answering = answering
        _draft = State(initialValue: draft)
    }

    // MARK: - What the engine sent

    /// `mode: "url"` and nothing else. An absent mode is a form (D8), which is what every recorded
    /// server has sent.
    var isURLMode: Bool { request.fields.mode == "url" }

    var url: String? { request.fields.url }

    /// Nil in url mode, and nil for a form-mode request whose schema is not an object.
    var form: ElicitationForm? { isURLMode ? nil : ElicitationForm(request.fields.requestedSchema) }

    /// What the user has said about one property, which is three states and not two: a value, an
    /// explicit emptying, and silence. Only the third falls back to the schema's `default`.
    enum Entry: Sendable, Hashable {
        case untouched, cleared, value(JSONValue)
    }

    func entry(_ name: String) -> Entry {
        if let value = draft.values[name] { return .value(value) }
        return draft.cleared.contains(name) ? .cleared : .untouched
    }

    /// The `content` an accept would carry: the user's values over the schema's defaults.
    ///
    /// **An emptied list is an empty list; an emptied string is no answer.** `string[]` has a value
    /// meaning "none of these" and the card sends it, because the user chose it. A string does not:
    /// `""` is indistinguishable from a field nobody filled in, so an emptied text field is absent,
    /// which is also what leaves a required one unacceptable.
    var content: JSONValue {
        guard let form else { return .object([:]) }
        var out: [String: JSONValue] = [:]
        for field in form.fields {
            switch entry(field.name) {
            case .value(let typed):
                out[field.name] = typed
            case .cleared:
                if case .multiSelect = field.control { out[field.name] = .array([]) }
            case .untouched:
                if let initial = ElicitationForm.initialValue(field.control) { out[field.name] = initial }
            }
        }
        return ElicitationForm.content(out)
    }

    /// A required property with no value is a form that cannot be accepted yet. Decline and cancel
    /// stay available regardless.
    var canAccept: Bool {
        guard let form else { return false }
        guard draft.malformed.isEmpty else { return false }
        let answered = content.objectValue ?? [:]
        return form.fields.allSatisfy { !$0.isRequired || answered[$0.name] != nil }
    }

    /// What the card says about a raw field that does not parse. The text stays in the control —
    /// throwing away what the user typed is worse than refusing to send it.
    static let malformedReading = "This value was written as JSON and does not parse, so it cannot be sent yet."

    private var isAnswering: Bool { answering.isAnswering(card.requestID) }

    // MARK: - Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            Text(request.fields.title ?? request.fields.displayName ?? request.fields.mcpServerName)
                .font(.body.weight(.semibold))
            Text(request.fields.mcpServerName).font(.caption).foregroundStyle(.secondary)
            Text(request.fields.message).font(.callout)
            if isURLMode {
                urlBody
            } else {
                formBody
            }
            HStack(spacing: 8) {
                if !isURLMode {
                    Button("Accept") {
                        answering.send(.acceptElicitation(content: content), on: card, in: channel)
                    }
                    .disabled(!canAccept)
                }
                Button("Decline") { answering.send(.declineElicitation, on: card, in: channel) }
                Button("Cancel") { answering.send(.cancelElicitation, on: card, in: channel) }
            }
            .disabled(isAnswering)
            if let banner = answering.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var urlBody: some View {
        if let url {
            Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("Open this address to continue with the server.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var formBody: some View {
        if let form {
            ForEach(form.fields) { field in
                self.field(field)
            }
            if form.fields.isEmpty {
                Text("This server asked for no values: accepting sends it an empty answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if form.isPartial {
                Text("Part of this form is shown as raw JSON: the server asked for a shape afleet does not draw.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("This server asked for no fields.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One property's control, as the body builds it. Not private: `ForEach` stores its content
    /// closure rather than the views it makes, so this is the only handle on what a field draws.
    @ViewBuilder
    func field(_ field: ElicitationForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.isRequired ? "\(field.title) (required)" : field.title).font(.callout)
            if let description = field.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            control(field)
        }
    }

    @ViewBuilder
    func control(_ field: ElicitationForm.Field) -> some View {
        switch field.control {
        case .text(let fallback):
            TextField(field.title, text: text(field.name, default: fallback ?? ""))
        case .picker(let options, _):
            Picker(field.title, selection: selection(for: field)) {
                // The empty row is the selection an untouched enum with no `default` has. Without a
                // row of its own that state drew as the first option, so the card showed a choice
                // the answer did not carry — and, for a required property, showed one while Accept
                // stayed disabled.
                Text("Not chosen").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .number(let isInteger, let fallback):
            TextField(field.title, text: number(field.name, isInteger: isInteger, default: fallback))
        case .toggle(let fallback):
            Toggle(field.title, isOn: toggle(field.name, default: fallback))
        case .multiSelect(let options, let fallback):
            if let options {
                ForEach(options, id: \.self) { option in
                    self.option(option, in: field)
                }
            } else {
                TextField(field.title, text: list(field.name, default: fallback ?? []))
            }
        case .raw(let schema):
            VStack(alignment: .leading, spacing: 2) {
                Text(ElicitationForm.schemaText(schema))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                TextField("JSON", text: raw(field.name))
                if draft.malformed.contains(field.name) {
                    Text(Self.malformedReading).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One option of an enum-array control.
    ///
    /// **A `Toggle`, because the control has to say which options are chosen** (sweep#3). The row
    /// used to be a plain `Button(option)`, which draws the same whether the option is in the
    /// answer or not: the user pressed an option, the card looked unchanged, and the only way to
    /// find out what an accept would carry was to send it. Not private for the reason
    /// `control(_:)` is not — `ForEach` stores its content closure rather than the views it makes,
    /// so this is the only handle on what one option draws.
    @ViewBuilder
    func option(_ option: String, in field: ElicitationForm.Field) -> some View {
        Toggle(option, isOn: optionSelection(option, in: field))
    }

    /// Whether one option of an enum-array control is in the answer. The setter is `pick`, so the
    /// drawn state and the sent value cannot come apart.
    func optionSelection(_ option: String, in field: ElicitationForm.Field) -> Binding<Bool> {
        guard case .multiSelect(_, let fallback) = field.control else { return .constant(false) }
        return Binding(get: {
            self.selected(field.name, default: fallback ?? []).contains(option)
        }, set: { _ in
            self.pick(option, in: field.name, default: fallback ?? [])
        })
    }

    // MARK: - The controls' bindings

    /// A picker's selection, which is the empty string when nothing is selected. Not private for the
    /// same reason `control(_:)` is not: a `Picker`'s selection lives in SwiftUI's storage, so this
    /// is the only handle on the value the card is showing — and that value is what an accept has to
    /// agree with.
    func selection(for field: ElicitationForm.Field) -> Binding<String> {
        guard case .picker(_, let fallback) = field.control else { return text(field.name, default: "") }
        return text(field.name, default: fallback ?? "")
    }

    /// The bindings are internal for the reason `control(_:)` is: SwiftUI stores a control's
    /// binding, not the edit a user makes through it, so this is the only handle on what typing
    /// into a field does to the draft.
    func text(_ name: String, default fallback: String) -> Binding<String> {
        Binding(get: {
            switch entry(name) {
            case .value(let value): value.stringValue ?? fallback
            case .cleared: ""
            case .untouched: fallback
            }
        }, set: { typed in
            draft.values[name] = typed.isEmpty ? nil : .string(typed)
            if typed.isEmpty { draft.cleared.insert(name) } else { draft.cleared.remove(name) }
        })
    }

    /// A numeric control, in the same three states every other control has (sweep#2).
    ///
    /// Emptying it used to store `nil` and touch nothing else, so the getter fell through to the
    /// schema's `default` and `content` carried it: a defaulted number could not be cleared, and
    /// the field redrew the value the user had just deleted. The typed text is kept beside the
    /// parsed value so that a number being typed — `-`, `1.`, `1e` — is not erased on its way to
    /// being one.
    func number(_ name: String, isInteger: Bool, default fallback: Double?) -> Binding<String> {
        Binding(get: {
            if let typed = draft.numberText[name] { return typed }
            switch entry(name) {
            case .value(let value): return value.doubleValue.map { ElicitationForm.spell($0, isInteger: isInteger) } ?? ""
            case .cleared: return ""
            case .untouched: return fallback.map { ElicitationForm.spell($0, isInteger: isInteger) } ?? ""
            }
        }, set: { text in
            draft.numberText[name] = text
            let parsed = ElicitationForm.numberValue(text, isInteger: isInteger)
            draft.values[name] = parsed
            if parsed == nil { draft.cleared.insert(name) } else { draft.cleared.remove(name) }
        })
    }

    func toggle(_ name: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { draft.values[name]?.boolValue ?? fallback }, set: { draft.values[name] = .bool($0) })
    }

    /// A free-typed string array: one value per comma-separated element, which is what a server
    /// asking for `string[]` without an `enum` has no better way to receive.
    func list(_ name: String, default fallback: [String]) -> Binding<String> {
        Binding(get: {
            self.selected(name, default: fallback).joined(separator: ", ")
        }, set: { text in
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.store(parts, in: name)
        })
    }

    func raw(_ name: String) -> Binding<String> {
        Binding(get: { draft.rawText[name] ?? "" }, set: { text in
            draft.rawText[name] = text
            switch ElicitationForm.rawEntry(text) {
            case .value(let value):
                draft.values[name] = value
                draft.cleared.remove(name)
                draft.malformed.remove(name)
            case .empty:
                draft.values[name] = nil
                draft.cleared.insert(name)
                draft.malformed.remove(name)
            case .malformed:
                // Neither a value nor an emptying: the field is still being written, and Accept
                // waits rather than sending the text as a string.
                draft.values[name] = nil
                draft.cleared.insert(name)
                draft.malformed.insert(name)
            }
        })
    }

    func pick(_ option: String, in name: String, default fallback: [String]) {
        var current = selected(name, default: fallback)
        if let index = current.firstIndex(of: option) { current.remove(at: index) } else { current.append(option) }
        store(current, in: name)
    }

    /// A list control's current elements: the draft's, then the schema's default, and none at all
    /// once the user has emptied it.
    private func selected(_ name: String, default fallback: [String]) -> [String] {
        switch entry(name) {
        case .value(let value): value.arrayValue?.compactMap(\.stringValue) ?? fallback
        case .cleared: []
        case .untouched: fallback
        }
    }

    private func store(_ elements: [String], in name: String) {
        draft.values[name] = elements.isEmpty ? nil : .array(elements.map(JSONValue.string))
        if elements.isEmpty { draft.cleared.insert(name) } else { draft.cleared.remove(name) }
    }
}
