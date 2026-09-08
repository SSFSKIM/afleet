import Foundation
import XCTest
@testable import SourceControlCore

/// Milestone 2: a real repository's history is a `[GitCommit]`.
///
/// Assertion style, as in `ToolRunnerTests` and for the same reason: no `XCTAssertEqual` over a
/// value that transitively reaches a runtime path or an environment, because it prints both
/// operands and every path in this suite is under the system temporary directory, which on macOS
/// contains the machine account's hash (§6.3, §11). Commit hashes, subjects, ref names and
/// timestamps are *authored* — they are functions of the fixture's invented identity, invented
/// messages and fixed timestamps and of nothing on this machine — so they are compared directly.
/// Paths never are.
final class GitLogTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    // MARK: - a real repository parses to exact hashes, parents, refs and subjects

    /// Two commits, a tag, a branch and a detached `HEAD` — the milestone's acceptance shape.
    ///
    /// The layout, built below: `first commit` (root) ← `second commit` (carrying `main`, the tag
    /// `v0.1` and a detached `HEAD`) ← `sidecar commit` (carrying the branch `sidecar`).
    func testAFixtureHistoryParsesToTheExactHashesParentsRefsAndSubjects() async throws {
        let fixture = try await GitFixture(tree)
        let first = try await fixture.commit(message: "first commit", files: ["a.txt": "one\n"])
        let second = try await fixture.commit(message: "second commit", files: ["b.txt": "two\n"])
        try await fixture.tag("v0.1")
        try await fixture.branch("sidecar")
        let third = try await fixture.commit(message: "sidecar commit", files: ["c.txt": "three\n"])
        // Detaching at `main` puts `HEAD`, the tag and the branch on one commit, which is the
        // decoration shape the ledger measured on git 2.55.0.
        try await fixture.detach("main")

        let commits = try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                               runner: ToolRunner())

        // The floor: an empty result is a subset of every expectation, so every assertion below
        // would hold vacuously without it.
        XCTAssertEqual(commits.count, 3, "the window read a number of commits the fixture does not have")

        let actualHashes = Set(commits.map(\.hash))
        let expectedHashes: Set<String> = [first, second, third]
        XCTAssertTrue(expectedHashes.isSubset(of: actualHashes),
                      "the parse is missing commits the fixture created")
        XCTAssertTrue(actualHashes.isSubset(of: expectedHashes),
                      "the parse returned commits the fixture never created")

        let byHash = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
        guard let rootCommit = byHash[first], let middle = byHash[second], let tip = byHash[third] else {
            return XCTFail("one of the three fixture commits is absent from the parse")
        }

        XCTAssertEqual(rootCommit.parents, [], "the root commit was given a parent")
        XCTAssertEqual(middle.parents, [first], "the second commit's parent list is wrong")
        XCTAssertEqual(tip.parents, [second], "the sidecar commit's parent list is wrong")

        XCTAssertEqual(rootCommit.subject, "first commit", "the root commit's subject is wrong")
        XCTAssertEqual(middle.subject, "second commit", "the second commit's subject is wrong")
        XCTAssertEqual(tip.subject, "sidecar commit", "the sidecar commit's subject is wrong")

        XCTAssertEqual(rootCommit.authorName, GitFixture.authorName,
                       "the author name is not the fixture's invented identity")
        // `%at` is a Unix timestamp in seconds; the fixture advances it by one second per commit
        // from its fixed base, so the root commit is base + 1.
        XCTAssertEqual(rootCommit.authorTimestamp,
                       Date(timeIntervalSince1970: TimeInterval(GitFixture.baseTimestamp + 1)),
                       "the author timestamp did not decode as Unix seconds")

        assertRefs(of: rootCommit, are: [], "the root commit")
        assertRefs(of: middle, are: [GitRef(kind: .head, name: "HEAD"),
                                     GitRef(kind: .tag, name: "v0.1"),
                                     GitRef(kind: .branch, name: "main")], "the detached commit")
        assertRefs(of: tip, are: [GitRef(kind: .branch, name: "sidecar")], "the sidecar tip")
    }

    /// Compares a commit's refs as a set in both directions.
    private func assertRefs(of commit: GitCommit, are expected: Set<GitRef>, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let actual = Set(commit.refs)
        XCTAssertTrue(expected.isSubset(of: actual),
                      "\(label) is missing refs it carries in the repository", file: file, line: line)
        XCTAssertTrue(actual.isSubset(of: expected),
                      "\(label) carries refs the repository does not have", file: file, line: line)
    }

    // MARK: - the field-count guard: a malformed record throws, it is never skipped

    /// §17.7's seventh named instance: a parser that silently drops the record the test exists to
    /// compare makes that test unfalsifiable. A short record must throw, and the good record that
    /// precedes it must not be returned instead.
    func testARecordWithTheWrongFieldCountThrowsRatherThanBeingSkipped() throws {
        let good = record("1111111111111111111111111111111111111111", "", "", "Wren Alcove",
                          "1614800001", "first commit")
        // Five fields: the subject is gone, which is exactly what a truncated read produces.
        let truncated = "2222222222222222222222222222222222222222\u{1f}\u{1f}\u{1f}Wren Alcove\u{1f}1614800002\u{1e}\n"

        do {
            let parsed = try GitLog.parse(good + truncated)
            XCTFail("a five-field record parsed instead of throwing; \(parsed.count) commits were returned")
        } catch let error as ToolError {
            guard case .decodeFailed(let subject, _) = error else {
                return XCTFail("the parser threw a ToolError that is not .decodeFailed")
            }
            XCTAssertEqual(subject, "git log record", "the decode failure does not name what it was decoding")
        }

        // Seven fields fails the same way: the guard is `exactly six`, not `at least six`.
        let overlong = good.dropLast(2) + "\u{1f}extra\u{1e}\n"
        XCTAssertThrowsError(try GitLog.parse(String(overlong)),
                             "a seven-field record parsed instead of throwing")
    }

    // MARK: - `%D` decoration syntax, as measured on git 2.55.0

    /// The architect's ruling at the gate: every probe-derived parsing fact is cited in the test
    /// that depends on it, naming `git` 2.55.0 and the measured shape, so a future git whose bytes
    /// differ fails a named test instead of silently mis-parsing.
    ///
    /// Measured with `git` 2.55.0 (`git log -1 --format='%D'`): decorations are comma-and-space
    /// separated; a tag is prefixed `tag: `; an attached `HEAD` prints `HEAD -> main`; a detached
    /// one prints a bare `HEAD`, and a detached `HEAD` that also carries a tag and sits on a
    /// branch prints `HEAD, tag: v9, main`; a remote-tracking branch prints `origin/main`.
    func testTheDecorationSyntaxMeasuredOnGit2_55_0Parses() throws {
        let cases: [(decoration: String, expected: Set<GitRef>)] = [
            ("", []),
            ("HEAD -> main", [GitRef(kind: .head, name: "HEAD"), GitRef(kind: .branch, name: "main")]),
            ("HEAD", [GitRef(kind: .head, name: "HEAD")]),
            ("HEAD, tag: v9, main", [GitRef(kind: .head, name: "HEAD"),
                                     GitRef(kind: .tag, name: "v9"),
                                     GitRef(kind: .branch, name: "main")]),
            ("origin/main", [GitRef(kind: .remoteBranch(remote: "origin"), name: "main")]),
            ("HEAD -> main, origin/main, tag: v9",
             [GitRef(kind: .head, name: "HEAD"), GitRef(kind: .branch, name: "main"),
              GitRef(kind: .remoteBranch(remote: "origin"), name: "main"),
              GitRef(kind: .tag, name: "v9")]),
        ]
        // The floor: a loop over an empty table passes every assertion inside it.
        XCTAssertEqual(cases.count, 6, "the decoration table lost a case")
        for (decoration, expected) in cases {
            let parsed = try GitLog.parse(record("3333333333333333333333333333333333333333", "",
                                                 decoration, "Wren Alcove", "1614800003", "a subject"))
            XCTAssertEqual(parsed.count, 1, "the decoration '\(decoration)' did not parse to one commit")
            let actual = Set(parsed.first?.refs ?? [])
            XCTAssertTrue(expected.isSubset(of: actual),
                          "the decoration '\(decoration)' lost refs")
            XCTAssertTrue(actual.isSubset(of: expected),
                          "the decoration '\(decoration)' invented refs")
        }
    }

    // MARK: - a subject carrying separator-like bytes survives

    func testASubjectWithAPipeATabAndANonASCIICharacterSurvives() async throws {
        // A pipe (the separator a naive format would have used), a literal tab, and characters
        // outside ASCII. Invented text, and deliberately not trailing-whitespace-terminated,
        // because `git commit -m` strips trailing whitespace from every line.
        let subject = "pipe | tab\there and é ünïcode ✓"
        let fixture = try await GitFixture(tree)
        let hash = try await fixture.commit(message: subject, files: ["a.txt": "one\n"])

        let commits = try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                               runner: ToolRunner())
        XCTAssertEqual(commits.count, 1, "the fixture's single commit did not parse to one commit")
        XCTAssertEqual(commits.first?.hash, hash, "the parsed hash is not the commit the fixture made")
        XCTAssertEqual(commits.first?.subject, subject,
                       "the subject did not survive byte-for-byte through %s")
    }

    // MARK: - the window (D5)

    func testTheWindowLimitsAndSkips() async throws {
        let fixture = try await GitFixture(tree)
        var hashes: [String] = []
        for index in 1...4 {
            hashes.append(try await fixture.commit(message: "commit \(index)", files: ["a.txt": "\(index)\n"]))
        }

        let newest = try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                              runner: ToolRunner(), limit: 2)
        XCTAssertEqual(newest.map(\.hash), [hashes[3], hashes[2]],
                       "-n did not window the log to the newest two commits")

        let skipped = try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                               runner: ToolRunner(), limit: 2, skip: 2)
        XCTAssertEqual(skipped.map(\.hash), [hashes[1], hashes[0]],
                       "--skip did not move the window")
    }

    // MARK: - the command line is exactly W7's, plus the window

    /// W7 is binding, and the argument vector is the only place it can be checked. `--parents` is
    /// redundant with `%P` and is kept because W7 names it.
    func testTheCommandLineIsW7sPlusTheWindow() async throws {
        let runner = RecordingRunner()
        _ = try await GitLog.commits(root: URL(filePath: "/"), environment: ["PATH": "/usr/bin"],
                                     runner: runner, limit: 7, skip: 3)
        XCTAssertEqual(runner.invocations.count, 1, "commits() did not run exactly one command")
        XCTAssertEqual(runner.invocations.first?.tool, .git, "commits() ran a tool that is not git")
        XCTAssertEqual(runner.invocations.first?.arguments,
                       ["log", "--topo-order", "--all", "--parents",
                        "--format=%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s%x1e",
                        "-n", "7", "--skip", "3"],
                       "the git log argument vector is not W7's plus the window")
    }

    func testANonZeroExitBecomesCommandFailed() async throws {
        let runner = RecordingRunner(stderr: Data("fatal: invented failure\n".utf8), exitCode: 128)
        do {
            _ = try await GitLog.commits(root: URL(filePath: "/"), environment: ["PATH": "/usr/bin"],
                                         runner: runner)
            XCTFail("a non-zero git log exit did not become .commandFailed")
        } catch let error as ToolError {
            guard case .commandFailed(let tool, let code, _) = error else {
                return XCTFail("the wrapper threw a ToolError that is not .commandFailed")
            }
            XCTAssertEqual(tool, .git, "the failure names the wrong tool")
            XCTAssertEqual(code, 128, "the failure carries the wrong exit code")
        }
    }

    // MARK: - helpers

    /// One `git log` record in the format's own bytes: six `\u{1f}`-separated fields, a `\u{1e}`,
    /// and the newline git emits after it.
    private func record(_ fields: String...) -> String {
        fields.joined(separator: "\u{1f}") + "\u{1e}\n"
    }
}

/// A `ToolRunning` that records what it was asked to run and returns a fixed result, so that the
/// argument vector and the exit-code contract can be asserted without a process.
private final class RecordingRunner: ToolRunning, @unchecked Sendable {

    struct Invocation: Sendable {
        let tool: Tool
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let stdout: Data
    private let stderr: Data
    private let exitCode: Int32

    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL,
             environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(Invocation(tool: tool, arguments: arguments)) }
        return ToolOutput(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: false)
    }
}
