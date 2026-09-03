import Foundation

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int64? { if case .integer(let i) = self { return i }; return nil }

    /// Equality that treats .integer(n) and .number(Double(n)) as equal, recursively.
    public func numericallyEqual(_ other: JSONValue) -> Bool {
        switch (self, other) {
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)): return Double(a) == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.numericallyEqual($1) }
        case (.object(let a), .object(let b)):
            return a.keys == b.keys && a.allSatisfy { k, v in b[k].map(v.numericallyEqual) ?? false }
        default: return self == other
        }
    }

    /// Deterministic encoding: keys sorted recursively, no whitespace, no escaped slashes.
    public func canonicalData() throws -> Data {
        var out = ""
        try Self.write(self, into: &out)
        return Data(out.utf8)
    }
    private static func write(_ v: JSONValue, into out: inout String) throws {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .integer(let i): out += String(i)
        case .number(let d):
            guard d.isFinite else { throw EncodingError.invalidValue(d, .init(codingPath: [], debugDescription: "non-finite")) }
            out += d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): out += Self.quote(s)
        case .array(let a):
            out += "["; for (i, e) in a.enumerated() { if i > 0 { out += "," }; try write(e, into: &out) }; out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                out += Self.quote(k) + ":"; try write(o[k]!, into: &out)
            }
            out += "}"
        }
    }
    static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case let c where c.value < 0x20: r += String(format: "\\u%04x", c.value)
            default: r.unicodeScalars.append(u)
            }
        }
        return r + "\""
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unrepresentable JSON"))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .integer(let i): try c.encode(i)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A coding key for arbitrary strings; used to enumerate undeclared keys.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

/// The first failing field of a decoding error, for error messages that name it.
public struct DecodeFailure: Sendable {
    public let field: String
    public let description: String
    public init(_ error: any Error) {
        switch error as? DecodingError {
        case .keyNotFound(let k, let ctx): field = (ctx.codingPath + [k]).map(\.stringValue).joined(separator: "."); description = ctx.debugDescription
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            field = ctx.codingPath.map(\.stringValue).joined(separator: "."); description = ctx.debugDescription
        default: field = ""; description = String(describing: error)
        }
    }
}
