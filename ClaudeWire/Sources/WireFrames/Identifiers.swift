public struct ProcessEpoch: Hashable, Comparable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let first = ProcessEpoch(rawValue: 1)
    public func next() -> ProcessEpoch { ProcessEpoch(rawValue: rawValue + 1) }
    public static func < (a: ProcessEpoch, b: ProcessEpoch) -> Bool { a.rawValue < b.rawValue }
}

public struct RequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}
