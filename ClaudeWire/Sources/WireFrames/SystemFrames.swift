import Foundation

// TEMPORARY (Task 3): Task 4 replaces this file with the typed system frames and their
// payload structs. Only the shape `Frame` needs is declared here so the enum's cases can be
// fixed once, in Task 3, with their final payload types.

public struct SystemFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String
    public var subtype: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype }
}

public enum SystemFrame: Hashable, Sendable {
    case opaque(subtype: String, JSONValue)

    static func decode(line: Data, value: JSONValue, subtype: String?) -> Frame {
        .system(.opaque(subtype: subtype ?? "", value))
    }

    func encode() throws -> Data {
        switch self {
        case .opaque(_, let v): return try JSONEncoder().encode(v)
        }
    }
}
