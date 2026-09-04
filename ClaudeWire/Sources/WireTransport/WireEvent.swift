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
public struct Handshake: Sendable {
    public let initialize: InitializeResponse
    public let systemInit: SystemInit
    public let pending: [InboundRequest]
    public init(initialize: InitializeResponse, systemInit: SystemInit, pending: [InboundRequest]) { self.initialize = initialize; self.systemInit = systemInit; self.pending = pending }
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
