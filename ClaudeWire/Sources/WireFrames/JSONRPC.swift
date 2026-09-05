import Foundation

public enum JSONRPCID: Hashable, Sendable {
    case number(Int64), string(String), null
}

public struct JSONRPCRequest: Hashable, Sendable {
    public var id: JSONRPCID; public var method: String; public var params: JSONValue?
    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) { self.id = id; self.method = method; self.params = params }
}
public struct JSONRPCNotification: Hashable, Sendable {
    public var method: String; public var params: JSONValue?
    public init(method: String, params: JSONValue? = nil) { self.method = method; self.params = params }
}
public struct JSONRPCResponse: Hashable, Sendable {
    public var id: JSONRPCID; public var result: JSONValue
    public init(id: JSONRPCID, result: JSONValue) { self.id = id; self.result = result }
}
public struct JSONRPCErrorBody: Hashable, Sendable {
    public var code: Int; public var message: String; public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) { self.code = code; self.message = message; self.data = data }
}
public struct JSONRPCErrorResponse: Hashable, Sendable {
    public var id: JSONRPCID; public var error: JSONRPCErrorBody
    public init(id: JSONRPCID, error: JSONRPCErrorBody) { self.id = id; self.error = error }
}

/// JSON-RPC 2.0 message as carried inside mcp_message.
public enum JSONRPCMessage: Hashable, Sendable, Codable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case error(JSONRPCErrorResponse)

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let o = v.objectValue else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON-RPC message must be an object")) }
        // A missing "id" key means notification; an "id" key that is present but not an integer,
        // a string or null is malformed and must throw rather than silently become a notification —
        // a notification owes no response, so misreading one leaves the peer waiting forever.
        let id: JSONRPCID?
        if let idv = o["id"] {
            switch idv {
            case .integer(let i): id = .number(i)
            case .string(let s): id = .string(s)
            case .null: id = .null
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath + [AnyCodingKey(stringValue: "id")],
                    debugDescription: "JSON-RPC id must be an integer, a string or null"))
            }
        } else {
            id = nil
        }
        if let method = o["method"]?.stringValue {
            if let id { self = .request(.init(id: id, method: method, params: o["params"])) }
            else { self = .notification(.init(method: method, params: o["params"])) }
        } else if let err = o["error"]?.objectValue, let code = err["code"]?.intValue {
            self = .error(.init(id: id ?? .null, error: .init(code: Int(code), message: err["message"]?.stringValue ?? "", data: err["data"])))
        } else if let result = o["result"] {
            self = .response(.init(id: id ?? .null, result: result))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "neither request, notification, response nor error"))
        }
    }

    public var jsonValue: JSONValue {
        func idValue(_ id: JSONRPCID) -> JSONValue {
            switch id { case .number(let n): return .integer(n); case .string(let s): return .string(s); case .null: return .null }
        }
        var o: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch self {
        case .request(let r): o["id"] = idValue(r.id); o["method"] = .string(r.method); if let p = r.params { o["params"] = p }
        case .notification(let n): o["method"] = .string(n.method); if let p = n.params { o["params"] = p }
        case .response(let r): o["id"] = idValue(r.id); o["result"] = r.result
        case .error(let e):
            var body: [String: JSONValue] = ["code": .integer(Int64(e.error.code)), "message": .string(e.error.message)]
            if let d = e.error.data { body["data"] = d }
            o["id"] = idValue(e.id); o["error"] = .object(body)
        }
        return .object(o)
    }
    public func encode(to encoder: any Encoder) throws { try jsonValue.encode(to: encoder) }
}
