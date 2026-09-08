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
/// here reads — which is how `log.decorate` and `log.showRoot=false` both reached review as
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
        // `git log`: `%D` prints shortened decorations, which drop the namespace a ref came
        // from — a local branch named `origin/feature` becomes indistinguishable from the
        // remote-tracking one, and a local `feature/x` reads as a remote `feature`'s branch `x`.
        // Adverse in this direction since W7's 2026-09-08 amendment (D52); pinned by
        // `--decorate=full`.
        "log.decorate": "short",
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
        // `git log` and `git show`: on a **signed** commit git prints its signature verdict on
        // stdout ahead of the record, inside no field of the format. `git log`'s record still
        // splits into six fields, so the verdict lands in `GitCommit.hash` and nothing throws;
        // `git show`'s listing gains a line the status parser rejects. Pinned by
        // `--no-show-signature`. R4 ruled this setting out because every fixture here was
        // unsigned — see the R5 record.
        "log.showSignature": "true",
        // `git show`, `git diff` and `git status`: below the limit git skips the exhaustive half
        // of rename detection, so a rename that also edited the file is a delete and an add —
        // what `--find-renames` prevents, through the other door. Pinned by `-l1000` on the diff
        // forms and by `-c diff.renameLimit=1000` on `git status`, which has no such option.
        "diff.renameLimit": "2",
        // The same, through the key `git status` prefers over `diff.renameLimit`.
        "status.renameLimit": "2",
    ]

    /// Settings measured on `git` 2.55.0 to change nothing any reader here parses, kept as a test
    /// so that a future `git` which *starts* honouring one of them fails a named test rather than
    /// changing a panel's answer quietly. The configuration-sensitivity table in the ledger records
    /// why each was ruled out.
    ///
    /// **R5 re-measured every one of these on a fixture that can exhibit them**, which R4's could
    /// not: signed commits, a `.mailmap`, a note, a configured upstream, a subdirectory, an
    /// *inexact* rename and a modified file. Two of R4's eighteen were inert only for want of such
    /// a fixture — `log.showSignature` and `diff.renameLimit` — and both moved to `hostile` above.
    /// The sixteen that remain are inert against a fixture that can make them speak, which is the
    /// difference between a tripwire and a green light (root spec §17.7).
    static let ruledOut: [String: String] = [
        "core.quotePath": "false",          // moot under `-z`, which quotes nothing
        "status.relativePaths": "true",     // porcelain paths are always relative to the root
        "status.aheadBehind": "false",      // porcelain v2 computes `# branch.ab` regardless
        "log.abbrevCommit": "true",         // `%H` is the full object name by construction
        "core.abbrev": "7",                 // the same
        "log.mailmap": "true",              // `%an` is the raw author; `%aN` is the mapped one
        "log.date": "raw",                  // `%at` is a Unix timestamp, not a rendered date
        "format.pretty": "oneline",         // an explicit `--format=` outranks it
        "notes.displayRef": "refs/notes/*", // notes reach a custom format only through `%N`
        "log.diffMerges": "combined",       // an explicit `--first-parent` outranks it
        "diff.algorithm": "minimal",        // numstat counts unchanged on this history
        "diff.noprefix": "true",            // no prefix is printed by `--name-status`/`--numstat`
        "diff.relative": "true",            // the invocations run at the repository root
        "diff.external": "/bin/false",      // `--name-status`/`--numstat` never call it
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
    /// a tag, a local branch and a **remote-tracking** branch on the root commit, and a second
    /// local branch — deliberately **slashed** — on the tip.
    ///
    /// The remote-tracking ref and the slashed name are what make this fixture able to *exhibit*
    /// `log.decorate=short` now that `--decorate=full` is the pin (tracker 123's lesson). A
    /// tripwire over a form is only worth its name if the repository under it carries the names
    /// that form cannot express: under the shortened form `origin/feature` is what a
    /// remote-tracking branch and a local branch of that name both print, which is the ambiguity
    /// tracker 115 recorded and `--decorate=full` closed.
    private func decoratedFixture() async throws -> (GitFixture, root: String, tip: String) {
        let fixture = try await GitFixture(tree)
        let root = try await fixture.commit(message: "the first commit",
                                            files: ["a.txt": "one\n", "b.txt": "two\n"])
        try await fixture.tag("v0.1")
        try await fixture.publishAsRemoteBranch("main", named: "feature")
        try await fixture.branch("sidecar/one", from: root)
        let tip = try await fixture.commit(message: "the sidecar commit",
                                           files: ["c.txt": "three\n"])
        try await fixture.checkout("main")
        return (fixture, root, tip)
    }

    // MARK: - one adverse setting at a time

    /// `log.decorate=short` — the R4 reviewer's first instance, in the direction W7's 2026-09-08
    /// amendment turned it (D52). The parser strips full ref paths, so a user holding the
    /// shortened form is the one who loses the namespace.
    ///
    /// What would have to be true for this to fail: `GitLog`'s command line losing
    /// `--decorate=full`, or a `git` in which that option stops overriding the configuration.
    func testDecorationsAreReadCorrectlyUnderLogDecorateShort() async throws {
        let (fixture, root, tip) = try await decoratedFixture()
        try await configure(fixture, ["log.decorate": "short"])

        let parsed = try await commits(fixture)
        let refs = Dictionary(uniqueKeysWithValues: parsed.map { ($0.hash, Set($0.refs)) })

        XCTAssertEqual(refs[root], [GitRef(kind: .head, name: "HEAD"),
                                    GitRef(kind: .branch, name: "main"),
                                    GitRef(kind: .tag, name: "v0.1"),
                                    GitRef(kind: .remoteBranch(remote: "origin"), name: "feature")],
                       "under log.decorate=short the root commit's decorations were not read as an "
                       + "attached HEAD, the local branch main, the tag v0.1 and the "
                       + "remote-tracking branch origin/feature")
        XCTAssertEqual(refs[tip], [GitRef(kind: .branch, name: "sidecar/one")],
                       "under log.decorate=short the slashed branch sidecar/one was not read as a "
                       + "local branch")
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

    // MARK: - the R5 wave: fixtures that can exhibit the condition a setting acts on

    /// Stages an **inexact** rename together with enough unpaired destinations to exceed a small
    /// rename limit.
    ///
    /// The count is what makes the shape: `diff.renameLimit` caps the *sources times destinations*
    /// the exhaustive pass may consider, so the filler paths have to be added in the same change
    /// as the rename. Committed beforehand they are not destinations at all, the pairing is one
    /// against one, and no limit above one is ever reached — a fixture that looks like this one
    /// and pins nothing.
    private func stageInexactRenameOverTheLimit(_ fixture: GitFixture) async throws {
        try await fixture.renameEditing("carried.txt", to: "moved.txt",
                                        contents: "alpha\nbeta\ngamma\ndelta\nzeta\n")
        for index in 1...6 {
            try fixture.write("filler\(index).txt", bytes: Data("filler\n".utf8))
        }
        try await fixture.run(["add", "-A"])
    }

    /// True when `status` is a rename from `path`, whatever similarity score git assigned it.
    /// An *inexact* rename's score depends on the content edit, which is not what any of these
    /// tests is asserting — only that git paired the two paths at all.
    private static func isRename(_ status: FileChange.Status?, from path: String) -> Bool {
        guard case .renamed(let from, _) = status else { return false }
        return from == path
    }

    /// A **signed** two-commit history, or nil when the machine has no `ssh-keygen`.
    ///
    /// R4's suite could not have caught `log.showSignature` with any assertion, because every
    /// fixture it built was unsigned and the setting only speaks over a signature. That is root
    /// spec §17.7 wearing a new hat: the tripwire was green because the fixture could not make it
    /// red. Signing is therefore fixture machinery here, not a feature under test.
    ///
    /// The key is ephemeral, generated per fixture inside the `TempTree` and beside the
    /// repository, and the configuration naming it is repository-local. Nothing reads or writes
    /// the machine's `~/.ssh` or its git configuration.
    private func signedFixture() async throws -> (GitFixture, root: String, tip: String)? {
        let fixture = try await GitFixture(tree)
        guard try await fixture.enableSSHSigning() else { return nil }
        let root = try await fixture.commit(message: "the first commit",
                                            files: ["a.txt": "one\n", "b.txt": "two\n"])
        let tip = try await fixture.commit(message: "the second commit",
                                           files: ["c.txt": "three\n"])
        return (fixture, root, tip)
    }

    /// `log.showSignature=true` over a signed commit — the R5 reviewer's instance, and the worst
    /// shape of the class: nothing throws.
    ///
    /// Measured on `git` 2.55.0: git prints its verdict for each commit on **stdout**, ahead of
    /// the record, and a custom `--format` does not suppress it. The record still splits into
    /// exactly six fields, so `GitLog.parse`'s field-count guard never fires; the verdict line is
    /// carried into `GitCommit.hash` instead, where it breaks every parent match and every lookup.
    ///
    /// What would have to be true for this to fail: `GitLog`'s command line losing
    /// `--no-show-signature`. Because the corruption is silent, the assertions are written to
    /// catch it in the only place it shows — the *shape* of the hash. A test that compared the
    /// window's hashes against the fixture's own would already have caught this one, so this test
    /// asserts the two independent things a downstream consumer relies on and a contaminated hash
    /// breaks: that every hash is a 40-character hex object name, and that the tip's recorded
    /// parent resolves to a commit actually in the window.
    func testASignedCommitWindowIsNotContaminatedByLogShowSignature() async throws {
        guard let (fixture, root, tip) = try await signedFixture() else {
            throw XCTSkip("ssh-keygen is not on PATH, so no signed fixture can be built")
        }
        try await configure(fixture, ["log.showSignature": "true"])

        // `XCTAssertTrue` over the comparison rather than `XCTAssertEqual`: a *contaminated* hash
        // is git's signature verdict with the object name stuck to it, and printing it into a test
        // log would print the signing key's fingerprint (§6.3, §11). The message is authored here
        // and names the count instead.
        let parsed = try await commits(fixture)
        XCTAssertTrue(Set(parsed.map(\.hash)) == [root, tip],
                      "under log.showSignature=true the signed window's \(parsed.count) hashes are "
                      + "not the two commits the fixture made")
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(parsed.allSatisfy { $0.hash.count == 40
                          && CharacterSet(charactersIn: $0.hash).isSubset(of: hex) },
                      "under log.showSignature=true a parsed hash is not a 40-character hex "
                      + "object name — git's signature verdict was read as part of it")
        let byHash = Dictionary(uniqueKeysWithValues: parsed.map { ($0.hash, $0) })
        XCTAssertTrue(byHash[tip]?.parents == [root],
                      "under log.showSignature=true the tip's parent is not the root commit")
        XCTAssertNotNil(byHash[tip]?.parents.first.flatMap { byHash[$0] },
                        "under log.showSignature=true the tip's parent does not resolve to a "
                        + "commit in the window, so parent matching is broken")
    }

    /// The same setting against `GitDiff`, where it is loud rather than silent: the verdict line
    /// reaches the `--name-status` parser as a status code and is rejected.
    ///
    /// What would have to be true for this to fail: `.commitAgainstParent`'s invocation losing
    /// `--no-show-signature`.
    func testASignedCommitsTreeIsStillListedUnderLogShowSignature() async throws {
        guard let (fixture, root, _) = try await signedFixture() else {
            throw XCTSkip("ssh-keygen is not on PATH, so no signed fixture can be built")
        }
        try await configure(fixture, ["log.showSignature": "true"])

        let list = try await changes(fixture, .commitAgainstParent(root))
        XCTAssertEqual(Set(list.map(\.path)), ["a.txt", "b.txt"],
                       "under log.showSignature=true the signed root commit's paths are not the "
                       + "two committed")
        XCTAssertTrue(list.allSatisfy { $0.status == .added },
                      "the signed root commit's whole tree is additions and was not reported as such")
    }

    /// A low `diff.renameLimit` / `status.renameLimit` — R5's re-check of R4's ruled-out list, and
    /// the second setting that was inert only because the fixture was too plain.
    ///
    /// R4 ruled `diff.renameLimit` out on the true observation that an **exact** rename is paired
    /// before the limit applies. A rename that also *edits* the file is paired only by the
    /// exhaustive pass the limit cuts off, and that pass is the one `--find-renames` cannot restore
    /// on its own. Below the limit the change comes back as a delete and an add: two rows for one
    /// change, the same wrong answer `--find-renames` exists to prevent.
    ///
    /// What would have to be true for this to fail: `GitDiff`'s tail losing `-l1000`, or
    /// `WorkingTreeStatus`'s vector losing its two `-c` overrides.
    func testAnInexactRenameSurvivesALowRenameLimit() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["carried.txt": "alpha\nbeta\ngamma\ndelta\nepsilon\n"])
        try await stageInexactRenameOverTheLimit(fixture)
        try await configure(fixture, ["diff.renameLimit": "2", "status.renameLimit": "2"])

        let worktree = try await status(fixture)
        XCTAssertEqual(worktree.entries.count, 7,
                       "under a low rename limit the staged change was not the six additions and "
                       + "the one rename the fixture describes — a rename split into a delete and "
                       + "an add is eight")
        XCTAssertTrue(worktree.entries.contains(.init(path: "moved.txt",
                                                  staged: .renamed(from: "carried.txt"),
                                                  worktree: nil)),
                      "under a low rename limit the staged change is not a rename from carried.txt")

        let committed = try await fixture.commit(message: "the second commit")
        let list = try await changes(fixture, .commitAgainstParent(committed))
        XCTAssertEqual(list.count, 7,
                       "under a low rename limit the commit listed the inexact rename as a delete "
                       + "and an add")
        let renames = list.filter { Self.isRename($0.status, from: "carried.txt") }
        XCTAssertEqual(renames.count, 1,
                       "under a low rename limit the commit's inexact rename was not paired")
        XCTAssertEqual(renames.first?.path, "moved.txt",
                       "the inexact rename was not reported under its new path")
    }

    /// Every adverse value in `hostile` at once, over a **signed** repository carrying an inexact
    /// rename — the floor of the class as R5 leaves it.
    ///
    /// The sibling below runs the same dictionary over the plain fixture and passes whatever
    /// happens to the two settings only a signed, inexactly-renamed repository can exhibit. This
    /// one is the version that can go red for them.
    func testEveryReaderIsCorrectUnderTheWholeHostileConfigurationOnASignedRepository() async throws {
        let fixture = try await GitFixture(tree)
        guard try await fixture.enableSSHSigning() else {
            throw XCTSkip("ssh-keygen is not on PATH, so no signed fixture can be built")
        }
        let root = try await fixture.commit(message: "the first commit",
                                            files: ["carried.txt": "alpha\nbeta\ngamma\ndelta\nepsilon\n"])
        try await stageInexactRenameOverTheLimit(fixture)
        let tip = try await fixture.commit(message: "the second commit")
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"),
                            atomically: true, encoding: .utf8)
        try await configure(fixture, Self.hostile)

        let parsed = try await commits(fixture)
        XCTAssertTrue(Set(parsed.map(\.hash)) == [root, tip],
                      "the signed commit window's \(parsed.count) hashes are wrong under the whole "
                      + "hostile configuration")

        let list = try await changes(fixture, .commitAgainstParent(tip))
        XCTAssertEqual(list.count, 7,
                       "the signed tip's changed-file list is not the six additions and the one "
                       + "rename the fixture describes, under the whole hostile configuration")
        XCTAssertEqual(list.filter { Self.isRename($0.status, from: "carried.txt") }.count, 1,
                       "the inexact rename is missing under the whole hostile configuration")

        let worktree = try await status(fixture)
        XCTAssertEqual(worktree.entries.count, 1,
                       "the working-tree status did not report exactly the untracked file under "
                       + "the whole hostile configuration")
        XCTAssertTrue(worktree.entries.contains(.init(path: "untracked.txt", staged: nil,
                                                  worktree: .untracked)),
                      "the untracked path is missing under the whole hostile configuration")
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
                       [GitRef(kind: .branch, name: "sidecar/one")],
                       "the tip's decorations are wrong under the whole hostile configuration")
        XCTAssertEqual(Set(parsed.first { $0.hash == root }?.refs ?? []),
                       [GitRef(kind: .head, name: "HEAD"), GitRef(kind: .branch, name: "main"),
                        GitRef(kind: .tag, name: "v0.1"),
                        GitRef(kind: .remoteBranch(remote: "origin"), name: "feature")],
                       "the root commit's decorations are wrong under the whole hostile "
                       + "configuration")

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

    /// The settings ruled out by measurement change nothing — over a fixture that can make each
    /// of them speak.
    ///
    /// Not a pin but a tripwire, and R5's re-examination of it is the reason that wave exists. A
    /// tripwire is only worth its name if the fixture underneath can exhibit the condition each
    /// setting acts on; R4's could not, for two of the eighteen, and both turned out to be live
    /// defects. So this fixture is built to be exhibitable rather than convenient:
    ///
    /// - **signed commits**, best effort, for `log.showSignature` — now pinned, and the remaining
    ///   `log.*` and `notes.*` entries are re-measured over signatures here rather than assumed
    ///   inert over their absence. Signing is skipped silently when the machine has no
    ///   `ssh-keygen`, because the settings that need it have their own tests above which skip
    ///   with a named reason;
    /// - an **inexact** rename with enough other paths to exceed a small limit, for
    ///   `diff.renameLimit` — also now pinned — and for `diff.algorithm`, which has nothing to
    ///   choose between on a history of pure additions;
    /// - a **modified** file, for the same reason;
    /// - a `.mailmap` that actually maps the fixture's author, for `log.mailmap`;
    /// - a **note** on the tip, for `notes.displayRef`;
    /// - a configured **upstream**, for `status.aheadBehind`: with no upstream `git status` prints
    ///   no `# branch.ab` header at all, so the setting reads inert for want of the header;
    /// - a path in a **subdirectory**, for `status.relativePaths` and `diff.relative`.
    ///
    /// If a future `git` starts honouring one of the sixteen, this test names the class rather
    /// than a panel drawing a quietly different answer.
    func testTheSettingsRuledOutByMeasurementChangeNothing() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.enableSSHSigning()
        let files = ["carried.txt": "alpha\nbeta\ngamma\ndelta\nepsilon\n",
                     "edited.txt": "before\n",
                     "sub/nested.txt": "nested\n",
                     ".mailmap": "Mapped Name <mapped@example.invalid> "
                               + "\(GitFixture.authorName) <\(GitFixture.authorEmail)>\n"]
        let root = try await fixture.commit(message: "the first commit", files: files)
        try await stageInexactRenameOverTheLimit(fixture)
        let tip = try await fixture.commit(message: "the second commit",
                                           files: ["edited.txt": "before\nafter\n"])
        try await fixture.tag("v0.1")
        try await fixture.note("a note on the tip", on: tip)
        try await fixture.publishToUpstream()
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"),
                            atomically: true, encoding: .utf8)

        let before = try await commits(fixture)
        let beforeList = try await changes(fixture, .commitAgainstParent(tip))
        let beforeStatus = try await status(fixture)
        try await configure(fixture, Self.ruledOut)

        let after = try await commits(fixture)
        let afterList = try await changes(fixture, .commitAgainstParent(tip))
        let afterStatus = try await status(fixture)
        XCTAssertEqual(after, before,
                       "a setting ruled out by measurement changed the commit window")
        XCTAssertEqual(afterList, beforeList,
                       "a setting ruled out by measurement changed the changed-file list")
        XCTAssertEqual(afterStatus, beforeStatus,
                       "a setting ruled out by measurement changed the working-tree status")
        // The floor: three empty answers would be equal to three empty answers. Each clause also
        // says that the shape the enriched fixture was built for is actually present, because a
        // fixture that quietly failed to build one of them is the failure this test now exists to
        // rule out.
        XCTAssertTrue(Set(before.map(\.hash)).isSuperset(of: [root, tip]),
                      "the fixture did not build the two commits it describes")
        XCTAssertTrue(before.contains { $0.authorName == GitFixture.authorName },
                      "the mailmap fixture's raw author name is missing from the window")
        XCTAssertTrue(beforeList.contains { Self.isRename($0.status, from: "carried.txt") },
                      "the tip did not carry the inexact rename the fixture describes")
        XCTAssertTrue(beforeList.contains { $0.path == "edited.txt" && $0.status == .modified },
                      "the tip did not carry the modification the fixture describes")
        XCTAssertNotNil(beforeStatus.ahead,
                        "no upstream was configured, so no ahead/behind header was produced")
        XCTAssertTrue(beforeStatus.entries.contains(.init(path: "untracked.txt", staged: nil,
                                                     worktree: .untracked)),
                      "the untracked path the fixture describes is missing")
    }
}
