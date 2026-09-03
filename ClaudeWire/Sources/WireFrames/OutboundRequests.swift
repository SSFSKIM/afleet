import Foundation

public protocol ControlRequestSpec: Sendable {
    associatedtype Response: Decodable & Sendable
    static var subtype: String { get }
    /// The request object minus "subtype".
    var payload: JSONValue { get }
}
public struct EmptyResponse: Decodable, Sendable { public init() {}; public init(from decoder: any Decoder) throws {} }

public enum OutboundEnvelope {
    /// The only two subtypes the engine's stdin loop registers in its abort map; a `control_cancel_request` for any
    /// other subtype is a no-op the engine logs and ignores.
    public static let abortableSubtypes: Set<String> = ["side_question", "mcp_call"]
    public static func encode<R: ControlRequestSpec>(spec: R, requestID: RequestID) throws -> Data {
        var request = spec.payload.objectValue ?? [:]
        request["subtype"] = .string((spec as? RawControlRequest)?.wireSubtype ?? R.subtype)
        return try JSONValue.object(["type": .string("control_request"), "request_id": .string(requestID.rawValue), "request": .object(request)]).canonicalData()
    }
}

public struct Interrupt: ControlRequestSpec {
    public struct Response: Decodable, Sendable {
        public var stillQueued: [String]?
        public var cancelled: [String]?
        enum CodingKeys: String, CodingKey { case stillQueued = "still_queued", cancelled }
    }
    public static let subtype = "interrupt"
    public var cancelQueued: Bool
    public init(cancelQueued: Bool = false) { self.cancelQueued = cancelQueued }
    public var payload: JSONValue { cancelQueued ? .object(["cancel_queued": .bool(true)]) : .object([:]) }
}
public struct SetPermissionMode: ControlRequestSpec { public typealias Response = EmptyResponse; public static let subtype = "set_permission_mode"
    public var mode: PermissionMode; public init(mode: PermissionMode) { self.mode = mode }
    public var payload: JSONValue { .object(["mode": .string(mode.rawValue)]) } }
public struct SetModel: ControlRequestSpec { public typealias Response = EmptyResponse; public static let subtype = "set_model"
    public var model: String?; public init(model: String?) { self.model = model }
    public var payload: JSONValue { .object(["model": model.map(JSONValue.string) ?? .null]) } }
public struct ListModels: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "list_models"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct SetMaxThinkingTokens: ControlRequestSpec { public typealias Response = EmptyResponse; public static let subtype = "set_max_thinking_tokens"
    public var maxThinkingTokens: Int?; public init(maxThinkingTokens: Int?) { self.maxThinkingTokens = maxThinkingTokens }
    public var payload: JSONValue { .object(["max_thinking_tokens": maxThinkingTokens.map { .integer(Int64($0)) } ?? .null]) } }
public struct ApplyFlagSettings: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "apply_flag_settings"
    public var settings: JSONValue; public init(settings: JSONValue) { self.settings = settings }
    public var payload: JSONValue { .object(["settings": settings]) } }
public struct RenameSession: ControlRequestSpec { public typealias Response = EmptyResponse; public static let subtype = "rename_session"
    public var title: String; public init(title: String) { self.title = title }
    public var payload: JSONValue { .object(["title": .string(title)]) } }
/// `trusted_directory` is required by the engine whenever `trust_accepted` is true: it pins the attestation to the exact
/// directory string from the `needs_trust` response being answered.
public struct SetCwd: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "set_cwd"
    public var path: String; public var trustAccepted: Bool?; public var trustedDirectory: String?
    public init(path: String, trustAccepted: Bool? = nil, trustedDirectory: String? = nil) { self.path = path; self.trustAccepted = trustAccepted; self.trustedDirectory = trustedDirectory }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["path": .string(path)]
        if let trustAccepted { o["trust_accepted"] = .bool(trustAccepted) }
        if let trustedDirectory { o["trusted_directory"] = .string(trustedDirectory) }
        return .object(o)
    } }
public struct GetSettings: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "get_settings"; public init() {}; public var payload: JSONValue { .object([:]) } }

// The auth requests below have no published typings; their payload keys are read off the bundle's own stdin handlers
// and the CLI's own client (2.1.258 `cli.pretty.js` lines 152320-152470 and 249910-249925). They are camelCase, unlike
// most of the control channel.
public struct ClaudeAuthenticate: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "claude_authenticate"
    public var loginWithClaudeAI: Bool?; public init(loginWithClaudeAI: Bool? = nil) { self.loginWithClaudeAI = loginWithClaudeAI }
    public var payload: JSONValue { loginWithClaudeAI.map { .object(["loginWithClaudeAi": .bool($0)]) } ?? .object([:]) } }
public struct ClaudeOAuthCallback: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "claude_oauth_callback"
    public var authorizationCode: String; public var state: String?
    public init(authorizationCode: String, state: String? = nil) { self.authorizationCode = authorizationCode; self.state = state }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["authorizationCode": .string(authorizationCode)]
        if let state { o["state"] = .string(state) }
        return .object(o)
    } }
public struct ClaudeOAuthWaitForCompletion: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "claude_oauth_wait_for_completion"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct MCPAuthenticate: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_authenticate"
    public var serverName: String; public var redirectURI: String?
    public init(serverName: String, redirectURI: String? = nil) { self.serverName = serverName; self.redirectURI = redirectURI }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["serverName": .string(serverName)]
        if let redirectURI { o["redirectUri"] = .string(redirectURI) }
        return .object(o)
    } }
public struct MCPOAuthCallbackURL: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_oauth_callback_url"
    public var serverName: String; public var callbackURL: String
    public init(serverName: String, callbackURL: String) { self.serverName = serverName; self.callbackURL = callbackURL }
    public var payload: JSONValue { .object(["serverName": .string(serverName), "callbackUrl": .string(callbackURL)]) } }
public struct MCPClearAuth: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_clear_auth"
    public var serverName: String; public init(serverName: String) { self.serverName = serverName }
    public var payload: JSONValue { .object(["serverName": .string(serverName)]) } }

/// `last_seen_user_message_uuid` is what lets a rewind past the newest turn succeed: with it absent the engine's
/// staleness check refuses any target followed by a later *human* user turn (its `O3` predicate wants a user message
/// that is not a tool result, has `origin.kind == "human"` and is not a stacked expansion). A rewind to the most
/// recent user turn has no such successor and works without the field.
public struct RewindConversation: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "rewind_conversation"
    public var targetMessageUUID: String; public var lastSeenUserMessageUUID: String?; public var interruptIfRunning: Bool?
    public init(targetMessageUUID: String, lastSeenUserMessageUUID: String? = nil, interruptIfRunning: Bool? = nil) {
        self.targetMessageUUID = targetMessageUUID; self.lastSeenUserMessageUUID = lastSeenUserMessageUUID; self.interruptIfRunning = interruptIfRunning
    }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["target_message_uuid": .string(targetMessageUUID)]
        if let lastSeenUserMessageUUID { o["last_seen_user_message_uuid"] = .string(lastSeenUserMessageUUID) }
        if let interruptIfRunning { o["interrupt_if_running"] = .bool(interruptIfRunning) }
        return .object(o)
    } }
public struct RewindFiles: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "rewind_files"
    public var userMessageID: String; public var dryRun: Bool
    public init(userMessageID: String, dryRun: Bool) { self.userMessageID = userMessageID; self.dryRun = dryRun }
    public var payload: JSONValue { .object(["user_message_id": .string(userMessageID), "dry_run": .bool(dryRun)]) } }
public struct GetContextUsage: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "get_context_usage"
    public var detail: String?; public init(detail: String? = nil) { self.detail = detail }
    public var payload: JSONValue { detail.map { .object(["detail": .string($0)]) } ?? .object([:]) } }
public struct GetSessionCost: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "get_session_cost"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct GetUsage: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "get_usage"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct GetBinaryVersion: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "get_binary_version"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct StopTask: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "stop_task"
    public var taskID: String; public init(taskID: String) { self.taskID = taskID }
    public var payload: JSONValue { .object(["task_id": .string(taskID)]) } }
public struct BackgroundTasks: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "background_tasks"
    public var toolUseID: String?; public init(toolUseID: String? = nil) { self.toolUseID = toolUseID }
    public var payload: JSONValue { toolUseID.map { .object(["tool_use_id": .string($0)]) } ?? .object([:]) } }
/// The engine destructures `{ question, history }`; `history` elements are `{question, response, fallback_notice?}`
/// and the key is omitted entirely when there is no history.
public struct SideQuestion: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "side_question"
    public var question: String; public var history: [JSONValue]
    public init(question: String, history: [JSONValue] = []) { self.question = question; self.history = history }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["question": .string(question)]
        if !history.isEmpty { o["history"] = .array(history) }
        return .object(o)
    } }
public struct FileSuggestions: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "file_suggestions"
    public var query: String; public init(query: String) { self.query = query }
    public var payload: JSONValue { .object(["query": .string(query)]) } }
public struct MCPStatus: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_status"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct MCPSetServers: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_set_servers"
    public var servers: JSONValue; public init(servers: JSONValue) { self.servers = servers }
    public var payload: JSONValue { .object(["servers": servers]) } }
public struct MCPReconnect: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_reconnect"   // schema: serverName (camelCase)
    public var serverName: String; public init(serverName: String) { self.serverName = serverName }
    public var payload: JSONValue { .object(["serverName": .string(serverName)]) } }
public struct MCPToggle: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_toggle"         // schema: serverName, enabled
    public var serverName: String; public var enabled: Bool
    public init(serverName: String, enabled: Bool) { self.serverName = serverName; self.enabled = enabled }
    public var payload: JSONValue { .object(["serverName": .string(serverName), "enabled": .bool(enabled)]) } }
public struct ReloadSkills: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "reload_skills"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct ReloadPlugins: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "reload_plugins"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct EndSession: ControlRequestSpec { public typealias Response = EmptyResponse; public static let subtype = "end_session"; public init() {}; public var payload: JSONValue { .object([:]) } }
public struct GenerateSessionTitle: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "generate_session_title"
    public var description: String?; public var persist: Bool
    public init(description: String? = nil, persist: Bool = true) { self.description = description; self.persist = persist }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["persist": .bool(persist)]
        if let description { o["description"] = .string(description) }
        return .object(o)
    } }
public struct UpdateSettings: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "update_settings"   // schema: source is required and only 'localSettings'
    public var settings: JSONValue; public init(settings: JSONValue) { self.settings = settings }
    public var payload: JSONValue { .object(["source": .string("localSettings"), "settings": settings]) } }
public struct MCPCall: ControlRequestSpec { public typealias Response = JSONValue; public static let subtype = "mcp_call"   // schema: tool (mcp__server__tool name), arguments?, timeout_ms?
    public var tool: String; public var arguments: JSONValue?; public var timeoutMs: Int?
    public init(tool: String, arguments: JSONValue? = nil, timeoutMs: Int? = nil) { self.tool = tool; self.arguments = arguments; self.timeoutMs = timeoutMs }
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["tool": .string(tool)]
        if let arguments { o["arguments"] = arguments }
        if let timeoutMs { o["timeout_ms"] = .integer(Int64(timeoutMs)) }
        return .object(o)
    } }

/// Escape hatch: any subtype, any payload, JSONValue response. `Self.subtype` is the constant "raw"; the wire subtype is per instance.
public struct RawControlRequest: ControlRequestSpec {
    public typealias Response = JSONValue
    public static let subtype = "raw"
    public var wireSubtype: String
    public var payload: JSONValue
    public init(subtype: String, payload: JSONValue) { self.wireSubtype = subtype; self.payload = payload }
}
