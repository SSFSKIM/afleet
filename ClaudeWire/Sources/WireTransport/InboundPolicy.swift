import Foundation
import WireFrames
import WireEnvironment

public enum PolicyDecision: Equatable, Sendable {
    case surface                       // hand to FleetKit as .request
    case answer(InboundAnswer)         // answer now, emit .policyAnswered
    case leaveUnanswered               // undeclared dialog kind, emit .unansweredDialog
    case routeToMCP                    // AfleetMCPServer answers, emit .hostToolInvoked when relevant
}

/// `InboundAnswer` lives in WireFrames, which has no reason to know that the transport compares answers,
/// so the conformance is added here. It needs no `@retroactive`: both modules ship in the ClaudeWire
/// package, and the compiler rejects the attribute for a same-package type.
/// Two answers are equal when the control_response they would produce for the same request id is byte-identical.
extension InboundAnswer: Equatable {
    public static func == (a: InboundAnswer, b: InboundAnswer) -> Bool {
        (try? a.controlResponse(for: .init(rawValue: "x")).jsonValue.canonicalData()) == (try? b.controlResponse(for: .init(rawValue: "x")).jsonValue.canonicalData())
    }
}

/// Parent §6.3 as data.
public struct InboundPolicy: Sendable {
    public var declaredDialogKinds: Set<String>
    public var registeredHookCallbackIDs: Set<String>
    public var afleetVersion: String
    public init(declaredDialogKinds: Set<String>, registeredHookCallbackIDs: Set<String>, afleetVersion: String = ProtocolBaseline.afleetVersion) {
        self.declaredDialogKinds = declaredDialogKinds; self.registeredHookCallbackIDs = registeredHookCallbackIDs; self.afleetVersion = afleetVersion
    }
    public static func `default`(declaredDialogKinds: Set<String>, registeredHookCallbackIDs: Set<String>) -> InboundPolicy {
        .init(declaredDialogKinds: declaredDialogKinds, registeredHookCallbackIDs: registeredHookCallbackIDs)
    }
    public func decide(_ request: InboundRequest) -> PolicyDecision {
        switch request.payload {
        case .unknown(let subtype, _): return .answer(.error("subtype \(subtype) not supported by afleet \(afleetVersion)"))
        case .malformed(let subtype, let field, _): return .answer(.error("\(subtype): cannot decode field \(field)"))
        case .requestUserDialog(let d): return declaredDialogKinds.contains(d.dialogKind) ? .surface : .leaveUnanswered
        case .hookCallback(let h): return registeredHookCallbackIDs.contains(h.callbackID) ? .surface : .answer(.hookContinue(.empty))
        case .mcpMessage: return .routeToMCP
        case .canUseTool, .elicitation: return .surface
        }
    }
}
