// SourceControlPanelTests: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// T5 — `SourceControlModel`. Spec Design §1, §3, §5, §6, §7; gates G1.1, G1.3, G1.4, G1.5,
// G3's `.commit` half and G4's two halves.
//
// §6.3/§11 hold over every line below: no assertion message names a path, an environment or a
// tool's output. What an assertion may name is a count, a repository-relative name and a shape.
// Every repository is built under `FileManager.default.temporaryDirectory` with an invented
// identity, and nothing here reads a path it did not create (TCC).
import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
import SourceControlCore
@testable import SourceControlPanel

@MainActor
final class SourceControlModelTests: XCTestCase {

    // MARK: - the read verbs G4 allows

    /// C7.3's read verbs, and the whole of what this model may produce (G4).
    ///
    /// `cat-file` is not here: this leaf's model never reads a blob — a diff is a `.diff` link and
    /// C7.5's resolver fetches the sides. `add`, `commit`, `checkout`, `switch`, `branch`,
    /// `restore`, `stash`, `reset`, `push` and `merge` are unrepresentable rather than merely
    /// unused, which is the whole of §9.2's enforcement. Extending this set is a deliberate edit.
    static let allowedGitVerbs: Set<String> = ["rev-parse", "log", "status", "diff", "show"]

    /// Asserts G4's argv half for one recorder, naming the set and the count it saw.
    ///
    /// The count clause is the point: a recorder that captured nothing satisfies "every verb is in
    /// the set" vacuously, and a suite that stopped invoking `git` would then stay green.
    private func assertOnlyReadVerbs(_ recorder: RecordingRunner, atLeast minimum: Int,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let verbs = recorder.verbs(of: .git)
        XCTAssertGreaterThanOrEqual(
            verbs.count, minimum,
            "recorded \(verbs.count) git invocations, expected at least \(minimum); a recording of "
            + "none would satisfy the verb set vacuously",
            file: file, line: line)
        let unexpected = Set(verbs).subtracting(Self.allowedGitVerbs)
        XCTAssertTrue(
            unexpected.isEmpty,
            "git verbs outside the asserted set "
            + "\(Self.allowedGitVerbs.sorted().joined(separator: ", ")): "
            + "\(unexpected.sorted().joined(separator: ", ")) (over \(verbs.count) invocations)",
            file: file, line: line)
    }

    // MARK: - the harness

    /// `nonisolated` deliberately: this is a synchronous read of a value, and passing a
    /// `GitRepository` to a **main-actor** method merges it into the main actor's region, after
    /// which every later `await repo.run(…)` is a send the compiler rejects.
    private nonisolated static func environment(_ repository: GitRepository) -> ResolvedEnvironment {
        ResolvedEnvironment(variables: repository.environment, shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback)
    }

    /// A model over `repository`, with the machine's own `git` behind a recorder.
    ///
    /// `watching: false` is the default here because most of these tests count invocations, and an
    /// FSEvents delivery arriving mid-assertion is a read nobody asked for. The watch has its own
    /// tests below, which turn it on.
    private func model(_ repository: GitRepository, cwd: URL? = nil,
                       links: (any LinkRouterCapability)? = nil,
                       windowLimit: Int = GitLog.defaultLimit,
                       watching: Bool = false)
        -> (model: SourceControlModel, runner: RecordingRunner) {
        model(root: cwd ?? repository.root, environment: Self.environment(repository), links: links,
              windowLimit: windowLimit, watching: watching)
    }

    /// The same, over values rather than over the repository.
    ///
    /// A test that runs `git` **after** the model exists takes this door: handing a `GitRepository`
    /// to a main-actor-isolated initialiser puts it in the main actor's region, and every later
    /// `await repo.run(…)` is then a send the compiler rejects. `URL` and `ResolvedEnvironment` are
    /// values and carry no region with them.
    private func model(root: URL, environment: ResolvedEnvironment,
                       links: (any LinkRouterCapability)? = nil,
                       windowLimit: Int = GitLog.defaultLimit,
                       watching: Bool = false)
        -> (model: SourceControlModel, runner: RecordingRunner) {
        let recorder = RecordingRunner()
        let model = SourceControlModel(cwd: root, environment: environment,
                                       runner: recorder, links: links,
                                       windowLimit: windowLimit,
                                       watchesForChanges: watching)
        return (model, recorder)
    }

    /// A repository with `count` commits on one line of history, newest last in the returned array.
    private func linearRepository(_ tree: ScratchTree, commits count: Int) async throws
        -> (repo: GitRepository, hashes: [String]) {
        let repo = try await GitRepository(tree)
        var hashes: [String] = []
        for index in 0..<count {
            hashes.append(try await repo.commit("commit \(index)",
                                                files: ["notes/\(index).txt": "line \(index)\n"]))
        }
        return (repo, hashes)
    }

    // MARK: - 1. one read per activation

    func testActivateLoadsOnceAndASecondActivationDoesNotReRead() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 3)
        let (model, recorder) = model(repo)

        await model.activate()
        let readout = model.readout
        XCTAssertTrue(readout.hasRead)
        XCTAssertFalse(readout.isEmptyState)
        XCTAssertEqual(readout.rows.count, 3, "one row per commit and no working-tree row")
        XCTAssertEqual(readout.rows.first?.commit?.hash, hashes.last, "newest first")
        XCTAssertEqual(readout.branch, "main")
        XCTAssertFalse(readout.hasWorkingTreeRow, "a clean tree has no row zero")
        XCTAssertNil(readout.notice)
        let afterFirst = recorder.invocations(of: .git).count
        XCTAssertGreaterThan(afterFirst, 0)

        await model.activate()
        XCTAssertEqual(recorder.invocations(of: .git).count, afterFirst,
                       "a second activation re-read the repository")

        // And the user's own door does read again.
        await model.refresh()
        XCTAssertGreaterThan(recorder.invocations(of: .git).count, afterFirst)
        assertOnlyReadVerbs(recorder, atLeast: 4)
    }

    // MARK: - 2. a commit lists its files, from one read

    func testSelectingACommitReadsItsChangesOnceAndListsWhatGitReported() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n",
                                                          "src/one.txt": "one\n"])
        try await repo.commit("the second commit", files: ["src/one.txt": "one and more\n",
                                                           "src/two.txt": "two\n"])
        let head = try await repo.commit("the third commit", files: ["src/three.txt": "three\n"])
        let (model, recorder) = model(repo)

        await model.activate()
        let before = recorder.verbs(of: .git).filter { $0 == "show" }.count
        await model.select(commit: head)

        let shows = recorder.verbs(of: .git).filter { $0 == "show" }.count - before
        XCTAssertEqual(shows, 1, "a selection read the commit's changes \(shows) times")
        XCTAssertEqual(model.selection, .commit(head))
        let detail = try XCTUnwrap(model.readout.detail)
        guard case .commit(let commit) = detail else { return XCTFail("the detail is not a commit's") }
        XCTAssertEqual(commit.hash, head)
        XCTAssertEqual(commit.subject, "the third commit")
        XCTAssertEqual(commit.files.map(\.path), ["src/three.txt"])
        XCTAssertEqual(commit.files.first?.status, .added)
        XCTAssertEqual(commit.files.first?.kind, .file)
        XCTAssertEqual(commit.files.first?.isBinary, false)

        // Selecting the same commit again reads it again is not asserted either way; selecting a
        // *different* one reads exactly once more.
        let earlier = try XCTUnwrap(model.readout.rows.last?.commit?.hash)
        await model.select(commit: earlier)
        XCTAssertEqual(recorder.verbs(of: .git).filter { $0 == "show" }.count - before, 2)
        assertOnlyReadVerbs(recorder, atLeast: 5)
    }

    // MARK: - 3. clicking a file emits a link and does nothing else

    func testClickingACommitFileEmitsTheDiffLinkAndNothingElse() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        let head = try await repo.commit("the first commit", files: ["src/one.txt": "one\n"])
        let links = RecordingLinks()
        let (model, _) = model(repo, links: links)

        await model.activate()
        await model.select(commit: head)
        let file = try XCTUnwrap(model.readout.detail?.files.first)
        XCTAssertTrue(file.opensADiff)
        await model.openDiff(for: change(named: file.path, in: model), from: .newWindow)

        XCTAssertEqual(links.opened.count, 1, "one click emitted \(links.opened.count) links")
        let opened = try XCTUnwrap(links.opened.first)
        guard case .diff(let ref) = opened.link else { return XCTFail("the link is not a diff") }
        XCTAssertEqual(ref.path, "src/one.txt")
        XCTAssertEqual(ref.base, .commitAgainstParent(head))
        XCTAssertEqual(ref.repository.standardizedFileURL.resolvingSymlinksInPath(),
                       (model.state.root ?? URL(filePath: "/"))
                           .standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(opened.destination, .newWindow,
                       "the destination the click carried did not reach open(_:from:)")
        XCTAssertTrue(links.registrations.isEmpty,
                      "the model registered a target; W5 gives that to the tab")
        // Nothing else: no tab selection and no editor exist on this seam, and the selection the
        // click was made from is untouched.
        XCTAssertEqual(model.selection, .commit(head))
    }

    func testClickingAWorkingTreeFileEmitsTheWorkingTreeDiffLink() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["src/one.txt": "one\n"])
        try repo.write("src/one.txt", "one, edited\n")
        let links = RecordingLinks()
        let (model, _) = model(repo, links: links)

        await model.activate()
        XCTAssertTrue(model.readout.hasWorkingTreeRow, "a dirty tree has row zero")
        await model.selectWorkingTree()
        let files = try XCTUnwrap(model.readout.detail?.files)
        XCTAssertEqual(files.map(\.path), ["src/one.txt"])
        await model.openDiff(for: change(named: "src/one.txt", in: model), from: .currentPanel)

        XCTAssertEqual(links.opened.count, 1)
        guard case .diff(let ref) = try XCTUnwrap(links.opened.first?.link) else {
            return XCTFail("the link is not a diff")
        }
        XCTAssertEqual(ref.path, "src/one.txt")
        XCTAssertEqual(ref.base, .workingTreeAgainstHEAD)
        XCTAssertEqual(links.opened.first?.destination, .currentPanel)
    }

    // MARK: - 4. the two kinds that offer no diff

    func testAGitlinkAndABinaryRowEmitNoLinkAndCarryAStatedReason() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let inner = try await GitRepository(tree, name: "inner")
        try await inner.commit("the submodule's own commit", files: ["inner.txt": "inner\n"])
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        try repo.write("assets/blob.bin", bytes: Data([0x00, 0x01, 0x02, 0x00, 0xff]))
        try await repo.commit("a binary file")
        try await repo.addSubmodule(inner, at: "vendor/inner")
        // Both sides now change without a commit: the gitlink names a new commit and the binary
        // file's bytes differ.
        try await repo.commitInsideSubmodule(at: "vendor/inner", files: ["more.txt": "more\n"])
        try repo.write("assets/blob.bin", bytes: Data([0x00, 0x09, 0x09, 0x00, 0x01]))
        // And an ordinary text change beside them, so the exclusion below is discriminating
        // rather than a list that never links.
        try repo.write("README.md", "loom, edited\n")

        let links = RecordingLinks()
        let (model, _) = model(repo, links: links)
        await model.activate()
        await model.selectWorkingTree()
        let files = try XCTUnwrap(model.readout.detail?.files)

        let gitlink = try XCTUnwrap(files.first { $0.kind == .gitlink },
                                    "the working-tree list carries no submodule row")
        XCTAssertFalse(gitlink.opensADiff)
        XCTAssertEqual(gitlink.exclusionReason, SourceControlReadout.submoduleReason)
        let binary = try XCTUnwrap(files.first { $0.isBinary },
                                   "the working-tree list carries no binary row")
        XCTAssertFalse(binary.opensADiff)
        XCTAssertEqual(binary.exclusionReason, SourceControlReadout.binaryReason)

        await model.openDiff(for: change(named: gitlink.path, in: model))
        await model.openDiff(for: change(named: binary.path, in: model))
        XCTAssertTrue(links.opened.isEmpty,
                      "an excluded row emitted \(links.opened.count) links")

        // And a row that is neither still emits, so the exclusion is discriminating rather than a
        // list that never links.
        let plain = try XCTUnwrap(files.first { $0.opensADiff })
        await model.openDiff(for: change(named: plain.path, in: model))
        XCTAssertEqual(links.opened.count, 1)
    }

    // MARK: - 5. G1.5's one-second clause

    func testTheWorkingTreeRowAppearsAndDisappearsWithinOneSecond() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["src/one.txt": "one\n"])
        let (model, _) = model(repo, watching: true)

        await model.activate()
        XCTAssertTrue(model.isWatchArmed, "the watch was not armed")
        XCTAssertFalse(model.readout.hasWorkingTreeRow)
        // Outside the measurement: the stream is armed by `activate()` and a write racing its
        // arming is a race about FSEvents, not about the bound this gate names.
        try await Task.sleep(for: .milliseconds(300))

        try repo.write("src/one.txt", "one, edited\n")
        let appeared = try await waitUntil("the working-tree row appears") {
            model.readout.hasWorkingTreeRow
        }
        XCTAssertLessThan(appeared, 1.0,
                          "the working-tree row took \(String(format: "%.3f", appeared)) s to "
                          + "appear; G1.5 bounds it at one second")

        try repo.write("src/one.txt", "one\n")
        let vanished = try await waitUntil("the working-tree row goes away") {
            !model.readout.hasWorkingTreeRow
        }
        XCTAssertLessThan(vanished, 1.0,
                          "the working-tree row took \(String(format: "%.3f", vanished)) s to go "
                          + "away; G1.5 bounds it at one second")
        model.deactivate()
    }

    /// The history half of §5: a `.history` change re-reads the window, the status and the
    /// assignment, and a `.workingTree` change does not.
    func testAHistoryChangeReReadsTheWindowAndAWorkingTreeChangeReadsTheStatus() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        // Built inline rather than through `linearRepository`: a `GitRepository` returned by a
        // main-actor method belongs to the main actor's region, and this test runs `git` again
        // *after* the model exists.
        let repo = try await GitRepository(tree)
        try await repo.commit("commit 0", files: ["notes/0.txt": "line 0\n"])
        try await repo.commit("commit 1", files: ["notes/1.txt": "line 1\n"])
        let (model, recorder) = model(root: repo.root, environment: Self.environment(repo))
        await model.activate()
        XCTAssertEqual(model.readout.rows.count, 2)

        // A working-tree change reads the status and not the window.
        try repo.write("src/one.txt", "one\n")
        try await repo.run(["add", "-A"])
        let before = recorder.verbs(of: .git)
        await model.handle(.changed(.workingTree))
        let afterWorkingTree = recorder.verbs(of: .git)
        XCTAssertEqual(afterWorkingTree.filter { $0 == "log" }.count,
                       before.filter { $0 == "log" }.count,
                       "a working-tree change re-read the commit window")
        XCTAssertGreaterThan(afterWorkingTree.filter { $0 == "status" }.count,
                             before.filter { $0 == "status" }.count)
        XCTAssertTrue(model.readout.hasWorkingTreeRow)

        // A history change re-reads everything, and the new commit is on screen.
        try await repo.commitStaged("the third commit")
        await model.handle(.changed(.history))
        XCTAssertEqual(model.readout.rows.count, 3)
        XCTAssertFalse(model.readout.hasWorkingTreeRow)
        assertOnlyReadVerbs(recorder, atLeast: 6)
    }

    /// `.rootGone` is the `.notARepository` empty state, and the watch is torn down with it.
    ///
    /// The decision this test pins: the panel does not keep drawing a repository that is not there,
    /// and it does not raise an error row for it either — a deleted or replaced root is the same
    /// answer as a channel that was never in a repository (`RepositoryWatch.Event.rootGone`'s own
    /// documentation asks the owner for exactly this).
    func testRootGoneBecomesTheEmptyStateAndStopsTheWatch() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 2)
        let (model, _) = model(repo, watching: true)
        await model.activate()
        await model.select(commit: try XCTUnwrap(hashes.last))
        XCTAssertTrue(model.isWatchArmed)

        await model.handle(.rootGone)

        XCTAssertTrue(model.readout.isEmptyState)
        XCTAssertNil(model.state.error, "a root that went away raised an error row")
        XCTAssertEqual(model.readout.notice?.placement, .emptyState)
        XCTAssertTrue(model.readout.rows.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.readout.detail)
        XCTAssertFalse(model.isWatchArmed, "the watch stayed armed on a root that is gone")
    }

    // MARK: - 6 and 7. the `.commit` delivery

    func testACommitInTheWindowIsSelectedAndItsDetailLoaded() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 4)
        let (model, _) = model(repo)
        await model.activate()

        await model.select(commit: try XCTUnwrap(hashes.first))

        XCTAssertEqual(model.selection, .commit(hashes[0]))
        XCTAssertNil(model.readout.notice)
        XCTAssertEqual(model.readout.detail?.files.map(\.path), ["notes/0.txt"])
        XCTAssertTrue(model.readout.rows.contains { $0.isSelected })
    }

    func testACommitOutsideTheWindowIsFoundByPagingAndTheWindowIsExtended() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 8)
        // A window of two, so the four oldest commits are outside it.
        let (model, recorder) = model(repo, windowLimit: 2)
        await model.activate()
        XCTAssertEqual(model.readout.rows.count, 2)
        let wanted = hashes[1]
        XCTAssertFalse(model.readout.rows.contains { $0.commit?.hash == wanted })

        await model.select(commit: wanted)

        XCTAssertEqual(model.selection, .commit(wanted))
        XCTAssertNil(model.readout.notice, "a delivery that found its commit raised a row")
        XCTAssertTrue(model.readout.rows.contains { $0.commit?.hash == wanted },
                      "the window was not extended, so the selected row is not on screen")
        XCTAssertTrue(model.readout.rows.contains { $0.isSelected })
        XCTAssertGreaterThan(recorder.verbs(of: .git).filter { $0 == "log" }.count, 1,
                             "nothing was paged")
        assertOnlyReadVerbs(recorder, atLeast: 4)
    }

    func testACommitNotFoundWithinThePagingBoundIsANamedRow() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        // Ten commits and a window of one: five pages reach six of them, so the oldest is real,
        // outside the bound, and must be reported rather than selected.
        let (repo, hashes) = try await linearRepository(tree, commits: 10)
        let (model, recorder) = model(repo, windowLimit: 1)
        await model.activate()

        await model.select(commit: try XCTUnwrap(hashes.first))

        XCTAssertNil(model.selection, "a commit beyond the bound was selected anyway")
        XCTAssertEqual(model.deliveryNotice, .commitNotFound(hash: hashes[0]))
        let notice = try XCTUnwrap(model.readout.notice, "the delivery was a silent no-op")
        XCTAssertEqual(notice.placement, .row)
        XCTAssertEqual(recorder.verbs(of: .git).filter { $0 == "log" }.count,
                       1 + SourceControlModel.pagingBound,
                       "the search did not stop at the bound")

        // And a hash that is in no repository at all: the walk ends when the history stops growing.
        await model.select(commit: "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(model.deliveryNotice,
                       .commitNotFound(hash: "0123456789abcdef0123456789abcdef01234567"))
        assertOnlyReadVerbs(recorder, atLeast: 8)
    }

    func testAnAmbiguousPrefixIsANamedRowAndNotAnArbitraryPick() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 20)
        let (model, _) = model(repo)
        await model.activate()

        // The shortest prefix two of these commits share. Twenty commits over sixteen first
        // characters make one near-certain; the test says so rather than asserting on luck.
        var ambiguous: (prefix: String, matches: Int)?
        for hash in hashes {
            let prefix = String(hash.prefix(1))
            let matches = hashes.filter { $0.hasPrefix(prefix) }.count
            if matches > 1 { ambiguous = (prefix, matches); break }
        }
        let found = try XCTUnwrap(ambiguous, "no two of the twenty hashes share a first character")

        await model.select(commit: found.prefix)

        XCTAssertNil(model.selection, "an ambiguous prefix picked a commit")
        XCTAssertEqual(model.deliveryNotice,
                       .ambiguousPrefix(prefix: found.prefix, matches: found.matches))
        XCTAssertEqual(model.readout.notice?.placement, .row)
    }

    func testAnAbbreviatedHashSelectsByUnambiguousPrefix() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 4)
        let (model, _) = model(repo)
        await model.activate()
        let wanted = try XCTUnwrap(hashes.last)

        await model.select(commit: String(wanted.prefix(8)))

        XCTAssertEqual(model.selection, .commit(wanted), "the abbreviation did not resolve")
        XCTAssertNil(model.readout.notice)
        XCTAssertEqual(model.readout.detail?.files.map(\.path), ["notes/3.txt"])
    }

    /// The empty state answers a delivery too — with a row, and never with a silent no-op.
    func testACommitDeliveredOutsideARepositoryIsANamedRow() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        let outside = try tree.directory("outside")
        let (model, _) = model(repo, cwd: outside)
        await model.activate()

        await model.select(commit: "0123456789abcdef0123456789abcdef01234567")

        XCTAssertNil(model.selection)
        XCTAssertEqual(model.deliveryNotice,
                       .noRepository(hash: "0123456789abcdef0123456789abcdef01234567"))
        XCTAssertEqual(model.readout.notice?.placement, .row)
    }

    // MARK: - 8. a failure names its tool, and carries no byte the tool printed

    func testAGitFailureIsOneRowNamingTheToolAndItsExitCode() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        // A token no message in this target could contain by accident. It is invented and belongs
        // to nobody (§11).
        let token = "MARLWEFT-4409"
        let failing = FailingVerbRunner(verb: "status", exitCode: 3,
                                        stderr: "fatal: \(token) — \(token)",
                                        underlying: ToolRunner())
        let model = SourceControlModel(cwd: repo.root, environment: Self.environment(repo),
                                       runner: failing, links: nil,
                                       windowLimit: GitLog.defaultLimit,
                                       watchesForChanges: false)

        await model.activate()

        let error = try XCTUnwrap(model.state.error, "a failed read raised no row")
        XCTAssertEqual(error.tool, .git, "the row named the wrong tool")
        XCTAssertEqual(error.exitCode, 3)
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertEqual(notice.placement, .row)
        XCTAssertTrue(notice.message.contains("Git"), "the row did not name the tool")
        XCTAssertTrue(notice.message.contains("3"), "the row did not name the exit code")

        let rendered = Self.renderedStrings(of: model.readout)
        XCTAssertFalse(rendered.isEmpty, "the readout rendered nothing to search")
        for string in rendered {
            XCTAssertFalse(string.contains(token),
                           "a rendered string carried a byte the tool printed")
        }
    }

    /// Every `String` reachable inside a value, by reflection.
    ///
    /// Reflection rather than a written-out list of fields: the assertion above is that **no**
    /// rendered string carries a tool's byte, and a list of fields would silently stop covering
    /// the field somebody adds next.
    private static func renderedStrings(of value: Any) -> [String] {
        if let string = value as? String { return [string] }
        var found: [String] = []
        for child in Mirror(reflecting: value).children { found += renderedStrings(of: child.value) }
        return found
    }

    /// A cancelled read is not a failure: the previous state stands, no notice is published, and
    /// `hasRead` is not latched — otherwise the tab shows an empty graph with nothing said about it
    /// and `activate()` never reads again.
    func testACancelledReadLeavesThePreviousStateAndPublishesNoNotice() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, _) = try await linearRepository(tree, commits: 2)
        let cancelling = ThrowingRunner(underlying: ToolRunner())
        let model = SourceControlModel(cwd: repo.root, environment: Self.environment(repo),
                                       runner: cancelling, links: nil,
                                       windowLimit: GitLog.defaultLimit,
                                       watchesForChanges: false)

        await model.activate()
        XCTAssertEqual(model.readout.rows.count, 2)
        cancelling.thrown = .cancelled(tool: .git)
        await model.refresh()

        XCTAssertEqual(model.readout.rows.count, 2, "a cancelled read cleared the graph")
        XCTAssertNil(model.readout.notice, "a cancelled read published a notice")
        XCTAssertNil(model.state.error)
    }

    /// The pin under the line above: what the reader produces for a cancellation is what the model
    /// recognises as one. Compared against `RepositoryError`'s own mapping rather than a literal,
    /// so a re-worded detail moves both sides together.
    func testTheCancellationTheReaderProducesIsTheOneTheModelRecognises() {
        XCTAssertTrue(SourceControlModel.isCancellation(RepositoryError(ToolError.cancelled(tool: .git))))
        XCTAssertFalse(SourceControlModel.isCancellation(
            RepositoryError(ToolError.commandFailed(tool: .git, exitCode: 3, stderrTail: ""))))
        XCTAssertFalse(SourceControlModel.isCancellation(RepositoryError(ToolError.notARepository)))
    }

    // MARK: - 9. `.notARepository` is the empty state

    func testNotARepositoryIsTheEmptyStateAndNoErrorRow() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        let outside = try tree.directory("outside")
        let (model, recorder) = model(repo, cwd: outside)

        await model.activate()

        XCTAssertTrue(model.readout.isEmptyState)
        XCTAssertNil(model.state.error, "the empty state was rendered as an error")
        XCTAssertEqual(model.readout.notice?.placement, .emptyState)
        XCTAssertNil(model.readout.notice?.hint)
        XCTAssertTrue(model.readout.rows.isEmpty)
        XCTAssertNil(model.readout.detail)
        assertOnlyReadVerbs(recorder, atLeast: 1)
    }

    // MARK: - G4: the inventory, and the argument vectors

    /// §9.2 is binding: this panel is a reader. The comparison is against a written-out list, so an
    /// action added to the enum fails here rather than passing under a predicate that drifts with
    /// the code it checks.
    func testTheActionInventoryIsTheWrittenOutListAndHoldsNoWriteAction() {
        XCTAssertEqual(SourceControlReadout.Action.allCases,
                       [.refresh, .selectCommit, .selectWorkingTree, .selectParentCommit,
                        .openFileDiff])

        // And the written-out list is itself checked against the operations §9.2 puts out of
        // scope, so a case renamed into one of them fails here as well as above. The comparison is
        // on the whole action name: `selectCommit` *selects* a commit and does not make one.
        let forbidden: Set<String> = ["stage", "unstage", "commit", "amend", "createBranch",
                                      "checkout", "switchBranch", "stash", "push", "pull", "merge",
                                      "rebase", "reset", "restore", "revert", "discard", "tag",
                                      "cherryPick"]
        let named = Set(SourceControlReadout.Action.allCases.map(\.rawValue))
        XCTAssertTrue(named.intersection(forbidden).isEmpty,
                      "the action inventory names a repository-modifying action")
    }

    /// G4's argv half over **every door of this model**, on one recorder.
    func testEveryGitArgumentVectorAcrossEveryDoorIsAReadVerb() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let (repo, hashes) = try await linearRepository(tree, commits: 6)
        try repo.write("notes/0.txt", "edited\n")
        let links = RecordingLinks()
        let (model, recorder) = model(repo, links: links, windowLimit: 2)

        await model.activate()
        await model.refresh()
        await model.selectWorkingTree()
        if let change = model.changes.first { await model.openDiff(for: change) }
        await model.select(commit: try XCTUnwrap(hashes.last))
        await model.select(commit: String(try XCTUnwrap(hashes.last).prefix(8)))
        await model.select(commit: try XCTUnwrap(hashes.first))          // paged
        await model.select(commit: "0123456789abcdef0123456789abcdef01234567")  // not found
        await model.handle(.changed(.workingTree))
        await model.handle(.changed(.history))
        await model.handle(.changed(.ignore))
        await model.handle(.rootGone)

        assertOnlyReadVerbs(recorder, atLeast: 12)
        XCTAssertFalse(links.opened.isEmpty, "no door emitted a link, so the sweep missed one")
    }

    // MARK: - helpers

    /// The `FileChange` behind a readout row, which is what a click carries.
    private func change(named path: String, in model: SourceControlModel) -> FileChange {
        model.changes.first { $0.path == path }
            ?? FileChange(path: path, status: .modified, additions: nil, deletions: nil,
                          isBinary: false)
    }

    /// A delivery-fulfilled wait: it returns as soon as `condition` holds, with the time it took,
    /// and fails the test at the outer guard rather than hanging. The guard is generous and the
    /// **assertion** is the bound, so a machine under load produces a measured number to re-run
    /// rather than a timeout with nothing in it.
    @discardableResult
    private func waitUntil(_ what: String, guard limit: Duration = .seconds(10),
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws -> Double {
        let started = ContinuousClock.now
        while started.duration(to: .now) < limit {
            if condition() { return started.duration(to: .now).seconds }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        return .infinity
    }
}

/// A `LinkRouterCapability` that records instead of routing.
///
/// The seam `openDiff(for:from:)` is written against, so a test asserts the **link and the
/// destination** that left this leaf rather than a pair that arrived somewhere. T6 drives the same
/// emission through a real `LinkRouter`; this is the unit half, and it is also what makes
/// "this model registers nothing" an assertion rather than a claim.
final class RecordingLinks: LinkRouterCapability, @unchecked Sendable {

    struct Opened: Sendable {
        let link: WorkspaceLink
        let destination: LinkDestination
    }

    private let lock = NSLock()
    private var _opened: [Opened] = []
    private var _registrations: [PanelTabID] = []

    var opened: [Opened] { lock.withLock { _opened } }
    var registrations: [PanelTabID] { lock.withLock { _registrations } }

    func register(_ target: LinkTarget) async { lock.withLock { _registrations.append(target.tab) } }
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        lock.withLock { _opened.append(Opened(link: link, destination: destination)) }
    }
}

/// Runs everything for real except one subcommand, which exits non-zero with an authored stderr.
///
/// The shape a mid-cycle failure takes: the root resolves, and the read that follows it does not.
/// The stderr is authored here and carries an invented token, which is what group 8 searches the
/// whole readout for.
final class FailingVerbRunner: ToolRunning, @unchecked Sendable {

    private let verb: String
    private let exitCode: Int32
    private let stderr: String
    private let underlying: any ToolRunning

    init(verb: String, exitCode: Int32, stderr: String, underlying: any ToolRunning) {
        self.verb = verb
        self.exitCode = exitCode
        self.stderr = stderr
        self.underlying = underlying
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        // Matched the way git reads a vector, so an option before the subcommand does not hide it.
        if RecordingRunner.Invocation(tool: tool, arguments: arguments).verb == verb {
            return ToolOutput(stdout: Data(), stderr: Data(stderr.utf8), exitCode: exitCode,
                              timedOut: false)
        }
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }
}

/// Runs everything for real until a test sets `thrown`, after which every invocation throws it.
final class ThrowingRunner: ToolRunning, @unchecked Sendable {

    private let lock = NSLock()
    private var _thrown: ToolError?
    private let underlying: any ToolRunning

    init(underlying: any ToolRunning) { self.underlying = underlying }

    var thrown: ToolError? {
        get { lock.withLock { _thrown } }
        set { lock.withLock { _thrown = newValue } }
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        if let thrown { throw thrown }
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
