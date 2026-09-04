import Foundation

// MARK: content blocks

public struct TextBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var text: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, text }
}
public struct ThinkingBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var thinking: String; public var signature: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, thinking, signature }
}
public struct RedactedThinkingBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var data: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, data }
}
public struct ToolUseBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var id: String; public var name: String; public var input: JSONValue
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, id, name, input }
}
public struct ToolResultBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var toolUseID: String; public var content: JSONValue?; public var isError: Bool?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, toolUseID = "tool_use_id", content, isError = "is_error" }
}
public struct ImageBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var source: JSONValue
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, source }
}
public struct DocumentBlockFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var source: JSONValue; public var title: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, source, title }
}
public typealias TextBlock = Lossless<TextBlockFields>
public typealias ThinkingBlock = Lossless<ThinkingBlockFields>
public typealias RedactedThinkingBlock = Lossless<RedactedThinkingBlockFields>
public typealias ToolUseBlock = Lossless<ToolUseBlockFields>
public typealias ToolResultBlock = Lossless<ToolResultBlockFields>
public typealias ImageBlock = Lossless<ImageBlockFields>
public typealias DocumentBlock = Lossless<DocumentBlockFields>

public enum ContentBlock: Hashable, Sendable, Codable {
    case text(TextBlock), thinking(ThinkingBlock), redactedThinking(RedactedThinkingBlock)
    case toolUse(ToolUseBlock), toolResult(ToolResultBlock), image(ImageBlock), document(DocumentBlock)
    case opaque(JSONValue)

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        let data = try v.canonicalData()
        let d = JSONDecoder()
        switch v["type"]?.stringValue {
        case "text": self = .text(try d.decode(TextBlock.self, from: data))
        case "thinking": self = .thinking(try d.decode(ThinkingBlock.self, from: data))
        case "redacted_thinking": self = .redactedThinking(try d.decode(RedactedThinkingBlock.self, from: data))
        case "tool_use": self = .toolUse(try d.decode(ToolUseBlock.self, from: data))
        case "tool_result": self = .toolResult(try d.decode(ToolResultBlock.self, from: data))
        case "image": self = .image(try d.decode(ImageBlock.self, from: data))
        case "document": self = .document(try d.decode(DocumentBlock.self, from: data))
        default: self = .opaque(v)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let b): try b.encode(to: encoder)
        case .thinking(let b): try b.encode(to: encoder)
        case .redactedThinking(let b): try b.encode(to: encoder)
        case .toolUse(let b): try b.encode(to: encoder)
        case .toolResult(let b): try b.encode(to: encoder)
        case .image(let b): try b.encode(to: encoder)
        case .document(let b): try b.encode(to: encoder)
        case .opaque(let v): try v.encode(to: encoder)
        }
    }
}

// MARK: typed tool inputs for the tools whose cards need fields

public struct ReadInput: Codable, Hashable, Sendable { public var filePath: String; public var offset: Int?; public var limit: Int?
    enum CodingKeys: String, CodingKey { case filePath = "file_path", offset, limit } }
public struct WriteInput: Codable, Hashable, Sendable { public var filePath: String; public var content: String
    enum CodingKeys: String, CodingKey { case filePath = "file_path", content } }
public struct EditInput: Codable, Hashable, Sendable { public var filePath: String; public var oldString: String; public var newString: String; public var replaceAll: Bool?
    enum CodingKeys: String, CodingKey { case filePath = "file_path", oldString = "old_string", newString = "new_string", replaceAll = "replace_all" } }
public struct BashInput: Codable, Hashable, Sendable { public var command: String; public var description: String?; public var timeout: Int?; public var runInBackground: Bool?
    enum CodingKeys: String, CodingKey { case command, description, timeout, runInBackground = "run_in_background" } }
public struct GlobInput: Codable, Hashable, Sendable { public var pattern: String; public var path: String? }
public struct GrepInput: Codable, Hashable, Sendable { public var pattern: String; public var path: String?; public var glob: String?; public var outputMode: String?
    enum CodingKeys: String, CodingKey { case pattern, path, glob, outputMode = "output_mode" } }
public struct AgentInput: Codable, Hashable, Sendable { public var description: String; public var prompt: String; public var subagentType: String?; public var model: String?; public var runInBackground: Bool?
    enum CodingKeys: String, CodingKey { case description, prompt, subagentType = "subagent_type", model, runInBackground = "run_in_background" } }
public struct AskUserQuestionInput: Codable, Hashable, Sendable { public var questions: [JSONValue] }
public struct ExitPlanModeInput: Codable, Hashable, Sendable { public var plan: String? }
public struct WebFetchInput: Codable, Hashable, Sendable { public var url: String; public var prompt: String? }
public struct WebSearchInput: Codable, Hashable, Sendable { public var query: String }
public struct TaskStopInput: Codable, Hashable, Sendable { public var taskID: String?
    enum CodingKeys: String, CodingKey { case taskID = "task_id" } }
public struct SendMessageInput: Codable, Hashable, Sendable { public var to: String; public var message: String?; public var summary: String? }

public enum ToolInput: Hashable, Sendable {
    case read(ReadInput), write(WriteInput), edit(EditInput), bash(BashInput), glob(GlobInput), grep(GrepInput)
    case agent(AgentInput), askUserQuestion(AskUserQuestionInput), exitPlanMode(ExitPlanModeInput)
    case webFetch(WebFetchInput), webSearch(WebSearchInput), taskStop(TaskStopInput), sendMessage(SendMessageInput)
    case other(name: String, JSONValue)

    public static func parse(name: String, input: JSONValue) -> ToolInput {
        func t<T: Decodable>(_: T.Type, _ wrap: (T) -> ToolInput) -> ToolInput {
            guard let data = try? input.canonicalData(), let v = try? JSONDecoder().decode(T.self, from: data) else { return .other(name: name, input) }
            return wrap(v)
        }
        switch name {
        case "Read": return t(ReadInput.self, ToolInput.read)
        case "Write": return t(WriteInput.self, ToolInput.write)
        case "Edit": return t(EditInput.self, ToolInput.edit)
        case "Bash": return t(BashInput.self, ToolInput.bash)
        case "Glob": return t(GlobInput.self, ToolInput.glob)
        case "Grep": return t(GrepInput.self, ToolInput.grep)
        case "Agent": return t(AgentInput.self, ToolInput.agent)
        case "AskUserQuestion": return t(AskUserQuestionInput.self, ToolInput.askUserQuestion)
        case "ExitPlanMode": return t(ExitPlanModeInput.self, ToolInput.exitPlanMode)
        case "WebFetch": return t(WebFetchInput.self, ToolInput.webFetch)
        case "WebSearch": return t(WebSearchInput.self, ToolInput.webSearch)
        case "TaskStop": return t(TaskStopInput.self, ToolInput.taskStop)
        case "SendMessage": return t(SendMessageInput.self, ToolInput.sendMessage)
        default: return .other(name: name, input)
        }
    }
}
public extension Lossless where Fields == ToolUseBlockFields {
    var typedInput: ToolInput { ToolInput.parse(name: fields.name, input: fields.input) }
}

// MARK: the message body

public struct MessageFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var id: String?; public var type: String?; public var role: String; public var model: String?
    public var content: [ContentBlock]; public var stopReason: String?; public var stopSequence: String?; public var usage: JSONValue?
    public enum CodingKeys: String, CodingKey, CaseIterable { case id, type, role, model, content, stopReason = "stop_reason", stopSequence = "stop_sequence", usage }
}
public typealias Message = Lossless<MessageFields>

/// A user message's content is either a string or blocks.
public enum UserContent: Hashable, Sendable, Codable {
    case text(String), blocks([ContentBlock])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([ContentBlock].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .text(let s): try c.encode(s); case .blocks(let b): try c.encode(b) }
    }
}
public struct UserMessageFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var role: String; public var content: UserContent
    public enum CodingKeys: String, CodingKey, CaseIterable { case role, content }
}
public typealias UserMessage = Lossless<UserMessageFields>

public struct MessageOriginFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var kind: String; public var from: String?; public var name: String?; public var body: String?; public var senderTaskID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case kind, from, name, body, senderTaskID = "senderTaskId" }
}
public typealias MessageOrigin = Lossless<MessageOriginFields>

// MARK: top-level frames

public struct AssistantFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var message: Message; public var parentToolUseID: String?
    public var uuid: String; public var sessionID: String; public var userMessageUUID: String?; public var userMessageUUIDs: [String]?
    public var supersedes: [String]?; public var aborted: Bool?; public var subagentType: String?; public var taskDescription: String?; public var timestamp: String?; public var error: String?
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, message, parentToolUseID = "parent_tool_use_id", uuid, sessionID = "session_id", userMessageUUID = "user_message_uuid",
             userMessageUUIDs = "user_message_uuids", supersedes, aborted, subagentType = "subagent_type", taskDescription = "task_description", timestamp, error
    }
}
public typealias AssistantFrame = Lossless<AssistantFields>

public struct UserFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var message: UserMessage; public var parentToolUseID: String?
    public var uuid: String?; public var sessionID: String?; public var isSynthetic: Bool?; public var isReplay: Bool?
    public var toolUseResult: JSONValue?; public var origin: MessageOrigin?; public var priority: String?; public var shouldQuery: Bool?
    public var timestamp: String?; public var subagentType: String?; public var taskDescription: String?
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, message, parentToolUseID = "parent_tool_use_id", uuid, sessionID = "session_id", isSynthetic, isReplay,
             toolUseResult = "tool_use_result", origin, priority, shouldQuery, timestamp, subagentType = "subagent_type", taskDescription = "task_description"
    }
}
public typealias UserFrame = Lossless<UserFields>

public struct StreamEventFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var event: JSONValue; public var parentToolUseID: String?; public var uuid: String; public var sessionID: String; public var userMessageUUID: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, event, parentToolUseID = "parent_tool_use_id", uuid, sessionID = "session_id", userMessageUUID = "user_message_uuid" }
}
public typealias StreamEventFrame = Lossless<StreamEventFields>

/// `duration_ms`, `total_cost_usd`, `uuid` and `session_id` are required, and stay required.
///
/// The authority is the bundle, which says what the engine *guarantees*, not the census, which says
/// only what was *observed*. In `~/claude-code-bundle/2.1.258/cli.pretty.js` every stream-json
/// `result` frame is built by one helper, `$W` at line 35141, whose own object — `type`,
/// `duration_ms`, `uuid` — is spread last and so cannot be overridden by any caller; all six of its
/// call sites pass a `common` carrying `session_id` and `total_cost_usd` (line 36304's `Wr` and the
/// five that spell the pair out), and the two literal `result` constructions that reach stdout, at
/// lines 613083 and 759779, write all four. No path emits a stream-json `result` frame lacking any
/// of them.
///
/// The two synthetic dialog fixtures omit them deliberately: `Tools/probe/synthetic/dialogs.py`
/// writes only the fields "whose value is known from the branch that produced the frame", because
/// "a fabricated zero would enter the census as a shape nothing observed". A recorded fixture is
/// authoritative about what the engine sends; a synthetic one is authoritative only about the shape
/// it was built to exercise, and its silence here is a fact about the constructor. Relaxing these to
/// optional would give up a real alarm — a live `result` frame that lost one of them would decode
/// silently instead of surfacing as a decode failure — against a guarantee the bundle states.
/// `FixtureCorpusTests` holds "a modelled type decodes typed" against the recorded fixtures and
/// reports the synthetic shortfall as a named finding.
public struct ResultFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var durationMs: Int; public var durationApiMs: Int?; public var isError: Bool
    public var numTurns: Int; public var result: String?; public var stopReason: String?; public var totalCostUSD: Double; public var usage: JSONValue?
    public var modelUsage: JSONValue?; public var permissionDenials: JSONValue?; public var queuedTurnCount: Int?; public var fastModeState: String?
    public var fastModeDisabledReason: String?; public var terminalReason: String?; public var errors: [String]?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, durationMs = "duration_ms", durationApiMs = "duration_api_ms", isError = "is_error", numTurns = "num_turns", result,
             stopReason = "stop_reason", totalCostUSD = "total_cost_usd", usage, modelUsage, permissionDenials = "permission_denials",
             queuedTurnCount = "queued_turn_count", fastModeState = "fast_mode_state", fastModeDisabledReason = "fast_mode_disabled_reason",
             terminalReason = "terminal_reason", errors, uuid, sessionID = "session_id"
    }
}
public typealias ResultFrame = Lossless<ResultFields>
