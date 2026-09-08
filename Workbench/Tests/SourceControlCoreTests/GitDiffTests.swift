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
/// Three facts follow, and each has a test of its own below:
///
/// 1. `--name-status` and `--numstat` given to the *same* command do not both print — the last
///    one wins, and no numstat section appears at all.
///    (`testNameStatusAndNumstatGivenTogetherDoNotBothPrint`.)
/// 2. `--raw` and `--numstat` given to the same command **do** both print, raw section first,
///    from one traversal of one snapshot — and `--raw` carries the file modes as well as the
///    status codes. That is why the changed-file list is **one** invocation rather than two reads
///    of the same repository joined across whatever happened between them, and it is where
///    `FileChange.Kind` comes from.
///    (`testRawAndNumstatGivenTogetherBothPrintOneSnapshot`.)
/// 3. Under `-z`, a rename in `--numstat` puts an **empty** path field between the counts and the
///    two paths, so a parser reading one path per record silently mis-joins every rename.
///    (`testNumstatPutsAnEmptyPathFieldBeforeARenamesTwoPaths`.) `-` for both counts is how a
///    binary file is reported, which is where `isBinary` comes from.
///
/// A `--raw -z` record is `:<src mode> <dst mode> <src oid> <dst oid> <status>\0<path>\0`, and
/// for a rename `…R<score>\0<old>\0<new>\0` — two paths, old first.
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
        // And the consequence, stated as a parse: the combined output holds no counts at all, so
        // the whole of it reads as a raw-less listing and nothing joins.
        XCTAssertThrowsError(try GitDiff.parse(both),
                             "the --name-status/--numstat combination parsed as one snapshot")
    }

    /// **Measured fact 2, `git` 2.55.0.** `--raw` and `--numstat` given to the same command *do*
    /// both print: the whole raw section first, then the whole numstat section, from one traversal
    /// of one snapshot. This is what lets `GitDiff.changes` take the status, the rename pairing,
    /// the file modes and the line counts from a **single** invocation.
    ///
    /// Two reads of the same repository resolve `HEAD`, the index and the working tree
    /// independently, so an edit landing between them either fails the strict join — a path in one
    /// listing and not the other — or silently mixes one instant's status with another's counts.
    /// The panel refreshes while the user is editing, which is precisely when that window is open.
    ///
    /// What would have to be true for this to fail: a `git` in which one of the two sections stops
    /// printing when the other is asked for, or in which the numstat section comes first.
    func testRawAndNumstatGivenTogetherBothPrintOneSnapshot() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "first", files: ["a.txt": "one\n"])
        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))
        _ = try await fixture.commit(message: "second", files: ["n.txt": "new\n"])

        let common = ["show", "--format=", "-z", "--find-renames", "HEAD"]
        let both = try await fixture.run(["show", "--format=", "--raw", "--numstat",
                                          "-z", "--find-renames", "HEAD"]).stdout
        let rawOnly = try await fixture.run(common + ["--raw"]).stdout
        let numstatOnly = try await fixture.run(common + ["--numstat"]).stdout

        XCTAssertGreaterThan(rawOnly.count, 0, "the raw listing was empty")
        XCTAssertGreaterThan(numstatOnly.count, 0, "the numstat listing was empty")
        XCTAssertEqual(both.count, rawOnly.count + numstatOnly.count,
                       "the combined output is not the two sections' bytes together")
        XCTAssertEqual(both.prefix(rawOnly.count), rawOnly,
                       "the raw section is not the first thing the combined output prints")
        XCTAssertEqual(both.suffix(numstatOnly.count), numstatOnly,
                       "the numstat section does not follow the raw section unchanged")

        // And the consequence, stated as a parse: one call over one output carries both halves.
        let parsed = try GitDiff.parse(both)
        XCTAssertEqual(parsed.count, 2, "the combined output did not parse to the two changes")
        XCTAssertEqual(parsed.first { $0.path == "a.txt" }?.additions, 1,
                       "the counts from the numstat section did not reach the raw section's paths")
        XCTAssertEqual(parsed.first { $0.path == "n.txt" }?.status, .added)
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

        var cursor = 0
        let parsed = try GitDiff.parseNumstat(GitDiff.split(bytes), from: &cursor)
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
        // Every raw record here is followed by the numstat section its paths need, so that the
        // rejection under test is the one the name describes rather than the strict join's.
        let badRaw: [(String, String)] = [
            ("a status letter this format does not define", ":100644 100644 aaaa bbbb Z\0a.txt\0"),
            ("a status field with no path after it", ":100644 100644 aaaa bbbb M\0"),
            ("a rename with only one path field", ":100644 100644 aaaa bbbb R100\0a.txt\0"),
            ("a rename whose score is not a number", ":100644 100644 aaaa bbbb Rxx\0a.txt\0b.txt\0"),
            ("a metadata field short of two modes, two object names and a status",
             ":100644 100644 aaaa M\0a.txt\0"),
            ("a score on a status that has none", ":100644 100644 aaaa bbbb M100\0a.txt\0"),
        ]
        for (name, text) in badRaw {
            XCTAssertThrowsError(try GitDiff.parse(Data(text.utf8)), name) { error in
                guard case ToolError.decodeFailed = error else {
                    return XCTFail("\(name) did not throw .decodeFailed")
                }
            }
        }
        let badCounts: [(String, String)] = [
            ("a record with no tab-separated counts", "a.txt\0"),
            ("a record with one count only", "1\ta.txt\0"),
            ("counts that are neither numbers nor dashes", "x\ty\ta.txt\0"),
            ("an empty path field with only one path after it", "1\t0\t\0a.txt\0"),
        ]
        for (name, text) in badCounts {
            XCTAssertThrowsError(try GitDiff.parse(Data((":100644 100644 aaaa bbbb M\0a.txt\0"
                                                         + text).utf8)), name) { error in
                guard case ToolError.decodeFailed = error else {
                    return XCTFail("\(name) did not throw .decodeFailed")
                }
            }
        }
        // The well-formed counterpart, so the assertions above cannot be passing because the
        // parser rejects everything.
        XCTAssertEqual(try GitDiff.parse(Data((":100644 100644 aaaa bbbb M\0a.txt\0"
                                               + "1\t0\ta.txt\0").utf8)).count, 1)
    }

    /// The join itself. The two sections are one snapshot now, so a path in one and not the other
    /// is git contradicting itself rather than two reads disagreeing — reported either way, never
    /// papered over with a change carrying no counts, which is indistinguishable from a binary.
    func testAJoinWhoseTwoSectionsDisagreeIsRejected() throws {
        func raw(_ path: String, _ status: FileChange.Status,
                 _ destination: String = "100644") -> GitDiff.RawRecord {
            GitDiff.RawRecord(path: path, status: status, sourceMode: "100644",
                              destinationMode: destination)
        }
        XCTAssertThrowsError(try GitDiff.join(raw: [raw("a.txt", .modified)], numstat: [])) { error in
            guard case ToolError.decodeFailed = error else {
                return XCTFail("a raw path missing from numstat did not throw .decodeFailed")
            }
        }
        XCTAssertThrowsError(try GitDiff.join(raw: [], numstat: [("a.txt", 1, 0)])) { error in
            guard case ToolError.decodeFailed = error else {
                return XCTFail("a numstat path missing from the raw section did not throw .decodeFailed")
            }
        }
        // The agreeing case, so the two assertions above are not passing on a join that always
        // throws. The gitlink is the classification the counts cannot carry: git prints ordinary
        // numeric counts for a submodule, so only the mode says it is one.
        let joined = try GitDiff.join(raw: [raw("a.txt", .modified), raw("b.bin", .added),
                                            raw("s", .modified, "160000")],
                                      numstat: [("b.bin", nil, nil), ("a.txt", 3, 2), ("s", 1, 1)])
        XCTAssertGreaterThan(joined.count, 0, "the join produced nothing")
        XCTAssertEqual(Set(joined), [
            FileChange(path: "a.txt", status: .modified, additions: 3, deletions: 2, isBinary: false),
            FileChange(path: "b.bin", status: .added, additions: nil, deletions: nil, isBinary: true),
            FileChange(path: "s", status: .modified, additions: 1, deletions: 1, isBinary: false,
                       kind: .gitlink),
        ])
    }

    // MARK: - merge commits (R3 F1)

    /// An **ordinary** merge commit's changed-file list is the merge against its *first* parent.
    ///
    /// **Measured on `git` 2.55.0**, with the global and system configuration disabled: for a
    /// merge whose result equals neither parent's tree, `git show --format= --name-status -z` of
    /// that commit prints **nothing at all**, while `git show --format= --numstat -z` of the same
    /// commit prints a record per path. The two listings `GitDiff.changes` joins therefore
    /// disagree completely, and the join throws — so selecting an ordinary merge row in the panel
    /// failed outright rather than showing what the merge brought in.
    ///
    /// `--first-parent` is what makes the two listings agree, and it is the listing a panel wants
    /// (D41): the merge as the branch it was merged into experienced it.
    ///
    /// What would have to be true for this to fail: either invocation losing `--first-parent`, or
    /// a `git` whose combined and first-parent listings differ in shape again.
    func testAnOrdinaryMergeListsWhatItBroughtInAgainstItsFirstParent() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "base", files: ["base.txt": "base\n"])
        try await fixture.branch("side")
        _ = try await fixture.commit(message: "side work", files: ["side.txt": "side\n"])
        try await fixture.checkout("main")
        _ = try await fixture.commit(message: "main work", files: ["main.txt": "main\n"])
        try await fixture.merge(["side"], message: "merge side into main")
        let merge = try await fixture.run(["rev-parse", "HEAD"]).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let list = try await changes(fixture, .commitAgainstParent(merge))
        XCTAssertGreaterThan(list.count, 0, "the merge commit's changed-file list was empty")
        XCTAssertEqual(list.count, 1, "against its first parent the merge brought in one path")
        XCTAssertEqual(list.first?.path, "side.txt", "the path the side branch added")
        XCTAssertEqual(list.first?.status, .added, "the first parent did not carry that path")
        XCTAssertEqual(list.first?.additions, 1)
        XCTAssertEqual(list.first?.deletions, 0)
    }

    /// A **conflict-resolving** merge, which fails in a different way from the ordinary one.
    ///
    /// **Measured on `git` 2.55.0**: for a merge commit whose tree differs from both parents on a
    /// path, `git show --format= --name-status -z` prints git's *combined* diff, whose status
    /// field carries **one letter per parent** — `MM` for a path modified relative to both. The
    /// name-status parser rejects a two-character code deliberately (a status letter it does not
    /// define is never silently skipped), so this commit threw at parse time rather than at the
    /// join. Both failures have the same cause and the same fix.
    ///
    /// What would have to be true for this to fail: the name-status invocation losing
    /// `--first-parent` and handing the parser a combined status code again.
    func testAConflictResolvingMergeIsListedAgainstItsFirstParentTooRatherThanCombined() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "base",
                                     files: ["shared.txt": "base\n", "base.txt": "base\n"])
        try await fixture.branch("side")
        _ = try await fixture.commit(message: "side work",
                                     files: ["shared.txt": "side\n", "side.txt": "side\n"])
        try await fixture.checkout("main")
        _ = try await fixture.commit(message: "main work", files: ["shared.txt": "main\n"])
        try await fixture.mergeResolvingConflict("side", message: "merge side into main",
                                                 resolution: ["shared.txt": "resolved\n"])
        let merge = try await fixture.run(["rev-parse", "HEAD"]).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentage = try await fixture.run(["rev-list", "--parents", "-n", "1", merge])
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").count
        XCTAssertEqual(parentage, 3, "the fixture must have built a two-parent merge commit")

        let list = try await changes(fixture, .commitAgainstParent(merge))
        XCTAssertGreaterThan(list.count, 0, "the conflict-resolving merge's list was empty")
        XCTAssertEqual(Set(list.map(\.path)), ["shared.txt", "side.txt"],
                       "against its first parent the merge brought in the side path and the resolution")
        XCTAssertEqual(list.first(where: { $0.path == "shared.txt" })?.status, .modified,
                       "the resolved path is a modification of the first parent's version")
        XCTAssertEqual(list.first(where: { $0.path == "side.txt" })?.status, .added)
    }

    // MARK: - symlinks (R3 F5)

    /// A tracked symbolic link: both sides of the diff must be the **link destination**, which is
    /// what git stores, and never the bytes of the file the link points at.
    ///
    /// `blob` returns git's stored object, and for a symlink that object is the destination text.
    /// Reading the working-tree side with `Data(contentsOf:)` *follows* the link, so the panel
    /// compared a path string against a file's contents and drew a retargeting as a total
    /// rewrite. The dangling case is worse: the read throws for a change git tracks perfectly
    /// well.
    ///
    /// What would have to be true for this to fail: a working-tree read that follows the link
    /// again, in either direction.
    func testTheWorkingTreeReadOfASymlinkReturnsItsDestinationRatherThanTheTargetsBytes() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.symlink("link.txt", to: "a.txt")
        let first = try await fixture.commit(message: "first",
                                             files: ["a.txt": "one\n", "b.txt": "two\n"])

        let stored = try await GitDiff.blob(root: fixture.root, rev: first, path: "link.txt",
                                            environment: fixture.environment, runner: ToolRunner())
        XCTAssertEqual(stored, Data("a.txt".utf8),
                       "git stores a symlink as its destination, with no trailing newline")

        // Retargeted, not rewritten: the two sides must be two destinations.
        try fixture.symlink("link.txt", to: "b.txt")
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "link.txt"),
                       Data("b.txt".utf8),
                       "the working-tree side of a symlink is its destination, not the target's bytes")

        // Dangling: a valid git change, and the read must not throw.
        try fixture.symlink("link.txt", to: "absent.txt")
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "link.txt"),
                       Data("absent.txt".utf8),
                       "a dangling symlink still has a destination to compare")

        // An ordinary file is unaffected: the symlink branch must not capture the common case.
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "a.txt"),
                       Data("one\n".utf8))
    }

    // MARK: - R6/F2 the unborn HEAD

    /// A repository that has been initialised and staged but never committed. `HEAD` names a
    /// branch with no commit, so it resolves to no object at all and `git diff HEAD` exits 128 —
    /// which this reader turned into `.commandFailed` for a repository state its sibling reader
    /// supports and reports (`WorkingTreeStatusTests.testAnUnbornRepositoryHasNoHeadObject`, whose
    /// `headOID` is nil for exactly this repository). Two readers of one repository disagreeing
    /// about whether it exists is the defect; the staged files are additions and there is nothing
    /// ambiguous about them.
    ///
    /// The comparison is against git's **empty tree**, which is what "before the first commit"
    /// means to git. Measured on `git` 2.55.0.
    func testAnUnbornRepositorysStagedFilesAreListedAsAdditions() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.write("a.txt", bytes: Data("one\n".utf8))
        try fixture.write("nested/b.txt", bytes: Data("two\nthree\n".utf8))
        try await fixture.run(["add", "-A"])

        let listed = try await changes(fixture, .workingTreeAgainstHEAD)

        XCTAssertEqual(listed.map(\.path).sorted(), ["a.txt", "nested/b.txt"],
                       "an unborn repository's staged files are not the changed-file list")
        XCTAssertTrue(listed.allSatisfy { $0.status == .added },
                      "a staged file in a repository with no first commit is not an addition")
        XCTAssertEqual(listed.first { $0.path == "nested/b.txt" }?.additions, 2,
                       "the added file's line count is not the two lines it holds")
        XCTAssertTrue(listed.allSatisfy { $0.deletions == 0 && !$0.isBinary },
                      "an addition in an unborn repository carries deletions or reads as binary")
    }

    /// And the other half of that state: an unborn repository whose files are **untracked** lists
    /// nothing, rather than failing or inventing additions. `git diff HEAD` never reports untracked
    /// paths, and substituting the empty tree must not change that — a substitution that listed
    /// them would make this base mean something else in the one repository it was added for.
    func testAnUnbornRepositoryWithNothingStagedListsNoChange() async throws {
        let fixture = try await GitFixture(tree)
        try fixture.write("untracked.txt", bytes: Data("one\n".utf8))

        let listed = try await changes(fixture, .workingTreeAgainstHEAD)

        XCTAssertEqual(listed.count, 0,
                       "an unborn repository with nothing staged reported \(listed.count) changed file(s)")
    }

    /// The command lines the three `DiffRef.Base` cases produce, asserted directly, because the
    /// mapping is the one place this leaf decides what "diff" means and the fixtures above would
    /// still pass if `.commitAgainstParent` quietly became `git diff <h>` on a non-root commit.
    func testTheThreeBaseCasesMapToTheirCommandLines() {
        // `--end-of-options` is the final wave's pin: the revision that follows it cannot be
        // parsed as an option however it is spelled, which is the second half of refusing a base
        // like `--output=<path>` (the first is resolving it to an object name before any command
        // is built).
        let tail = ["--raw", "--numstat", "-z", "--find-renames", "-l1000",
                    "--ignore-submodules=none", "--end-of-options"]
        XCTAssertEqual(GitDiff.arguments(for: .workingTreeAgainstHEAD), ["diff"] + tail + ["HEAD"])
        XCTAssertEqual(GitDiff.arguments(for: .commit("f00d")), ["diff"] + tail + ["f00d"])
        // `--first-parent` is the R3 wave's F1 fix (D41): without it a merge commit's listing is
        // git's combined diff, whose status codes the parser rejects. `-l1000` and
        // `--no-show-signature` are the R5 wave's pins (D47, D48) and `--ignore-submodules=none`
        // is wave 2's; what each buys is asserted against a hostile repository in
        // `AdverseConfigurationTests`, and this test pins that they are still passed at all.
        XCTAssertEqual(GitDiff.arguments(for: .commitAgainstParent("f00d")),
                       ["show", "--format=", "--first-parent", "--root", "--no-show-signature"]
                       + tail + ["f00d"])
    }
}

// MARK: - added by the wave-2 fix wave, additively and without touching anything above

extension GitDiffTests {

    /// A **submodule** change: the entry decodes, and it is classified as a gitlink rather than
    /// offered as a text file.
    ///
    /// Two defects meet on this fixture. The listing was empty under `diff.ignoreSubmodules=all`
    /// (that half is `AdverseConfigurationTests`'), and the entry that did arrive was
    /// indistinguishable from a one-line text change: `--numstat` prints ordinary numeric counts
    /// for a gitlink, so `isBinary` was false, and a panel that then asked for either side got a
    /// `cat-file blob` refusing a commit object and a working-tree read meeting a directory. Only
    /// the mode `--raw` prints says what the entry is.
    ///
    /// What would have to be true for this to fail: the changed-file list losing the modes, or
    /// classifying `160000` as anything but a gitlink.
    func testASubmoduleChangeDecodesAndIsClassifiedAsAGitlink() async throws {
        let fixture = try await GitFixture(tree)
        let inner = try await GitFixture(tree, name: "inner")
        _ = try await inner.commit(message: "the submodule's first commit", files: ["a.txt": "one\n"])
        _ = try await fixture.commit(message: "the first commit", files: ["f.txt": "one\n"])
        try await fixture.addSubmodule(inner, at: "s")
        try await fixture.commitInsideSubmodule(at: "s", message: "the submodule's second commit",
                                                files: ["a.txt": "one\ntwo\n"])

        let list = try await changes(fixture, .workingTreeAgainstHEAD)
        XCTAssertEqual(list.count, 1,
                       "a submodule-only change is one entry, and \(list.count) were listed")
        let entry = try XCTUnwrap(list.first, "the submodule entry is absent from the list")
        XCTAssertEqual(entry.path, "s", "the submodule entry is not under the submodule's path")
        XCTAssertEqual(entry.status, .modified, "the gitlink now names a different commit")
        XCTAssertEqual(entry.kind, .gitlink,
                       "a mode-160000 entry was not classified as a gitlink, so a panel would ask "
                       + "for blob bytes git cannot give it")

        // And the commit that added it, where the gitlink is an addition rather than a
        // modification: the classification must come from the destination mode either way.
        let head = try await fixture.run(["rev-parse", "HEAD"]).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let added = try await changes(fixture, .commitAgainstParent(head))
        XCTAssertEqual(Set(added.map(\.path)), [".gitmodules", "s"],
                       "the submodule-adding commit did not list the gitlink and .gitmodules")
        XCTAssertEqual(added.first { $0.path == "s" }?.kind, .gitlink)
        XCTAssertEqual(added.first { $0.path == ".gitmodules" }?.kind, .file,
                       "the ordinary file beside the gitlink was misclassified")
    }

    /// The changed-file list is **one** `git diff` command, counted through the runner.
    ///
    /// Two invocations resolved `HEAD`, the index and the working tree independently, so a write
    /// landing between them produced either a decode failure naming a path present in one listing
    /// and absent from the other, or a record silently mixing one instant's status with another's
    /// counts. There is no way to assert the absence of a race; there is a way to assert the
    /// property that removes it, which is that the snapshot is taken once.
    ///
    /// What would have to be true for this to fail: `changes` reading a second listing.
    func testTheChangedFileListIsOneGitDiffCommand() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["a.txt": "one\n", "r.txt": "moved\n"])
        try fixture.write("a.txt", bytes: Data("one\ntwo\n".utf8))
        try await fixture.run(["mv", "r.txt", "moved.txt"])

        let runner = CountingRunner()
        let list = try await GitDiff.changes(root: fixture.root, base: .workingTreeAgainstHEAD,
                                             environment: fixture.environment, runner: runner)
        XCTAssertEqual(list.count, 2, "the fixture's two changes were not listed")
        let listings = runner.invocations.filter { $0.first == "diff" || $0.first == "show" }
        XCTAssertEqual(listings.count, 1,
                       "the changed-file list ran \(listings.count) diff commands; a list joined "
                       + "across two of them is joined across whatever happened between them")
        XCTAssertTrue(listings.first?.contains("--raw") == true
                      && listings.first?.contains("--numstat") == true,
                      "the single listing did not ask for both sections")
    }

    // MARK: - the repository root (D13)

    /// A channel whose directory is a **subdirectory** is read at the repository root.
    ///
    /// git prints repository-relative paths whatever directory it runs in, so a listing taken from
    /// `repo/sub` names `sub/nested.txt` — and a reader that trusted its `root` argument then
    /// handed `repo/sub` + `sub/nested.txt` to the working-tree read, which is a file that does
    /// not exist. The resolver D13 promised was never written; this is what its absence did.
    ///
    /// What would have to be true for this to fail: a reader running at the directory it was
    /// handed, or `repositoryRoot` returning it unchanged.
    func testARepositoryOpenedFromASubdirectoryIsReadAtItsRoot() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["sub/nested.txt": "one\n", "top.txt": "top\n"])
        try fixture.write("sub/nested.txt", bytes: Data("one\ntwo\n".utf8))
        let opened = fixture.root.appending(path: "sub")

        let root = try await GitCommands.repositoryRoot(cwd: opened,
                                                        environment: fixture.environment,
                                                        runner: ToolRunner())
        let list = try await GitDiff.changes(root: opened, base: .workingTreeAgainstHEAD,
                                             environment: fixture.environment, runner: ToolRunner())
        XCTAssertEqual(list.map(\.path), ["sub/nested.txt"],
                       "the change is not named relative to the repository root")
        // The whole point of resolving: the listed path recombines with the resolved root into a
        // file that can actually be read.
        XCTAssertEqual(try GitDiff.workingTreeFile(root: root, path: list[0].path),
                       Data("one\ntwo\n".utf8),
                       "the listed path did not resolve to a readable file under the resolved root")

        // And the sibling readers answer about the whole repository rather than the subtree.
        let status = try await WorkingTreeStatus.read(root: opened,
                                                      environment: fixture.environment,
                                                      runner: ToolRunner())
        XCTAssertEqual(status.entries.map(\.path), ["sub/nested.txt"],
                       "the status read from a subdirectory is not the repository's")
        let commits = try await GitLog.commits(root: opened, environment: fixture.environment,
                                               runner: ToolRunner())
        XCTAssertEqual(commits.count, 1, "the commit window read from a subdirectory is empty")
    }

    /// A directory in no repository is `.notARepository` — the panel's empty state — rather than
    /// a generic command failure carrying git's diagnostic (§10, D13).
    func testADirectoryInNoRepositoryIsNotARepository() async throws {
        let outside = try tree.directory("not-a-repository")
        let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                           "HOME": outside.path(percentEncoded: false),
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                           "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]

        for label in ["the resolver", "the changed-file list", "the status reader"] {
            do {
                switch label {
                case "the resolver":
                    _ = try await GitCommands.repositoryRoot(cwd: outside, environment: environment,
                                                             runner: ToolRunner())
                case "the changed-file list":
                    _ = try await GitDiff.changes(root: outside, base: .workingTreeAgainstHEAD,
                                                  environment: environment, runner: ToolRunner())
                default:
                    _ = try await WorkingTreeStatus.read(root: outside, environment: environment,
                                                         runner: ToolRunner())
                }
                XCTFail("\(label) answered for a directory in no repository")
            } catch let error as ToolError {
                XCTAssertEqual(error, .notARepository,
                               "\(label) did not report a directory in no repository as the "
                               + "panel's empty state")
            }
        }
    }

    // MARK: - the working-tree read stays inside the repository

    /// `path` reaches this function from a panel, and a panel's rows are built from bytes the
    /// repository supplied. An escaping path must be refused: lexically when it is written as one,
    /// and by resolution when it is spelled through a **symbolic link in the ancestry**, which the
    /// final component's `lstat` says nothing about.
    ///
    /// What would have to be true for this to fail: the lexical guard, or the resolved-parent
    /// comparison, being dropped — the second is the one an `lstat`-only check cannot cover.
    func testAWorkingTreeReadCannotLeaveTheRepository() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["sub/nested.txt": "one\n"])
        let outside = try tree.directory("beside-the-repository")
        try "not the repository's\n".write(to: outside.appending(path: "secret.txt"),
                                           atomically: true, encoding: .utf8)
        // A directory link inside the working tree, pointing out of it: the ancestry case.
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appending(path: "escape").path(percentEncoded: false),
            withDestinationPath: outside.path(percentEncoded: false))

        let refused = ["../beside-the-repository/secret.txt",
                       "sub/../../beside-the-repository/secret.txt",
                       "escape/secret.txt",
                       outside.appending(path: "secret.txt").path(percentEncoded: false)]
        for path in refused {
            XCTAssertThrowsError(try GitDiff.workingTreeFile(root: fixture.root, path: path),
                                 "a path leaving the repository was read") { error in
                guard case ToolError.pathOutsideRepository = error else {
                    return XCTFail("an escaping path threw \(error) rather than "
                                   + ".pathOutsideRepository")
                }
            }
        }
        // The floor: an ordinary nested file is still read, so the guards above are not passing
        // because the function refuses everything.
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "sub/nested.txt"),
                       Data("one\n".utf8),
                       "an ordinary nested file inside the repository was refused")
    }

    // MARK: - the blob object name (2g)

    /// `<rev>:<path>` is parsed by git at the **first** colon, so a rev carrying one takes the
    /// path with it and git answers about an object nobody asked for. Refused before any command
    /// runs, which is why the runner is a counter here: a refusal that still spawned `git` would
    /// have already asked the question.
    func testABlobRevisionCarryingAColonIsRefusedBeforeAnyCommandRuns() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["Workbench/a.txt": "one\n"])
        let runner = CountingRunner()

        for rev in ["HEAD:Workbench", ":", "-l1000"] {
            do {
                _ = try await GitDiff.blob(root: fixture.root, rev: rev, path: "a.txt",
                                           environment: fixture.environment, runner: runner)
                XCTFail("a revision that cannot name a blob was accepted")
            } catch let error as ToolError {
                guard case .decodeFailed = error else {
                    return XCTFail("the refusal is not a typed decode failure")
                }
            }
        }
        XCTAssertEqual(runner.invocations.count, 0,
                       "\(runner.invocations.count) commands ran for revisions that were refused")

        // The floor: a symbolic revision is resolved and read, so the refusals above are not
        // passing on a blob reader that refuses everything.
        let bytes = try await GitDiff.blob(root: fixture.root, rev: "HEAD",
                                           path: "Workbench/a.txt",
                                           environment: fixture.environment, runner: runner)
        XCTAssertEqual(bytes, Data("one\n".utf8),
                       "a symbolic revision did not resolve to the committed bytes")
        XCTAssertTrue(runner.invocations.contains { $0.first == "rev-parse" },
                      "a symbolic revision was concatenated rather than resolved")
    }

    // MARK: - the wave stitch: a process-layer fact is read before the exit code

    /// The one call site where an unread timeout is a *wrong answer* rather than a failure.
    ///
    /// `.workingTreeAgainstHEAD` first asks `rev-parse --verify --quiet HEAD^{commit}` whether
    /// `HEAD` resolves, and reads any non-zero exit as "unborn" — which is exactly the exit a
    /// child killed for exceeding its budget leaves behind. Without the shared check the reader
    /// would then diff a repository with a full history against git's **empty tree** and hand the
    /// panel a listing in which every tracked file is newly added. So the check goes on the probe
    /// itself, before the unborn guard.
    ///
    /// The budget is expired by the runner rather than by a slow `git`: the process-layer facts
    /// are data on `ToolOutput` (D3), so an interposing runner that stamps them on one command's
    /// result reproduces a killed child exactly and costs the suite no wall clock.
    func testATimedOutHeadProbeIsNotReadAsAnUnbornHead() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["a.txt": "one\n", "sub/nested.txt": "two\n"])
        try fixture.write("a.txt", bytes: Data("one\nedited\n".utf8))
        // 143 is SIGTERM's status, which is what a child killed at its budget leaves behind.
        let runner = TimingOutRunner(when: { $0.first == "rev-parse" && $0.contains("HEAD^{commit}") },
                                     exitCode: 143)

        do {
            let changes = try await GitDiff.changes(root: fixture.root, base: .workingTreeAgainstHEAD,
                                                    environment: fixture.environment, runner: runner)
            XCTFail("a timed-out HEAD probe was read as an unborn HEAD and produced a diff of "
                    + "\(changes.count) change(s) against the empty tree")
        } catch let error as ToolError {
            guard case .timedOut(let tool, let afterMs) = error else {
                return XCTFail("a timed-out HEAD probe threw \(error) rather than .timedOut")
            }
            XCTAssertEqual(tool, .git)
            XCTAssertEqual(afterMs, 30_000, "the error named a budget other than the read timeout")
        }
    }

    // MARK: - the final wave: the base is a revision, never an option

    /// `DiffRef.Base` carries a `String` the panel composed, and it was appended to a git command
    /// line unchecked. A base spelled `--output=<path>` was therefore *executed as that option*:
    /// git exited 0, listed nothing, and wrote the diff to a file of the caller's choosing — a
    /// read of a repository that writes to the file system on request.
    ///
    /// What would have to be true for this to fail: the base reaching a command line without being
    /// resolved to an object name first, or `--end-of-options` leaving the argument vector.
    func testADiffBaseSpelledLikeAnOptionIsRefusedAndWritesNothing() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit", files: ["a.txt": "one\n"])
        let target = tree.root.appending(path: "not-created-by-a-refused-diff.txt")
            .path(percentEncoded: false)
        let runner = CountingRunner()

        for base in [DiffRef.Base.commit("--output=\(target)"),
                     .commitAgainstParent("--output=\(target)")] {
            do {
                let list = try await GitDiff.changes(root: fixture.root, base: base,
                                                     environment: fixture.environment,
                                                     runner: runner)
                XCTFail("a base spelled like an option was accepted and listed "
                        + "\(list.count) change(s)")
            } catch let error as ToolError {
                guard case .decodeFailed = error else {
                    return XCTFail("a base spelled like an option was not refused by a typed error")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target),
                           "a refused diff base still created a file")
        }
        XCTAssertFalse(runner.invocations.contains { $0.first == "diff" || $0.first == "show" },
                       "a refused base still ran a diff command")

        // The floor: a symbolic base is resolved and listed, so the refusals above are not a
        // reader that refuses everything.
        let list = try await GitDiff.changes(root: fixture.root, base: .commitAgainstParent("HEAD"),
                                             environment: fixture.environment, runner: runner)
        XCTAssertEqual(list.map(\.path), ["a.txt"],
                       "a symbolic base did not list what the commit changed")
        XCTAssertTrue(runner.invocations.contains { $0.contains("HEAD^{commit}") },
                      "a symbolic base was not resolved to an object name before the listing")
    }

    // MARK: - the final wave: the working-tree read is bounded and type-checked

    /// A tracked path can be *replaced* by something that is not a file, and the read fell through
    /// to `Data(contentsOf:)` for everything that was not a symbolic link. A **named pipe** with no
    /// writer then parked the caller inside `open` for as long as nobody wrote — forever, for a
    /// panel — and a directory failed as an untyped error nobody above this layer can act on.
    ///
    /// The read is performed off this task and polled, so that a read which never returns fails
    /// this test in five seconds rather than hanging the suite.
    ///
    /// What would have to be true for this to fail: an open that can block, or a read that does
    /// not ask what it opened.
    func testAWorkingTreePathThatIsNotARegularFileIsRefusedRatherThanRead() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit",
                                     files: ["a.txt": "one\n", "sub/nested.txt": "two\n"])
        let replaced = fixture.root.appending(path: "a.txt").path(percentEncoded: false)
        try FileManager.default.removeItem(atPath: replaced)
        XCTAssertEqual(mkfifo(replaced, 0o600), 0, "the fixture could not create a named pipe")

        let root = fixture.root
        let outcome = ReadOutcome()
        Task.detached { outcome.set(Result { try GitDiff.workingTreeFile(root: root, path: "a.txt") }) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while outcome.value == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard let result = outcome.value else {
            return XCTFail("the working-tree read of a named pipe did not return within five seconds")
        }
        switch result {
        case .success(let bytes):
            XCTFail("a named pipe was read as a file, for \(bytes.count) byte(s)")
        case .failure(let error):
            guard case ToolError.unreadableWorkingTreeEntry = error else {
                return XCTFail("a named pipe was not refused by a typed error naming its kind")
            }
        }

        // A directory, for the other half of the same question.
        XCTAssertThrowsError(try GitDiff.workingTreeFile(root: fixture.root, path: "sub"),
                             "a directory was read as a file") { error in
            guard case ToolError.unreadableWorkingTreeEntry = error else {
                return XCTFail("a directory was not refused by a typed error naming its kind")
            }
        }
        // The floor: an ordinary file is still read.
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "sub/nested.txt"),
                       Data("two\n".utf8), "an ordinary file inside the repository was refused")
    }

    /// The other half of the same fall-through: a tracked file of any size was loaded whole, past
    /// the cap the process layer holds every `git` invocation to (D53/b). Both sides of a diff end
    /// up in the same panel, so the side that does not go through `git` must not be the one that
    /// exhausts the app's memory.
    ///
    /// The cap is injected rather than met at its 64 MiB default, so the fixture is a moment's
    /// work. Byte counts, never bytes (§6.3, §11).
    func testAWorkingTreeFileAboveTheCapIsRefusedAndOneUnderItIsRead() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the first commit", files: ["a.txt": "one\n"])
        let cap = 1024
        try fixture.write("large.bin", bytes: Data(repeating: 0x61, count: cap * 4))

        XCTAssertThrowsError(try GitDiff.workingTreeFile(root: fixture.root, path: "large.bin",
                                                         limitBytes: cap),
                             "a working-tree file four times the cap was read whole") { error in
            guard case ToolError.outputLimitExceeded(let tool, let limitBytes) = error else {
                return XCTFail("a file above the cap was not refused by .outputLimitExceeded")
            }
            XCTAssertEqual(tool, .git)
            XCTAssertEqual(limitBytes, cap, "the refusal named a cap other than the one passed")
        }
        XCTAssertEqual(try GitDiff.workingTreeFile(root: fixture.root, path: "a.txt",
                                                   limitBytes: cap).count, 4,
                       "a file well under the cap was not read")
    }

    // MARK: - the final wave: only rev-parse's terminator is framing

    /// `rev-parse --show-toplevel` prints the root and one line feed. Every other byte belongs to
    /// the **pathname**, and a directory name may end in a space or a tab — legal on every
    /// filesystem this runs on. Trimming the whole whitespace set took those with it, so the
    /// resolved root named a directory that does not exist and every reader built its paths on it.
    ///
    /// What would have to be true for this to fail: any framing strip wider than one `\n`.
    func testARepositoryRootWhoseNameEndsInASpaceKeepsIt() async throws {
        let fixture = try await GitFixture(tree, name: "a repository named with a space ")
        _ = try await fixture.commit(message: "the first commit", files: ["a.txt": "one\n"])

        let root = try await GitCommands.repositoryRoot(cwd: fixture.root,
                                                        environment: fixture.environment,
                                                        runner: ToolRunner())
        XCTAssertTrue(root.lastPathComponent.hasSuffix(" "),
                      "the resolved root lost the trailing space its name ends in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)),
                      "the resolved repository root is not a directory that exists")
        XCTAssertEqual(try GitDiff.workingTreeFile(root: root, path: "a.txt"), Data("one\n".utf8),
                       "a file could not be read under the resolved root")
    }
}

/// The result of one synchronous working-tree read, set from whichever task performed it.
///
/// A box rather than a task group: the read under test may *never return* before its fix, and a
/// child task that blocks a thread would take the whole suite with it. This lets the test poll,
/// fail at its own bound, and leave the blocked read behind.
private final class ReadOutcome: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: Result<Data, any Error>?

    var value: Result<Data, any Error>? { lock.withLock { stored } }

    func set(_ result: Result<Data, any Error>) { lock.withLock { stored = result } }
}

/// Runs every command for real except the one `when` selects, whose result carries the process-
/// layer facts a child killed at its budget leaves behind.
private final class TimingOutRunner: ToolRunning, @unchecked Sendable {

    private let inner = ToolRunner()
    private let when: @Sendable ([String]) -> Bool
    private let exitCode: Int32

    init(when: @escaping @Sendable ([String]) -> Bool, exitCode: Int32) {
        self.when = when
        self.exitCode = exitCode
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        guard when(arguments) else {
            return try await inner.run(tool, arguments: arguments, cwd: cwd,
                                       environment: environment, timeout: timeout)
        }
        return ToolOutput(stdout: Data(), stderr: Data(), exitCode: exitCode, timedOut: true)
    }
}

/// A `ToolRunning` that records every invocation and runs it for real, so that a test can assert
/// **how many** commands a reader issued as well as what it answered.
private final class CountingRunner: ToolRunning, @unchecked Sendable {

    private let inner = ToolRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []

    /// The argument vectors, in order. Arguments are authored by this module, never an environment
    /// or a runtime path, so they are safe to compare and to name in a failure (§6.3, §11).
    var invocations: [[String]] {
        lock.withLock { recorded }
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(arguments) }
        return try await inner.run(tool, arguments: arguments, cwd: cwd, environment: environment,
                                   timeout: timeout)
    }
}
