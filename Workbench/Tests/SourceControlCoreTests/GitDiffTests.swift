import Foundation
import XCTest
import AfleetCore
@testable import SourceControlCore

/// The changed-file list and blob access, parsed off real repositories the tests build.
///
/// **What this milestone is, and is not** (ledger D8): a changed-file parser plus a way to fetch
/// either side's bytes — not a unified-diff hunk parser. Contract W4's Monaco bridge takes two
/// whole texts, original and modified, so a patch parser would have no consumer.
///
/// **The measured shapes, and why they are written down here.** The architect's ruling at the
/// gate binds every parser in this leaf: each probe-derived parsing fact is cited in the test
/// that depends on it, naming the `git` version it was measured on and the shape that was
/// measured, so a future `git` whose bytes differ fails a *named* test instead of silently
/// mis-joining. Measured with **`git` 2.55.0** on 2026-09-07 and re-measured on 2026-09-08 in
/// throwaway repositories (`LC_ALL=C`, global and system configuration disabled), NULs shown as
/// `^@`:
///
///     $ git show --format= --numstat --name-status -z --find-renames HEAD
///     M^@a.txt^@R100^@b.bin^@c.bin^@D^@d.txt^@A^@n.txt^@
///
///     $ git show --format= --numstat -z --find-renames HEAD
///     1	0	a.txt^@-	-	^@b.bin^@c.bin^@0	1	d.txt^@1	0	n.txt^@
///
/// Two facts follow, and each has a test of its own below:
///
/// 1. `--name-status` and `--numstat` given to the *same* command do not both print — the last
///    one wins, and no numstat section appears at all. So the changed-file list needs **two**
///    invocations joined by path, which is the whole shape of `GitDiff.changes`.
///    (`testNameStatusAndNumstatGivenTogetherDoNotBothPrint`.)
/// 2. Under `-z`, a rename in `--numstat` puts an **empty** path field between the counts and the
///    two paths, so a parser reading one path per record silently mis-joins every rename.
///    (`testNumstatPutsAnEmptyPathFieldBeforeARenamesTwoPaths`.) `-` for both counts is how a
///    binary file is reported, which is where `isBinary` comes from.
///
/// For contrast, `--name-status -z` is `<status>\0<path>\0`, and for a rename
/// `R<score>\0<old>\0<new>\0` — two paths, old first.
///
/// A third shape was measured on 2026-09-08 and decides a strictness question rather than a
/// parse: in a tree with an unresolved merge conflict, `git diff HEAD --name-status -z` reports
/// the conflicted path as an ordinary `M`, never as `U`. `FileChange.Status` therefore needs no
/// unmerged case for this command, and an unfamiliar status letter can be rejected outright.
///
/// **Assertion style**, as in the sibling suites and for the same reason: every repository here
/// lives under the system temporary directory, whose path on macOS contains the machine
/// account's hash (§6.3, §11). Nothing that transitively reaches a runtime path or an
/// environment is compared with `XCTAssertEqual`; counts and repository-relative paths are, and
/// those are authored in this file.
final class GitDiffTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    /// Invented bytes that are not valid UTF-8, so that git classifies the file as binary and the
    /// blob round-trip proves the runner carries bytes rather than a lossy string.
    private static let binaryBefore = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x0A])
    private static let binaryAfter = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0x0A])

    private func changes(_ fixture: GitFixture, _ base: DiffRef.Base) async throws -> [FileChange] {
        try await GitDiff.changes(root: fixture.root, base: base,
                                  environment: fixture.environment, runner: ToolRunner())
    }

    // MARK: - the central test: five change kinds in one commit

    /// Builds one commit carrying an added, a modified, a deleted, a renamed and a binary file at
    /// once, and compares the whole changed-file list as a set **in both directions** over a
    /// non-emptiness floor, so that neither a missing change nor an invented one passes.
    ///
    /// The rename's `from` path and score are named, because the join in `GitDiff.changes` is
    /// exactly where measured fact 2 bites: a parser that read one path per numstat record would
    /// attach the *old* path's record to the new path and every count in this list would shift by
    /// one. The binary file's counts are asserted nil with `isBinary` true, which is the other
    /// half of that record.
    func testOneCommitCarriesAddedModifiedDeletedRenamedAndBinaryChanges() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.write("b.bin", bytes: Self.binaryBefore)
        _ = try await fixture.commit(message: "first",
                                     files: ["a.txt": "one\n", "d.txt": "gone\n", "r.txt": "moved\n"])

        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))
        try fixture.write("b.bin", bytes: Self.binaryAfter)
        try await fixture.run(["rm", "-q", "d.txt"])
        try await fixture.run(["mv", "r.txt", "moved.txt"])
        let head = try await fixture.commit(message: "second", files: ["n.txt": "new\n"])

        let list = try await changes(fixture, .commitAgainstParent(head))
        XCTAssertGreaterThan(list.count, 0, "the changed-file list was empty")
        XCTAssertEqual(list.count, 5, "the commit changed five paths")

        let expected: Set<FileChange> = [
            FileChange(path: "a.txt", status: .modified, additions: 1, deletions: 0, isBinary: false),
            FileChange(path: "b.bin", status: .modified, additions: nil, deletions: nil, isBinary: true),
            FileChange(path: "d.txt", status: .deleted, additions: 0, deletions: 1, isBinary: false),
            FileChange(path: "moved.txt", status: .renamed(from: "r.txt", score: 100),
                       additions: 0, deletions: 0, isBinary: false),
            FileChange(path: "n.txt", status: .added, additions: 1, deletions: 0, isBinary: false),
        ]
        let actual = Set(list)
        XCTAssertEqual(actual, expected)
        // Both directions, named, so a failure says which change was missing and which was
        // invented rather than printing two sets and leaving the reader to diff them.
        XCTAssertTrue(expected.subtracting(actual).isEmpty,
                      "changes the commit made that the list omits: "
                      + "\(expected.subtracting(actual).map(\.path).sorted())")
        XCTAssertTrue(actual.subtracting(expected).isEmpty,
                      "changes the list reports that the commit did not make: "
                      + "\(actual.subtracting(expected).map(\.path).sorted())")

        // The rename, named on its own: a set comparison that failed would not say which half of
        // the pair was wrong.
        let renamed = try XCTUnwrap(list.first { $0.path == "moved.txt" },
                                    "the renamed path is absent from the list")
        XCTAssertEqual(renamed.status, .renamed(from: "r.txt", score: 100))
        // The binary, named on its own, for the same reason.
        let binary = try XCTUnwrap(list.first { $0.path == "b.bin" },
                                   "the binary path is absent from the list")
        XCTAssertTrue(binary.isBinary, "a file git reported with `-` counts was not marked binary")
        XCTAssertNil(binary.additions, "a binary file was given an addition count")
        XCTAssertNil(binary.deletions, "a binary file was given a deletion count")
    }

    // MARK: - what `-z` buys

    /// A path carrying a space and a non-ASCII character survives both invocations and the join
    /// intact. Without `-z` git C-quotes it — `"caf\303\251 notes/na\303\257ve file.txt"` — and
    /// every assertion below fails on a path that is a quoted rendering rather than a path
    /// (ledger D7). The rename is deliberate: the awkward path travels through the numstat
    /// record whose path field is empty, which is the join's hardest case.
    func testAPathWithASpaceAndNonASCIISurvives() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "first", files: ["café notes/naïve file.txt": "one\n"])
        try await fixture.run(["mv", "café notes/naïve file.txt", "café notes/renamed é.txt"])
        let head = try await fixture.commit(message: "second")

        let list = try await changes(fixture, .commitAgainstParent(head))
        XCTAssertGreaterThan(list.count, 0, "the changed-file list was empty")
        XCTAssertEqual(list.count, 1, "the commit renamed exactly one path")
        XCTAssertEqual(list[0].path, "café notes/renamed é.txt")
        XCTAssertEqual(list[0].status, .renamed(from: "café notes/naïve file.txt", score: 100))
    }

    /// A **binary** rename: the one record where both measured facts meet, because its numstat
    /// line is `-\t-\t\0<old>\0<new>\0` — dashes for the counts *and* the empty path field.
    /// Measured on `git` 2.55.0. A parser that read one path per record would report the change
    /// under the old path with the following record's counts.
    func testABinaryRenameJoinsTheEmptyNumstatPathField() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.write("b.bin", bytes: Self.binaryBefore)
        _ = try await fixture.commit(message: "first")
        try await fixture.run(["mv", "b.bin", "c.bin"])
        let head = try await fixture.commit(message: "second", files: ["tail.txt": "tail\n"])

        let list = try await changes(fixture, .commitAgainstParent(head))
        XCTAssertGreaterThan(list.count, 0, "the changed-file list was empty")
        XCTAssertEqual(list.count, 2, "the commit renamed one binary and added one text file")
        let renamed = try XCTUnwrap(list.first { $0.path == "c.bin" },
                                    "the renamed binary is absent from the list")
        XCTAssertEqual(renamed.status, .renamed(from: "b.bin", score: 100))
        XCTAssertTrue(renamed.isBinary)
        XCTAssertNil(renamed.additions)
        XCTAssertNil(renamed.deletions)
        // The record that follows the rename in the numstat stream: if the empty path field were
        // read as a path, this file's counts would land on the rename instead.
        let added = try XCTUnwrap(list.first { $0.path == "tail.txt" },
                                  "the added path is absent from the list")
        XCTAssertEqual(added.additions, 1)
        XCTAssertEqual(added.deletions, 0)
        XCTAssertFalse(added.isBinary)
    }

    // MARK: - the three `DiffRef.Base` cases

    /// `.workingTreeAgainstHEAD` runs `git diff HEAD`: the uncommitted edit is listed and the
    /// committed one is not.
    func testWorkingTreeAgainstHeadListsOnlyUncommittedChanges() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "first", files: ["a.txt": "one\n", "b.txt": "one\n"])
        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))

        let list = try await changes(fixture, .workingTreeAgainstHEAD)
        XCTAssertGreaterThan(list.count, 0, "the changed-file list was empty")
        XCTAssertEqual(Set(list.map(\.path)), ["a.txt"])
        XCTAssertEqual(list[0].status, .modified)
        XCTAssertEqual(list[0].additions, 1)
        XCTAssertEqual(list[0].deletions, 0)
    }

    /// `.commit(h)` runs `git diff <h>`: the working tree against that commit, so it spans every
    /// commit since `h` **and** the uncommitted edit. Both are asserted, because a base that
    /// silently meant `HEAD` would still pass on the uncommitted half alone.
    func testCommitBaseDiffsTheWorkingTreeAgainstThatCommit() async throws {
        let fixture = try await GitFixture(tree)
        let first = try await fixture.commit(message: "first", files: ["a.txt": "one\n"])
        _ = try await fixture.commit(message: "second", files: ["b.txt": "two\n"])
        try fixture.write("c.txt", bytes: Data("three\n".utf8))
        try await fixture.run(["add", "c.txt"])

        let list = try await changes(fixture, .commit(first))
        XCTAssertGreaterThan(list.count, 0, "the changed-file list was empty")
        XCTAssertEqual(Set(list.map(\.path)), ["b.txt", "c.txt"])
        XCTAssertTrue(list.allSatisfy { $0.status == .added },
                      "both paths were created after the base commit")
    }

    /// `.commitAgainstParent(h)` runs `git show --format= <h>` rather than `git diff <h>^ <h>`,
    /// and this is the case that decides it: a **root commit** has no `<h>^`, so the parent form
    /// would fail on the first commit of every repository. `git show` lists the whole tree as
    /// added instead.
    func testCommitAgainstParentOnTheRootCommitListsTheWholeTreeAsAdded() async throws {
        let fixture = try await GitFixture(tree)
        let root = try await fixture.commit(message: "first",
                                            files: ["a.txt": "one\n", "sub/b.txt": "two\n"])
        _ = try await fixture.commit(message: "second", files: ["c.txt": "three\n"])

        let list = try await changes(fixture, .commitAgainstParent(root))
        XCTAssertGreaterThan(list.count, 0, "the root commit's changed-file list was empty")
        XCTAssertEqual(Set(list.map(\.path)), ["a.txt", "sub/b.txt"])
        XCTAssertTrue(list.allSatisfy { $0.status == .added },
                      "a root commit adds every path it contains")
        XCTAssertTrue(list.allSatisfy { $0.additions == 1 && $0.deletions == 0 },
                      "each file in the root commit is one added line")
    }

    // MARK: - blob access, the other half of D8

    /// `blob` round-trips the exact bytes at a revision, binary included, and the working-tree
    /// read returns the other side. Together they are what contract W4's Monaco bridge needs:
    /// two whole texts, never a patch.
    func testBlobRoundTripsBytesAtARevisionAndTheWorkingTreeReadReturnsTheOtherSide() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.write("b.bin", bytes: Self.binaryBefore)
        let first = try await fixture.commit(message: "first", files: ["a.txt": "one\n"])
        try fixture.write("b.bin", bytes: Self.binaryAfter)
        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))

        let text = try await GitDiff.blob(root: fixture.root, rev: first, path: "a.txt",
                                          environment: fixture.environment, runner: ToolRunner())
        XCTAssertEqual(text, Data("one\n".utf8))
        let binary = try await GitDiff.blob(root: fixture.root, rev: first, path: "b.bin",
                                            environment: fixture.environment, runner: ToolRunner())
        XCTAssertEqual(binary.count, Self.binaryBefore.count)
        XCTAssertEqual(binary, Self.binaryBefore,
                       "the committed bytes did not survive the round trip")
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "b.bin"),
                       Self.binaryAfter)
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "a.txt"),
                       Data("one\ntwo\n".utf8))
    }

    /// A revision that does not carry the path is a `.commandFailed` the panel renders (§10, D3),
    /// never an exception crossing into the conversation and never empty `Data` mistaken for an
    /// empty file.
    func testBlobAtARevisionThatDoesNotCarryThePathFails() async throws {
        let fixture = try await GitFixture(tree)
        let first = try await fixture.commit(message: "first", files: ["a.txt": "one\n"])
        do {
            _ = try await GitDiff.blob(root: fixture.root, rev: first, path: "absent.txt",
                                       environment: fixture.environment, runner: ToolRunner())
            XCTFail("a missing path at a revision returned bytes")
        } catch let error as ToolError {
            guard case .commandFailed(let tool, let code, _) = error else {
                return XCTFail("the failure was not a .commandFailed")
            }
            XCTAssertEqual(tool, .git)
            XCTAssertNotEqual(code, 0)
        }
    }

    // MARK: - the two measured facts, each pinned by a test of its own

    /// **Measured fact 1, `git` 2.55.0.** `--name-status` and `--numstat` given to the same
    /// command do not both print: the last option wins and no section of the other appears at
    /// all. This is the whole reason `GitDiff.changes` issues two invocations and joins them, so
    /// a `git` that started printing both — or that flipped which one wins — must fail here
    /// rather than mis-joining somewhere downstream.
    func testNameStatusAndNumstatGivenTogetherDoNotBothPrint() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "first", files: ["a.txt": "one\n"])
        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))
        _ = try await fixture.commit(message: "second")

        let common = ["show", "--format=", "-z", "--find-renames", "HEAD"]
        let both = try await fixture.run(["show", "--format=", "--numstat", "--name-status",
                                          "-z", "--find-renames", "HEAD"]).stdout
        let nameStatusOnly = try await fixture.run(common + ["--name-status"]).stdout
        let numstatOnly = try await fixture.run(common + ["--numstat"]).stdout

        XCTAssertGreaterThan(nameStatusOnly.count, 0, "the name-status listing was empty")
        XCTAssertGreaterThan(numstatOnly.count, 0, "the numstat listing was empty")
        XCTAssertNotEqual(nameStatusOnly, numstatOnly,
                          "the two listings are indistinguishable, so this test proves nothing")
        XCTAssertEqual(both, nameStatusOnly,
                       "the last of --numstat and --name-status no longer wins")
        XCTAssertNotEqual(both, numstatOnly)
        // And the consequence, stated as a parse: the combined output holds no counts at all.
        let joined = try GitDiff.parseNameStatus(both)
        XCTAssertEqual(joined.count, 1)
        XCTAssertThrowsError(try GitDiff.parseNumstat(both),
                             "the combined output parsed as numstat, so it did carry counts")
    }

    /// **Measured fact 2, `git` 2.55.0.** Under `-z`, a rename in `--numstat` prints
    /// `<adds>\t<dels>\t\0<old>\0<new>\0` — the path field of the record is *empty* and two path
    /// fields follow. The raw field layout is asserted here rather than only its parsed effect,
    /// so a git that dropped the empty field fails a test that names the byte shape.
    func testNumstatPutsAnEmptyPathFieldBeforeARenamesTwoPaths() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "first", files: ["r.txt": "one\n"])
        try await fixture.run(["mv", "r.txt", "moved.txt"])
        _ = try await fixture.commit(message: "second", files: ["n.txt": "new\n"])

        let bytes = try await fixture.run(["show", "--format=", "--numstat", "-z",
                                           "--find-renames", "HEAD"]).stdout
        let fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // Four fields and the empty tail after the final terminator: the rename's counts record
        // with its empty path, the old path, the new path, then the added file's whole record.
        XCTAssertGreaterThan(fields.count, 0, "the numstat listing produced no fields")
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields[0], "0\t0\t", "the rename's counts record did not end with an empty path field")
        XCTAssertEqual(fields[1], "r.txt", "the rename's original path is not the field after the counts")
        XCTAssertEqual(fields[2], "moved.txt", "the rename's new path is not the second path field")
        XCTAssertEqual(fields[3], "1\t0\tn.txt")

        let parsed = try GitDiff.parseNumstat(bytes)
        XCTAssertGreaterThan(parsed.count, 0, "the numstat parse produced nothing")
        XCTAssertEqual(parsed.count, 2, "three path fields were read as three records")
        XCTAssertEqual(parsed[0].0, "moved.txt", "a rename is reported under its new path")
        XCTAssertEqual(parsed[0].1, 0)
        XCTAssertEqual(parsed[0].2, 0)
        XCTAssertEqual(parsed[1].0, "n.txt")
        XCTAssertEqual(parsed[1].1, 1)
    }

    // MARK: - rejection rather than silent skipping

    /// Malformed input throws `.decodeFailed` and is never skipped. A parser that dropped the
    /// record a test exists to compare would make that test unfalsifiable, which is the failure
    /// mode §17.7 names.
    func testMalformedRecordsAreRejectedRatherThanSkipped() throws {
        let bad: [(String, Data)] = [
            ("a status letter this format does not define", Data("Z\0a.txt\0".utf8)),
            ("a status field with no path after it", Data("M\0".utf8)),
            ("a rename with only one path field", Data("R100\0a.txt\0".utf8)),
            ("a rename whose score is not a number", Data("Rxx\0a.txt\0b.txt\0".utf8)),
        ]
        for (name, bytes) in bad {
            XCTAssertThrowsError(try GitDiff.parseNameStatus(bytes), name) { error in
                guard case ToolError.decodeFailed = error else {
                    return XCTFail("\(name) did not throw .decodeFailed")
                }
            }
        }
        let badCounts: [(String, Data)] = [
            ("a record with no tab-separated counts", Data("a.txt\0".utf8)),
            ("a record with one count only", Data("1\ta.txt\0".utf8)),
            ("counts that are neither numbers nor dashes", Data("x\ty\ta.txt\0".utf8)),
            ("an empty path field with only one path after it", Data("1\t0\t\0a.txt\0".utf8)),
        ]
        for (name, bytes) in badCounts {
            XCTAssertThrowsError(try GitDiff.parseNumstat(bytes), name) { error in
                guard case ToolError.decodeFailed = error else {
                    return XCTFail("\(name) did not throw .decodeFailed")
                }
            }
        }
        // The well-formed counterpart of each, so the assertions above cannot be passing because
        // the parser rejects everything.
        XCTAssertEqual(try GitDiff.parseNameStatus(Data("M\0a.txt\0".utf8)).count, 1)
        XCTAssertEqual(try GitDiff.parseNumstat(Data("1\t0\ta.txt\0".utf8)).count, 1)
    }

    /// The join itself. Two invocations can only be joined by path, so a path in one listing and
    /// not the other is an inconsistency between two reads of the same repository — reported,
    /// never papered over with a change carrying no counts, which is indistinguishable from a
    /// binary file.
    func testAJoinWhoseTwoListingsDisagreeIsRejected() throws {
        XCTAssertThrowsError(try GitDiff.join(nameStatus: [("a.txt", .modified)], numstat: [])) { error in
            guard case ToolError.decodeFailed = error else {
                return XCTFail("a name-status path missing from numstat did not throw .decodeFailed")
            }
        }
        XCTAssertThrowsError(try GitDiff.join(nameStatus: [], numstat: [("a.txt", 1, 0)])) { error in
            guard case ToolError.decodeFailed = error else {
                return XCTFail("a numstat path missing from name-status did not throw .decodeFailed")
            }
        }
        // The agreeing case, so the two assertions above are not passing on a join that always
        // throws.
        let joined = try GitDiff.join(nameStatus: [("a.txt", .modified), ("b.bin", .added)],
                                      numstat: [("b.bin", nil, nil), ("a.txt", 3, 2)])
        XCTAssertGreaterThan(joined.count, 0, "the join produced nothing")
        XCTAssertEqual(Set(joined), [
            FileChange(path: "a.txt", status: .modified, additions: 3, deletions: 2, isBinary: false),
            FileChange(path: "b.bin", status: .added, additions: nil, deletions: nil, isBinary: true),
        ])
    }

    /// The command lines the three `DiffRef.Base` cases produce, asserted directly, because the
    /// mapping is the one place this leaf decides what "diff" means and the fixtures above would
    /// still pass if `.commitAgainstParent` quietly became `git diff <h>` on a non-root commit.
    func testTheThreeBaseCasesMapToTheirCommandLines() {
        XCTAssertEqual(GitDiff.arguments(for: .workingTreeAgainstHEAD, listing: "--name-status"),
                       ["diff", "--name-status", "-z", "--find-renames", "HEAD"])
        XCTAssertEqual(GitDiff.arguments(for: .commit("f00d"), listing: "--numstat"),
                       ["diff", "--numstat", "-z", "--find-renames", "f00d"])
        XCTAssertEqual(GitDiff.arguments(for: .commitAgainstParent("f00d"), listing: "--name-status"),
                       ["show", "--format=", "--name-status", "-z", "--find-renames", "f00d"])
    }
}
