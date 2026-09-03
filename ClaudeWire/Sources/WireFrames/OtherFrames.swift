import Foundation

// The one-way frames that are not `system` and not part of the message family. Same shape as
// SystemFrames.swift: one `XFields` per wire type, wrapped in `Lossless` so undeclared keys and
// explicit nulls survive a round trip.

/// `parent_tool_use_id` is nullable but always present; decoded as `String?`, it stays in
/// `Lossless.explicitNulls` when null so re-encoding writes the key back.
public struct ToolProgressFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var toolUseID: String; public var toolName: String; public var parentToolUseID: String?
    public var elapsedTimeSeconds: Double; public var taskID: String?; public var heartbeat: Bool?; public var subagentType: String?
    public var subagentRetry: JSONValue?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, toolUseID = "tool_use_id", toolName = "tool_name", parentToolUseID = "parent_tool_use_id",
             elapsedTimeSeconds = "elapsed_time_seconds", taskID = "task_id", heartbeat, subagentType = "subagent_type",
             subagentRetry = "subagent_retry", uuid, sessionID = "session_id"
    }
}
public typealias ToolProgressFrame = Lossless<ToolProgressFields>

public struct ToolUseSummaryFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var summary: String; public var precedingToolUseIDs: [String]; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, summary, precedingToolUseIDs = "preceding_tool_use_ids", uuid, sessionID = "session_id"
    }
}
public typealias ToolUseSummaryFrame = Lossless<ToolUseSummaryFields>

public struct RateLimitEventFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var rateLimitInfo: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, rateLimitInfo = "rate_limit_info", uuid, sessionID = "session_id" }
}
public typealias RateLimitEventFrame = Lossless<RateLimitEventFields>

public struct AuthStatusFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var isAuthenticating: Bool; public var output: [String]; public var error: String?
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, isAuthenticating, output, error, uuid, sessionID = "session_id" }
}
public typealias AuthStatusFrame = Lossless<AuthStatusFields>

public struct PromptSuggestionFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var suggestion: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, suggestion, uuid, sessionID = "session_id" }
}
public typealias PromptSuggestionFrame = Lossless<PromptSuggestionFields>

public struct ConversationResetFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var newConversationID: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, newConversationID = "new_conversation_id", uuid, sessionID = "session_id" }
}
public typealias ConversationResetFrame = Lossless<ConversationResetFields>

/// Not in the public union; modelled from the bundle. The mirror writer emits it without
/// `uuid`/`session_id`, which is why both are optional.
public struct TranscriptMirrorFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var filePath: String; public var entries: [JSONValue]; public var uuid: String?; public var sessionID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, filePath, entries, uuid, sessionID = "session_id" }
}
public typealias TranscriptMirrorFrame = Lossless<TranscriptMirrorFields>

/// Not in the public union; modelled from the bundle. The wire key is `state`, not `event`:
/// `queued | started | completed | cancelled | discarded | refused`
/// [2.1.258 `cli.pretty.js` schema `yse`]. The plan's table said `event`, which is on no frame.
public struct CommandLifecycleFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var state: String; public var commandUUID: String?; public var uuid: String?; public var sessionID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, state, commandUUID = "command_uuid", uuid, sessionID = "session_id" }
}
public typealias CommandLifecycleFrame = Lossless<CommandLifecycleFields>
