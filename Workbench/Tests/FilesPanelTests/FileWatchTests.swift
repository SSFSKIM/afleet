// C7.5's watcher and its conflict policy: spec Design §8, gate G1 items 3–5, plan T3's five
// groups. Every tree is built under `FileManager.default.temporaryDirectory` and nothing outside
// it is read, because `open(2)` on the user's content directories is TCC-gated here. Every
// assertion names counts, sets and shapes and never a path or a buffer (§6.3, §11). Every wait is
// fulfilled by the event it waits for; the limit only turns a hang into a failure.
import Foundation
import XCTest
@testable import FilesPanel

final class FileWatchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afleet-c7.5-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - 1. An in-place write delivers one snapshot whose digest differs from the loaded one

    func testInPlaceWriteDeliversASnapshotUnderTheVnodeSource() async throws {
        try await assertInPlaceWriteDelivers(mode: .vnode)
    }

    func testInPlaceWriteDeliversASnapshotUnderThePollFallback() async throws {
        try await assertInPlaceWriteDelivers(mode: .poll)
    }

    private func assertInPlaceWriteDelivers(mode: FileWatch.Mode,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let target = root.appendingPathComponent("note.txt")
        try write("one", to: target)
        let loaded = try XCTUnwrap(FileSnapshot.read(target), "the premise did not hold: nothing was readable")

        let log = EventLog()
        let watch = watcher(on: target, mode: mode, log: log)
        await watch.start(baseline: loaded)
        defer { Task { await watch.stop() } }

        try write("two", to: target)
        let events = await wait(on: log, until: { $0.count >= 1 }, "no snapshot arrived in \(mode)",
                                file: file, line: line)

        XCTAssertEqual(events.count, 1, "\(mode) delivered \(events.count) events for one write",
                       file: file, line: line)
        let delivered = try XCTUnwrap(events.first?.snapshot, "the delivery was a deletion, not a snapshot",
                                      file: file, line: line)
        XCTAssertNotEqual(delivered.digest, loaded.digest,
                          "the delivered digest matched the loaded one", file: file, line: line)
        XCTAssertEqual(delivered.digest, FileSnapshot.read(target)?.digest,
                       "the delivered digest was not the file's own", file: file, line: line)
        XCTAssertEqual(delivered.size, 3, "the delivered size was \(delivered.size)", file: file, line: line)
    }

    // MARK: - 2. A rename-replace delivers too — the re-arm

    /// A vnode source watches the *inode* it was opened on. One rename-replace still fires the
    /// original source (the old inode is deleted), so a single replace proves nothing; the second
    /// replace is what a source armed once can never see. Both are asserted, in order.
    func testRenameReplaceKeepsDeliveringUnderTheVnodeSource() async throws {
        try await assertRenameReplaceKeepsDelivering(mode: .vnode)
    }

    func testRenameReplaceKeepsDeliveringUnderThePollFallback() async throws {
        try await assertRenameReplaceKeepsDelivering(mode: .poll)
    }

    private func assertRenameReplaceKeepsDelivering(mode: FileWatch.Mode,
                                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let target = root.appendingPathComponent("note.txt")
        try write("one", to: target)
        let loaded = try XCTUnwrap(FileSnapshot.read(target))

        let log = EventLog()
        let watch = watcher(on: target, mode: mode, log: log)
        await watch.start(baseline: loaded)
        defer { Task { await watch.stop() } }

        try renameReplace("second", over: target)
        var events = await wait(on: log, until: { $0.contains { $0.snapshot?.size == 6 } },
                                "the first rename-replace delivered nothing in \(mode)", file: file, line: line)
        XCTAssertFalse(events.contains(.deleted),
                       "a rename-replace was reported as a deletion in \(mode)", file: file, line: line)

        try renameReplace("the third one", over: target)
        events = await wait(on: log, until: { $0.contains { $0.snapshot?.size == 13 } },
                            "the second rename-replace delivered nothing in \(mode): the source never re-armed",
                            file: file, line: line)
        XCTAssertEqual(events.last?.snapshot?.digest, FileSnapshot.read(target)?.digest,
                       "the last delivery did not carry the file's final contents", file: file, line: line)
        XCTAssertFalse(events.contains(.deleted),
                       "a rename-replace was reported as a deletion in \(mode)", file: file, line: line)
    }

    // MARK: - 3. Deletion is reported after the coalescing delay; a re-create inside it is not

    func testDeletionIsReportedUnderTheVnodeSource() async throws {
        try await assertDeletionIsReported(mode: .vnode)
    }

    func testDeletionIsReportedUnderThePollFallback() async throws {
        try await assertDeletionIsReported(mode: .poll)
    }

    private func assertDeletionIsReported(mode: FileWatch.Mode,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let target = root.appendingPathComponent("note.txt")
        try write("one", to: target)
        let loaded = try XCTUnwrap(FileSnapshot.read(target))

        let log = EventLog()
        let watch = watcher(on: target, mode: mode, log: log)
        await watch.start(baseline: loaded)
        defer { Task { await watch.stop() } }

        try FileManager.default.removeItem(at: target)
        let events = await wait(on: log, until: { $0.contains(.deleted) },
                                "the deletion was never reported in \(mode)", file: file, line: line)
        XCTAssertEqual(events.filter { $0 == .deleted }.count, 1,
                       "the deletion was reported \(events.filter { $0 == .deleted }.count) times",
                       file: file, line: line)
    }

    /// The same deletion, undone inside the coalescing delay: one snapshot, no deletion. The delay
    /// is long here so the re-create is unambiguously inside it, and the test still returns the
    /// moment the snapshot arrives.
    func testRecreateInsideTheDelayReportsASnapshotInsteadOfADeletion() async throws {
        let target = root.appendingPathComponent("note.txt")
        try write("one", to: target)
        let loaded = try XCTUnwrap(FileSnapshot.read(target))

        let log = EventLog()
        let watch = watcher(on: target, mode: .vnode, log: log,
                            delay: .milliseconds(1500), poll: .milliseconds(1500))
        await watch.start(baseline: loaded)
        defer { Task { await watch.stop() } }

        try FileManager.default.removeItem(at: target)
        try write("restored", to: target)

        let events = await wait(on: log, until: { $0.contains { $0.snapshot?.size == 8 } },
                                "the re-created file was never delivered")
        XCTAssertFalse(events.contains(.deleted),
                       "a file that came back inside the delay was reported deleted")
        XCTAssertNotEqual(events.last?.snapshot?.digest, loaded.digest,
                          "the delivery carried the digest of the file that was removed")
    }

    // MARK: - 4. A burst coalesces, and the last delivery carries the final contents

    func testABurstCoalescesUnderTheVnodeSource() async throws {
        try await assertABurstCoalesces(mode: .vnode)
    }

    func testABurstCoalescesUnderThePollFallback() async throws {
        try await assertABurstCoalesces(mode: .poll)
    }

    private func assertABurstCoalesces(mode: FileWatch.Mode,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let target = root.appendingPathComponent("note.txt")
        let writes = 10
        try write("start", to: target)
        let loaded = try XCTUnwrap(FileSnapshot.read(target))

        let log = EventLog()
        let watch = watcher(on: target, mode: mode, log: log,
                            delay: .milliseconds(400), poll: .milliseconds(400))
        await watch.start(baseline: loaded)
        defer { Task { await watch.stop() } }

        for step in 1...writes { try write(String(repeating: "x", count: step), to: target) }

        let events = await wait(on: log, until: { $0.contains { $0.snapshot?.size == writes } },
                                "the burst's final contents were never delivered in \(mode)",
                                file: file, line: line)
        XCTAssertLessThan(events.count, writes,
                          "\(mode) delivered \(events.count) events for \(writes) writes: nothing coalesced",
                          file: file, line: line)
        XCTAssertEqual(events.last?.snapshot?.digest, FileSnapshot.read(target)?.digest,
                       "the last delivery did not carry the final contents", file: file, line: line)
    }

    /// The fallback itself: a path the source cannot be armed on at all (it does not exist yet)
    /// falls back to the stat poll, and the poll drives the same deliveries.
    func testAPathThatCannotBeArmedFallsBackToThePoll() async throws {
        let target = root.appendingPathComponent("appears-later.txt")

        let log = EventLog()
        let watch = watcher(on: target, mode: .vnode, log: log)
        await watch.start(baseline: nil)
        defer { Task { await watch.stop() } }

        let polling = await watch.isPolling
        XCTAssertTrue(polling, "an unarmable path did not fall back to the poll")

        try write("here now", to: target)
        let events = await wait(on: log, until: { $0.contains { $0.snapshot?.size == 8 } },
                                "the poll fallback never delivered the created file")
        XCTAssertFalse(events.contains(.deleted), "a file that never existed was reported deleted")
    }

    // MARK: - 5. The policy, as a table with no file system in it

    func testTheSaveEchoIsIgnored() {
        let loaded = Self.snapshot("loaded", size: 6)
        let written = Self.snapshot("written", size: 7)
        XCTAssertEqual(outcome(observed: written, lastLoaded: loaded, lastWritten: written, isDirty: false),
                       .ignore, "a clean save echo was not ignored")
        XCTAssertEqual(outcome(observed: written, lastLoaded: loaded, lastWritten: written, isDirty: true),
                       .ignore, "a save echo under a dirty buffer was not ignored")
    }

    /// The echo is keyed on the digest, not on identity: the file's mtime after the rename is not
    /// the one the save recorded, and the outcome must not depend on it.
    func testTheSaveEchoIsKeyedOnTheDigestAndNotOnTheTimestamp() {
        let loaded = Self.snapshot("loaded", size: 6)
        let written = Self.snapshot("written", size: 7)
        let echo = FileSnapshot(size: written.size, modified: written.modified.addingTimeInterval(3),
                                digest: written.digest)
        XCTAssertEqual(outcome(observed: echo, lastLoaded: loaded, lastWritten: written, isDirty: true),
                       .ignore, "an echo with a later timestamp was not ignored")
    }

    func testIdenticalContentsAreIgnored() {
        let loaded = Self.snapshot("loaded", size: 6)
        let touched = FileSnapshot(size: loaded.size, modified: loaded.modified.addingTimeInterval(9),
                                   digest: loaded.digest)
        XCTAssertEqual(outcome(observed: touched, lastLoaded: loaded, lastWritten: nil, isDirty: false),
                       .ignore, "a touch of identical bytes was not ignored")
        XCTAssertEqual(outcome(observed: touched, lastLoaded: loaded, lastWritten: nil, isDirty: true),
                       .ignore, "a touch of identical bytes under a dirty buffer was not ignored")
    }

    func testChangedAndCleanRefreshes() {
        let loaded = Self.snapshot("loaded", size: 6)
        let changed = Self.snapshot("changed", size: 7)
        XCTAssertEqual(outcome(observed: changed, lastLoaded: loaded, lastWritten: nil, isDirty: false),
                       .refresh, "a changed file over a clean buffer did not refresh")
        XCTAssertEqual(outcome(observed: changed, lastLoaded: loaded,
                               lastWritten: Self.snapshot("written", size: 7), isDirty: false),
                       .refresh, "a change that is neither the echo nor the loaded bytes did not refresh")
    }

    func testChangedAndDirtyConflicts() {
        let loaded = Self.snapshot("loaded", size: 6)
        let changed = Self.snapshot("changed", size: 7)
        XCTAssertEqual(outcome(observed: changed, lastLoaded: loaded, lastWritten: nil, isDirty: true),
                       .conflict, "a changed file over a dirty buffer did not conflict")
        XCTAssertEqual(outcome(observed: changed, lastLoaded: loaded,
                               lastWritten: Self.snapshot("written", size: 7), isDirty: true),
                       .conflict, "a change that is neither the echo nor the loaded bytes did not conflict")
    }

    /// A vanished file is not the echo and not the loaded bytes, so it follows the same last rule.
    func testAVanishedFileFollowsTheDirtyRule() {
        let loaded = Self.snapshot("loaded", size: 6)
        XCTAssertEqual(outcome(observed: nil, lastLoaded: loaded, lastWritten: nil, isDirty: false), .refresh,
                       "a vanished file over a clean buffer did not refresh")
        XCTAssertEqual(outcome(observed: nil, lastLoaded: loaded,
                               lastWritten: Self.snapshot("written", size: 7), isDirty: true), .conflict,
                       "a vanished file over a dirty buffer did not conflict")
    }

    // MARK: - Rig

    private func watcher(on url: URL, mode: FileWatch.Mode, log: EventLog,
                         delay: Duration = .milliseconds(120),
                         poll: Duration = .milliseconds(60)) -> FileWatch {
        FileWatch(url: url, mode: mode, coalescingDelay: delay, pollInterval: poll) { event in
            Task { await log.record(event) }
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// A write-by-rename: a sibling written whole, then `rename(2)` over the path — the shape an
    /// editor and the engine's own edit path use, and the one that orphans a vnode source.
    private func renameReplace(_ text: String, over url: URL) throws {
        let sibling = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try Data(text.utf8).write(to: sibling)
        guard rename(sibling.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A snapshot with an invented digest: the policy compares digests and never hashes here.
    private static func snapshot(_ seed: String, size: Int) -> FileSnapshot {
        FileSnapshot(size: size, modified: Date(timeIntervalSince1970: 1_700_000_000),
                     digest: "digest-\(seed)")
    }

    /// Returns the moment `predicate` holds. `limit` is a guard that turns a hang into a failure;
    /// it is never waited out on the happy path.
    @discardableResult
    private func wait(on log: EventLog,
                      until predicate: @Sendable ([FileWatch.Event]) -> Bool,
                      _ what: String,
                      within limit: Duration = .seconds(20),
                      file: StaticString = #filePath, line: UInt = #line) async -> [FileWatch.Event] {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            let events = await log.events
            if predicate(events) { return events }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let events = await log.events
        XCTFail("\(what) (\(events.count) events within the guard)", file: file, line: line)
        return events
    }
}

/// What the watcher's callback writes to. An actor, so the count a test reads is a count that was
/// actually recorded.
private actor EventLog {
    private(set) var events: [FileWatch.Event] = []
    func record(_ event: FileWatch.Event) { events.append(event) }
}

private extension FileWatch.Event {
    var snapshot: FileSnapshot? {
        if case .changed(let snapshot) = self { return snapshot }
        return nil
    }
}
