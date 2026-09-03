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
    public var requestID: RequestID
    public var response: JSONValue?
    /// The two `pending_*` arrays exactly as they arrived, kept raw rather than rebuilt from the
    /// typed views. Re-encoding therefore reproduces them key for key: an absent key stays absent,
    /// a present empty array stays a present empty array, and an element's keys beyond
    /// type/request_id/request survive. `nil` means the key was not on the wire.
    public var rawPendingPermissionRequests: JSONValue?
    public var rawPendingUserDialogRequests: JSONValue?

    /// Typed views over the raw arrays. An element that does not decode as a control request is
    /// skipped here; it is still re-encoded verbatim, because the raw value is what gets written.
    public var pendingPermissionRequests: [ControlRequestFrame] { Self.requestFrames(rawPendingPermissionRequests) }
    public var pendingUserDialogRequests: [ControlRequestFrame] { Self.requestFrames(rawPendingUserDialogRequests) }

    /// Builds a response afleet is about to send. An empty array omits the key, which is what this
    /// type did before the arrays became raw.
    public init(requestID: RequestID, response: JSONValue?, pendingPermissionRequests: [ControlRequestFrame] = [], pendingUserDialogRequests: [ControlRequestFrame] = []) {
        self.requestID = requestID
        self.response = response
        self.rawPendingPermissionRequests = pendingPermissionRequests.isEmpty ? nil : .array(pendingPermissionRequests.map(\.jsonValue))
        self.rawPendingUserDialogRequests = pendingUserDialogRequests.isEmpty ? nil : .array(pendingUserDialogRequests.map(\.jsonValue))
    }
    /// Preserves what arrived on the wire; used by `ControlResponseFrame.init(from:)`.
    public init(requestID: RequestID, response: JSONValue?, rawPendingPermissionRequests: JSONValue?, rawPendingUserDialogRequests: JSONValue?) {
        self.requestID = requestID
        self.response = response
        self.rawPendingPermissionRequests = rawPendingPermissionRequests
        self.rawPendingUserDialogRequests = rawPendingUserDialogRequests
    }
    private static func requestFrames(_ value: JSONValue?) -> [ControlRequestFrame] {
        guard let elements = value?.arrayValue else { return [] }
        return elements.compactMap { element in
            guard let data = try? element.canonicalData() else { return nil }
            return try? JSONDecoder().decode(ControlRequestFrame.self, from: data)
        }
    }
}
public struct ControlFailure: Hashable, Sendable {
    public var requestID: RequestID
    /// The `error` value exactly as it arrived. `nil` means the frame carried no `error` key, and
    /// re-encoding must not invent one.
    public var rawError: JSONValue?
    /// The error text; empty when the frame carried no `error` key or carried a non-string one.
    public var error: String { rawError?.stringValue ?? "" }
    public init(requestID: RequestID, error: String) { self.requestID = requestID; self.rawError = .string(error) }
    public init(requestID: RequestID, rawError: JSONValue?) { self.requestID = requestID; self.rawError = rawError }
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
        // Every key here is either modelled by the body or carried in `additional`, and `jsonValue`
        // writes each exactly once, so the "response" object round-trips key for key.
        let known: Set<String> = ["subtype", "request_id", "response", "error", "pending_permission_requests", "pending_user_dialog_requests"]
        additional = r.filter { !known.contains($0.key) }
        switch sub {
        case "success": body = .success(.init(requestID: .init(rawValue: id), response: r["response"],
                                              rawPendingPermissionRequests: r["pending_permission_requests"],
                                              rawPendingUserDialogRequests: r["pending_user_dialog_requests"]))
        case "error": body = .error(.init(requestID: .init(rawValue: id), rawError: r["error"]))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [AnyCodingKey(stringValue: "response.subtype")], debugDescription: "unknown control_response subtype \(sub)"))
        }
    }
    public var jsonValue: JSONValue {
        var r = additional
        switch body {
        case .success(let s):
            r["subtype"] = .string("success"); r["request_id"] = .string(s.requestID.rawValue)
            if let resp = s.response { r["response"] = resp }
            if let pending = s.rawPendingPermissionRequests { r["pending_permission_requests"] = pending }
            if let pending = s.rawPendingUserDialogRequests { r["pending_user_dialog_requests"] = pending }
        case .error(let e):
            r["subtype"] = .string("error"); r["request_id"] = .string(e.requestID.rawValue)
            if let error = e.rawError { r["error"] = error }
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
