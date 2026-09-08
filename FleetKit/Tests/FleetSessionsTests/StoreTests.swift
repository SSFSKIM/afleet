import XCTest
import AfleetCore
@testable import FleetSessions

final class StoreTests: XCTestCase {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    struct Pins: Codable, Equatable, Sendable { var sessions: [SessionID] }
    /// Every store in this file is built the way production builds one: through the single validating initialiser.
    func makeStore(_ dir: URL, ops: any StoreFileOperations = DarwinStoreFileOperations(),
                   diagnostics: @escaping @Sendable (StoreDiagnostic) -> Void = { _ in }) throws -> FileStateStore {
        try FileStateStore(baseDirectory: dir, configHomes: [], fileOperations: ops, onDiagnostic: diagnostics)
    }

    func testWriteThenReadRoundTripsAndDottedKeysAreOrdinary() async throws {
        let store = try makeStore(try tempDir())
        let pins = Pins(sessions: [SessionID(), SessionID()])
        try await store.write(pins, namespace: .fleetKit, key: "pins")
        try await store.write("tabs", namespace: .workbench, key: "workbench.browser")
        try await store.write(3, namespace: .workbench, key: "workbench.panel.ab12cd34.\(SessionID())")
        let back = try await store.read(Pins.self, namespace: .fleetKit, key: "pins")
        XCTAssertEqual(back, pins)
        let keys = try await store.keys(in: .workbench)
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains("workbench.browser"))
        XCTAssertTrue(keys.contains { $0.hasPrefix("workbench.panel.ab12cd34.") })
        // Deliberate break: split keys on "." into a hierarchy -> the two workbench keys collide or nest and the count or the prefix check fails.
    }
    func testEachNamespaceIsItsOwnDocumentWithASchemaVersion() async throws {
        let dir = try tempDir(); let store = try makeStore(dir)
        try await store.write(1, namespace: .fleetKit, key: "a")
        try await store.write(2, namespace: .afleet, key: "b")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(Set(names), ["state.fleetKit.json", "state.afleet.json"])
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.fleetKit.json"))) as? [String: Any]
        XCTAssertEqual(doc?["schemaVersion"] as? Int, FileStateStore.schemaVersion)
        XCTAssertEqual(Set(((doc?["values"] as? [String: Any]) ?? [:]).keys), ["a"])
        // Deliberate break: write one document for all namespaces -> the file set is wrong.
    }
    func testAFailureAtWriteFsyncOrRenameLeavesTheOldOrTheNewDocumentNeverAPartialOne() async throws {
        let new = Array(repeating: "new", count: 5_000)
        for point in FaultingFileOperations.Point.allCases {          // .create, .write (after a 4 KiB prefix landed), .fsync, .close, .rename, .fsyncDirectory
            let dir = try tempDir()
            let ops = FaultingFileOperations(failAt: point)            // passes every call through to Darwin until armed
            let store = try makeStore(dir, ops: ops)
            try await store.write(["old"], namespace: .fleetKit, key: "k")
            ops.arm()
            do { try await store.write(new, namespace: .fleetKit, key: "k"); XCTFail("\(point): the write did not fail") }
            catch let e as StoreError { guard case .io = e else { return XCTFail("\(point): \(e)") } }
            // A reader opened fresh on the directory sees a whole document: the old one when the rename never happened,
            // the new one when the fault came after it. Never a partial file, never nothing.
            let seen = try await makeStore(dir).read([String].self, namespace: .fleetKit, key: "k")
            // Every fault before the rename leaves the old document readable; only a fault after it (the directory fsync) shows the new one.
            XCTAssertEqual(seen, point == .fsyncDirectory ? new : ["old"], "\(point): partial or missing document")
            // The listing is read off the assertion line: `dir` is under the temporary directory, and the names
            // it yields are relative, but the assertion itself must not mention a path (tracker 75).
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
            XCTAssertEqual(names, ["state.fleetKit.json"], "\(point): the staging file was not removed")
            XCTAssertEqual(ops.removed.count, point == .fsyncDirectory ? 0 : 1, "\(point): the staging file was not removed through the seam")
            // Deliberate break: write the document in place with `Data.write(to:)` -> the `.write` fault leaves a truncated file and the read throws.
        }
    }
    func testANewerSchemaVersionIsReadForUnderstoodKeysRefusesWritesAndRaisesTheBanner() async throws {
        let dir = try tempDir()
        let newer = #"{"schemaVersion": 999, "values": {"k": 1, "fromTheFuture": {"x": 1}}}"#
        try Data(newer.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let store = try makeStore(dir)
        let understood = try await store.read(Int.self, namespace: .fleetKit, key: "k")
        XCTAssertEqual(understood, 1)   // the keys this build understands are readable
        do { try await store.write(2, namespace: .fleetKit, key: "k"); XCTFail("rewrote a document from the future") }
        catch let e as StoreError { guard case .schemaTooNew(found: 999, supported: FileStateStore.schemaVersion) = e else { return XCTFail("\(e)") } }
        let banner = await store.schemaStatus(of: .fleetKit)
        XCTAssertEqual(banner, .newer(found: 999))       // the banner's source
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.fleetKit.json"), encoding: .utf8), newer)
        // Deliberate break: refuse the read as well -> the first assertion throws; ignore schemaVersion on write -> the file changes.
    }
    func testAMalformedDocumentIsMovedAsideWithADiagnosticAndTheNamespaceStartsEmpty() async throws {
        let dir = try tempDir()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let seen = LockedBox<[StoreDiagnostic]>([])
        let store = try makeStore(dir, diagnostics: { seen.append($0) })
        let emptyAfterMoveAside = try await store.keys(in: .fleetKit)
        XCTAssertEqual(emptyAfterMoveAside, [])
        try await store.write(1, namespace: .fleetKit, key: "k")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("state.fleetKit.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("state.fleetKit.json.malformed-") })
        XCTAssertEqual(seen.value, [.malformedMovedAside(namespace: .fleetKit)])
        // Deliberate break: overwrite the malformed file in place -> one entry in the listing and no diagnostic.
    }
    func testAnOlderSchemaVersionIsMigratedPerNamespaceOnRead() async throws {
        let dir = try tempDir()
        // Version 0 is the reserved pre-release version whose migration to 1 is the identity; it exists so the chain is real.
        try Data(#"{"schemaVersion": 0, "values": {"k": 1}}"#.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let store = try makeStore(dir)
        let migratedValue = try await store.read(Int.self, namespace: .fleetKit, key: "k")
        XCTAssertEqual(migratedValue, 1)
        let migratedStatus = await store.schemaStatus(of: .fleetKit)
        XCTAssertEqual(migratedStatus, .migrated(from: 0))
        try await store.write(2, namespace: .fleetKit, key: "k")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.fleetKit.json"))) as? [String: Any]
        XCTAssertEqual(doc?["schemaVersion"] as? Int, FileStateStore.schemaVersion)
        // Deliberate break: skip the migration table for version 0 -> the status is `.current` and a later real migration never runs.
    }
    func testABaseDirectoryInsideAConfigHomeIsRejectedByTheOnlyInitialiser() throws {
        let home = try tempDir()
        XCTAssertThrowsError(try FileStateStore(baseDirectory: home.appendingPathComponent("afleet"), configHomes: [home])) { e in
            guard case StoreError.insideConfigHome = e as? StoreError ?? .io("") else { return XCTFail("\(e)") }
        }
        // A real alias of the config home: `alias -> <home>`; `alias/sub` lies inside the home only once the link is resolved.
        let alias = try tempDir().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        XCTAssertThrowsError(try FileStateStore(baseDirectory: alias.appendingPathComponent("sub"), configHomes: [home])) { e in
            guard case StoreError.insideConfigHome = e as? StoreError ?? .io("") else { return XCTFail("alias: \(e)") }
        }
        XCTAssertNoThrow(try FileStateStore(baseDirectory: try tempDir(), configHomes: [home]))
        // Deliberate break: compare paths without resolving symlinks -> the alias case fails to throw.
    }
    func testRemoveDeletesOneKeyAndLeavesTheRest() async throws {
        let store = try makeStore(try tempDir())
        try await store.write(1, namespace: .fleetKit, key: "a"); try await store.write(2, namespace: .fleetKit, key: "b")
        try await store.remove(namespace: .fleetKit, key: "a")
        let remaining = try await store.keys(in: .fleetKit)
        XCTAssertEqual(remaining, ["b"])
        let gone = try await store.read(Int.self, namespace: .fleetKit, key: "a")
        XCTAssertNil(gone)
    }
}
