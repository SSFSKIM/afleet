import Foundation
import AfleetCore
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
    ///
    /// `Handshake.pending` is a wire fact; nothing renders from it. It is the engine's own report of what it
    /// still has outstanding, recorded verbatim so a diagnostic or a test can compare it against what followed.
    /// The one surface a consumer may draw prompts from is the event stream: the engine re-sends each of these
    /// as a live `control_request` immediately after the handshake, those pass through the inbound policy, and
    /// only the ones the policy surfaces arrive as request events. Reading this array to display prompts is not
    /// an ambiguity in the contract to be resolved by taste — it is a violation of it, and it double-shows or
    /// shows a prompt the policy answered on the caller's behalf.
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

/// Whose session this channel is, and whether that is yet a fact.
///
/// `.new` and `.resume` know it at construction: the id on the command line is the id the engine adopts.
/// A **fork** does not. `--fork-session` makes the engine mint a fresh id and write the forked transcript
/// under it, so the `--resume` target names the session forked *from* and never this one. Reporting it as
/// this channel's id collides two channels — captures are keyed by session id, and so is everything a
/// consumer files under one.
///
/// The unknown is in the type rather than behind a plausible-looking default, because a guess that is right
/// most of the time is exactly what nobody checks. The real id arrives at frame 5, on the `auth_status` the
/// engine emits immediately after the initialize response and before any user frame.
public enum SessionIdentity: Hashable, Sendable {
    case known(SessionID)
    /// A fork, before its own id has arrived. `from` is the session forked from — kept because it is worth
    /// reporting, never as a stand-in for the answer. `provisional` names the capture file until then.
    case awaitingFork(from: SessionID, provisional: SessionID)

    /// This channel's own session id, or `nil` while a fork's is still unknown.
    public var resolved: SessionID? { if case .known(let id) = self { return id }; return nil }
    /// The id a capture file is keyed by right now. Provisional for an unresolved fork; the capture is
    /// renamed when the real id arrives.
    public var captureKey: SessionID {
        switch self { case .known(let id): id; case .awaitingFork(_, let provisional): provisional }
    }
}

public enum WireEvent: Sendable {
    case handshakeCompleted(Handshake, ProcessEpoch)
    /// A fork learned its own session id. Emitted once, from the first frame that carries one.
    case sessionIdentityResolved(SessionID, ProcessEpoch)
    case frame(Frame, ProcessEpoch)
    case request(InboundRequest)
    case requestCancelled(RequestID, ProcessEpoch)
    case policyAnswered(InboundRequest, error: String)
    case unansweredDialog(InboundRequest)
    case hostToolInvoked(HostToolInvocation, ProcessEpoch)
    case stderr(String, ProcessEpoch)
    case exited(ExitStatus, ProcessEpoch)
}
