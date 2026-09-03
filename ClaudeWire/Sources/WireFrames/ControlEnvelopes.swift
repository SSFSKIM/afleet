import Foundation

/// {"type":"control_request","request_id":..,"request":{"subtype":..,...}} — the inner request is kept as JSONValue here;
/// InboundRequests.swift (Task 5) decodes it into typed payloads.
public struct ControlRequestFrame: Hashable, Sendable, Codable {
    public var requestID: RequestID
    public var request: JSONValue
    public var subtype: String { request["subtype"]?.stringValue ?? "" }
    public init(requestID: RequestID, request: JSONValue) { self.requestID = requestID; self.request = request }
    enum CodingKeys: String, CodingKey { case type, requestID = "request_id", request }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = RequestID(rawValue: try c.decode(String.self, forKey: .requestID))
        request = try c.decode(JSONValue.self, forKey: .request)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("control_request", forKey: .type); try c.encode(requestID.rawValue, forKey: .requestID); try c.encode(request, forKey: .request)
    }
}

public struct ControlSuccess: Hashable, Sendable {
    public var requestID: RequestID; public var response: JSONValue?; public var pendingPermissionRequests: [ControlRequestFrame]; public var pendingUserDialogRequests: [ControlRequestFrame]
    public init(requestID: RequestID, response: JSONValue?, pendingPermissionRequests: [ControlRequestFrame] = [], pendingUserDialogRequests: [ControlRequestFrame] = []) {
        self.requestID = requestID; self.response = response; self.pendingPermissionRequests = pendingPermissionRequests; self.pendingUserDialogRequests = pendingUserDialogRequests
    }
}
public struct ControlFailure: Hashable, Sendable {
    public var requestID: RequestID; public var error: String
    public init(requestID: RequestID, error: String) { self.requestID = requestID; self.error = error }
}
public enum ControlResponseBody: Hashable, Sendable { case success(ControlSuccess), error(ControlFailure) }

public struct ControlResponseFrame: Hashable, Sendable, Codable {
    public var body: ControlResponseBody
    public var additional: [String: JSONValue]      // undeclared keys inside "response"
    public init(body: ControlResponseBody, additional: [String: JSONValue] = [:]) { self.body = body; self.additional = additional }
    public var requestID: RequestID { switch body { case .success(let s): s.requestID; case .error(let e): e.requestID } }

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let r = v["response"]?.objectValue, let id = r["request_id"]?.stringValue, let sub = r["subtype"]?.stringValue else {
            throw DecodingError.keyNotFound(AnyCodingKey(stringValue: "response.request_id"), .init(codingPath: decoder.codingPath, debugDescription: "control_response without response.request_id/subtype"))
        }
        let known: Set<String> = ["subtype", "request_id", "response", "error", "pending_permission_requests", "pending_user_dialog_requests"]
        additional = r.filter { !known.contains($0.key) }
        func frames(_ key: String) throws -> [ControlRequestFrame] {
            guard let arr = r[key]?.arrayValue else { return [] }
            return try arr.map { try JSONDecoder().decode(ControlRequestFrame.self, from: try $0.canonicalData()) }
        }
        switch sub {
        case "success": body = .success(.init(requestID: .init(rawValue: id), response: r["response"], pendingPermissionRequests: try frames("pending_permission_requests"), pendingUserDialogRequests: try frames("pending_user_dialog_requests")))
        case "error": body = .error(.init(requestID: .init(rawValue: id), error: r["error"]?.stringValue ?? ""))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [AnyCodingKey(stringValue: "response.subtype")], debugDescription: "unknown control_response subtype \(sub)"))
        }
    }
    public var jsonValue: JSONValue {
        var r = additional
        switch body {
        case .success(let s):
            r["subtype"] = .string("success"); r["request_id"] = .string(s.requestID.rawValue)
            if let resp = s.response { r["response"] = resp }
            if !s.pendingPermissionRequests.isEmpty { r["pending_permission_requests"] = .array(s.pendingPermissionRequests.map(\.jsonValue)) }
            if !s.pendingUserDialogRequests.isEmpty { r["pending_user_dialog_requests"] = .array(s.pendingUserDialogRequests.map(\.jsonValue)) }
        case .error(let e):
            r["subtype"] = .string("error"); r["request_id"] = .string(e.requestID.rawValue); r["error"] = .string(e.error)
        }
        return .object(["type": .string("control_response"), "response": .object(r)])
    }
    public func encode(to encoder: any Encoder) throws { try jsonValue.encode(to: encoder) }
}
public extension ControlRequestFrame {
    var jsonValue: JSONValue { .object(["type": .string("control_request"), "request_id": .string(requestID.rawValue), "request": request]) }
}

public struct ControlCancelFrame: Hashable, Sendable, Codable {
    public var requestID: RequestID
    public init(requestID: RequestID) { self.requestID = requestID }
    enum CodingKeys: String, CodingKey { case type, requestID = "request_id" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = RequestID(rawValue: try c.decode(String.self, forKey: .requestID))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("control_cancel_request", forKey: .type); try c.encode(requestID.rawValue, forKey: .requestID)
    }
}
