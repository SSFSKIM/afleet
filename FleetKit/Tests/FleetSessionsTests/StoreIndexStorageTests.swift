import XCTest
import AfleetCore
import FleetTimeline
@testable import FleetSessions

/// C3's `IndexStorage` satisfied over `FileStateStore`: one value, in the `fleetKit` namespace, under
/// `FleetKitKeys.timelineIndex`. C3's index never opens a file itself, which is what keeps that target free of every
/// path under a Claude Code config home (X6, X9).
final class StoreIndexStorageTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Built the way production builds one: through the single validating initialiser.
    private func makeStore(_ dir: URL) throws -> FileStateStore {
        try FileStateStore(baseDirectory: dir, configHomes: [])
    }

    /// Invented identifiers and an invented path: nothing here came off an engine.
    private func snapshot(entries: [IndexEntry] = []) -> IndexSnapshot {
        IndexSnapshot(configHome: URL(fileURLWithPath: "/tmp/afleet-index-tests/config-home"),
                      builtAt: Date(timeIntervalSince1970: 1_700_000_000),
                      entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.sessionID, $0) }))
    }

    private func entry(_ id: SessionID, entrypoint: String? = nil, continuedIn: SessionID? = nil) -> IndexEntry {
        IndexEntry(sessionID: id,
                   path: URL(fileURLWithPath: "/tmp/afleet-index-tests/projects/proj/\(id).jsonl"),
                   slug: "proj", cwd: "/tmp/afleet-index-tests/proj", title: "a title", titleSource: .firstPrompt,
                   preview: "a preview", mtime: Date(timeIntervalSince1970: 1_699_000_000), size: 4_096,
                   entrypoint: entrypoint, continuedIn: continuedIn)
    }

    func testSaveThenLoadRoundTripsTheSnapshot() async throws {
        let dir = try tempDir()
        let storage = StoreIndexStorage(store: try makeStore(dir))
        let saved = snapshot(entries: [entry(SessionID(), entrypoint: "sdk-cli"), entry(SessionID())])

        try await storage.save(saved)
        let loaded = try await storage.load()

        XCTAssertEqual(loaded, saved)
        // The value lands under the one key of the one namespace, and nowhere else.
        let keys = try await makeStore(dir).keys(in: .fleetKit)
        XCTAssertEqual(keys, [FleetKitKeys.timelineIndex])
        XCTAssertEqual(FleetKitKeys.timelineIndex, "timeline.index")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["state.fleetKit.json"])
        // Deliberate break: save under `.workbench` -> the fleetKit key list is empty and the round trip reads nil.
    }

    func testLoadOnAnEmptyStoreIsNil() async throws {
        let storage = StoreIndexStorage(store: try makeStore(try tempDir()))
        let loaded = try await storage.load()
        XCTAssertNil(loaded)
        // Deliberate break: return an empty snapshot instead of nil -> C3 cannot tell "never built" from "built empty".
    }

    func testAStoreFromTheFutureRefusesTheSave() async throws {
        let dir = try tempDir()
        let fromTheFuture = #"{"schemaVersion": 999, "values": {}}"#
        try Data(fromTheFuture.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let storage = StoreIndexStorage(store: try makeStore(dir))

        do {
            try await storage.save(snapshot())
            XCTFail("a save landed on a document from the future")
        } catch let error as StoreError {
            guard case .schemaTooNew(found: 999, supported: FileStateStore.schemaVersion) = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.fleetKit.json"), encoding: .utf8),
                       fromTheFuture)
        let loaded = try await storage.load()
        XCTAssertNil(loaded, "the future document carries no index of ours")
        // Deliberate break: swallow the error in `save` -> the failure is invisible and the file check still passes,
        // so the `XCTFail` above is the one that catches it.
    }
}
