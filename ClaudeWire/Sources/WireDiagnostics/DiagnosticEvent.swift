import Foundation
import WireFrames

public enum Direction: String, Sendable { case inbound, outbound }

public enum DiagnosticEvent: Sendable {
    case frame(direction: Direction, type: String, subtype: String?, bytes: Int, epoch: ProcessEpoch, requestID: RequestID?)
    case answer(requestID: RequestID, subtype: String, behavior: String, classification: String?, epoch: ProcessEpoch)
    case lifecycle(LifecycleNotice, epoch: ProcessEpoch)
    case handshake(durationMs: Int, epoch: ProcessEpoch)
    case terminateEscalated(step: String, epoch: ProcessEpoch)
    case captureSkipped(reason: String)
    /// An in-process MCP tool threw something unexpected. Deliberately metadata only: an MCP tool's
    /// arguments come straight off engine frames, so `String(describing:)` on its error is frame-derived
    /// payload — a `send_user_file` failure carries the path the *model* named. The tool name, the error's
    /// type and its bridged `NSError` domain and code are what actually diagnose a Foundation failure, and
    /// they keep this log's contract intact.
    case mcpToolFailure(tool: String, errorType: String, domain: String, code: Int, epoch: ProcessEpoch)

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
        case .lifecycle(let notice, let e):
            o["event"] = .string("lifecycle"); o["epoch"] = .integer(Int64(e.rawValue))
            for (k, v) in notice.fields { o[k] = v }
        case .handshake(let ms, let e): o["event"] = .string("handshake"); o["duration_ms"] = .integer(Int64(ms)); o["epoch"] = .integer(Int64(e.rawValue))
        case .terminateEscalated(let step, let e): o["event"] = .string("terminate_escalated"); o["step"] = .string(step); o["epoch"] = .integer(Int64(e.rawValue))
        case .captureSkipped(let reason): o["event"] = .string("capture_skipped"); o["reason"] = .string(reason)
        case .mcpToolFailure(let tool, let errorType, let domain, let code, let e):
            o["event"] = .string("mcp_tool_failure"); o["tool"] = .string(tool); o["error_type"] = .string(errorType)
            o["domain"] = .string(domain); o["code"] = .integer(Int64(code)); o["epoch"] = .integer(Int64(e.rawValue))
        }
        return .object(o)
    }
}

/// Which of the three exit-publication sites found the event channel already finished.
public enum ExitPublicationSite: String, Sendable { case launchFailure = "launch_failure", exit, neverLaunched = "never_launched" }

/// Why an MCP reply the in-process server produced was never delivered to the child.
public enum MCPDeliveryAbandonment: String, Sendable { case cancelled, writeFailed = "write_failed" }

/// The lifecycle notices, one case per thing that can be reported.
///
/// This used to be a free-form `String`, and a free-form String in a metadata log is an open door: the
/// `exited` site interpolated an `ExitStatus`, whose associated value carries up to fifty lines of raw child
/// stderr, straight into `diagnostics.log`. Fixing that one interpolation would have left the next one to be
/// written. So the type is the fix — the same reasoning that gave `mcpToolFailure` separate typed fields.
/// Every case below carries identifiers, counts or nothing at all, and there is no arm a payload can ride.
///
/// The exit's stderr tail still reaches consumers, on the `.exited` event and on `WireError.handshakeTimeout`.
/// It is removed from the log, not from the API.
public enum LifecycleNotice: Sendable {
    case spawned(pid: Int32)
    case exitEventDropped(site: ExitPublicationSite)
    /// `ControlSuccess`'s typed views skip an element that does not decode; this is how many were lost.
    case handshakePendingUnderReported(decoded: Int, onWire: Int, key: String)
    case uncorrelatedControlResponse(requestID: RequestID)
    case readerDrainDeadlineExceeded
    /// A `tools/call` produced a reply that was not sent on: the request had been cancelled, or the write
    /// failed. Either way no `hostToolInvoked` was published, which is the point of recording it.
    case mcpDeliveryAbandoned(requestID: RequestID, reason: MCPDeliveryAbandonment)
    case exited(code: Int32)
    case exitedOnSignal(Int32)

    var fields: [String: JSONValue] {
        switch self {
        case .spawned(let pid):
            ["what": .string("spawned"), "pid": .integer(Int64(pid))]
        case .exitEventDropped(let site):
            ["what": .string("exit_event_dropped"), "site": .string(site.rawValue)]
        case .handshakePendingUnderReported(let decoded, let onWire, let key):
            ["what": .string("handshake_pending_under_reported"), "decoded": .integer(Int64(decoded)),
             "on_wire": .integer(Int64(onWire)), "key": .string(key)]
        case .uncorrelatedControlResponse(let requestID):
            ["what": .string("uncorrelated_control_response"), "request_id": .string(requestID.rawValue)]
        case .readerDrainDeadlineExceeded:
            ["what": .string("reader_drain_deadline_exceeded")]
        case .mcpDeliveryAbandoned(let requestID, let reason):
            ["what": .string("mcp_delivery_abandoned"), "request_id": .string(requestID.rawValue), "reason": .string(reason.rawValue)]
        case .exited(let code):
            ["what": .string("exited"), "code": .integer(Int64(code))]
        case .exitedOnSignal(let signal):
            ["what": .string("exited"), "signal": .integer(Int64(signal))]
        }
    }
}

public protocol DiagnosticsSink: Sendable { func record(_ event: DiagnosticEvent) }

public struct NullDiagnostics: DiagnosticsSink {
    public init() {}
    public func record(_ event: DiagnosticEvent) {}
}
