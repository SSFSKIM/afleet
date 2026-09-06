import Foundation

/// Per-(tab, channel) key-value persistence, handed to a tab through its `ChannelContext`.
///
/// It is its own protocol rather than FleetKit's `StateStore` narrowed, because the point is
/// that a panel cannot name a namespace at all: the host binds the scope when it constructs
/// the context, and a tab can only reach its own keys.
public protocol ScopedStore: Sendable {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T?
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws
    func remove(key: String) async throws
    func keys() async throws -> [String]
}
