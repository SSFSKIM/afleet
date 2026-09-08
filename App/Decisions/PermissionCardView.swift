import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The permission card (§8.4's first row): what the engine wants to do, why it is asking, and the
/// three answers.
///
/// Every branch here is data the engine sent. `default_to_no`, `requires_user_interaction` and
/// `suppress_always_allow_rule` are **omitted when false** (`cli.pretty.js:283001`), so a nil is a
/// false and never an "unknown"; reading absence as unknown would either offer an approval the
/// engine asked not to default to, or hide one it never suppressed.
struct PermissionCardView: View {

    let card: DecisionCard
    let tool: CanUseToolRequest
    let presentation: DecisionCardView.Presentation
    let channel: ChannelKey
    let answering: DecisionAnswering

    /// Which control opens focused.
    enum Focus: Hashable, Sendable { case approve, decline }

    /// What a denial says when the user typed nothing. One constant, used by both presentations, so
    /// the same request denied from either host produces the same bytes — it is the engine's own
    /// sentence for a rejected tool use (`cli.pretty.js`, the tool-rejection result).
    static let unstatedDenial = "The user doesn't want to proceed with this tool use."

    /// The destination the *Always allow* rule is filed at, when the card offers a choice at all.
    /// Its initial value is the suggestion's own destination (spec D5).
    @State private var destination: PermissionUpdateDestination?
    @State private var denial: String = ""
    @FocusState private var focus: Focus?

    init(card: DecisionCard,
         tool: CanUseToolRequest,
         presentation: DecisionCardView.Presentation,
         channel: ChannelKey,
         answering: DecisionAnswering) {
        self.card = card
        self.tool = tool
        self.presentation = presentation
        self.channel = channel
        self.answering = answering
        _destination = State(initialValue: card.alwaysAllow?.preselected)
    }

    // MARK: - What the engine said

    /// The title: the engine's own display name, and the raw tool name when it sent none.
    var title: String { tool.fields.displayName ?? tool.fields.toolName }

    /// The consent line — what this call is for, in the engine's words.
    var consentLine: String? { tool.fields.description }

    /// The label for a card raised inside a subagent (item 52's card half). The run's type and
    /// description are C3's join and arrive with the Agents tab; the id alone is what this card
    /// has, and a card that said nothing would hide that the ask is not the main thread's.
    var subagentLabel: String? {
        guard let agent = tool.fields.agentID, !agent.isEmpty else { return nil }
        return "In a subagent run"
    }

    /// Why the engine is asking, as text a person reads.
    ///
    /// The recorded reason is stripped of ANSI first — the engine writes it for a terminal — and
    /// when it is empty or absent the reason is rebuilt from `decision_reason_type` and
    /// `matched_ask_rule`, which are the two fields that still say why (*A-24*).
    var reason: String? {
        let stripped = Self.strippingANSI(tool.fields.decisionReason ?? "")
        if !stripped.isEmpty { return stripped }
        return Self.rebuiltReason(type: tool.fields.decisionReasonType, rule: tool.fields.matchedAskRule)
    }

    // MARK: - Which actions exist

    /// `requires_user_interaction` is the engine saying the tool's own card is the surface. The
    /// one-tap approve and deny are removed entirely — not disabled — because answering here would
    /// answer a question the user has not been shown.
    var offersOneTapAnswer: Bool { tool.fields.requiresUserInteraction != true }

    /// `default_to_no`: the safe answer is no, so decline opens focused…
    var initialFocus: Focus { tool.fields.defaultToNo == true ? .decline : .approve }

    /// …and approve binds no shortcut, so Return cannot approve by reflex.
    var approveShortcut: KeyboardShortcut? { tool.fields.defaultToNo == true ? nil : .defaultAction }

    /// The message a denial carries: what the user typed, or the standing sentence.
    var denialMessage: String {
        let typed = denial.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? Self.unstatedDenial : typed
    }

    private var isAnswering: Bool { answering.isAnswering(card.requestID) }

    // MARK: - Drawing

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 6 : 4) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                if let subagentLabel {
                    Text(subagentLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            if presentation == .full {
                if let consentLine { Text(consentLine).font(.callout) }
                ToolInputView(input: tool.typedInput)
            }
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            actions
        }
        .defaultFocus($focus, initialFocus)
    }

    @ViewBuilder
    private var actions: some View {
        if offersOneTapAnswer {
            if presentation == .full {
                TextField("Why not", text: $denial)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button("Allow once") { answering.send(.allowOnce, on: card, in: channel) }
                    .keyboardShortcut(approveShortcut)
                    .focused($focus, equals: .approve)
                if let offer = card.alwaysAllow {
                    if presentation == .full, !offer.destinations.isEmpty {
                        Picker("File the rule in", selection: $destination) {
                            ForEach(offer.destinations, id: \.self) { target in
                                Text(Self.name(of: target)).tag(Optional(target))
                            }
                        }
                        .labelsHidden()
                    }
                    Button("Always allow") {
                        answering.send(.alwaysAllow(destination: destination), on: card, in: channel)
                    }
                }
                Button("Deny") { answering.send(.deny(message: denialMessage), on: card, in: channel) }
                    .focused($focus, equals: .decline)
            }
            .disabled(isAnswering)
        } else {
            Text("This tool asks for the answer in its own card.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func name(of destination: PermissionUpdateDestination) -> String {
        switch destination {
        case .userSettings: "Your settings"
        case .projectSettings: "This project"
        case .localSettings: "This project, locally"
        default: destination.rawValue
        }
    }

    // MARK: - The reason, as text

    /// Drops CSI sequences. The engine writes `decision_reason` for a terminal, and the escape
    /// bytes render as glyphs in a SwiftUI `Text`.
    static func strippingANSI(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\u{1B}" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            var scan = text.index(after: index)
            // CSI: ESC [ parameters intermediates final. Anything else after ESC is a two-byte
            // sequence, and dropping the pair is right for every one of them.
            if scan < text.endIndex, text[scan] == "[" {
                scan = text.index(after: scan)
                while scan < text.endIndex, !("@"..."~").contains(text[scan]) {
                    scan = text.index(after: scan)
                }
            }
            index = scan < text.endIndex ? text.index(after: scan) : text.endIndex
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reason rebuilt from the two fields that survive an empty `decision_reason`.
    ///
    /// The type's own sentences are the engine's (`cli.pretty.js:398220`); the rule is
    /// `{source, tool_name, rule_content?}`, and naming it is what tells the user which rule
    /// stopped the call.
    static func rebuiltReason(type: String?, rule: JSONValue?) -> String? {
        var parts: [String] = []
        switch type {
        case "hook": parts.append("A configured hook requires confirmation.")
        case "classifier": parts.append("An automated safety classifier requires confirmation.")
        case "safetyCheck", "subcommandResults": parts.append("A safety check requires confirmation.")
        case "sandboxOverride": parts.append("This call asked to run outside the sandbox.")
        case .some(let named) where !named.isEmpty && named != "other":
            parts.append("The engine asked because of \(named).")
        default: break
        }
        if let named = Self.name(ofRule: rule) { parts.append("Matched the ask rule \(named).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func name(ofRule rule: JSONValue?) -> String? {
        guard case .object(let fields)? = rule else { return nil }
        guard case .string(let tool)? = fields["tool_name"] else { return nil }
        if case .string(let content)? = fields["rule_content"], !content.isEmpty {
            return "\(tool)(\(content))"
        }
        return tool
    }
}

/// The tool's input, formatted per §8.4: a shell command in monospace, a path named as itself,
/// everything else as the tool's own summary.
///
/// The path is drawn and not yet linked: the routing seam is the per-row capability environment
/// value C6.1 lands (spec D1), and there is no `ChannelContext.links` reachable from a card until
/// it does. `Edit` and `Write` render their change through `DiffRendering` (spec D9) — the card
/// names the seam and never the conformer, so C7.2's Monaco replaces the drawing and this file
/// does not change.
struct ToolInputView: View {

    let input: ToolInput

    var body: some View {
        switch input {
        case .bash(let bash):
            Text(bash.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        case .read(let read):
            path(read.filePath)
        case .write(let write):
            VStack(alignment: .leading, spacing: 4) {
                path(write.filePath)
                DiffView(input: input)
            }
        case .edit(let edit):
            VStack(alignment: .leading, spacing: 4) {
                path(edit.filePath)
                DiffView(input: input)
            }
        case .glob(let glob):
            Text(glob.pattern).font(.system(.callout, design: .monospaced))
        case .grep(let grep):
            Text(grep.pattern).font(.system(.callout, design: .monospaced))
        case .webFetch(let fetch):
            Text(fetch.url).font(.callout)
        case .webSearch(let search):
            Text(search.query).font(.callout)
        default:
            EmptyView()
        }
    }

    private func path(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .underline()
            .textSelection(.enabled)
    }
}
