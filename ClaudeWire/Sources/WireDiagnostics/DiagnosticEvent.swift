import Foundation
import WireFrames

public enum Direction: String, Sendable { case inbound, outbound }

public enum DiagnosticEvent: Sendable {
    case frame(direction: Direction, type: String, subtype: String?, bytes: Int, epoch: ProcessEpoch, requestID: RequestID?)
    case answer(requestID: RequestID, subtype: String, behavior: String, classification: String?, epoch: ProcessEpoch)
    case lifecycle(String, epoch: ProcessEpoch)
    case handshake(durationMs: Int, epoch: ProcessEpoch)
    case terminateEscalated(step: String, epoch: ProcessEpoch)
    case captureSkipped(reason: String)
    /// An in-process MCP tool threw something unexpected. The text the model sees is summarised so a
    /// Foundation error cannot leak the path it failed on into the conversation; the full description is
    /// kept here, in the local metadata log, where an operator can actually diagnose it.
    case mcpToolFailure(tool: String, error: String)

    /// Metadata only: names, sizes, identifiers and timings. No frame payload ever reaches this value.
    public var jsonValue: JSONValue {
        var o: [String: JSONValue] = ["at": .string(ISO8601DateFormatter().string(from: Date()))]
        switch self {
        case .frame(let d, let t, let s, let b, let e, let r):
            o["event"] = .string("frame"); o["direction"] = .string(d.rawValue); o["type"] = .string(t); if let s { o["subtype"] = .string(s) }
            o["bytes"] = .integer(Int64(b)); o["epoch"] = .integer(Int64(e.rawValue)); if let r { o["request_id"] = .string(r.rawValue) }
        case .answer(let r, let s, let b, let c, let e):
            o["event"] = .string("answer"); o["request_id"] = .string(r.rawValue); o["subtype"] = .string(s); o["behavior"] = .string(b)
            if let c { o["classification"] = .string(c) }
            o["epoch"] = .integer(Int64(e.rawValue))
        case .lifecycle(let what, let e): o["event"] = .string("lifecycle"); o["what"] = .string(what); o["epoch"] = .integer(Int64(e.rawValue))
        case .handshake(let ms, let e): o["event"] = .string("handshake"); o["duration_ms"] = .integer(Int64(ms)); o["epoch"] = .integer(Int64(e.rawValue))
        case .terminateEscalated(let step, let e): o["event"] = .string("terminate_escalated"); o["step"] = .string(step); o["epoch"] = .integer(Int64(e.rawValue))
        case .captureSkipped(let reason): o["event"] = .string("capture_skipped"); o["reason"] = .string(reason)
        case .mcpToolFailure(let tool, let error): o["event"] = .string("mcp_tool_failure"); o["tool"] = .string(tool); o["error"] = .string(error)
        }
        return .object(o)
    }
}

public protocol DiagnosticsSink: Sendable { func record(_ event: DiagnosticEvent) }

public struct NullDiagnostics: DiagnosticsSink {
    public init() {}
    public func record(_ event: DiagnosticEvent) {}
}
