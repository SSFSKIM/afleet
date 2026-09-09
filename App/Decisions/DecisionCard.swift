import Foundation
import ClaudeWire
import FleetKit

/// One decision the engine raised, as a value a view can draw and a mapping can answer.
///
/// It is decoded from a `DecisionItem` and holds no reference to a channel, a lifecycle or a view,
/// which is what lets the timeline and Activity render the same component (spec §8.4, contract Y2).
/// `DecisionItem.payload` is the *whole* inner `request` object as the engine sent it
/// (`WireReducer.open(_:state:at:)`), so every field §8.4 names is decoded here with C2's own
/// public `Codable` types and no second source is consulted.
///
/// There is no task case. A task is a `TimelineItem.taskRun`, never a `DecisionItem`, and
/// `DecisionItem.Kind` has no such case (spec D15).
struct DecisionCard: Sendable {

    /// The typed request behind the card. `.unmodelled` is the payload this build cannot type: it
    /// renders read-only and answers nothing, because §6.3 answers an unknown *inbound request* at
    /// the transport and a card is never the place to guess.
    enum Payload: Sendable {
        case permission(CanUseToolRequest)
        case question(CanUseToolRequest)
        case plan(CanUseToolRequest)
        case elicitation(ElicitationRequest)
        case dialog(UserDialogRequest)
        case unmodelled(JSONValue)
    }

    /// The two dialog kinds afleet declares to the engine in `initialize`. A `dialog_kind` outside
    /// this pair is left to the binary (§6.3) and this card answers none of its actions.
    enum DialogKind: String, Sendable {
        case refusalFallback = "refusal_fallback_prompt"
        case overageConsent = "fable_overage_consent_prompt"
    }

    var kind: DecisionItem.Kind
    var state: DecisionItem.State
    var requestID: RequestID
    var toolUseID: String?
    var agentID: String?
    var payload: Payload
    /// The `system/model_consent_fallback` frame the fold attached to this decision, where one
    /// arrived (§8.4, item 62). It travels **on the card** because it is part of the decision's own
    /// state: every host draws the same component, and a frame each host had to hand in separately
    /// is a frame most hosts would not have.
    var consentFallback: ModelConsentFallback?

    init(_ item: DecisionItem) {
        self.kind = item.kind
        self.state = item.state
        self.requestID = item.requestID
        self.toolUseID = item.toolUseID
        self.agentID = item.agentID
        self.payload = Self.decode(item.payload, as: item.kind)
        self.consentFallback = item.consentFallback
    }

    /// The payload case for a raw request object.
    ///
    /// A `can_use_tool` chooses between the three tool-shaped cases by the same rule
    /// `WireReducer.kind(of:)` uses, read from the decoded request rather than from the item's
    /// `kind`, so the two cannot disagree about the request in hand.
    private static func decode(_ raw: JSONValue, as kind: DecisionItem.Kind) -> Payload {
        guard let data = try? raw.canonicalData() else { return .unmodelled(raw) }
        let decoder = JSONDecoder()
        switch kind {
        case .permission, .question, .plan:
            guard let tool = try? decoder.decode(CanUseToolRequest.self, from: data) else { return .unmodelled(raw) }
            switch tool.fields.toolName {
            case "AskUserQuestion": return .question(tool)
            case "ExitPlanMode": return .plan(tool)
            default: return .permission(tool)
            }
        case .elicitation:
            guard let e = try? decoder.decode(ElicitationRequest.self, from: data) else { return .unmodelled(raw) }
            return .elicitation(e)
        case .dialog:
            guard let d = try? decoder.decode(UserDialogRequest.self, from: data) else { return .unmodelled(raw) }
            return .dialog(d)
        case .other:
            return .unmodelled(raw)
        }
    }

    /// The declared dialog kind this card carries, or nil for anything else — including a dialog
    /// kind afleet never declared, whose actions are the binary's to settle.
    var dialogKind: DialogKind? {
        guard case .dialog(let d) = payload else { return nil }
        return DialogKind(rawValue: d.fields.dialogKind)
    }

    /// `overagesEnabled` on an overage dialog. Absent is false: the engine omits the flag it means
    /// to be false, so nil never means "unknown".
    var overagesEnabled: Bool { overageConsent?.overagesEnabled ?? false }

    /// `refusal_fallback_prompt`'s payload (anchor 2, `cli.pretty.js:702406`).
    ///
    /// Every field but the two model names is optional, and `apiRefusalCategory` is **nullable**:
    /// the engine writes an explicit `null` as readily as it omits the key, so a card that read the
    /// key's *presence* would draw a category that names nothing. Reading the value is what makes
    /// the two shapes one.
    struct RefusalFallback: Sendable, Hashable {
        var originalModel: String?
        var fallbackModel: String?
        var apiRefusalCategory: String?
        var guidanceText: String?
        /// The already-streamed messages this dialog takes back once it is resolved (spec D11).
        var retractedMessageUUIDs: [String]
    }

    var refusalFallback: RefusalFallback? {
        guard case .dialog(let d) = payload, dialogKind == .refusalFallback else { return nil }
        let object = d.fields.payload
        return RefusalFallback(
            originalModel: object["originalModel"]?.stringValue,
            fallbackModel: object["fallbackModel"]?.stringValue,
            apiRefusalCategory: object["apiRefusalCategory"]?.stringValue,
            guidanceText: object["guidanceText"]?.stringValue,
            retractedMessageUUIDs: object["retractedMessageUuids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// `fable_overage_consent_prompt`'s payload (anchor 3, `cli.pretty.js:725659`).
    ///
    /// `balanceCents` and `currency` are declared by the schema and **currently unfed**: the sole
    /// runtime construction sends `{overagesEnabled, modelName}` (`cli.pretty.js:770104`), and the
    /// one fixture carrying them carries an explicit `null` on its disabled arm. Both are read as
    /// values, so an absent balance and a null balance are the same nothing — and neither becomes a
    /// zero a user would read as a real account balance.
    struct OverageConsent: Sendable, Hashable {
        var overagesEnabled: Bool
        var modelName: String?
        var balanceCents: Int64?
        var currency: String?
    }

    var overageConsent: OverageConsent? {
        guard case .dialog(let d) = payload, dialogKind == .overageConsent else { return nil }
        let object = d.fields.payload
        return OverageConsent(overagesEnabled: object["overagesEnabled"]?.boolValue ?? false,
                              modelName: object["modelName"]?.stringValue,
                              balanceCents: object["balanceCents"]?.intValue,
                              currency: object["currency"]?.stringValue)
    }

    /// Whether *Always allow* exists at all, and over which destinations it may be filed.
    ///
    /// Spec D5: only the rule- and directory-carrying suggestions take a chosen destination.
    /// `setMode` names a session-scoped permission *mode*, and a destination picker over one would
    /// offer to write a mode into a settings file; an unmodelled suggestion cannot be described to
    /// the user at all. So a `setMode`-only card offers *Always allow* with no picker, and an
    /// all-unmodelled card offers no *Always allow*.
    struct AlwaysAllowOffer: Hashable, Sendable {
        /// The destinations the picker offers, empty when no suggestion takes one.
        var destinations: [PermissionUpdateDestination]
        /// Where the picker starts; nil exactly when `destinations` is empty.
        var preselected: PermissionUpdateDestination?
    }

    /// The three destinations §8.4 names. `session` and `cliArg` are not among them: neither is a
    /// settings file the user chooses between.
    static let ruleDestinations: [PermissionUpdateDestination] = [.userSettings, .projectSettings, .localSettings]

    var alwaysAllow: AlwaysAllowOffer? {
        guard case .permission(let tool) = payload else { return nil }
        guard tool.fields.suppressAlwaysAllowRule != true else { return nil }
        let suggestions = tool.fields.permissionSuggestions ?? []
        guard !suggestions.isEmpty else { return nil }
        // Nothing describable, nothing to offer.
        guard suggestions.contains(where: { !$0.isUnmodelled }) else { return nil }
        guard let filed = suggestions.first(where: { $0.destination != nil }) else {
            return AlwaysAllowOffer(destinations: [], preselected: nil)
        }
        let own = filed.destination
        let start = own.flatMap { Self.ruleDestinations.contains($0) ? $0 : nil } ?? .localSettings
        return AlwaysAllowOffer(destinations: Self.ruleDestinations, preselected: start)
    }
}

extension PermissionUpdate {
    /// The destination this suggestion files itself at, or nil for a variant that files nothing —
    /// `setMode`, whose destination is the session, and a suggestion this build does not model.
    var destination: PermissionUpdateDestination? {
        switch self {
        case .addRules(_, _, let d, _), .replaceRules(_, _, let d, _), .removeRules(_, _, let d, _),
             .addDirectories(_, let d, _), .removeDirectories(_, let d, _):
            d
        case .setMode, .unknown:
            nil
        }
    }

    var isUnmodelled: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The same suggestion filed somewhere else. Only a variant that carries a destination moves;
    /// `setMode` and an unmodelled suggestion are returned exactly as they arrived (spec D5).
    func filed(at destination: PermissionUpdateDestination) -> PermissionUpdate {
        switch self {
        case .addRules(let r, let b, _, let e): .addRules(rules: r, behavior: b, destination: destination, extras: e)
        case .replaceRules(let r, let b, _, let e): .replaceRules(rules: r, behavior: b, destination: destination, extras: e)
        case .removeRules(let r, let b, _, let e): .removeRules(rules: r, behavior: b, destination: destination, extras: e)
        case .addDirectories(let d, _, let e): .addDirectories(directories: d, destination: destination, extras: e)
        case .removeDirectories(let d, _, let e): .removeDirectories(directories: d, destination: destination, extras: e)
        case .setMode, .unknown: self
        }
    }
}

extension DecisionItem {

    /// The item Activity hands the card component (spec D14).
    ///
    /// Activity is fleet-wide and holds no `ChannelTimeline` for a channel the user has not opened,
    /// so it cannot read C3's overlay; it holds the live `InboundRequest` in its pump. This builds
    /// the item the reducer would have built for the same request — same `payload: request.raw`,
    /// same derived `kind`, `title`, `toolUseID` and `agentID`, `state: .pending` — so both hosts
    /// hand the component one type. Nil for a request the reducer opens no item for.
    init?(surfacing request: InboundRequest, in channel: ChannelKey, at moment: Date = Date()) {
        guard let kind = Self.surfacedKind(of: request.payload) else { return nil }
        let stream = LogicalStream(configHome: channel.configHome, sessionID: channel.session, name: .main)
        self.init(id: ItemID(stream: stream, key: request.id.rawValue),
                  timestamp: moment,
                  provenance: Provenance(stream: stream, epoch: request.epoch, origin: .wire),
                  requestID: request.id,
                  kind: kind,
                  title: Self.surfacedTitle(of: request.payload),
                  toolUseID: Self.surfacedToolUseID(of: request.payload),
                  agentID: Self.surfacedAgentID(of: request.payload),
                  state: .pending,
                  payload: request.raw)
    }

    private static func surfacedKind(of payload: InboundRequest.Payload) -> Kind? {
        switch payload {
        case .canUseTool(let tool):
            switch tool.fields.toolName {
            case "AskUserQuestion": .question
            case "ExitPlanMode": .plan
            default: .permission
            }
        case .requestUserDialog: .dialog
        case .elicitation: .elicitation
        case .hookCallback: .other
        case .mcpMessage, .unknown, .malformed: nil
        }
    }

    private static func surfacedTitle(of payload: InboundRequest.Payload) -> String {
        switch payload {
        case .canUseTool(let t): t.fields.title ?? t.fields.displayName ?? t.fields.toolName
        case .requestUserDialog(let d): d.fields.dialogKind
        case .elicitation(let e): e.fields.title ?? e.fields.displayName ?? e.fields.message
        case .hookCallback(let h): h.fields.callbackID
        case .mcpMessage(let m): m.fields.serverName
        case .unknown(let subtype, _): subtype
        case .malformed(let subtype, _, _): subtype
        }
    }

    private static func surfacedToolUseID(of payload: InboundRequest.Payload) -> String? {
        switch payload {
        case .canUseTool(let t): t.fields.toolUseID
        case .requestUserDialog(let d): d.fields.toolUseID
        case .hookCallback(let h): h.fields.toolUseID
        default: nil
        }
    }

    private static func surfacedAgentID(of payload: InboundRequest.Payload) -> String? {
        if case .canUseTool(let t) = payload { return t.fields.agentID }
        return nil
    }
}
