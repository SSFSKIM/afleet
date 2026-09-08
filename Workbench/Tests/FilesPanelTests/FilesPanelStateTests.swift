import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI
@testable import FilesPanel

/// T4's five groups: the per-channel document of spec Design §6, exercised against a **real**
/// `FileStateStore` in a temporary directory behind a scoped store bound to `.workbench`, which
/// is how the app's host binds it.
///
/// No assertion below names a path outside the tree the test built.
final class FilesPanelStateTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filespanel-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Group 1: the round trip, and the key

    func testStateRoundTripsUnderTheChannelKey() async throws {
        let scoped = try makeStore()
        let home = configHome("one")
        let session = SessionID()
        let store = FilesPanelStore(store: scoped, configHome: home, session: session)

        var state = FilesPanelState.empty
        state.openFiles = [
            .init(path: "/tmp/invented/alpha.swift", line: 12, column: 3, rendersMarkdown: false),
            .init(path: "/tmp/invented/notes.md", line: 1, column: 1, rendersMarkdown: true),
        ]
        state.selectedPath = "/tmp/invented/notes.md"
        state.showsHiddenFiles = true
        state.showsGitIgnored = true
        state.filter = "alp"          // deliberately not persisted (Design §6)

        await store.save(state)
        await store.flush()

        let expectedKey = "panel.files.\(FilesPanelStore.configHomeHash(home)).\(session.description)"
        XCTAssertEqual(store.key, expectedKey, "the key is the W6 shape for this panel and channel")
        let keys = try await scoped.keys()
        XCTAssertEqual(keys, [expectedKey], "the session wrote exactly one document")

        let restored = await FilesPanelStore(store: scoped, configHome: home, session: session).load()
        XCTAssertEqual(restored.openFiles.count, 2, "both open files restore")
        XCTAssertEqual(restored.openFiles.map(\.line), [12, 1], "each cursor line restores")
        XCTAssertEqual(restored.openFiles.map(\.column), [3, 1], "each cursor column restores")
        XCTAssertEqual(restored.openFiles.map(\.rendersMarkdown), [false, true], "the markdown toggle restores per file")
        XCTAssertEqual(restored.selectedPath, state.selectedPath, "the selection restores")
        XCTAssertTrue(restored.showsHiddenFiles, "the hidden-files toggle restores")
        XCTAssertTrue(restored.showsGitIgnored, "the gitignore toggle restores")
        XCTAssertEqual(restored.filter, "", "the filter is deliberately not persisted")
    }

    // MARK: - Group 2: two channels, two keys

    func testTwoChannelsWriteTwoKeysAndNeitherReadsTheOther() async throws {
        let scoped = try makeStore()
        let home = configHome("one")
        let first = SessionID(), second = SessionID()

        var a = FilesPanelState.empty
        a.openFiles = [.init(path: "/tmp/invented/a.swift", line: 4, column: 1, rendersMarkdown: false)]
        var b = FilesPanelState.empty
        b.openFiles = [
            .init(path: "/tmp/invented/b.swift", line: 7, column: 2, rendersMarkdown: false),
            .init(path: "/tmp/invented/c.swift", line: 9, column: 2, rendersMarkdown: false),
        ]

        let storeA = FilesPanelStore(store: scoped, configHome: home, session: first)
        let storeB = FilesPanelStore(store: scoped, configHome: home, session: second)
        await storeA.save(a); await storeA.flush()
        await storeB.save(b); await storeB.flush()

        let keys = try await scoped.keys()
        XCTAssertEqual(keys.count, 2, "two channels wrote two documents")
        XCTAssertEqual(Set(keys).count, 2, "the two keys are distinct")

        let readA = await storeA.load(), readB = await storeB.load()
        XCTAssertEqual(readA.openFiles.count, 1, "the first channel reads its own document")
        XCTAssertEqual(readB.openFiles.count, 2, "the second channel reads its own document")

        // A third config home with the same session id is a third channel.
        let other = FilesPanelStore(store: scoped, configHome: configHome("two"), session: first)
        let readOther = await other.load()
        XCTAssertEqual(readOther.openFiles.count, 0,
                       "a different config home with the same session id restores empty")
    }

    // MARK: - Group 3: the config-home hash

    func testConfigHomeHashIsTwelveLowercaseHexAndStable() {
        let home = configHome("one")
        let hash = FilesPanelStore.configHomeHash(home)
        XCTAssertEqual(hash.count, 12, "the hash is twelve characters")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "the hash is lowercase hexadecimal")
        XCTAssertEqual(hash, FilesPanelStore.configHomeHash(configHome("one")),
                       "the same config home hashes the same across constructions")
        XCTAssertNotEqual(hash, FilesPanelStore.configHomeHash(configHome("two")),
                          "two config homes hash differently")
    }

    // MARK: - Group 4: a future schema version

    func testAFutureSchemaVersionRestoresTheEmptyState() async throws {
        let scoped = try makeStore()
        let home = configHome("one")
        let session = SessionID()
        let store = FilesPanelStore(store: scoped, configHome: home, session: session)

        var future = FilesPanelState.empty
        future.schemaVersion = FilesPanelState.currentSchemaVersion + 1
        future.openFiles = [.init(path: "/tmp/invented/future.swift", line: 3, column: 1, rendersMarkdown: false)]
        future.selectedPath = "/tmp/invented/future.swift"
        try await scoped.write(future, key: store.key)

        let restored = await store.load()
        XCTAssertEqual(restored.openFiles.count, 0, "a future document is refused into the empty state")
        XCTAssertNil(restored.selectedPath, "nothing of the future document is decoded")
        XCTAssertEqual(restored.schemaVersion, FilesPanelState.currentSchemaVersion,
                       "the empty state carries this build's schema version")
    }

    // MARK: - Group 5: coalescing

    func testABurstOfCursorWritesIsCoalesced() async throws {
        let counting = CountingStore(inner: try makeStore())
        let home = configHome("one")
        let session = SessionID()
        let store = FilesPanelStore(store: counting, configHome: home, session: session,
                                    coalescingInterval: .milliseconds(50))

        let burst = 24
        for line in 1...burst {
            var state = FilesPanelState.empty
            state.openFiles = [.init(path: "/tmp/invented/a.swift", line: line, column: 1, rendersMarkdown: false)]
            await store.save(state)
        }
        await store.flush()

        let writes = await counting.writes
        XCTAssertLessThan(writes, burst, "\(burst) cursor writes coalesced into \(writes) store writes")
        XCTAssertGreaterThan(writes, 0, "the burst landed at least once")

        let restored = await FilesPanelStore(store: counting, configHome: home, session: session).load()
        XCTAssertEqual(restored.openFiles.first?.line, burst, "the last value in the burst is the one that landed")
    }

    // MARK: - Harness

    /// The real `FileStateStore`, wrapped exactly as `WorkbenchScopedStore` wraps it in the app:
    /// pinned to `.workbench`, keys passed through unchanged.
    private func makeStore() throws -> WorkbenchScoped {
        let base = root.appendingPathComponent("state-\(UUID().uuidString)", isDirectory: true)
        return WorkbenchScoped(store: try FileStateStore(baseDirectory: base, configHomes: []))
    }

    private func configHome(_ name: String) -> URL {
        root.appendingPathComponent("home-\(name)", isDirectory: true)
    }

    struct WorkbenchScoped: ScopedStore {
        let store: any StateStore
        func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
            try await store.read(type, namespace: .workbench, key: key)
        }
        func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
            try await store.write(value, namespace: .workbench, key: key)
        }
        func remove(key: String) async throws { try await store.remove(namespace: .workbench, key: key) }
        func keys() async throws -> [String] { try await store.keys(in: .workbench) }
    }

    /// Counts the writes that reach the real store, which is what "coalesced" is measured in.
    actor CountingStore: ScopedStore {
        private let inner: any ScopedStore
        private(set) var writes = 0
        init(inner: any ScopedStore) { self.inner = inner }
        func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
            try await inner.read(type, key: key)
        }
        func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
            writes += 1
            try await inner.write(value, key: key)
        }
        func remove(key: String) async throws { try await inner.remove(key: key) }
        func keys() async throws -> [String] { try await inner.keys() }
    }
}
