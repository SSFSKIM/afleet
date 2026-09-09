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
    /// Whether this card is the one the user is acting on.
    ///
    /// Both hosts draw **lists** of cards — Activity a compact card per waiting channel, the
    /// timeline a full card per pending ask — and a keyboard default action is singular. A card
    /// that claimed Return because nothing told it not to would let one Return answer whichever
    /// competing channel's card registered first. So no card owns Return, or the initial focus,
    /// unless its host says this one is active; `default_to_no` then unbinds the shortcut on top of
    /// that (spec §8.4).
    let isActive: Bool
    let answering: DecisionAnswering
    /// The channel's agent-run tree, for item 52's label alone. A host that has none — Activity's
    /// fleet-wide list, a card drawn outside a channel's publish — passes none, and the card then
    /// says the ask is a subagent's without naming which.
    let agents: AgentRunTree?

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
         isActive: Bool = false,
         answering: DecisionAnswering,
         agents: AgentRunTree? = nil) {
        self.card = card
        self.tool = tool
        self.presentation = presentation
        self.channel = channel
        self.isActive = isActive
        self.answering = answering
        self.agents = agents
        _destination = State(initialValue: card.alwaysAllow?.preselected)
    }

    // MARK: - What the engine said

    /// The title: the engine's own display name, and the raw tool name when it sent none.
    var title: String { tool.fields.displayName ?? tool.fields.toolName }

    /// The consent line — what this call is for, in the engine's words.
    var consentLine: String? { tool.fields.description }

    /// What a card raised inside a subagent says (item 52's card half): the run's type and its
    /// errand, from the channel's own tree, in the Agents tab's own words.
    ///
    /// **The tab's formatter and not a second one.** The same ask is drawn on the run's node and in
    /// the main timeline, and two spellings of one sentence would leave the two surfaces naming the
    /// same work differently.
    ///
    /// The standing sentence survives for the run the tree does not hold — a channel whose fold has
    /// not opened, or an ask that outran its `task_started`. A card that said nothing would hide
    /// that the ask is not the main thread's; a card that invented a name would attribute it to the
    /// wrong work.
    var subagentLabel: String? {
        guard let agent = tool.fields.agentID, !agent.isEmpty else { return nil }
        guard let node = agents?.node(agent) else { return Self.unattributedSubagentLabel }
        return AgentNodeDecisions.label(agentType: node.agentType, description: node.description)
    }

    /// What the card says when the ask names a run this channel's tree does not hold.
    static let unattributedSubagentLabel = "In a subagent run"

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
    ///
    /// The flag is the second gate, not the first: an inactive card binds nothing whatever the
    /// engine said, because Return belongs to the card the user is acting on and to no other.
    var approveShortcut: KeyboardShortcut? {
        guard isActive, tool.fields.defaultToNo != true else { return nil }
        return .defaultAction
    }

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
            if let expansionReading {
                Text(expansionReading).font(.caption).foregroundStyle(.secondary)
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

    // MARK: - What Always allow would do

    /// What each suggestion behind *Always allow* would change, in one sentence each.
    ///
    /// The button persists something beyond this call, and what it persists is the engine's
    /// suggestion rather than anything the card composes: a `setMode` switches the session's
    /// permission mode, so later calls of that kind stop being asked about at all, and a rule is
    /// written into a settings file. Neither is legible from the words *Always allow*. The card
    /// therefore states the expansion **before** the user takes it, at the destination the card
    /// would actually submit — which is also what makes the compact presentation honest, since it
    /// shows no picker and submits the preselection (spec D5).
    ///
    /// Empty when there is no offer, and silent about a suggestion this build cannot describe: an
    /// `.unknown` re-encodes verbatim and inventing a sentence for it would be a guess.
    /// The expansions as one block of caption text, or nil where there is nothing to say.
    var expansionReading: String? {
        let lines = expansions
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var expansions: [String] {
        guard let offer = card.alwaysAllow else { return [] }
        let target = destination ?? offer.preselected
        return (tool.fields.permissionSuggestions ?? []).compactMap {
            Self.expansion(of: target.map($0.filed(at:)) ?? $0)
        }
    }

    static func expansion(of update: PermissionUpdate) -> String? {
        switch update {
        case .setMode(let mode, let scope, _):
            let where_ = scope == .session ? "this session" : name(of: scope)
            return "Always allow sets \(where_)'s permission mode to \(name(of: mode))."
        case .addRules(let rules, let behavior, let destination, _):
            return "Always allow adds \(reading(of: rules, behavior)) to \(name(of: destination))."
        case .replaceRules(let rules, let behavior, let destination, _):
            return "Always allow replaces the rules in \(name(of: destination)) with \(reading(of: rules, behavior))."
        case .removeRules(let rules, let behavior, let destination, _):
            return "Always allow removes \(reading(of: rules, behavior)) from \(name(of: destination))."
        case .addDirectories(let directories, let destination, _):
            return "Always allow adds \(reading(of: directories)) to \(name(of: destination))."
        case .removeDirectories(let directories, let destination, _):
            return "Always allow removes \(reading(of: directories)) from \(name(of: destination))."
        case .unknown:
            return nil
        }
    }

    private static func reading(of rules: [PermissionRuleValue], _ behavior: PermissionBehavior) -> String {
        let named = rules.map { rule in
            guard let content = rule.ruleContent, !content.isEmpty else { return rule.toolName }
            return "\(rule.toolName)(\(content))"
        }.joined(separator: ", ")
        let word = behavior == .allow ? "an allow rule" : "a \(behavior.rawValue) rule"
        return rules.count == 1 ? "\(word) for \(named)" : "\(behavior.rawValue) rules for \(named)"
    }

    /// Every directory, named (scalpel-2#2).
    ///
    /// The count was the whole description of what *Always allow* would grant, and the list reaches
    /// the engine in full: `DecisionAnswerMapping` sends the suggestion as it arrived, and no other
    /// control on the card exposes it — the picker chooses where the rule is filed, not what it
    /// covers. A user cannot consent to directories they were never shown.
    private static func reading(of directories: [String]) -> String {
        let named = directories.joined(separator: ", ")
        return directories.count == 1 ? "the directory \(named)" : "the directories \(named)"
    }

    private static func name(of mode: PermissionMode) -> String {
        switch mode {
        case .default: "Default"
        case .acceptEdits: "Accept edits"
        case .bypassPermissions: "Bypass permissions"
        case .plan: "Plan"
        case .dontAsk: "Don't ask"
        case .auto: "Auto"
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
/// everything else as the tool's own summary — and, for a tool this build has no view for, the
/// input object's own keys and values.
///
/// **There is no branch that draws nothing** (sweep#1). The specialised views cover the file and
/// search tools; an MCP call parses as `.other` and `Agent` and `SendMessage` have no view of their
/// own, so a card for one of them used to draw a title, a reason and three buttons over no
/// arguments at all. A permission card exists to put what the engine wants to do in front of the
/// person answering; an approval collected over an input the card did not show is not one.
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
        case .agent, .askUserQuestion, .exitPlanMode, .taskStop, .sendMessage, .other:
            GenericToolInputView(object: Self.object(of: input) ?? .object([:]))
        }
    }

    /// The input as an object, for the branches with no view of their own.
    ///
    /// The switch is exhaustive on purpose: a tool this build learns to model later must be a
    /// decision about which of the two halves it belongs in, not a silent fall into a branch that
    /// draws nothing. The typed payloads re-encode through their own `CodingKeys`, so what is drawn
    /// carries the engine's field names rather than Swift's; `.other` is already the wire's object.
    static func object(of input: ToolInput) -> JSONValue? {
        func encoded(_ value: some Encodable) -> JSONValue? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        switch input {
        case .read, .write, .edit, .bash, .glob, .grep, .webFetch, .webSearch: return nil
        case .other(_, let value): return value
        case .agent(let agent): return encoded(agent)
        case .askUserQuestion(let ask): return encoded(ask)
        case .exitPlanMode(let plan): return encoded(plan)
        case .taskStop(let stop): return encoded(stop)
        case .sendMessage(let message): return encoded(message)
        }
    }

    private func path(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .underline()
            .textSelection(.enabled)
    }
}

// MARK: - A tool this build has no view for

/// One tool input's fields, as text.
///
/// Separated from the view so the shape of what is drawn can be asserted without a render pass, and
/// so the bound below is a property of the value rather than of a modifier somebody could drop.
enum GenericToolInput {

    /// One field as it will be drawn.
    struct Field: Hashable, Identifiable {
        var key: String
        var text: String
        var id: String { key }
    }

    /// How much of one value is drawn before the disclosure.
    ///
    /// A card sits in a scrolling list beside every other card, and an engine may send an argument
    /// of any size — a whole prompt, a pasted document. Long enough that the ordinary argument is
    /// drawn whole, short enough that one field cannot push the buttons off the screen.
    static let visibleCharacters = 600

    /// The fields, in key order. A non-object input — the wire allows one — is drawn as a single
    /// unnamed value rather than dropped.
    static func fields(of object: JSONValue) -> [Field] {
        guard case .object(let members) = object else {
            return [Field(key: "input", text: text(of: object))]
        }
        return members.keys.sorted().map { Field(key: $0, text: text(of: members[$0]!)) }
    }

    /// A scalar as itself — a string verbatim, without the quotes an encoder would add — and
    /// anything structured as indented JSON, which is the only rendering of a nested object that
    /// stays true to what the engine sent.
    static func text(of value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .integer(let number): String(number)
        case .number(let number): String(number)
        case .array, .object: indented(value)
        }
    }

    /// Whether a field is longer than the card draws before the disclosure.
    static func isElided(_ text: String) -> Bool { text.count > visibleCharacters }

    /// The head of a field, when it is longer than the card draws at once.
    static func head(of text: String) -> String {
        isElided(text) ? String(text.prefix(visibleCharacters)) + "\u{2026}" : text
    }

    private static func indented(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            // Nothing an engine can send fails here — `JSONValue` came from JSON — and a field that
            // cannot be drawn must still say that it exists rather than vanish from the input.
            return "(this value could not be displayed)"
        }
        return text
    }
}

/// The generic rendering: every key the input carries, and its value.
///
/// The fields are resolved at construction and stored. They are what the view draws and the only
/// thing it draws, so holding them is what lets a test read the input a card is offering approval
/// over — `ForEach` builds its rows from a closure, which reflection does not enter (tracker 166).
struct GenericToolInputView: View {

    let fields: [GenericToolInput.Field]

    init(object: JSONValue) {
        fields = GenericToolInput.fields(of: object)
    }

    /// The fields the user has asked to see in full. Per key, and per card: the disclosure is about
    /// reading, and nothing is answered by it.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.key).font(.caption).foregroundStyle(.secondary)
                    Text(expanded.contains(field.key) ? field.text : GenericToolInput.head(of: field.text))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    if GenericToolInput.isElided(field.text), !expanded.contains(field.key) {
                        Button("Show more") { expanded.insert(field.key) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }
}
