import Foundation

public struct PermissionRuleValue: Codable, Hashable, Sendable {
    public var toolName: String
    public var ruleContent: String?
    public init(toolName: String, ruleContent: String? = nil) { self.toolName = toolName; self.ruleContent = ruleContent }
}
public enum PermissionBehavior: String, Codable, Sendable, CaseIterable { case allow, deny, ask }
public enum PermissionMode: String, Codable, Sendable, CaseIterable { case `default`, acceptEdits, bypassPermissions, plan, dontAsk, auto }
public enum PermissionUpdateDestination: String, Codable, Sendable, CaseIterable { case userSettings, projectSettings, localSettings, session, cliArg }

/// The engine's `PermissionUpdate` discriminated union (bundle 2.1.258 `cli.pretty.js:513878`, schema `_i`).
public enum PermissionUpdate: Hashable, Sendable, Codable {
    case addRules(rules: [PermissionRuleValue], behavior: PermissionBehavior, destination: PermissionUpdateDestination)
    case replaceRules(rules: [PermissionRuleValue], behavior: PermissionBehavior, destination: PermissionUpdateDestination)
    case removeRules(rules: [PermissionRuleValue], behavior: PermissionBehavior, destination: PermissionUpdateDestination)
    case setMode(mode: PermissionMode, destination: PermissionUpdateDestination)
    case addDirectories(directories: [String], destination: PermissionUpdateDestination)
    case removeDirectories(directories: [String], destination: PermissionUpdateDestination)

    public enum CodingKeys: String, CodingKey { case type, rules, behavior, destination, mode, directories }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dest = try c.decode(PermissionUpdateDestination.self, forKey: .destination)
        switch try c.decode(String.self, forKey: .type) {
        case "addRules": self = .addRules(rules: try c.decode([PermissionRuleValue].self, forKey: .rules), behavior: try c.decode(PermissionBehavior.self, forKey: .behavior), destination: dest)
        case "replaceRules": self = .replaceRules(rules: try c.decode([PermissionRuleValue].self, forKey: .rules), behavior: try c.decode(PermissionBehavior.self, forKey: .behavior), destination: dest)
        case "removeRules": self = .removeRules(rules: try c.decode([PermissionRuleValue].self, forKey: .rules), behavior: try c.decode(PermissionBehavior.self, forKey: .behavior), destination: dest)
        case "setMode": self = .setMode(mode: try c.decode(PermissionMode.self, forKey: .mode), destination: dest)
        case "addDirectories": self = .addDirectories(directories: try c.decode([String].self, forKey: .directories), destination: dest)
        case "removeDirectories": self = .removeDirectories(directories: try c.decode([String].self, forKey: .directories), destination: dest)
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown PermissionUpdate type \(other)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addRules(let r, let b, let d): try c.encode("addRules", forKey: .type); try c.encode(r, forKey: .rules); try c.encode(b, forKey: .behavior); try c.encode(d, forKey: .destination)
        case .replaceRules(let r, let b, let d): try c.encode("replaceRules", forKey: .type); try c.encode(r, forKey: .rules); try c.encode(b, forKey: .behavior); try c.encode(d, forKey: .destination)
        case .removeRules(let r, let b, let d): try c.encode("removeRules", forKey: .type); try c.encode(r, forKey: .rules); try c.encode(b, forKey: .behavior); try c.encode(d, forKey: .destination)
        case .setMode(let m, let d): try c.encode("setMode", forKey: .type); try c.encode(m, forKey: .mode); try c.encode(d, forKey: .destination)
        case .addDirectories(let dirs, let d): try c.encode("addDirectories", forKey: .type); try c.encode(dirs, forKey: .directories); try c.encode(d, forKey: .destination)
        case .removeDirectories(let dirs, let d): try c.encode("removeDirectories", forKey: .type); try c.encode(dirs, forKey: .directories); try c.encode(d, forKey: .destination)
        }
    }
}

/// `can_use_tool` (bundle schema: subtype, tool_name, input, permission_suggestions, blocked_path, decision_reason,
/// decision_reason_type, classifier_approvable, suppress_always_allow_rule, default_to_no, matched_ask_rule, title,
/// display_name, tool_use_id, agent_id, description, requires_user_interaction).
///
/// `input` is a JSON *record* in the engine's schema, so it is decoded as one: a non-object `input` must fail the
/// typed decode and land the request in `.malformed(field: "input")` rather than silently decoding as any JSON.
public struct CanUseToolFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var subtype: String
    public var toolName: String
    public var inputObject: [String: JSONValue]
    public var permissionSuggestions: [PermissionUpdate]?
    public var blockedPath: String?
    public var decisionReason: String?
    public var decisionReasonType: String?
    public var classifierApprovable: Bool?
    public var suppressAlwaysAllowRule: Bool?
    public var defaultToNo: Bool?
    public var matchedAskRule: JSONValue?
    public var title: String?
    public var displayName: String?
    public var toolUseID: String
    public var agentID: String?
    public var description: String?
    public var requiresUserInteraction: Bool?

    public var input: JSONValue { .object(inputObject) }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case subtype, toolName = "tool_name", inputObject = "input", permissionSuggestions = "permission_suggestions",
             blockedPath = "blocked_path", decisionReason = "decision_reason",
             decisionReasonType = "decision_reason_type", classifierApprovable = "classifier_approvable",
             suppressAlwaysAllowRule = "suppress_always_allow_rule", defaultToNo = "default_to_no",
             matchedAskRule = "matched_ask_rule", title, displayName = "display_name", toolUseID = "tool_use_id",
             agentID = "agent_id", description, requiresUserInteraction = "requires_user_interaction"
    }
}
public typealias CanUseToolRequest = Lossless<CanUseToolFields>
public extension Lossless where Fields == CanUseToolFields {
    var typedInput: ToolInput { ToolInput.parse(name: fields.toolName, input: fields.input) }
}

/// `request_user_dialog` (subtype, dialog_kind, payload, tool_use_id).
public struct UserDialogFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var subtype: String
    public var dialogKind: String
    public var payload: JSONValue
    public var toolUseID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case subtype, dialogKind = "dialog_kind", payload, toolUseID = "tool_use_id" }
}
public typealias UserDialogRequest = Lossless<UserDialogFields>

/// `elicitation` (subtype, mcp_server_name, message, mode, url, elicitation_id, requested_schema, title, display_name, description).
public struct ElicitationFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var subtype: String
    public var mcpServerName: String
    public var message: String
    public var mode: String?
    public var url: String?
    public var elicitationID: String?
    public var requestedSchema: JSONValue?
    public var title: String?
    public var displayName: String?
    public var description: String?
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case subtype, mcpServerName = "mcp_server_name", message, mode, url, elicitationID = "elicitation_id",
             requestedSchema = "requested_schema", title, displayName = "display_name", description
    }
}
public typealias ElicitationRequest = Lossless<ElicitationFields>

/// `hook_callback` (subtype, callback_id, input, tool_use_id). The engine also carries `issued_at` and `deadline_ms`,
/// both marked @internal in its schema; they are left undeclared and survive in `additional`.
public struct HookCallbackFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var subtype: String
    public var callbackID: String
    public var input: JSONValue
    public var toolUseID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case subtype, callbackID = "callback_id", input, toolUseID = "tool_use_id" }
}
public typealias HookCallbackRequest = Lossless<HookCallbackFields>

/// `mcp_message` (subtype, server_name, message).
public struct MCPMessageFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var subtype: String
    public var serverName: String
    public var message: JSONRPCMessage
    public enum CodingKeys: String, CodingKey, CaseIterable { case subtype, serverName = "server_name", message }
}
public typealias MCPMessageRequest = Lossless<MCPMessageFields>

public struct InboundRequest: Sendable, Identifiable {
    public let id: RequestID
    public let epoch: ProcessEpoch
    public let receivedAt: ContinuousClock.Instant
    public let payload: Payload
    /// The "request" object as received, for opaque items and diagnostics.
    public let raw: JSONValue

    public enum Payload: Sendable {
        case canUseTool(CanUseToolRequest), requestUserDialog(UserDialogRequest), elicitation(ElicitationRequest)
        case hookCallback(HookCallbackRequest), mcpMessage(MCPMessageRequest)
        case unknown(subtype: String, JSONValue)
        case malformed(subtype: String, field: String, JSONValue)
    }
    public init(id: RequestID, epoch: ProcessEpoch, receivedAt: ContinuousClock.Instant, payload: Payload, raw: JSONValue) {
        self.id = id; self.epoch = epoch; self.receivedAt = receivedAt; self.payload = payload; self.raw = raw
    }
    public var subtype: String {
        switch payload {
        case .canUseTool: "can_use_tool"
        case .requestUserDialog: "request_user_dialog"
        case .elicitation: "elicitation"
        case .hookCallback: "hook_callback"
        case .mcpMessage: "mcp_message"
        case .unknown(let s, _), .malformed(let s, _, _): s
        }
    }

    public static func parse(frame: ControlRequestFrame, epoch: ProcessEpoch, receivedAt: ContinuousClock.Instant) -> InboundRequest {
        let subtype = frame.subtype
        func typed<T: Decodable>(_: T.Type, _ wrap: (T) -> Payload) -> Payload {
            do { return wrap(try JSONDecoder().decode(T.self, from: try frame.request.canonicalData())) }
            catch { let f = DecodeFailure(error); return .malformed(subtype: subtype, field: f.field, frame.request) }
        }
        let payload: Payload
        switch subtype {
        case "can_use_tool": payload = typed(CanUseToolRequest.self, Payload.canUseTool)
        case "request_user_dialog": payload = typed(UserDialogRequest.self, Payload.requestUserDialog)
        case "elicitation": payload = typed(ElicitationRequest.self, Payload.elicitation)
        case "hook_callback": payload = typed(HookCallbackRequest.self, Payload.hookCallback)
        case "mcp_message": payload = typed(MCPMessageRequest.self, Payload.mcpMessage)
        default: payload = .unknown(subtype: subtype, frame.request)
        }
        return InboundRequest(id: frame.requestID, epoch: epoch, receivedAt: receivedAt, payload: payload, raw: frame.request)
    }
}
