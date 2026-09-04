import Foundation
import WireFrames
import WireMCP

public struct InitializeResponse: Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var commands: [JSONValue] { raw["commands"]?.arrayValue ?? [] }
    public var agents: [JSONValue] { raw["agents"]?.arrayValue ?? [] }
    public var models: [JSONValue] { raw["models"]?.arrayValue ?? [] }
    public var outputStyle: String? { raw["output_style"]?.stringValue }
    public var availableOutputStyles: [String] { raw["available_output_styles"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var account: JSONValue? { raw["account"] }
    public var currentModel: String? { raw["current_model"]?.stringValue }
    public var currentPermissionMode: PermissionMode? { raw["current_permission_mode"]?.stringValue.flatMap(PermissionMode.init(rawValue:)) }
    public var sessionState: JSONValue? { raw["session_state"] }
    public var pid: Int? { raw["pid"]?.intValue.map(Int.init) }
    public var fastModeState: String? { raw["fast_mode_state"]?.stringValue }
}
/// What `control_request/initialize` answers with, and nothing else.
///
/// There is deliberately no `systemInit` here. The engine emits `system/init` at the start of each **turn**,
/// not at startup: on the stream-json output this app consumes the frame is built on the message-submission
/// path (2.1.258 `cli.pretty.js`, `submitMessage`'s generator yields `qe` → `ku` → `Mxe`, line 146882), and
/// every one of C1's recorded fixtures places it after the first `user` frame — the two that submit no message
/// contain none at all. A consumer that wants the engine's tool list, model or version reads
/// `.frame(.system(.initialize(_)))` off the event stream when the first turn produces it.
///
/// It is absent rather than optional on purpose. A field that is nil on essentially every launch invites reads
/// that work against a fabricated handshake and fail in production; one source is better than two.
public struct Handshake: Sendable {
    public let initialize: InitializeResponse
    /// Requests the engine re-arms in the initialize response itself (`pending_permission_requests`,
    /// `pending_user_dialog_requests`) — not from `system/init`, so unaffected by the above.
    public let pending: [InboundRequest]
    public init(initialize: InitializeResponse, pending: [InboundRequest]) { self.initialize = initialize; self.pending = pending }
}
public enum ExitStatus: Hashable, Sendable {
    case code(Int32, stderrTail: String)
    case signal(Int32, stderrTail: String)
    public var isClean: Bool { if case .code(0, _) = self { return true }; return false }
}
public enum ProcessStatus: Hashable, Sendable { case launching, handshaking, running, terminating, exited(ExitStatus) }

public enum WireError: Error, Sendable, Equatable {
    case launchFailed(String)
    case handshakeTimeout(stderrTail: String)
    case handshakeRejected(String)
    case processExited
    case controlError(String)
    case unknownRequest(RequestID)
    case notInRunningState(ProcessStatus)
    /// A caller-supplied value cannot be handed to the CLI as the value of `option`. Thrown before anything
    /// is spawned, so the configuration is rejected rather than partially applied.
    case invalidArgument(option: String, reason: String)
}

public enum WireEvent: Sendable {
    case handshakeCompleted(Handshake, ProcessEpoch)
    case frame(Frame, ProcessEpoch)
    case request(InboundRequest)
    case requestCancelled(RequestID, ProcessEpoch)
    case policyAnswered(InboundRequest, error: String)
    case unansweredDialog(InboundRequest)
    case hostToolInvoked(HostToolInvocation, ProcessEpoch)
    case stderr(String, ProcessEpoch)
    case exited(ExitStatus, ProcessEpoch)
}
