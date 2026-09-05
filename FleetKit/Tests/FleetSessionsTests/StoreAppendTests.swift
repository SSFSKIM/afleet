import XCTest
import AfleetCore
@testable import FleetSessions

/// `sweep#13`: the shorts of afleet's own background jobs are appended, and appending is one step on the store.
///
/// The list is how the sidebar knows which roster jobs are afleet's, and it grows one short per handoff from one
/// supervisor per channel. A read and a write are two hops onto the store actor; whichever short lands in between
/// is written over, and the job it named is afleet's own for the rest of the session without afleet knowing it.
final class StoreAppendTests: XCTestCase {

    private func makeStore() throws -> FileStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afleet-store-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try FileStateStore(baseDirectory: directory, configHomes: [])
    }

    /// Two handoffs at once. Both shorts are there afterwards, in the order they landed.
    ///
    /// Deliberate break: implement `rememberOwnJob` as `read`, append, `write` again — two hops, and the second
    /// appender's list never saw the first's short.
    func testTwoConcurrentAppendsBothLand() async throws {
        let store = try makeStore()
        async let first: Void = store.appendUnique("jaa1", namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        async let second: Void = store.appendUnique("jbb2", namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        _ = try await (first, second)

        let stored = try await store.read([String].self, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        XCTAssertEqual(Set(stored ?? []), ["jaa1", "jbb2"], "neither handoff's short was written over")
    }

    /// The list is a set: a short already there is not appended twice, which is the behaviour `rememberOwnJob`
    /// had and keeps.
    func testAShortAlreadyThereIsNotAppendedTwice() async throws {
        let store = try makeStore()
        try await store.appendUnique("jaa1", namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        try await store.appendUnique("jaa1", namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        let stored = try await store.read([String].self, namespace: .fleetKit, key: FleetKitKeys.ownJobShorts)
        XCTAssertEqual(stored, ["jaa1"])
    }
}
