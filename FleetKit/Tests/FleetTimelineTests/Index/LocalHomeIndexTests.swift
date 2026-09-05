import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Gate G2's budget half, measured against the machine's own Claude Code config home.
///
/// Opt-in only: without `AFLEET_LOCAL_INDEX=1` every test here is an `XCTSkip`, because the corpus under `Fixtures/`
/// is a handful of small recordings and says nothing about a real home's shape. With the flag the home is **read**
/// and nothing else (parent X9): no file under `~/.claude` or `$CLAUDE_CONFIG_DIR` is created, modified or removed,
/// every read goes through the same `O_NOFOLLOW` paths the rest of this target uses, and the one measurement that
/// needs a modification — the incremental update after a `touch` — touches a *copy* placed under
/// `FileManager.default.temporaryDirectory` and indexes a temporary tree that holds only that copy.
///
/// Output discipline: the four `print`s below are the only output. Counts, byte sizes and milliseconds; never a path,
/// a slug, a session id, a title or a record.
final class LocalHomeIndexTests: XCTestCase {

    // MARK: - The opt-in gate and the home

    /// `CLAUDE_CONFIG_DIR` when the environment sets it, else `~/.claude`. Read-only for the whole of this file.
    private func localConfigHome() throws -> ConfigHome {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AFLEET_LOCAL_INDEX"] == "1" else {
            throw XCTSkip("set AFLEET_LOCAL_INDEX=1 to measure the local config home; read-only")
        }
        if let explicit = environment["CLAUDE_CONFIG_DIR"], !explicit.isEmpty {
            return ConfigHome(root: URL(fileURLWithPath: explicit, isDirectory: true), source: .environment)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return ConfigHome(root: root, source: .default)
    }

    /// Collects `indexBuilt`'s file count, which is the number of main transcripts the build actually read — the
    /// number the budget is about. It is a count, not a listing.
    private final class FileCount: TimelineDiagnosticsSink, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var files: Int { lock.lock(); defer { lock.unlock() }; return value }
        func record(_ notice: TimelineNotice) {
            guard case .indexBuilt(let files, _) = notice else { return }
            lock.lock(); value = files; lock.unlock()
        }
    }

    // MARK: - G2, first budget: the median of five cold builds under 500 ms

    func testColdBuildUnderHalfASecond() async throws {
        let home = try localConfigHome()
        var samples: [Double] = []
        var files = 0
        for _ in 0..<5 {
            let counter = FileCount()
            // A fresh actor and a fresh in-memory store every round: nothing is carried between builds.
            let index = TranscriptIndex(configHome: home, storage: InMemoryIndexStorage(), diagnostics: counter)
            let started = Date()
            _ = try await index.build()
            samples.append(Date().timeIntervalSince(started) * 1000)
            files = counter.files
        }
        let sorted = samples.sorted()
        let median = sorted[2]
        print("files=\(files) median_ms=\(Int(median.rounded())) min_ms=\(Int(sorted[0].rounded())) max_ms=\(Int(sorted[4].rounded()))")
        XCTAssertGreaterThan(files, 0, "the local config home holds no main transcript; the measurement is vacuous")
        XCTAssertLessThan(median, 500, "cold build median over budget")
    }

    // MARK: - G2, second budget: an incremental update after one touch under 50 ms

    /// The `touch` lands on a **copy** under the temporary directory, never on the home. The copy is the home's
    /// largest main transcript, so the measurement is the worst case the machine can offer.
    func testIncrementalUpdateUnderFiftyMilliseconds() async throws {
        let home = try localConfigHome()
        let cold = try await TranscriptIndex(configHome: home, storage: InMemoryIndexStorage()).build()
        let largest = try XCTUnwrap(cold.entries.values.max { $0.size < $1.size },
                                    "the local config home holds no main transcript")

        let temp = try TempTree()
        let directory = temp.projects.appendingPathComponent(largest.slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(largest.sessionID).jsonl")
        try FileManager.default.copyItem(at: largest.path, to: copy)

        let index = TranscriptIndex(configHome: ConfigHome(root: temp.root, source: .environment),
                                    storage: InMemoryIndexStorage())
        let seeded = try await index.build()
        XCTAssertEqual(seeded.entries.count, 1, "the temporary tree holds exactly the one copy")

        try temp.setModificationDate(copy, Date())
        let started = Date()
        let delta = await index.update(changed: [copy])
        let elapsed = Date().timeIntervalSince(started) * 1000
        print("incremental_files=1 incremental_ms=\(Int(elapsed.rounded()))")
        // Compared without printing the id: a failure message here would carry a real session id off the local home.
        XCTAssertEqual(delta.updated.count, 1, "the update re-read exactly one session")
        XCTAssertTrue(delta.updated.first == largest.sessionID, "the touched copy is the session the update re-read")
        XCTAssertLessThan(elapsed, 50, "incremental update over budget")
    }

    // MARK: - G2, third budget: the largest local transcript's channel history under one second

    func testLargestTranscriptHistoryUnderOneSecond() async throws {
        let home = try localConfigHome()
        let cold = try await TranscriptIndex(configHome: home, storage: InMemoryIndexStorage()).build()
        let largest = try XCTUnwrap(cold.entries.values.max { $0.size < $1.size },
                                    "the local config home holds no main transcript")
        let stream = try XCTUnwrap(TranscriptPath.resolve(largest.path, under: home.root)?.0,
                                   "the index's own entry path does not resolve to a stream")

        let started = Date()
        let read = try WindowedTranscript.read(TranscriptReader(url: largest.path))
        var options = RecordReducer.Options()
        options.window = read.window
        let projection = RecordReducer.reduce(read.records, stream: stream, sourceFile: largest.path, options: options)
        let elapsed = Date().timeIntervalSince(started) * 1000

        print("size=\(largest.size) records=\(read.records.count) window=\(read.window.earlierAvailable) extensions=\(read.extensions) ms=\(Int(elapsed.rounded()))")
        XCTAssertEqual(projection.window, read.window, "the projection carries the window the read produced")
        XCTAssertLessThan(elapsed, 1000, "largest transcript history over budget")
    }

    // MARK: - The watcher, on a temporary tree

    /// Every batch the watcher yields, collected by one long-lived consumer. A single consumer for the whole test is
    /// what makes the settle sound: `clear()` after the tree has stopped changing throws away the events that placing
    /// the fixture caused, so a batch seen afterwards can only be the touch's.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[URL]] = []
        func append(_ batch: [URL]) { lock.lock(); batches.append(batch); lock.unlock() }
        func clear() { lock.lock(); batches.removeAll(); lock.unlock() }
        func names(_ name: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return batches.contains { $0.contains { $0.lastPathComponent == name } }
        }
    }

    /// FSEvents over a config-home-shaped temporary tree. The real home is never watched and never written.
    func testWatcherDeliversOneEventForOneTouch() async throws {
        _ = try localConfigHome()
        let temp = try TempTree()
        let fixture = try XCTUnwrap(try FixtureCorpus.all().first { $0.name == "plain-two-turn" })
        let main = try temp.add(fixture, slug: "plain-two-turn")

        let watcher = TranscriptWatcher(configHome: temp.root)
        let collected = Collected()
        let changes = watcher.changes
        let consumer = Task { for await batch in changes { collected.append(batch) } }
        defer { consumer.cancel() }
        try watcher.start()
        defer { watcher.stop() }

        // FSEvents arms from "since now" but still reports what it coalesced around that instant, so the fixture's
        // own arrival lands here; a settle and a clear are what leave only the touch to be seen.
        try await Task.sleep(nanoseconds: 700_000_000)
        collected.clear()
        _ = try temp.touch(main)

        let name = main.lastPathComponent
        let deadline = Date().addingTimeInterval(2)
        var delivered = false
        while Date() < deadline {
            if collected.names(name) { delivered = true; break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(delivered, "no FSEvents batch named the touched file within two seconds")
    }
}
