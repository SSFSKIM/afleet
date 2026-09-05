import Foundation
import FleetTimeline

/// C3's `IndexStorage` satisfied over the fleet's own store: the whole index snapshot as one value in the `fleetKit`
/// namespace, under `FleetKitKeys.timelineIndex` (X6). C3 declares the seam and never opens a file itself, which is
/// what keeps `FleetTimeline` free of every path under a Claude Code config home (X9), and the store's own atomic
/// write is what a half-written index would otherwise cost.
public struct StoreIndexStorage: IndexStorage {
    private let store: any StateStore

    public init(store: any StateStore) { self.store = store }

    public func load() async throws -> IndexSnapshot? {
        try await store.read(IndexSnapshot.self, namespace: .fleetKit, key: FleetKitKeys.timelineIndex)
    }

    /// A store whose document was written by a newer build refuses, and the error reaches C3: an index rebuilt by
    /// this build must not overwrite what that one keeps.
    public func save(_ snapshot: IndexSnapshot) async throws {
        try await store.write(snapshot, namespace: .fleetKit, key: FleetKitKeys.timelineIndex)
    }
}
