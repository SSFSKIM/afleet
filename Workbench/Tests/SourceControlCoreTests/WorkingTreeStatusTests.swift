import Foundation
import XCTest
@testable import SourceControlCore

/// Half of gate G1: `git status --porcelain=v2 --branch -z` parsed off real repositories the
/// tests build.
///
/// **The measured shapes, and why they are written down here.** The architect's ruling at the
/// gate (ledger, "Architect's rulings at the gate") binds every parser in this leaf: each
/// probe-derived parsing fact is cited in the test that depends on it, naming the `git` version
/// it was measured on and the shape that was measured, so a future `git` whose bytes differ
/// fails a *named* test instead of silently mis-joining. Measured with **`git` 2.55.0** on
/// 2026-09-07 and re-measured on 2026-09-08 in a throwaway repository (`LC_ALL=C`, global and
/// system configuration disabled), NULs shown as `^@`:
///
///     # branch.oid <oid>^@# branch.head main^@1 .M N... 100644 100644 100644 <hH> <hI> a.txt^@
///     1 A. N... 000000 100644 100644 <hH> <hI> added.txt^@
///     2 R. N... 100644 100644 100644 <hH> <hI> R100 d.bin^@c.bin^@
///     1 .D N... 100644 100644 000000 <hH> <hI> n.txt^@? untracked.txt^@
///
/// The one that had to be established by measurement rather than read off the prose is the
/// **field order of a rename**: the *new* path is the last field of the `2` record and the
/// *original* path follows as its own NUL-terminated field. A parser that read them the other
/// way round would produce a plausible, wrong answer on every rename, which is why
/// `testAllFiveChangeKindsAppearInOneStatus` asserts the `from` path by name.
///
/// Three further shapes, measured the same way and each cited at its test: an unborn repository
/// prints the literal `# branch.oid (initial)`; a detached `HEAD` prints
/// `# branch.head (detached)`; an unmerged path prints a `u` record carrying **ten**
/// space-separated fields before the path (`u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3>
/// <path>`), three more than an ordinary entry.
///
/// **Assertion style**, as in `ToolRunnerTests` and for the same reason: `XCTAssertEqual` prints
/// both operands, and every repository in this suite lives under the system temporary directory,
/// whose path on macOS contains the machine account's hash (§6.3, §11). Nothing that transitively
/// reaches a runtime path or an environment is compared with `XCTAssertEqual`. Entry paths are
/// repository-relative and authored here, so they are safe to name — and they are named, because
/// an assertion that cannot say which entry it wanted is an assertion that cannot fail usefully.
final class WorkingTreeStatusTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    private func read(_ root: URL, environment: [String: String],
                      includeIgnored: Bool = false) async throws -> WorkingTreeStatus {
        try await WorkingTreeStatus.read(root: root, environment: environment,
                                         runner: ToolRunner(), includeIgnored: includeIgnored)
    }

    // MARK: - G1: modified, added, deleted, renamed and untracked, all at once

    /// The milestone's central test. One tree carries all five change kinds simultaneously and
    /// the parse is compared as a set in **both** directions — every expected entry present, and
    /// no unexpected entry present — over a non-emptiness floor, because a subset assertion alone
    /// is satisfied by an empty parse.
    ///
    /// Cites the `git` 2.55.0 shapes in this file's note, and in particular the rename field
    /// order: `d.bin` is the record's own path and `c.bin` is the separate field that follows.
    func testAllFiveChangeKindsAppearInOneStatus() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "the tree before the change", files: [
            "a.txt": "one\n",
            "c.bin": "carried\n",
            "n.txt": "doomed\n",
        ])

        // modified, unstaged
        try "one\ntwo\n".write(to: fixture.root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        // added, staged
        try "fresh\n".write(to: fixture.root.appending(path: "added.txt"), atomically: true, encoding: .utf8)
        try await fixture.run(["add", "added.txt"])
        // renamed, staged
        try await fixture.run(["mv", "c.bin", "d.bin"])
        // deleted, unstaged
        try FileManager.default.removeItem(at: fixture.root.appending(path: "n.txt"))
        // untracked
        try "loose\n".write(to: fixture.root.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)

        let status = try await read(fixture.root, environment: fixture.environment)

        let expected: Set<WorkingTreeStatus.Entry> = [
            .init(path: "a.txt", staged: nil, worktree: .modified),
            .init(path: "added.txt", staged: .added, worktree: nil),
            .init(path: "d.bin", staged: .renamed(from: "c.bin"), worktree: nil),
            .init(path: "n.txt", staged: nil, worktree: .deleted),
            .init(path: "untracked.txt", staged: nil, worktree: .untracked),
        ]
        let parsed = Set(status.entries)

        // The floor: an empty parse is a subset of everything, so the subset assertions below
        // would both pass over one.
        XCTAssertEqual(status.entries.count, 5,
                       "the status did not report exactly the five entries the tree was put into")
        XCTAssertFalse(parsed.isEmpty, "the status parsed to no entries at all")
        XCTAssertFalse(status.isClean, "a tree carrying five changes reported itself clean")

        for entry in expected {
            XCTAssertTrue(parsed.contains(entry),
                          "the status is missing the expected entry for \(entry.path)")
        }
        for entry in parsed {
            XCTAssertTrue(expected.contains(entry),
                          "the status carries an entry for \(entry.path) that was not expected, "
                          + "or carries it with the wrong staged/worktree change")
        }

        // Named separately, because it is the field whose position the probe had to establish and
        // the one a mis-join would get wrong while every other assertion still passed.
        let rename = status.entries.first { $0.path == "d.bin" }
        XCTAssertTrue(rename?.staged == .renamed(from: "c.bin"),
                      "the rename's original path is not c.bin; under git 2.55.0 the new path is "
                      + "the 2-record's own last field and the original follows as its own field")
    }

    // MARK: - the clean tree, the branch name, the detached head, the unborn repository

    func testACleanRepositoryIsCleanAndNamesItsBranch() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "only commit", files: ["a.txt": "one\n"])

        let status = try await read(fixture.root, environment: fixture.environment)

        XCTAssertTrue(status.isClean, "a freshly committed tree did not report itself clean")
        XCTAssertTrue(status.entries.isEmpty, "a clean tree reported entries")
        XCTAssertEqual(status.branch, "main", "the branch name was not read from # branch.head")
        XCTAssertTrue(status.headOID?.count == 40,
                      "# branch.oid did not yield a full object name")
        XCTAssertNil(status.upstream, "a repository with no remote reported an upstream")
    }

    /// `git` 2.55.0 prints `# branch.head (detached)` for a detached `HEAD`; the literal is the
    /// whole of how detachment is detected, so it is named here.
    func testADetachedHeadHasNoBranchName() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "only commit", files: ["a.txt": "one\n"])
        try await fixture.detach("HEAD")

        let status = try await read(fixture.root, environment: fixture.environment)

        XCTAssertNil(status.branch, "a detached HEAD reported a branch name")
        XCTAssertTrue(status.headOID?.isEmpty == false,
                      "a detached HEAD reported no object name")
    }

    /// `git` 2.55.0 prints `# branch.oid (initial)` before the first commit — a literal, not an
    /// absent header — so an unborn repository is detected by that string and by nothing else.
    func testAnUnbornRepositoryHasNoHeadObject() async throws {
        let fixture = try await GitFixture(tree)

        let status = try await read(fixture.root, environment: fixture.environment)

        XCTAssertNil(status.headOID, "an unborn repository reported a HEAD object name")
        XCTAssertEqual(status.branch, "main", "the unborn branch was not named")
        XCTAssertTrue(status.isClean, "an empty unborn repository reported entries")
    }

    // MARK: - upstream, ahead and behind

    /// `# branch.upstream <name>` and `# branch.ab +<n> -<n>`, measured on `git` 2.55.0 in a
    /// clone that is one commit ahead: `# branch.ab +1 -0`. Both directions of the count are
    /// asserted so that a parser reading the two numbers the wrong way round fails.
    func testUpstreamAndAheadBehindAreRead() async throws {
        let upstream = try await GitFixture(tree, name: "upstream")
        _ = try await upstream.commit(message: "shared history", files: ["a.txt": "one\n"])

        let clone = tree.root.appending(path: "clone")
        try await upstream.run(["clone", upstream.root.path(percentEncoded: false),
                                clone.path(percentEncoded: false)], in: tree.root)

        let before = try await read(clone, environment: upstream.environment)
        XCTAssertEqual(before.upstream, "origin/main", "the clone did not report its upstream")
        XCTAssertEqual(before.ahead, 0, "a fresh clone reported commits ahead")
        XCTAssertEqual(before.behind, 0, "a fresh clone reported commits behind")

        try "one\ntwo\n".write(to: clone.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let stamp = "\(GitFixture.baseTimestamp + 900) +0000"
        try await upstream.run(["commit", "-a", "-m", "one ahead"], in: clone,
                               extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])

        let after = try await read(clone, environment: upstream.environment)
        XCTAssertEqual(after.ahead, 1, "one local commit was not reported as one ahead")
        XCTAssertEqual(after.behind, 0, "a clone with no fetched commits reported commits behind")
    }

    // MARK: - the record kinds an ordinary tree does not produce

    /// The `u` record: ten space-separated fields before the path under `git` 2.55.0
    /// (`u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`), three more than an ordinary
    /// entry, so a parser that split it as an ordinary entry would take a mode as the path.
    func testAnUnmergedPathIsParsed() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "base", files: ["f.txt": "base\n"])
        try await fixture.branch("side")
        _ = try await fixture.commit(message: "side edit", files: ["f.txt": "side\n"])
        try await fixture.checkout("main")
        _ = try await fixture.commit(message: "main edit", files: ["f.txt": "main\n"])
        // The conflicting merge exits non-zero by design, so it is not run through the fixture's
        // zero-exit helper.
        let merge = try await ToolRunner().run(.git, arguments: ["merge", "side"], cwd: fixture.root,
                                               environment: fixture.environment, timeout: .seconds(30))
        XCTAssertNotEqual(merge.exitCode, 0, "the merge was expected to conflict and did not")

        let status = try await read(fixture.root, environment: fixture.environment)

        XCTAssertFalse(status.entries.isEmpty, "a conflicted tree parsed to no entries")
        let conflicted = status.entries.first { $0.path == "f.txt" }
        XCTAssertTrue(conflicted?.worktree == .unmerged,
                      "the conflicted path f.txt was not reported unmerged on the working-tree side")
        XCTAssertTrue(conflicted?.staged == .unmerged,
                      "the conflicted path f.txt was not reported unmerged on the index side")
    }

    /// `! <path>`, which `git status` prints only when asked with `--ignored`. Both directions:
    /// the ignored file is absent from the default read and present from the asking one, because
    /// an entry that always appeared would pass the second assertion alone.
    func testAnIgnoredPathAppearsOnlyWhenAskedFor() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "base", files: [".gitignore": "ignored.txt\n"])
        try "hidden\n".write(to: fixture.root.appending(path: "ignored.txt"), atomically: true, encoding: .utf8)

        let plain = try await read(fixture.root, environment: fixture.environment)
        XCTAssertTrue(plain.isClean,
                      "an ignored file was reported by a status that did not ask for ignores")

        let asked = try await read(fixture.root, environment: fixture.environment, includeIgnored: true)
        XCTAssertFalse(asked.entries.isEmpty, "the --ignored read parsed to no entries")
        let ignored = asked.entries.first { $0.path == "ignored.txt" }
        XCTAssertTrue(ignored?.worktree == .ignored,
                      "the ignored file was not carried as an ignored working-tree change")
    }

    // MARK: - what `-z` is for (D7)

    /// A path with a space and a non-ASCII character survives byte for byte. Without `-z` git
    /// C-quotes such a path — `"caf\303\251 notes/na\303\257ve file.txt"` — and this assertion
    /// would see the quotes and the octal escapes. Measured on `git` 2.55.0.
    func testAPathWithASpaceAndNonASCIISurvives() async throws {
        let awkward = "café notes/naïve file.txt"
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "awkward path", files: [awkward: "one\n"])
        try "one\ntwo\n".write(to: fixture.root.appending(path: awkward), atomically: true, encoding: .utf8)

        let status = try await read(fixture.root, environment: fixture.environment)

        XCTAssertEqual(status.entries.count, 1, "the awkward path did not produce exactly one entry")
        let entry = status.entries.first
        XCTAssertTrue(entry?.path == awkward,
                      "the path was not carried through unquoted; -z is what prevents git from "
                      + "C-quoting a path with a space or a non-ASCII byte (D7)")
        XCTAssertTrue(entry?.worktree == .modified, "the awkward path was not reported modified")
    }

    // MARK: - the field-count guard

    /// A parser that skipped the record it could not read would make every test above
    /// unfalsifiable — §17.7's named failure mode. Each malformed input is rejected with
    /// `.decodeFailed`, never dropped.
    func testMalformedRecordsAreRejectedRatherThanSkipped() throws {
        // A rename record whose separate original-path field is missing: the exact mis-join the
        // measured field order exists to prevent.
        let renameWithoutOrigin = Data("2 R. N... 100644 100644 100644 aaaa bbbb R100 d.bin\0".utf8)
        XCTAssertThrowsError(try WorkingTreeStatus.parse(renameWithoutOrigin),
                             "a rename with no original-path field was accepted") { error in
            XCTAssertTrue(Self.isDecodeFailure(error),
                          "the rename guard threw something other than .decodeFailed")
        }

        // An ordinary record with too few space-separated fields.
        let shortOrdinary = Data("1 .M N... 100644 100644\0".utf8)
        XCTAssertThrowsError(try WorkingTreeStatus.parse(shortOrdinary),
                             "a truncated ordinary record was accepted") { error in
            XCTAssertTrue(Self.isDecodeFailure(error),
                          "the ordinary-record guard threw something other than .decodeFailed")
        }

        // A record whose leading token is none of the documented kinds.
        let unknownKind = Data("9 whatever\0".utf8)
        XCTAssertThrowsError(try WorkingTreeStatus.parse(unknownKind),
                             "a record of an unknown kind was accepted") { error in
            XCTAssertTrue(Self.isDecodeFailure(error),
                          "the unknown-kind guard threw something other than .decodeFailed")
        }

        // An unmerged record split as if it were an ordinary one: it has three extra fields, so
        // a parser using the ordinary widths would silently take a mode as the path.
        let shortUnmerged = Data("u UU N... 100644 100644 100644 aaaa bbbb f.txt\0".utf8)
        XCTAssertThrowsError(try WorkingTreeStatus.parse(shortUnmerged),
                             "an unmerged record with the wrong field count was accepted") { error in
            XCTAssertTrue(Self.isDecodeFailure(error),
                          "the unmerged guard threw something other than .decodeFailed")
        }
    }

    private static func isDecodeFailure(_ error: any Error) -> Bool {
        guard let toolError = error as? ToolError, case .decodeFailed = toolError else { return false }
        return true
    }
}
