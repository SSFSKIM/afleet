import Foundation

/// The persistence seam. C4 implements it over its own namespaced store (spec Contracts, X6); the index never writes
/// a file itself, which is what keeps this target free of every path under a Claude Code config home (parent X9).
public protocol IndexStorage: Sendable {
    func load() async throws -> IndexSnapshot?
    func save(_ snapshot: IndexSnapshot) async throws
}

/// The seam satisfied in memory, for tests and for a run with persistence switched off. Copies of the value share one
/// box, so an index and the index that reloads from it can be handed the same `InMemoryIndexStorage`.
public struct InMemoryIndexStorage: IndexStorage {
    private let box = Box()

    public init() {}

    public func load() async throws -> IndexSnapshot? { await box.value }
    public func save(_ snapshot: IndexSnapshot) async throws { await box.set(snapshot) }

    private actor Box {
        var value: IndexSnapshot?
        func set(_ snapshot: IndexSnapshot?) { value = snapshot }
    }
}
