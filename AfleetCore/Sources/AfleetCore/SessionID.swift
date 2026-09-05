import Foundation

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init() { self.uuid = UUID() }
    public init(uuid: UUID) { self.uuid = uuid }
    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a UUID: \(raw)"))
        }
        self.uuid = uuid
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
