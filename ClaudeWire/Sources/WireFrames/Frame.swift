import Foundation

public enum OpaqueReason: Hashable, Sendable {
    case invalidJSON
    case unknownType
    case unknownSubtype
    case decodeFailure(field: String, description: String)
}

public struct OpaqueFrame: Hashable, Sendable {
    public let raw: Data
    public let value: JSONValue
    public let type: String?
    public let subtype: String?
    public let reason: OpaqueReason
    public init(raw: Data, value: JSONValue, type: String?, subtype: String?, reason: OpaqueReason) {
        self.raw = raw; self.value = value; self.type = type; self.subtype = subtype; self.reason = reason
    }
}

public enum Frame: Sendable {
    case assistant(AssistantFrame)
    case user(UserFrame)
    case streamEvent(StreamEventFrame)
    case result(ResultFrame)
    case system(SystemFrame)                     // Task 4
    case toolProgress(ToolProgressFrame)         // Task 4
    case toolUseSummary(ToolUseSummaryFrame)     // Task 4
    case rateLimitEvent(RateLimitEventFrame)     // Task 4
    case authStatus(AuthStatusFrame)             // Task 4
    case promptSuggestion(PromptSuggestionFrame) // Task 4
    case conversationReset(ConversationResetFrame) // Task 4
    case transcriptMirror(TranscriptMirrorFrame) // Task 4
    case commandLifecycle(CommandLifecycleFrame) // Task 4
    case keepAlive
    case controlRequest(ControlRequestFrame)
    case controlResponse(ControlResponseFrame)
    case controlCancelRequest(ControlCancelFrame)
    case opaque(OpaqueFrame)

    public var typeName: String {
        switch self {
        case .assistant: "assistant"; case .user: "user"; case .streamEvent: "stream_event"; case .result: "result"
        case .system: "system"; case .toolProgress: "tool_progress"; case .toolUseSummary: "tool_use_summary"
        case .rateLimitEvent: "rate_limit_event"; case .authStatus: "auth_status"; case .promptSuggestion: "prompt_suggestion"
        case .conversationReset: "conversation_reset"; case .transcriptMirror: "transcript_mirror"; case .commandLifecycle: "command_lifecycle"
        case .keepAlive: "keep_alive"; case .controlRequest: "control_request"; case .controlResponse: "control_response"
        case .controlCancelRequest: "control_cancel_request"; case .opaque(let o): o.type ?? "?"
        }
    }
}

public enum FrameDecoder {
    /// Stage one parses the line into a JSONValue; stage two decodes the typed model from the same bytes.
    /// A failure at any stage yields .opaque; this function never throws.
    public static func decode(line: Data) -> Frame {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: line) }
        catch { return .opaque(.init(raw: line, value: .null, type: nil, subtype: nil, reason: .invalidJSON)) }
        let type = value["type"]?.stringValue
        let subtype = value["subtype"]?.stringValue
        func typed<T: Decodable>(_: T.Type, _ wrap: (T) -> Frame) -> Frame {
            do { return wrap(try JSONDecoder().decode(T.self, from: line)) }
            catch { let f = DecodeFailure(error); return .opaque(.init(raw: line, value: value, type: type, subtype: subtype, reason: .decodeFailure(field: f.field, description: f.description))) }
        }
        switch type {
        case "assistant": return typed(AssistantFrame.self, Frame.assistant)
        case "user": return typed(UserFrame.self, Frame.user)
        case "stream_event": return typed(StreamEventFrame.self, Frame.streamEvent)
        case "result": return typed(ResultFrame.self, Frame.result)
        case "system": return SystemFrame.decode(line: line, value: value, subtype: subtype)   // Task 4
        case "tool_progress": return typed(ToolProgressFrame.self, Frame.toolProgress)
        case "tool_use_summary": return typed(ToolUseSummaryFrame.self, Frame.toolUseSummary)
        case "rate_limit_event": return typed(RateLimitEventFrame.self, Frame.rateLimitEvent)
        case "auth_status": return typed(AuthStatusFrame.self, Frame.authStatus)
        case "prompt_suggestion": return typed(PromptSuggestionFrame.self, Frame.promptSuggestion)
        case "conversation_reset": return typed(ConversationResetFrame.self, Frame.conversationReset)
        case "transcript_mirror": return typed(TranscriptMirrorFrame.self, Frame.transcriptMirror)
        case "command_lifecycle": return typed(CommandLifecycleFrame.self, Frame.commandLifecycle)
        case "keep_alive": return .keepAlive
        case "control_request": return typed(ControlRequestFrame.self, Frame.controlRequest)
        case "control_response": return typed(ControlResponseFrame.self, Frame.controlResponse)
        case "control_cancel_request": return typed(ControlCancelFrame.self, Frame.controlCancelRequest)
        default: return .opaque(.init(raw: line, value: value, type: type, subtype: subtype, reason: .unknownType))
        }
    }

    /// Encodes a frame back to one JSON line (no trailing newline). Opaque frames re-emit their raw bytes.
    public static func encode(_ frame: Frame) throws -> Data {
        let enc = JSONEncoder()
        switch frame {
        case .assistant(let f): return try enc.encode(f)
        case .user(let f): return try enc.encode(f)
        case .streamEvent(let f): return try enc.encode(f)
        case .result(let f): return try enc.encode(f)
        case .system(let f): return try f.encode()                                    // Task 4
        case .toolProgress(let f): return try enc.encode(f)
        case .toolUseSummary(let f): return try enc.encode(f)
        case .rateLimitEvent(let f): return try enc.encode(f)
        case .authStatus(let f): return try enc.encode(f)
        case .promptSuggestion(let f): return try enc.encode(f)
        case .conversationReset(let f): return try enc.encode(f)
        case .transcriptMirror(let f): return try enc.encode(f)
        case .commandLifecycle(let f): return try enc.encode(f)
        case .keepAlive: return Data(#"{"type":"keep_alive"}"#.utf8)
        case .controlRequest(let f): return try enc.encode(f)
        case .controlResponse(let f): return try enc.encode(f)
        case .controlCancelRequest(let f): return try enc.encode(f)
        case .opaque(let o): return o.raw
        }
    }
}
