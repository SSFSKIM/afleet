import Foundation
import XCTest
import AfleetCore
@testable import SourceControlCore

/// The R4 wave's suite: every reader in this module, run against a repository whose git
/// configuration is deliberately **hostile**, asserting the same answers the hermetic fixtures get.
///
/// **Why this suite exists at all.** Ledger D14 runs every other fixture with the user's global and
/// system configuration disabled (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`), so
/// that the suite does not pass or fail by accident of the developer's `~/.gitconfig`. Production
/// does the opposite by contract: X11 runs the *user's* `git` with the *user's* configuration, so
/// that hooks, credential helpers and worktrees behave as the user's own terminal does. The two
/// together leave the fixtures structurally blind to any setting that changes the bytes a parser
/// here reads — which is how `log.decorate=full` and `log.showRoot=false` both reached review as
/// live defects. Hermeticity stays the default for every other test; this one file is its
/// adversary, and it is the test that catches the next instance rather than the last two.
///
/// The adverse values are set with **repository-local** `git config` inside a `TempTree` fixture:
/// nothing here writes to the machine's own configuration, and the local tier outranks the
/// disabled global and system tiers exactly as a real user's global tier would.
///
/// **Assertion style**, as in the sibling suites and for the same reason: no `XCTAssertEqual` over
/// a value that transitively reaches a runtime path or an environment (§6.3, §11). Hashes,
/// subjects, ref names and repository-relative paths are authored in this file and are compared
/// directly; counts are reported, paths are not.
final class AdverseConfigurationTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    /// Every setting this module pins on the command line, at its adverse value, in one dictionary.
    ///
    /// One place for the class to grow: a new pin adds its adverse value here and the
    /// whole-configuration test below covers it without a new fixture. Each entry names the reader
    /// it attacks and what it does to that reader's bytes when the pin is missing.
    static let hostile: [String: String] = [
        // `git log`: `%D` prints `refs/heads/main` and `refs/remotes/origin/main`, so an attached
        // branch keeps the prefix and every other local branch is read as a remote branch of a
        // remote named `refs`. Pinned by `--decorate=short`.
        "log.decorate": "full",
        // `git show`: a root commit's listings both come back empty, so the join agrees on "no
        // changed files" and a non-empty initial tree is reported as no change at all — the silent
        // wrong answer. Pinned by `--root`.
        "log.showRoot": "false",
        // `git log`: the whole of the output is re-encoded, so the UTF-8 decode in `parse` sees
        // bytes that are not the format's. Pinned by `--encoding=UTF-8`.
        "i18n.logOutputEncoding": "UTF-16",
        // `git status`: untracked paths vanish from the porcelain entirely.
        // Pinned by `--untracked-files=normal`, which also normalises the `all` value's expansion
        // of untracked directories into their files.
        "status.showUntrackedFiles": "no",
        // `git status`: a staged rename is reported as a delete and an add, so
        // `Entry.Change.renamed(from:)` never occurs. Pinned by `--find-renames`.
        "status.renames": "false",
        // The same, through the other key porcelain v2 rename detection reads.
        "diff.renames": "false",
    ]

    /// Settings measured on `git` 2.55.0 to change nothing any reader here parses, kept as a test
    /// so that a future `git` which *starts* honouring one of them fails a named test rather than
    /// changing a panel's answer quietly. The R4 configuration-sensitivity table in the ledger
    /// records why each was ruled out.
    static let ruledOut: [String: String] = [
        "core.quotePath": "false",          // moot under `-z`, which quotes nothing
        "status.relativePaths": "true",     // porcelain paths are always relative to the root
        "status.aheadBehind": "false",      // porcelain v2 computes `# branch.ab` regardless
        "log.abbrevCommit": "true",         // `%H` is the full object name by construction
        "core.abbrev": "7",                 // the same
        "log.mailmap": "true",              // `%an` is the raw author; `%aN` is the mapped one
        "log.date": "raw",                  // `%at` is a Unix timestamp, not a rendered date
        "format.pretty": "oneline",         // an explicit `--format=` outranks it
        "log.showSignature": "true",        // nothing is added to a custom format's output
        "notes.displayRef": "refs/notes/*", // notes reach a custom format only through `%N`
        "log.diffMerges": "combined",       // an explicit `--first-parent` outranks it
        "diff.algorithm": "minimal",        // numstat counts unchanged on this history
        "diff.noprefix": "true",            // no prefix is printed by `--name-status`/`--numstat`
        "diff.relative": "true",            // the invocations run at the repository root
        "diff.external": "/bin/false",      // `--name-status`/`--numstat` never call it
        "diff.renameLimit": "2",            // exact renames are detected outside the limit
        "core.pager": "cat",                // git pages only onto a terminal
        "core.commentChar": ";",            // only the long status format carries comments
    ]

    // MARK: - helpers

    /// Applies `settings` to `fixture` as repository-local configuration.
    ///
    /// Applied **after** the history is built, so that a hostile value cannot change the fixture
    /// itself and leave the test asserting against a different repository than it describes.
    private func configure(_ fixture: GitFixture, _ settings: [String: String]) async throws {
        for key in settings.keys.sorted() {
            try await fixture.run(["config", key, settings[key]!])
        }
    }

    private func commits(_ fixture: GitFixture) async throws -> [GitCommit] {
        try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                 runner: ToolRunner())
    }

    private func changes(_ fixture: GitFixture, _ base: DiffRef.Base) async throws -> [FileChange] {
        try await GitDiff.changes(root: fixture.root, base: base,
                                  environment: fixture.environment, runner: ToolRunner())
    }

    private func status(_ fixture: GitFixture) async throws -> WorkingTreeStatus {
        try await WorkingTreeStatus.read(root: fixture.root, environment: fixture.environment,
                                         runner: ToolRunner())
    }

    /// A two-commit history carrying one decoration of every kind `%D` prints: an attached `HEAD`,
    /// a tag and a local branch on the root commit, and a second local branch on the tip.
    ///
    /// Both branch names are deliberately **unslashed**. A slashed local branch is misread under
    /// the shortened form too (tracker 115, the ambiguity `--decorate=full` would resolve), so a
    /// slashed name here would fail for two reasons at once and stop separating this suite's
    /// question — is the decoration form the parser assumes the one it gets — from that one.
    private func decoratedFixture() async throws -> (GitFixture, root: String, tip: String) {
        let fixture = try await GitFixture(tree)
        let root = try await fixture.commit(message: "the first commit",
                                            files: ["a.txt": "one\n", "b.txt": "two\n"])
        try await fixture.tag("v0.1")
        try await fixture.branch("sidecar", from: root)
        let tip = try await fixture.commit(message: "the sidecar commit",
                                           files: ["c.txt": "three\n"])
        try await fixture.checkout("main")
        return (fixture, root, tip)
    }

    // MARK: - one adverse setting at a time

    /// `log.decorate=full` — the R4 reviewer's first instance.
    ///
    /// What would have to be true for this to fail: `GitLog`'s command line losing
    /// `--decorate=short`, or a `git` in which that option stops overriding the configuration.
    func testDecorationsAreReadCorrectlyUnderLogDecorateFull() async throws {
        let (fixture, root, tip) = try await decoratedFixture()
        try await configure(fixture, ["log.decorate": "full"])

        let parsed = try await commits(fixture)
        let refs = Dictionary(uniqueKeysWithValues: parsed.map { ($0.hash, Set($0.refs)) })

        XCTAssertEqual(refs[root], [GitRef(kind: .head, name: "HEAD"),
                                    GitRef(kind: .branch, name: "main"),
                                    GitRef(kind: .tag, name: "v0.1")],
                       "under log.decorate=full the root commit's decorations were not read as an "
                       + "attached HEAD, the local branch main and the tag v0.1")
        XCTAssertEqual(refs[tip], [GitRef(kind: .branch, name: "sidecar")],
                       "under log.decorate=full the branch sidecar was not read as a local branch")
    }

    /// `log.showRoot=false` — the R4 reviewer's second instance, and the worst shape: both
    /// listings come back empty, they agree, and `changes` returns "no changed files" for a
    /// non-empty initial tree.
    ///
    /// What would have to be true for this to fail: `.commitAgainstParent`'s invocation losing
    /// `--root`.
    func testARootCommitsTreeIsStillListedUnderLogShowRootFalse() async throws {
        let fixture = try await GitFixture(tree)
        let root = try await fixture.commit(message: "the first commit",
                                            files: ["a.txt": "one\n", "b.txt": "two\n"])
        try await configure(fixture, ["log.showRoot": "false"])

        let list = try await changes(fixture, .commitAgainstParent(root))
        XCTAssertEqual(list.count, 2,
                       "under log.showRoot=false the root commit did not list its two files")
        XCTAssertEqual(Set(list.map(\.path)), ["a.txt", "b.txt"],
                       "under log.showRoot=false the root commit's paths are not the two committed")
        XCTAssertTrue(list.allSatisfy { $0.status == .added },
                      "the root commit's whole tree is additions and was not reported as such")
    }

    /// `i18n.logOutputEncoding` — the reader decodes UTF-8, so an output encoding the user chose
    /// for their terminal must not reach it.
    ///
    /// What would have to be true for this to fail: `GitLog`'s command line losing
    /// `--encoding=UTF-8`.
    func testTheCommitWindowSurvivesAnAlternateLogOutputEncoding() async throws {
        let (fixture, root, tip) = try await decoratedFixture()
        try await configure(fixture, ["i18n.logOutputEncoding": "UTF-16"])

        let parsed = try await commits(fixture)
        XCTAssertEqual(Set(parsed.map(\.hash)), [root, tip],
                       "under an alternate log output encoding the window's hashes are not the "
                       + "two commits the fixture made")
        XCTAssertEqual(Set(parsed.map(\.subject)), ["the first commit", "the sidecar commit"],
                       "under an alternate log output encoding the subjects did not decode")
        XCTAssertTrue(parsed.allSatisfy { $0.authorName == GitFixture.authorName },
                      "under an alternate log output encoding the author name did not decode")
    }

    /// `status.showUntrackedFiles=no` — an untracked file is a change the panel draws, and a
    /// configuration that hides it from `git status` must not hide it from the panel.
    ///
    /// What would have to be true for this to fail: `WorkingTreeStatus`'s command line losing
    /// `--untracked-files=normal`.
    func testUntrackedPathsSurviveStatusShowUntrackedFilesNo() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit", files: ["a.txt": "one\n"])
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"),
                            atomically: true, encoding: .utf8)
        try await configure(fixture, ["status.showUntrackedFiles": "no"])

        let parsed = try await status(fixture)
        XCTAssertFalse(parsed.isClean,
                       "under status.showUntrackedFiles=no a tree with an untracked file reported "
                       + "itself clean")
        XCTAssertTrue(parsed.entries.contains(.init(path: "untracked.txt", staged: nil,
                                                    worktree: .untracked)),
                      "under status.showUntrackedFiles=no the untracked path is missing from the "
                      + "status")
    }

    /// `status.renames=false` and `diff.renames=false` — a staged rename becomes a delete and an
    /// add, which is two rows a panel draws instead of the one the user made.
    ///
    /// What would have to be true for this to fail: `WorkingTreeStatus`'s command line losing
    /// `--find-renames`.
    func testAStagedRenameSurvivesRenameDetectionBeingConfiguredOff() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["carried.txt": "alpha\nbeta\ngamma\ndelta\n"])
        try await fixture.run(["mv", "carried.txt", "moved.txt"])
        try await configure(fixture, ["status.renames": "false", "diff.renames": "false"])

        let parsed = try await status(fixture)
        XCTAssertEqual(parsed.entries.count, 1,
                       "under rename detection configured off the staged rename was reported as "
                       + "more than one entry")
        XCTAssertTrue(parsed.entries.first?.staged == .renamed(from: "carried.txt"),
                      "under rename detection configured off the staged change is not a rename "
                      + "from carried.txt")
        XCTAssertEqual(parsed.entries.first?.path, "moved.txt",
                       "the rename was not reported under its new path")
    }

    // MARK: - the whole hostile configuration at once

    /// Every adverse value in `hostile`, in one repository, read by all three readers.
    ///
    /// The per-setting tests above each pin one command-line option; this one is the class's
    /// floor. It fails if any pin is dropped, and it is the test a future setting is added to
    /// rather than the test a future setting needs a new fixture beside.
    func testEveryReaderIsCorrectUnderTheWholeHostileConfiguration() async throws {
        let (fixture, root, tip) = try await decoratedFixture()
        try await fixture.run(["mv", "a.txt", "moved.txt"])
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"),
                            atomically: true, encoding: .utf8)
        try await configure(fixture, Self.hostile)

        let parsed = try await commits(fixture)
        XCTAssertEqual(Set(parsed.map(\.hash)), [root, tip],
                       "the commit window is wrong under the whole hostile configuration")
        XCTAssertEqual(Set(parsed.first { $0.hash == tip }?.refs ?? []),
                       [GitRef(kind: .branch, name: "sidecar")],
                       "the decorations are wrong under the whole hostile configuration")

        let list = try await changes(fixture, .commitAgainstParent(root))
        XCTAssertEqual(Set(list.map(\.path)), ["a.txt", "b.txt"],
                       "the root commit's changed-file list is wrong under the whole hostile "
                       + "configuration")

        let worktree = try await status(fixture)
        XCTAssertEqual(worktree.entries.count, 2,
                       "the working-tree status did not report exactly the rename and the "
                       + "untracked file under the whole hostile configuration")
        XCTAssertTrue(worktree.entries.contains(.init(path: "moved.txt",
                                                  staged: .renamed(from: "a.txt"), worktree: nil)),
                      "the staged rename is missing under the whole hostile configuration")
        XCTAssertTrue(worktree.entries.contains(.init(path: "untracked.txt", staged: nil,
                                                  worktree: .untracked)),
                      "the untracked path is missing under the whole hostile configuration")
    }

    /// The settings ruled out by measurement change nothing.
    ///
    /// Not a pin but a tripwire: each of these was checked against `git` 2.55.0 and found not to
    /// reach any byte this module parses, which is why none of them costs a command-line option.
    /// If a future `git` changes that, this test names the class rather than a panel drawing a
    /// quietly different answer.
    func testTheSettingsRuledOutByMeasurementChangeNothing() async throws {
        let (fixture, root, _) = try await decoratedFixture()
        try await fixture.run(["mv", "a.txt", "moved.txt"])
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"),
                            atomically: true, encoding: .utf8)

        let before = try await commits(fixture)
        let beforeList = try await changes(fixture, .commitAgainstParent(root))
        let beforeStatus = try await status(fixture)
        try await configure(fixture, Self.ruledOut)

        let after = try await commits(fixture)
        let afterList = try await changes(fixture, .commitAgainstParent(root))
        let afterStatus = try await status(fixture)
        XCTAssertEqual(after, before,
                       "a setting ruled out by measurement changed the commit window")
        XCTAssertEqual(afterList, beforeList,
                       "a setting ruled out by measurement changed the changed-file list")
        XCTAssertEqual(afterStatus, beforeStatus,
                       "a setting ruled out by measurement changed the working-tree status")
        // The floor: three empty answers would be equal to three empty answers.
        XCTAssertEqual(before.count, 2, "the fixture did not build the two commits it describes")
        XCTAssertFalse(beforeList.isEmpty, "the root commit listed no changed file")
        XCTAssertEqual(beforeStatus.entries.count, 2,
                       "the fixture did not build the two working-tree entries it describes")
    }
}
