// C7.7's watcher and its path policy: spec Design §5, gate G1.5, plan T2's six groups.
//
// Every repository is built under `FileManager.default.temporaryDirectory` through `ScratchTree`
// and nothing outside the tree the test created is read or written, because `open(2)` on the
// user's content directories is TCC-gated on this machine. Every assertion names counts, classes
// and shapes and never a path, a byte git printed or an environment (§6.3, §11). Every positive
// wait is fulfilled by the delivery it waits for, with a generous outer guard that only turns a
// hang into a failure; the two negative waits (nothing is delivered) are the only fixed windows,
// and each is longer than the stream's own latency plus the debounce.
import Foundation
import XCTest
@testable import SourceControlPanel
import SourceControlCore

final class RepositoryWatchTests: XCTestCase {

    // MARK: - 1. The policy as a table, with no file system in it

    /// An invented root. Nothing under it exists and nothing is created: the classifier is a pure
    /// function over two paths and this group proves it by never touching a disk.
    private let policyRoot = URL(filePath: "/tmp/afleet-c7.7-policy/repo")

    private func assertClass(_ relative: String, _ expected: RepositoryWatch.Change,
                             file: StaticString = #filePath, line: UInt = #line) {
        let path = policyRoot.path(percentEncoded: false) + "/" + relative
        let actual = RepositoryWatch.classify(path: path, root: policyRoot)
        XCTAssertEqual(actual, expected,
                       "a path of the \(expected) class was classified \(actual)",
                       file: file, line: line)
    }

    func testATrackedSourceFileIsAWorkingTreeChange() {
        assertClass("src/main.swift", .workingTree)
    }

    func testAFileAtTheTopOfTheTreeIsAWorkingTreeChange() {
        assertClass("README.md", .workingTree)
    }

    func testADotGitignoreIsAWorkingTreeChangeAndNotADotGitPath() {
        assertClass(".gitignore", .workingTree)
    }

    func testAFileWhoseNameMerelyContainsDotGitIsAWorkingTreeChange() {
        assertClass("foo.gitignore", .workingTree)
        assertClass("vendor/.gitmodules", .workingTree)
    }

    func testADotGithubDirectoryIsAWorkingTreeChange() {
        assertClass(".github/workflows/ci.yml", .workingTree)
        assertClass("notes/.github/agenda.md", .workingTree)
    }

    func testADirectoryWhoseNameStartsWithDotGitIsAWorkingTreeChange() {
        assertClass(".git.bak/HEAD", .workingTree)
    }

    func testTheRootItselfIsAWorkingTreeChange() {
        XCTAssertEqual(RepositoryWatch.classify(path: policyRoot.path(percentEncoded: false),
                                                root: policyRoot),
                       .workingTree)
    }

    func testHeadIsAHistoryChange() {
        assertClass(".git/HEAD", .history)
    }

    func testPackedRefsIsAHistoryChange() {
        assertClass(".git/packed-refs", .history)
    }

    func testABranchRefIsAHistoryChange() {
        assertClass(".git/refs/heads/main", .history)
    }

    func testARemoteBranchRefIsAHistoryChange() {
        assertClass(".git/refs/remotes/origin/main", .history)
    }

    func testTheHeadReflogIsAHistoryChange() {
        assertClass(".git/logs/HEAD", .history)
    }

    func testABranchReflogIsAHistoryChange() {
        assertClass(".git/logs/refs/heads/main", .history)
    }

    /// The load-bearing exclusion: `git status` writes the index when it refreshes stat
    /// information, so an index write that meant "something changed" would make the panel re-read
    /// the status because it had just read the status.
    func testTheIndexIsIgnored() {
        assertClass(".git/index", .ignore)
    }

    func testTheIndexLockIsIgnored() {
        assertClass(".git/index.lock", .ignore)
    }

    func testALooseObjectIsIgnored() {
        assertClass(".git/objects/ab/cdef0123456789", .ignore)
    }

    func testTheCommitMessageDraftIsIgnored() {
        assertClass(".git/COMMIT_EDITMSG", .ignore)
    }

    func testOrigHeadIsIgnored() {
        assertClass(".git/ORIG_HEAD", .ignore)
    }

    /// `HEAD` is history; a lock file that merely begins with the same name is not.
    func testAHeadLockIsIgnored() {
        assertClass(".git/HEAD.lock", .ignore)
    }

    /// A worktree's or a submodule's `.git` is a regular *file* holding a `gitdir:` pointer, and
    /// in an ordinary repository the same path is the directory every index write modifies. It is
    /// ignored for the second reason: the real git directory of a worktree is outside the root and
    /// is never delivered to this stream anyway, while a delivery for the directory itself would
    /// reopen the feedback loop the index exclusion closes.
    func testTheDotGitEntryItselfIsIgnored() {
        assertClass(".git", .ignore)
    }

    /// A path outside the root is not this watch's business — and a sibling directory whose name
    /// begins with the root's own is the case a string prefix on the root gets wrong.
    func testAPathOutsideTheRootIsIgnored() {
        XCTAssertEqual(RepositoryWatch.classify(path: "/tmp/afleet-c7.7-policy/elsewhere/file.txt",
                                                root: policyRoot),
                       .ignore)
        XCTAssertEqual(RepositoryWatch.classify(path: "/tmp/afleet-c7.7-policy/repository/file.txt",
                                                root: policyRoot),
                       .ignore)
    }

    // MARK: - 2. An edit to a tracked file is delivered within one second

    /// G1's own number, and the only timing bound in this leaf.
    private static let bound = Duration.seconds(1)

    func testAnEditDeliversAWorkingTreeChangeWithinOneSecond() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }

        var withinTheBound = 0
        var worst = Duration.zero
        let runs = 10
        for run in 1...runs {
            // Each run starts from quiet: `NoDefer` delivers the first event after a quiet period
            // at once, which is what the bound is bought with, and a run begun inside the previous
            // run's own latency window would be measuring the coalescing instead.
            try await Task.sleep(for: .milliseconds(1200))
            let baseline = log.count
            let wroteAt = ContinuousClock.now
            try repository.write("src/main.swift", "edit \(run)\n")
            let delivered = try await waitForDelivery(log, after: baseline,
                                                      "no delivery for the edit of run \(run)")
            let latency = delivered.at - wroteAt
            if latency < Self.bound { withinTheBound += 1 }
            worst = max(worst, latency)
            XCTAssertEqual(delivered.event, .changed(.workingTree),
                           "run \(run) delivered \(delivered.event) for an edit outside .git")
        }
        XCTAssertEqual(withinTheBound, runs,
                       "\(withinTheBound) of \(runs) edits were delivered within one second; "
                       + "the slowest was \(Self.milliseconds(worst)) ms")
    }

    // MARK: - 3. A burst coalesces

    func testABurstOfTenWritesCoalescesToFewerDeliveries() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }

        let writes = 10
        for index in 1...writes { try repository.write("src/main.swift", "burst \(index)\n") }
        let lastWriteAt = ContinuousClock.now

        _ = try await waitForDelivery(log, after: 0, "the burst delivered nothing")
        // The trailing, coalesced delivery is the one that carries the burst's final state.
        try await waitUntil("no delivery followed the last write of the burst") {
            (log.deliveries.last?.at).map { $0 > lastWriteAt } ?? false
        }
        try await Task.sleep(for: .seconds(2))

        let deliveries = log.deliveries
        XCTAssertLessThan(deliveries.count, writes,
                          "\(writes) writes produced \(deliveries.count) deliveries: nothing coalesced")
        XCTAssertGreaterThan(deliveries.count, 0, "the burst delivered nothing at all")
        XCTAssertTrue(deliveries.allSatisfy { $0.event == .changed(.workingTree) },
                      "the burst delivered a class other than the working tree")
        XCTAssertTrue((deliveries.last?.at).map { $0 > lastWriteAt } ?? false,
                      "the last delivery did not follow the last write")
    }

    // MARK: - 4. A commit is history; the index write it also makes is not

    func testACommitDeliversHistoryAndNoWorkingTreeChange() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // An empty commit: it writes the index, the reflog and the branch ref and touches no file
        // in the working tree, so every delivery it produces is a delivery about `.git`.
        _ = try await repository.commitStaged("second")

        try await waitUntil("the commit delivered no history change") {
            log.deliveries.contains { $0.event == .changed(.history) }
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(log.deliveries.contains { $0.event == .changed(.workingTree) },
                       "a commit that touched no working-tree file delivered a working-tree change")
    }

    /// The feedback loop, put as an assertion: reading the status is what a `.workingTree`
    /// delivery causes, so a status read must cause no delivery of its own.
    func testRepeatedStatusReadsDeliverNothing() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }

        try repository.write("src/main.swift", "edited\n")
        _ = try await waitForDelivery(log, after: 0, "the edit delivered nothing")
        try await Task.sleep(for: .seconds(2))
        let settled = log.count

        for _ in 1...5 {
            _ = try await repository.run(["status", "--porcelain=v2", "--branch"])
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(log.count, settled,
                       "five status reads produced \(log.count - settled) deliveries of their own")
    }

    // MARK: - 5. The root disappearing is reported, not stalled

    func testDeletingTheRootReportsItGone() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.removeItem(at: repository.root)
        try await waitUntil("the deleted root was never reported gone") {
            log.deliveries.contains { $0.event == .rootGone }
        }
    }

    func testReplacingTheRootReportsItGone() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")
        defer { watch.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let displaced = tree.root.appending(path: "displaced-root")
        try FileManager.default.moveItem(at: repository.root, to: displaced)
        try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true)

        try await waitUntil("the replaced root was never reported gone") {
            log.deliveries.contains { $0.event == .rootGone }
        }
    }

    // MARK: - 6. A stopped watch delivers nothing

    func testStoppingTheWatchStopsDeliveries() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["src/main.swift": "one\n"])

        let log = DeliveryLog()
        let watch = RepositoryWatch(root: repository.root) { [log] event in log.record(event) }
        XCTAssertTrue(watch.start(), "the stream did not start")

        try repository.write("src/main.swift", "edited\n")
        _ = try await waitForDelivery(log, after: 0, "the edit before the stop delivered nothing")

        watch.stop()
        let delivered = log.count

        for index in 1...3 { try repository.write("after-\(index).txt", "written\n") }
        try await Task.sleep(for: .seconds(3))

        XCTAssertEqual(log.count, delivered,
                       "\(log.count - delivered) deliveries arrived after stop() returned")
    }

    // MARK: - Waiting

    private struct TimedOut: Error {}

    /// Returns the first delivery recorded past `after`. Fulfilled by the delivery; the guard only
    /// turns a hang into a failure.
    @discardableResult
    private func waitForDelivery(_ log: DeliveryLog, after: Int, _ what: String,
                                 within limit: Duration = .seconds(20),
                                 file: StaticString = #filePath, line: UInt = #line)
        async throws -> DeliveryLog.Delivery {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let deliveries = log.deliveries
            if deliveries.count > after { return deliveries[after] }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(what) (\(log.count) deliveries within the guard)", file: file, line: line)
        throw TimedOut()
    }

    private func waitUntil(_ what: String, within limit: Duration = .seconds(20),
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(what, file: file, line: line)
        throw TimedOut()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// What the watch's callback writes to, with the instant each delivery arrived. A lock rather than
/// an actor: the callback is synchronous and `@Sendable`, and a delivery has to be recorded before
/// it returns for the "nothing after `stop()`" assertion to mean anything.
final class DeliveryLog: @unchecked Sendable {

    struct Delivery: Sendable {
        let event: RepositoryWatch.Event
        let at: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var recorded: [Delivery] = []

    func record(_ event: RepositoryWatch.Event) {
        lock.withLock { recorded.append(Delivery(event: event, at: ContinuousClock.now)) }
    }

    var deliveries: [Delivery] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }
}
