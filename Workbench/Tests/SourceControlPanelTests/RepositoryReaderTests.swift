// SourceControlPanelTests: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// T1 — `RepositoryReader`. Spec Design §1, §3, §6; gates G1.1, G1.3 and G4's argv half.
//
// §6.3/§11 hold over every line below: no assertion message names a path, an environment or a
// tool's output. What an assertion may name is a count, a repository-relative name and a shape.
import XCTest
import AfleetCore
import SourceControlCore
@testable import SourceControlPanel

final class RepositoryReaderTests: XCTestCase {

    // MARK: - the read verbs G4 allows

    /// C7.3's read verbs, and the whole of what this leaf may produce (G4).
    ///
    /// `cat-file` is *not* here. C7.3's list carries it because `GitDiff.blob` exists; this leaf's
    /// reader never calls `blob`, so a `cat-file` in a recording is a reader that grew a read this
    /// task did not sanction, and that must fail rather than pass under a wider set. Extending
    /// this set is a deliberate edit, never a silent one.
    static let allowedGitVerbs: Set<String> = ["rev-parse", "log", "status", "diff", "show"]

    /// The subcommand of one recorded invocation, as git itself reads it.
    ///
    /// `RecordingRunner.Invocation.verb` cannot serve here, and the reason is a finding rather
    /// than a preference: it takes "the first argument that is not an option", and `git`'s `-c`
    /// takes a **value** that is not an option either. `WorkingTreeStatus.arguments()` opens with
    /// `-c diff.renameLimit=1000`, so that helper reads a `status` invocation's verb as
    /// `diff.renameLimit=1000` — its own documentation says `git -c foo=bar log` is a `log`, and it
    /// is not. G4's whole assertion is on these verbs, and one read as a configuration assignment
    /// is a write verb this leaf could hide behind a `-c`. `Support/` is read-only to this task, so
    /// the correct reading lives here and the fixture's is filed as tech debt.
    private static func verb(of invocation: RecordingRunner.Invocation) -> String {
        var index = 0
        while index < invocation.arguments.count {
            let argument = invocation.arguments[index]
            if argument == "-c" || argument == "--config-env" || argument == "--namespace" {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument
        }
        return ""
    }

    private static func gitVerbs(_ recorder: RecordingRunner) -> [String] {
        recorder.invocations(of: .git).map(verb(of:))
    }

    /// Asserts G4's half for one recorder, naming the set and the count it saw.
    ///
    /// The count clause is the point: a recorder that captured nothing satisfies "every verb is in
    /// the set" vacuously, and a suite that stopped invoking `git` would then stay green.
    private func assertOnlyReadVerbs(_ recorder: RecordingRunner,
                                     atLeast minimum: Int,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let verbs = Self.gitVerbs(recorder)
        XCTAssertGreaterThanOrEqual(
            verbs.count, minimum,
            "recorded \(verbs.count) git invocations, expected at least \(minimum); "
            + "a recording of none would satisfy the verb set vacuously",
            file: file, line: line)
        let unexpected = Set(verbs).subtracting(Self.allowedGitVerbs)
        XCTAssertTrue(
            unexpected.isEmpty,
            "git verbs outside the asserted set "
            + "\(Self.allowedGitVerbs.sorted().joined(separator: ", ")): "
            + "\(unexpected.sorted().joined(separator: ", ")) "
            + "(over \(verbs.count) invocations)",
            file: file, line: line)
    }

    // MARK: - fixture helpers this task owns (Support/ is read-only to it)

    private func environment(_ repository: GitRepository) -> ResolvedEnvironment {
        ResolvedEnvironment(variables: repository.environment, shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback)
    }

    /// Compares two directory URLs as paths, tolerating the trailing separator a
    /// `directoryHint: .isDirectory` URL carries and the one a filesystem URL does not.
    private func samePath(_ one: URL?, _ other: URL) -> Bool {
        func normalised(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        guard let one else { return false }
        return normalised(one) == normalised(other)
    }

    private func paths(_ result: RepositoryResult<[FileChange]>) -> [String] {
        guard case .value(let changes) = result else { return [] }
        return changes.map(\.path).sorted()
    }

    private func change(_ result: RepositoryResult<[FileChange]>, _ path: String) -> FileChange? {
        guard case .value(let changes) = result else { return nil }
        return changes.first { $0.path == path }
    }

    /// The corpus group 4 asserts over: one merge commit whose **first-parent** set carries a
    /// modification, an add, a delete, a rename, a binary change and a submodule gitlink.
    ///
    /// Built as a side branch merged into `main` with `--no-ff`, so `main`'s tip before the merge
    /// is the merge's first parent and `git show --first-parent` answers "what did the branch this
    /// landed on gain".
    private func corpus(_ tree: ScratchTree) async throws -> (repo: GitRepository,
                                                              root: String, merge: String) {
        let inner = try await GitRepository(tree, name: "inner")
        try await inner.commit("the submodule's first commit", files: ["inner.txt": "inner\n"])

        let repo = try await GitRepository(tree, name: "repo")
        try repo.write("bin.dat", bytes: Data([0x00, 0x01, 0x02, 0x00, 0xff]))
        let root = try await repo.commit("the root commit", files: [
            "a.txt": "one\n",
            "gone.txt": "removed later\n",
            "old-name.txt": "moved later, unchanged\n",
        ])

        try await repo.branch("side")
        try await repo.checkout("side")
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("added.txt", "new\n")
        try repo.remove("gone.txt")
        try await repo.rename("old-name.txt", to: "new-name.txt")
        try repo.write("bin.dat", bytes: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x00, 0xfe]))
        try await repo.commitStaged("the side branch's change")
        try await repo.addSubmodule(inner, at: "sub")

        try await repo.checkout("main")
        let merge = try await repo.merge(["side"], message: "merge the side branch")
        return (repo, root, merge)
    }

    // MARK: - 1. the root resolves from a subdirectory cwd

    /// C7.3's D13: the channel's cwd is any directory the user opened. A reader that trusted it
    /// would read a working tree out of a directory that is not the root.
    func testLoadResolvesTheRootFromASubdirectoryCwd() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the root commit", files: ["a.txt": "one\n", "sub/n.txt": "n\n"])
        try await repo.commit("a second commit", files: ["b.txt": "two\n"])
        try repo.write("a.txt", "one\nedited\n")

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: try repo.directory("sub"),
                                      environment: environment(repo), runner: recorder)
        let state = await reader.load()

        XCTAssertNil(state.error, "a healthy repository raised a panel-local error row")
        XCTAssertTrue(samePath(state.root, repo.root),
                      "load() did not resolve the repository root from a subdirectory cwd")
        XCTAssertEqual(state.commits.count, 2,
                       "the window holds \(state.commits.count) commits, expected 2")
        XCTAssertEqual(state.status?.branch, "main")
        XCTAssertEqual(state.status?.isClean, false,
                       "the edited tree read as clean")
        // Status, window and assignment arrive as one value: row zero is the working tree exactly
        // when the tree is dirty (C7.3's rule, spec §3).
        XCTAssertEqual(state.assignment.rows.count, 3,
                       "the assignment holds \(state.assignment.rows.count) rows, expected 3 "
                       + "(a dirty working tree plus 2 commits)")
        XCTAssertEqual(state.assignment.rows.first?.content, .workingTree,
                       "row zero is not the working tree over a dirty tree")
        assertOnlyReadVerbs(recorder, atLeast: 3)
    }

    // MARK: - 2. the empty state: no repository, and a bare one

    func testACwdInNoRepositoryIsTheEmptyStateAndNotAnErrorRow() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let outside = try tree.directory("not-a-repository")

        let recorder = RecordingRunner()
        let reader = RepositoryReader(
            cwd: outside,
            environment: ResolvedEnvironment(
                variables: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                            "HOME": outside.path(percentEncoded: false),
                            "LC_ALL": "C", "TZ": "UTC", "GIT_TERMINAL_PROMPT": "0"],
                shell: "/bin/zsh", capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                mode: .processFallback),
            runner: recorder)
        let state = await reader.load()

        XCTAssertNil(state.root, "a directory in no repository resolved a root")
        XCTAssertNil(state.error, ".notARepository was reported as a panel-local error row")
        XCTAssertTrue(state.commits.isEmpty)
        XCTAssertEqual(state.assignment.rows.count, 0)
        let uncommitted = await reader.workingTreeChanges()
        XCTAssertEqual(uncommitted, .notARepository,
                       "a working-tree read in no repository is not the empty state")
        assertOnlyReadVerbs(recorder, atLeast: 1)
    }

    /// A bare repository has no working tree, so `rev-parse --show-toplevel` prints nothing on
    /// exit **0**: the case a reader that only checked the exit code turns into an empty path.
    func testABareRepositoryIsTheSameEmptyState() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        // The bare repository is created through the fixture's own runner, which is the sanctioned
        // way to build a shape `GitRepository` does not offer; the reader under test still writes
        // no command line of its own (W7).
        let carrier = try await GitRepository(tree, name: "carrier")
        let bare = try tree.directory("bare.git")
        try await carrier.run(["init", "--bare", bare.path(percentEncoded: false)], in: tree.root)

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: bare, environment: environment(carrier),
                                      runner: recorder)
        let state = await reader.load()

        XCTAssertNil(state.root, "a bare repository resolved a working-tree root")
        XCTAssertNil(state.error, "a bare repository raised a panel-local error row")
        XCTAssertTrue(state.commits.isEmpty)
        assertOnlyReadVerbs(recorder, atLeast: 1)
    }

    // MARK: - 3. the window is GitLog's, and a page extends it

    func testASecondPageExtendsTheWindowWithoutDuplicatingOrReorderingACommit() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let repo = try await GitRepository(tree)
        for index in 1...7 {
            try await repo.commit("commit \(index)", files: ["n\(index).txt": "\(index)\n"])
        }

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: repo.root, environment: environment(repo),
                                      runner: recorder)
        let state = await reader.load(limit: 3)
        XCTAssertEqual(state.commits.count, 3,
                       "the first page holds \(state.commits.count) commits, expected 3")

        guard case .value(let second) = await reader.page(after: state.commits, limit: 3) else {
            return XCTFail("the second page did not produce a window")
        }
        XCTAssertEqual(second.count, 6,
                       "the extended window holds \(second.count) commits, expected 6")
        XCTAssertEqual(Set(second.map(\.hash)).count, second.count,
                       "the extended window repeats a commit")
        XCTAssertEqual(Array(second.prefix(3)).map(\.hash), state.commits.map(\.hash),
                       "paging reordered the commits already in the window")

        guard case .value(let third) = await reader.page(after: second, limit: 3) else {
            return XCTFail("the third page did not produce a window")
        }
        XCTAssertEqual(third.count, 7,
                       "the whole history is \(third.count) commits, expected 7")
        XCTAssertEqual(Set(third.map(\.hash)).count, 7, "the whole window repeats a commit")
        XCTAssertEqual(Array(third.prefix(6)).map(\.hash), second.map(\.hash),
                       "the last page reordered the commits already in the window")

        // A page past the end adds nothing and still does not duplicate.
        guard case .value(let fourth) = await reader.page(after: third, limit: 3) else {
            return XCTFail("the page past the end did not produce a window")
        }
        XCTAssertEqual(fourth.map(\.hash), third.map(\.hash),
                       "a page past the end changed the window")
        assertOnlyReadVerbs(recorder, atLeast: 5)
    }

    // MARK: - 4. a commit's changed files

    func testAMergeCommitListsItsFirstParentChangeSet() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let built = try await corpus(tree)

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: built.repo.root, environment: environment(built.repo),
                                      runner: recorder)
        let result = await reader.changes(in: built.merge)

        XCTAssertEqual(paths(result),
                       [".gitmodules", "a.txt", "added.txt", "bin.dat", "gone.txt",
                        "new-name.txt", "sub"],
                       "the merge's first-parent set is not the seven expected names")
        XCTAssertEqual(change(result, "a.txt")?.status, .modified)
        XCTAssertEqual(change(result, "added.txt")?.status, .added)
        XCTAssertEqual(change(result, "gone.txt")?.status, .deleted)
        XCTAssertEqual(change(result, ".gitmodules")?.status, .added)
        if case .renamed(let from, _)? = change(result, "new-name.txt")?.status {
            XCTAssertEqual(from, "old-name.txt", "the rename names the wrong original")
        } else {
            XCTFail("the moved path is not reported as a rename")
        }
        XCTAssertEqual(change(result, "bin.dat")?.isBinary, true,
                       "the binary change was not flagged binary")
        XCTAssertNil(change(result, "bin.dat")?.additions,
                     "a binary change reported a line count")
        XCTAssertEqual(change(result, "sub")?.kind, .gitlink,
                       "the submodule entry is not a gitlink")
        // The combined-diff shape a merge lists without `--first-parent` would carry the side's
        // own commits' paths too; the count above is the assertion that it does not.
        XCTAssertEqual(recorder.blobObjectNames.count, 0,
                       "the reader blob-read an object; a changed-file list reads no blob")
        assertOnlyReadVerbs(recorder, atLeast: 2)
    }

    func testARootCommitListsItsWholeTreeAsAdded() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let built = try await corpus(tree)

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: built.repo.root, environment: environment(built.repo),
                                      runner: recorder)
        let result = await reader.changes(in: built.root)

        XCTAssertEqual(paths(result), ["a.txt", "bin.dat", "gone.txt", "old-name.txt"],
                       "the root commit does not list its whole tree")
        for name in ["a.txt", "bin.dat", "gone.txt", "old-name.txt"] {
            XCTAssertEqual(change(result, name)?.status, .added,
                           "\(name) is not added in the root commit")
        }
        assertOnlyReadVerbs(recorder, atLeast: 2)
    }

    // MARK: - 5. the working tree's diff is not the status's entries

    /// Spec §6: `WorkingTreeStatus.entries` is the row-zero signal and the header, never the file
    /// list. A path staged and then modified again is the case that separates them — porcelain v2
    /// reports an index side *and* a working-tree side, and `git diff HEAD` reports one change.
    func testAStagedAndModifiedPathIsOneDiffRowAndTwoStatusSides() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the root commit", files: ["s.txt": "one\n"])
        try repo.write("s.txt", "one\ntwo\n")
        try await repo.run(["add", "s.txt"])
        try repo.write("s.txt", "one\ntwo\nthree\n")

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: repo.root, environment: environment(repo),
                                      runner: recorder)
        let state = await reader.load()
        let diff = await reader.workingTreeChanges()

        let entries = state.status?.entries ?? []
        XCTAssertEqual(entries.count, 1,
                       "the status holds \(entries.count) entries, expected 1")
        XCTAssertEqual(entries.first?.path, "s.txt")
        XCTAssertEqual(entries.first?.staged, .modified,
                       "the status entry has no index side")
        XCTAssertEqual(entries.first?.worktree, .modified,
                       "the status entry has no working-tree side")

        XCTAssertEqual(paths(diff), ["s.txt"],
                       "the working-tree diff is not the single expected name")
        XCTAssertEqual(change(diff, "s.txt")?.status, .modified)
        XCTAssertEqual(change(diff, "s.txt")?.additions, 2,
                       "the diff against HEAD did not count both staged and unstaged lines")
        assertOnlyReadVerbs(recorder, atLeast: 4)
    }

    // MARK: - 6. a git that is not on the resolved PATH

    /// Every function's return type is non-throwing, so "the reader throws nothing past its own
    /// return type" is a compile-time property of this file; what is asserted here is that the
    /// failure arrives as a **value** naming the tool, and carries no byte the tool printed.
    func testAGitThatIsNotOnTheResolvedPathIsAPanelLocalValue() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let repo = try await GitRepository(tree)
        try await repo.commit("the root commit", files: ["a.txt": "one\n"])
        let empty = try tree.directory("no-tools-here")

        let blind = ResolvedEnvironment(variables: ["PATH": empty.path(percentEncoded: false)],
                                        shell: "/bin/zsh",
                                        capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                                        mode: .processFallback)
        let reader = RepositoryReader(cwd: repo.root, environment: blind, runner: ToolRunner())

        let state = await reader.load()
        XCTAssertEqual(state.error?.tool, .git,
                       "a git that cannot be resolved did not produce one git error row")
        XCTAssertNil(state.error?.exitCode,
                     "a binary that never ran reported an exit code")
        XCTAssertEqual(state.error?.detail, RepositoryError.binaryNotFoundDetail,
                       "the error row does not name the absence in this module's own words")
        XCTAssertNil(state.root)
        XCTAssertTrue(state.commits.isEmpty)

        for result in [await reader.workingTreeChanges(),
                       await reader.changes(in: "0000000000000000000000000000000000000000")] {
            guard case .failed(let error) = result else {
                return XCTFail("a read with no git resolved to something other than a failure")
            }
            XCTAssertEqual(error.tool, .git)
        }
        guard case .failed = await reader.page(after: [], limit: 3) else {
            return XCTFail("paging with no git resolved to something other than a failure")
        }
    }

    // MARK: - 7. G4's argv half

    /// One recorder driven through **every** entry point this reader has, over the corpus that
    /// exercises every branch of them, so the asserted set is asserted over the reader's whole
    /// universe of invocations and not over a sample.
    func testEveryGitVerbTheReaderProducesIsAReadVerb() async throws {
        let tree = try ScratchTree(); defer { tree.remove() }
        let built = try await corpus(tree)
        try built.repo.write("a.txt", "one\nedited again\n")

        let recorder = RecordingRunner()
        let reader = RepositoryReader(cwd: try built.repo.directory("sub-dir"),
                                      environment: environment(built.repo), runner: recorder)
        let state = await reader.load(limit: 2)
        _ = await reader.page(after: state.commits, limit: 2)
        _ = await reader.changes(in: built.merge)
        _ = await reader.changes(in: built.root)
        _ = await reader.workingTreeChanges()
        // The failing legs produce argument vectors too, and an unrepresentable write verb has to
        // be unrepresentable on those as well.
        _ = await reader.changes(in: "0000000000000000000000000000000000000000")

        let verbs = Self.gitVerbs(recorder)
        XCTAssertEqual(Set(verbs).subtracting(Self.allowedGitVerbs), [],
                       "the reader produced a git verb outside "
                       + "{rev-parse, log, status, diff, show} over \(verbs.count) invocations")
        // Named individually, so that a set assertion cannot pass by the reader having stopped
        // producing one of them.
        for verb in ["rev-parse", "log", "status", "diff", "show"] {
            XCTAssertTrue(verbs.contains(verb),
                          "the suite recorded no \(verb); the asserted set is wider than what ran")
        }
        XCTAssertGreaterThanOrEqual(verbs.count, 12,
                                    "recorded \(verbs.count) git invocations across six reads, "
                                    + "expected at least 12")
        XCTAssertEqual(recorder.invocations(of: .gh).count, 0,
                       "the repository reader invoked gh")
    }
}
