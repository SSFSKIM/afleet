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
        let answered = content.objectValue ?? [:]
        return form.fields.allSatisfy { !$0.isRequired || answered[$0.name] != nil }
    }

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
                    Button(option) { pick(option, in: field.name, default: fallback) }
                }
            } else {
                TextField(field.title, text: list(field.name, default: fallback))
            }
        case .raw(let schema):
            VStack(alignment: .leading, spacing: 2) {
                Text(ElicitationForm.schemaText(schema))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                TextField("JSON", text: raw(field.name))
            }
        }
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

    func number(_ name: String, isInteger: Bool, default fallback: Double?) -> Binding<String> {
        Binding(get: {
            if let typed = draft.values[name]?.doubleValue {
                return ElicitationForm.spell(typed, isInteger: isInteger)
            }
            return fallback.map { ElicitationForm.spell($0, isInteger: isInteger) } ?? ""
        }, set: { text in
            draft.values[name] = ElicitationForm.numberValue(text, isInteger: isInteger)
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
            draft.values[name] = ElicitationForm.rawValue(text)
            if draft.values[name] == nil { draft.cleared.insert(name) } else { draft.cleared.remove(name) }
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
