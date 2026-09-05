import Foundation

/// The engine's classification enum is exactly these three values (bundle 2.1.258 `cli.pretty.js:513878`, schema `BL`);
/// it parses the field with `.catch(void 0)`, so any other string is silently dropped rather than rejected.
public enum PermissionDecisionClassification: String, Codable, Sendable, CaseIterable {
    case userTemporary = "user_temporary", userPermanent = "user_permanent", userReject = "user_reject"
}
/// The can_use_tool response body (bundle schema `KL`): allow carries updatedInput/updatedPermissions, deny requires message.
public enum PermissionResult: Hashable, Sendable {
    case allow(updatedInput: JSONValue?, updatedPermissions: [PermissionUpdate]?, classification: PermissionDecisionClassification?)
    case deny(message: String, interrupt: Bool, classification: PermissionDecisionClassification?)
}
public enum DialogAnswer: Hashable, Sendable { case completed(result: JSONValue), cancelled }
public enum ElicitationAnswer: Hashable, Sendable { case accept(content: JSONValue), decline, cancel }
public struct HookOutput: Hashable, Sendable {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue] = [:]) { self.fields = fields }
    public static let empty = HookOutput()
}

public enum InboundAnswer: Sendable {
    case permission(PermissionResult)
    case dialog(DialogAnswer)
    case elicitation(ElicitationAnswer)
    case hookContinue(HookOutput)
    case mcpResponse(JSONRPCMessage)
    case error(String)

    public func controlResponse(for id: RequestID) -> ControlResponseFrame {
        switch self {
        case .error(let message): return ControlResponseFrame(body: .error(.init(requestID: id, error: message)))
        default: return ControlResponseFrame(body: .success(.init(requestID: id, response: responseBody)))
        }
    }
    var responseBody: JSONValue {
        switch self {
        case .permission(.allow(let input, let perms, let cls)):
            var o: [String: JSONValue] = ["behavior": .string("allow")]
            if let input { o["updatedInput"] = input }
            if let perms { o["updatedPermissions"] = .array(perms.map { (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))) ?? .null }) }
            if let cls { o["decisionClassification"] = .string(cls.rawValue) }
            return .object(o)
        case .permission(.deny(let message, let interrupt, let cls)):
            var o: [String: JSONValue] = ["behavior": .string("deny"), "message": .string(message), "interrupt": .bool(interrupt)]
            if let cls { o["decisionClassification"] = .string(cls.rawValue) }
            return .object(o)
        case .dialog(.completed(let result)): return .object(["behavior": .string("completed"), "result": result])
        case .dialog(.cancelled): return .object(["behavior": .string("cancelled")])
        case .elicitation(.accept(let content)): return .object(["action": .string("accept"), "content": content])
        case .elicitation(.decline): return .object(["action": .string("decline")])
        case .elicitation(.cancel): return .object(["action": .string("cancel")])
        case .hookContinue(let out): return .object(out.fields)
        case .mcpResponse(let m): return .object(["mcp_response": m.jsonValue])
        case .error: return .null
        }
    }
}
