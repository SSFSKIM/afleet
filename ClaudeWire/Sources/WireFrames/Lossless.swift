import Foundation

/// A Codable whose CodingKeys enumerate the keys it models; everything else is "additional".
public protocol DeclaredKeys {
    associatedtype CodingKeys: CodingKey & CaseIterable
    static var declaredKeys: [String] { get }
}
public extension DeclaredKeys {
    static var declaredKeys: [String] { CodingKeys.allCases.map(\.stringValue) }
}

/// Wraps a typed Fields struct and keeps every undeclared key AND every declared key that was an explicit null,
/// so re-encoding reproduces the original object key for key (an optional field decoded from `null` would otherwise vanish).
@dynamicMemberLookup
public struct Lossless<Fields: Codable & Sendable & DeclaredKeys>: Codable, Sendable {
    public var fields: Fields
    public var additional: [String: JSONValue]
    public var explicitNulls: Set<String>

    public init(fields: Fields, additional: [String: JSONValue] = [:], explicitNulls: Set<String> = []) {
        self.fields = fields; self.additional = additional; self.explicitNulls = explicitNulls
    }
    public subscript<T>(dynamicMember keyPath: KeyPath<Fields, T>) -> T { fields[keyPath: keyPath] }
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Fields, T>) -> T {
        get { fields[keyPath: keyPath] }
        set { fields[keyPath: keyPath] = newValue }
    }

    public init(from decoder: any Decoder) throws {
        fields = try Fields(from: decoder)
        let declared = Set(Fields.declaredKeys)
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        var nulls: Set<String> = []
        for key in c.allKeys {
            if declared.contains(key.stringValue) {
                if try c.decodeNil(forKey: key) { nulls.insert(key.stringValue) }
            } else {
                extras[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            }
        }
        additional = extras; explicitNulls = nulls
    }
    public func encode(to encoder: any Encoder) throws {
        // Nulls first, then the typed fields (a field mutated to a value overrides its recorded null), then extras.
        // Because `additional` is written last, a key present in both `fields` and `additional` is won by
        // `additional`. Decoding cannot produce that overlap — declared and undeclared keys are disjoint there —
        // but the public memberwise initialiser can, so callers must keep the two sets disjoint themselves.
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for k in explicitNulls { try c.encodeNil(forKey: AnyCodingKey(stringValue: k)) }
        try fields.encode(to: encoder)
        for (k, v) in additional { try c.encode(v, forKey: AnyCodingKey(stringValue: k)) }
    }
}
extension Lossless: Equatable where Fields: Equatable {}
extension Lossless: Hashable where Fields: Hashable {}
