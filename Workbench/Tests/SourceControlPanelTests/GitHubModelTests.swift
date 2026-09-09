// C7.7 spec Design §8, plan T4. Gates G2.1, G2.2, G2.4 and G3's `gh` half.
import Foundation
import XCTest
@testable import SourceControlPanel
import AfleetCore
import PanelHostAPI
import SourceControlCore

/// The GitHub tab's reads, its rollup, and every way it can fail.
///
/// **Nothing here runs the machine's `gh`** except the one conditional live leg at the bottom.
/// The machine's `gh` holds the author's own token and its output would be a recorded account in a
/// committed expectation (§11), so the documents these tests decode are the authored ones under
/// `Samples/`: real field names, invented values, no account that exists.
///
/// The `git` half is real, because the branch the list is scoped to has to come from somewhere
/// honest: a repository built under the temporary directory with an invented identity, exactly as
/// `GitRepository` builds it.
@MainActor
final class GitHubModelTests: XCTestCase {

    // MARK: - the invented constants these tests are written against

    /// The branch the fixture repository is on, and therefore the `--head` the branch-scoped list
    /// must carry. Invented, like everything else in `Samples/`.
    private static let branch = "feature/scope-control"

    /// The `gh` argument-vector prefixes this leaf is allowed to produce, named here so that the
    /// assertion in group 8 has a written-out set to compare against rather than a predicate that
    /// could drift with the code it checks. `auth` is not on it and cannot be: every call this
    /// target makes goes through `GhCommands`, which offers these three verbs and no other.
    private static let allowedGhPrefixes = ["pr list", "pr checks", "issue list"]

    // MARK: - the harness

    /// A repository on `branch`, and the environment to run tools in.
    /// `detached` leaves `HEAD` off any branch, which is the state the branch scope has no head to
    /// filter on. It is done here rather than in the test because a `GitRepository` handed to a
    /// nonisolated command after the test has touched it is a value in two isolation regions.
    private func repository(detached: Bool = false) async throws
        -> (tree: ScratchTree, repo: GitRepository) {
        let tree = try ScratchTree()
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        try await repo.branch(Self.branch)
        try await repo.checkout(Self.branch)
        if detached { try await repo.detach("HEAD") }
        return (tree, repo)
    }

    /// The `git` verbs this leaf's GitHub tab is allowed to produce, as the same written-out set
    /// G4 holds the source-control tab to. `add`, `commit`, `checkout`, `branch`, `push` and every
    /// other write verb is absent from it, so a verb introduced here is caught by the gate that
    /// exists to make one unrepresentable rather than by review.
    private static let allowedGitVerbs = ["rev-parse", "log", "status", "diff", "show", "cat-file"]

    /// A model over the fixture repository, with `gh` answered from a script and `git` run for
    /// real. Returns the model, the runner the `gh` vectors are read off, and the one the `git`
    /// vectors are.
    ///
    /// **The `git` side is recorded too.** This model makes `git` invocations of its own —
    /// `rev-parse` for the root and `status` for the branch — and a bare `ToolRunner` on that side
    /// left them outside the universe G4's argv assertion is an assertion about.
    private func model(_ repo: GitRepository, gh script: [(String, StubRunner.Answer)],
                       git: (any ToolRunning)? = nil,
                       links: (any LinkRouterCapability)? = nil)
        -> (model: GitHubModel, gh: StubRunner, git: RecordingRunner) {
        model(cwd: repo.root, environment: repo.environment, gh: script, git: git, links: links)
    }

    /// The same, from the fixture's *values* rather than from the fixture. A test that runs a
    /// further `git` command on the repository — checking out a detached `HEAD`, say — has sent it
    /// to another isolation region by the time it wants a model, and the model needs a directory
    /// and an environment rather than the builder.
    private func model(cwd: URL, environment: [String: String],
                       gh script: [(String, StubRunner.Answer)],
                       git: (any ToolRunning)? = nil,
                       links: (any LinkRouterCapability)? = nil)
        -> (model: GitHubModel, gh: StubRunner, git: RecordingRunner) {
        let stub = StubRunner(script)
        let recorder = RecordingRunner(underlying: git ?? ToolRunner())
        let runner = SplitRunner(git: recorder, gh: stub)
        let model = GitHubModel(cwd: cwd, environment: environment,
                                      runner: runner, links: links)
        return (model, stub, recorder)
    }

    /// The ordinary happy script: the branch-scoped list, checks for both of its pull requests,
    /// and the issue list.
    private func happyScript(checks: String = "checks-passing") throws -> [(String, StubRunner.Answer)] {
        [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
         ("pr checks", .document(try GhSamples.data(checks))),
         ("issue list", .document(try GhSamples.data("issues")))]
    }

    /// Group 8, applied at the end of every flow in this file rather than only in its own test:
    /// the argument-vector assertion is about a **universe of invocations**, so the more of the
    /// suite it sees the more it proves. It names the set it allowed and the count it saw, so a
    /// flow that recorded nothing fails here instead of passing vacuously.
    private func assertOnlyGhReadVerbs(_ stub: StubRunner, atLeast minimum: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let vectors = stub.invocations.filter { $0.tool == .gh }.map { $0.arguments.joined(separator: " ") }
        XCTAssertGreaterThanOrEqual(
            vectors.count, minimum,
            "saw \(vectors.count) gh invocations, expected at least \(minimum); "
            + "an argv assertion over nothing passes vacuously",
            file: file, line: line)
        for vector in vectors {
            XCTAssertTrue(Self.allowedGhPrefixes.contains { vector.hasPrefix($0) },
                          "a gh vector began with none of \(Self.allowedGhPrefixes)",
                          file: file, line: line)
        }
    }

    /// The same assertion for the `git` half of this model, for the same reason: a universe of
    /// invocations rather than a sample, failing rather than passing when it saw none.
    private func assertOnlyGitReadVerbs(_ recorder: RecordingRunner, atLeast minimum: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let verbs = recorder.verbs(of: .git)
        XCTAssertGreaterThanOrEqual(
            verbs.count, minimum,
            "saw \(verbs.count) git invocations, expected at least \(minimum); "
            + "an argv assertion over nothing passes vacuously",
            file: file, line: line)
        for verb in verbs {
            XCTAssertTrue(Self.allowedGitVerbs.contains(verb),
                          "a git vector began with none of \(Self.allowedGitVerbs)",
                          file: file, line: line)
        }
    }

    // MARK: - 1. the branch-scoped list

    func testTheBranchScopedListDecodesAndRendersEveryFieldByValue() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub, git) = model(repo, gh: try happyScript())

        await model.appear()
        let readout = model.readout

        XCTAssertEqual(readout.branch, Self.branch)
        XCTAssertEqual(readout.scope, .branch)
        XCTAssertNil(readout.notice, "the happy path put a notice on the panel")
        XCTAssertEqual(readout.pullRequests.count, 2)

        let first = try XCTUnwrap(readout.pullRequests.first)
        XCTAssertEqual(first.number, 204)
        XCTAssertEqual(first.title, "Scope the pull-request list to the checked-out branch")
        XCTAssertEqual(first.author, "fennel-varro")
        XCTAssertFalse(first.isDraft)
        XCTAssertEqual(first.reviewDecision, "Approved")
        XCTAssertEqual(first.checks, .read(.passing))

        let second = readout.pullRequests[1]
        XCTAssertEqual(second.number, 207)
        XCTAssertEqual(second.title, "Carry the check rollup into the pull-request row")
        XCTAssertEqual(second.author, "dune-pellwick")
        XCTAssertTrue(second.isDraft)
        XCTAssertEqual(second.reviewDecision, "No review requested")

        // The scope is what `--head` says it is, and nothing else.
        let listed = stub.invocations.first { $0.arguments.first == "pr" }
        XCTAssertEqual(listed?.arguments.contains("--head"), true)
        XCTAssertEqual(listed?.arguments.contains(Self.branch), true)
        XCTAssertEqual(listed?.arguments.contains("--state"), true)
        XCTAssertEqual(listed?.arguments.contains("open"), true)

        assertOnlyGhReadVerbs(stub, atLeast: 4)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    func testAllOpenScopeDropsTheHeadFilterAndReadsChecksOnlyForTheSelection() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub, git) = model(
            repo,
            gh: [("pr list", .document(try GhSamples.data("all-open-pull-requests"))),
                 ("pr checks", .document(try GhSamples.data("checks-failing"))),
                 ("issue list", .document(try GhSamples.data("issues")))])

        await model.appear()
        await model.select(scope: .allOpen)
        var readout = model.readout
        XCTAssertEqual(readout.scope, .allOpen)
        XCTAssertEqual(readout.pullRequests.count, 3)
        // Nothing is selected, so no rollup has been read — and none of them claims one.
        XCTAssertEqual(readout.pullRequests.map(\.checks), [.notRead, .notRead, .notRead])

        await model.select(pullRequest: 199)
        readout = model.readout
        XCTAssertEqual(readout.selectedPullRequest, 199)
        XCTAssertEqual(readout.pullRequests.first { $0.number == 199 }?.checks, .read(.failing))
        XCTAssertEqual(readout.selectedChecks.count, 3)
        XCTAssertEqual(readout.selectedChecks.map(\.name),
                       ["build (macos-26)", "test (macos-26)", "integration (samples)"])

        // The all-open list carries no `--head` at all.
        let vectors = stub.invocations.filter { $0.arguments.first == "pr" && $0.arguments[1] == "list" }
        XCTAssertEqual(vectors.count, 2)
        XCTAssertFalse(vectors[1].arguments.contains("--head"),
                       "the all-open list was still scoped to a branch")
        assertOnlyGhReadVerbs(stub, atLeast: 5)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    // MARK: - 2. the check rollup table

    func testTheRollupTable() throws {
        // One row per case, and the empty list first: a rollup that answered `passing` for no
        // checks at all passes every happy-path test ever written against it.
        let table: [(sample: String, expected: CheckRollup)] = [
            ("checks-none", .none),
            ("checks-failing", .failing),
            ("checks-cancelled", .failing),
            ("checks-pending", .pending),
            ("checks-passing", .passing),
            ("checks-skipping", .passing),
            ("checks-unrecognised-bucket", .unknown),
        ]
        for row in table {
            let checks = try GhCommands.decodeChecks(GhSamples.data(row.sample))
            XCTAssertEqual(CheckRollup.of(checks), row.expected,
                           "the rollup for \(row.sample) was not \(row.expected)")
        }
    }

    /// The precedence, over mixtures the samples cannot express — a document holds one shape, and
    /// what ranks above what is only visible where two buckets meet.
    func testTheRollupPrecedenceOverMixedBuckets() {
        let table: [(name: String, buckets: [CheckBucket], expected: CheckRollup)] = [
            // A failure outranks everything, including a bucket the panel cannot name.
            ("a failure among pendings", [.pending, .failing], .failing),
            ("a failure among unrecognised", [.unrecognised, .failing], .failing),
            // **The one case that distinguishes the two candidate rules.** `unrecognised` ranks
            // above `pending`: "still running" is a claim about what happens next, and the panel
            // has no basis to make it for a state it has never seen (ruled 2026-09-09).
            ("a pending beside an unrecognised", [.pending, .unrecognised], .unknown),
            ("a pending beside a pass", [.passing, .pending], .pending),
            // A skipped check did not fail and nothing further will change it — `gh`'s own exit
            // code says the same. Ruled, and named here rather than falling through the table.
            ("every check skipped", [.skipped, .skipped], .passing),
            ("a skip beside a pass", [.passing, .skipped], .passing),
            ("a skip beside a pending", [.skipped, .pending], .pending),
            // And "nothing ran at all", which is the case all-skipped must not be folded into.
            ("no checks at all", [], CheckRollup.none),
        ]
        for row in table {
            XCTAssertEqual(CheckRollup.of(row.buckets), row.expected,
                           "the rollup for \(row.name) was not \(row.expected)")
        }
    }

    func testAPullRequestWhoseChecksCouldNotBeReadSaysSoRatherThanPassing() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        // The list answers; `pr checks` does not.
        let (model, stub, git) = model(
            repo,
            gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                 ("pr checks", .failure(code: 1, stderr: "no checks reported on this branch")),
                 ("issue list", .document(try GhSamples.data("issues")))])

        await model.appear()
        let readout = model.readout
        XCTAssertEqual(readout.pullRequests.map(\.checks), [.notRead, .notRead])
        XCTAssertEqual(readout.pullRequests.first?.checksLabel, "Checks not read")
        assertOnlyGhReadVerbs(stub, atLeast: 4)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    // MARK: - 3. exit 8

    func testExitEightFromGhPrChecksRendersThePendingRowsRatherThanAnError() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let stub = StubRunner(
            [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
             ("issue list", .document(try GhSamples.data("issues")))])
        let runner = SplitRunner(git: ToolRunner(), gh: stub,
                                 pendingChecks: try GhSamples.data("checks-pending"))
        let model = GitHubModel(cwd: repo.root, environment: repo.environment, runner: runner)

        await model.appear()
        let readout = model.readout
        XCTAssertNil(readout.notice, "exit 8 was rendered as a failure")
        XCTAssertEqual(readout.pullRequests.map(\.checks), [.read(.pending), .read(.pending)])
        XCTAssertEqual(readout.pullRequests.first?.checksLabel, "Checks running")
    }

    // MARK: - 4. issues

    func testIssuesDecodeAndRender() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub, git) = model(repo, gh: try happyScript())

        await model.appear()
        let readout = model.readout
        XCTAssertEqual(readout.issues.count, 2)

        let first = try XCTUnwrap(readout.issues.first)
        XCTAssertEqual(first.number, 312)
        XCTAssertEqual(first.title, "The rollup badge shows passing before the checks are read")
        XCTAssertEqual(first.author, "fennel-varro")
        XCTAssertEqual(first.labels, ["bug", "panel"])
        XCTAssertEqual(first.updatedAt,
                       try Date("2026-05-13T07:19:44Z", strategy: .iso8601))

        let second = readout.issues[1]
        XCTAssertEqual(second.number, 305)
        XCTAssertEqual(second.author, "loom-upkeep-bot")
        XCTAssertEqual(second.labels, [])
        assertOnlyGhReadVerbs(stub, atLeast: 4)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    // MARK: - 5. gh absent

    func testAbsentGhRendersItsOwnEmptyStateWithNoAuthHint() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(repo, gh: [("", .binaryNotFound)])

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertEqual(notice.placement, .emptyState)
        XCTAssertTrue(notice.message.contains("gh"), "the empty state does not name the tool")
        let hint = try XCTUnwrap(notice.hint, "the absent-gh state offers no remedy at all")
        XCTAssertFalse(hint.contains("gh auth login"),
                       "a missing binary was answered with a re-authentication hint")
        XCTAssertTrue(hint.lowercased().contains("install"),
                      "the absent-gh hint does not say to install it")
    }

    // MARK: - 6. logged out, and every other non-zero exit

    func testANotAuthenticatedExitRendersTheEmptyStateWithTheAuthHint() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(
            repo,
            gh: [("", .failure(code: 4, stderr: "gh: To get started with GitHub CLI, please run: "
                                              + "gh auth login"))])

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertEqual(notice.placement, .emptyState)
        XCTAssertEqual(notice.hint, GitHubReadout.authenticationHint)
    }

    func testAnyOtherNonZeroExitRendersAGenericRowWithNoHint() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(repo, gh: [("", .failure(code: 1, stderr: "could not resolve "
                                                                            + "to a Repository"))])

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertEqual(notice.placement, .row)
        XCTAssertNil(notice.hint, "a failure nobody can re-authenticate away offered the login hint")
    }

    // MARK: - 7. nothing rendered carries a byte the tool printed

    func testNoRenderedStringCarriesAByteTheToolsStderrCarried() async throws {
        // A token no message in this target could contain by accident. It is invented and belongs
        // to nobody (§11).
        let token = "QUILLWRACK-7731"
        for code: Int32 in [1, 4] {
            let (tree, repo) = try await repository()
            defer { tree.remove() }
            let (model, _, _) = model(
                repo,
                gh: [("", .failure(code: code,
                                   stderr: "gh: \(token) — gh auth login — \(token)"))])
            await model.appear()
            let readout = model.readout
            let rendered = Self.renderedStrings(of: readout)
            XCTAssertFalse(rendered.isEmpty, "the readout rendered nothing to search")
            for string in rendered {
                XCTAssertFalse(string.contains(token),
                               "a rendered string carried a byte the tool printed")
            }
        }

        // And the absent-binary path, whose error carries no stderr at all but whose message is
        // written by the same classifier.
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(repo, gh: [("", .binaryNotFound)])
        await model.appear()
        for string in Self.renderedStrings(of: model.readout) {
            XCTAssertFalse(string.contains(token))
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
        for child in Mirror(reflecting: value).children {
            found += renderedStrings(of: child.value)
        }
        return found
    }

    // MARK: - 8. the argv assertion

    func testEveryGhArgumentVectorBeginsWithOneOfTheThreeReadVerbs() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub, git) = model(
            repo,
            gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                 ("pr checks", .document(try GhSamples.data("checks-passing"))),
                 ("issue list", .document(try GhSamples.data("issues")))])

        // Every door into the model, so the universe this assertion sees is the whole of it.
        await model.appear()
        await model.refresh()
        await model.select(scope: .allOpen)
        await model.select(pullRequest: 204)
        await model.select(scope: .branch)
        await model.branchDidChange(to: "other/branch")

        let vectors = stub.invocations.filter { $0.tool == .gh }.map(\.arguments)
        XCTAssertGreaterThanOrEqual(
            vectors.count, 12,
            "the argv assertion saw \(vectors.count) gh invocations across "
            + "\(Self.allowedGhPrefixes) — too few to be proving anything")
        for vector in vectors {
            let line = vector.joined(separator: " ")
            XCTAssertTrue(Self.allowedGhPrefixes.contains { line.hasPrefix($0) },
                          "a gh vector began with none of \(Self.allowedGhPrefixes)")
            XCTAssertNotEqual(vector.first, "auth", "this leaf produced a gh auth vector")
        }
        // And the `git` half of the same universe: this model resolves a root and reads a status
        // of its own, and both are argv this leaf produces (G4).
        assertOnlyGitReadVerbs(git, atLeast: 6)
    }

    // MARK: - the readout's action inventory (G4's second proof, asserted again by T6)

    func testTheReadoutCarriesItsCompleteActionInventory() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(repo, gh: try happyScript())
        await model.appear()

        XCTAssertEqual(model.readout.actions,
                       [.refresh, .scopeToBranch, .scopeToAllOpen, .selectPullRequest,
                        .openPullRequest])
    }

    // MARK: - 9. which tool failed, in the words the user reads

    /// The `git` half of a read fails, and the panel says so about **`git`**.
    ///
    /// Two of the three reads this cycle makes are `git`'s, and a failure value that dropped the
    /// tool left every notice worded for the other one: a `git` that never answered told the user
    /// GitHub CLI did not answer in time, and the remedy they would go looking for is for a tool
    /// that was working.
    func testAGitTimeoutIsWordedForGitAndNotForTheGitHubCLI() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let git = ScriptedRunner()
        git.thrown = .timedOut(tool: .git, afterMs: 30_000)
        let (model, _, _) = model(repo, gh: try happyScript(), git: git)

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertFalse(notice.message.contains("GitHub CLI"),
                       "a git failure was reported to the user as a GitHub CLI failure")
        XCTAssertTrue(notice.message.hasPrefix("Git "),
                      "the notice does not name the tool that actually failed")
    }

    func testAGitNonZeroExitIsWordedForGitAndNotForTheGitHubCLI() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        // The root resolves; the status read is what exits non-zero, which is the one `git` failure
        // that reaches the classifier as `commandFailed` (a failing `rev-parse` is the empty state).
        let (model, _, _) = model(repo, gh: try happyScript(), git: Self.gitFailingStatus(
            in: repo, stderr: "fatal: detected dubious ownership in repository"))

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertFalse(notice.message.contains("GitHub CLI"),
                       "a git failure was reported to the user as a GitHub CLI failure")
        XCTAssertTrue(notice.message.hasPrefix("Git "),
                      "the notice does not name the tool that actually failed")
        XCTAssertTrue(notice.message.contains("128"), "the exit code git returned is not named")
    }

    /// The not-authenticated classification is about `gh` and only `gh`.
    ///
    /// `git` says "authentication failed" for a credential helper, a private remote and an expired
    /// SSH key alike, and none of those is fixed by `gh auth login`. G3's clause is binding: a
    /// panel that offered the same remedy for every failure would send the user to
    /// re-authenticate over something else entirely.
    func testAGitFailureMentioningAuthenticationNeverOffersTheGhLoginHint() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _, _) = model(repo, gh: try happyScript(), git: Self.gitFailingStatus(
            in: repo,
            stderr: "fatal: could not read Username for 'https://example.invalid': terminal "
                  + "prompts disabled; authentication failed"))

        await model.appear()
        let notice = try XCTUnwrap(model.readout.notice)
        XCTAssertNotEqual(notice.hint, GitHubReadout.authenticationHint,
                          "a git failure was answered with the gh login remedy")
        XCTAssertNil(notice.hint, "a git failure nobody can re-authenticate away offered a remedy")
        XCTAssertFalse(notice.message.contains("signed in"),
                       "a git failure was rendered as gh not being signed in")
    }

    /// A `git` runner whose `rev-parse` answers with the fixture's own root and whose `status`
    /// exits 128 with `stderr` behind it.
    private static func gitFailingStatus(in repo: GitRepository, stderr: String) -> ScriptedRunner {
        let root = repo.root.path(percentEncoded: false) + "\n"
        return ScriptedRunner([("rev-parse", .document(Data(root.utf8))),
                               ("status", .failure(code: 128, stderr: stderr))])
    }

    /// Every notice this tab can show, with its placement and its hint.
    ///
    /// A table rather than three tests, because the mapping *is* the failure clause of Design §8:
    /// which failures replace the tab's content and which sit above it, and which one remedy
    /// belongs to which problem. `nil` hints are rows here too — a hint offered for a failure
    /// nobody can act on is the same defect as the wrong hint.
    func testEveryNoticeThisTabCanShow() throws {
        typealias Row = (name: String,
                         failure: GitHubModel.Failure,
                         placement: GitHubReadout.Notice.Placement,
                         hint: String?)
        let table: [Row] = [
            ("no repository", .notARepository, .emptyState, nil),
            ("gh absent", .toolMissing(.gh), .emptyState, GitHubReadout.installHint),
            ("git absent", .toolMissing(.git), .emptyState, nil),
            ("gh logged out", .notAuthenticated, .emptyState,
             GitHubReadout.authenticationHint),
            ("gh exited non-zero", .commandFailed(tool: .gh, exitCode: 1), .row, nil),
            ("git exited non-zero", .commandFailed(tool: .git, exitCode: 128), .row, nil),
            ("gh timed out", .timedOut(tool: .gh), .row, nil),
            ("git timed out", .timedOut(tool: .git), .row, nil),
            ("gh printed something unreadable", .unreadable(tool: .gh), .row, nil),
            ("git printed something unreadable", .unreadable(tool: .git), .row, nil),
            ("gh could not be run", .unavailable(tool: .gh), .row, nil),
            ("git could not be run", .unavailable(tool: .git), .row, nil),
        ]
        for row in table {
            let notice = try XCTUnwrap(GitHubReadout.notice(for: row.failure),
                                       "\(row.name) rendered no notice at all")
            XCTAssertEqual(notice.placement, row.placement, "\(row.name) was placed wrongly")
            XCTAssertEqual(notice.hint, row.hint, "\(row.name) offered the wrong remedy")
            XCTAssertFalse(notice.message.isEmpty, "\(row.name) rendered an empty message")
        }
        XCTAssertNil(GitHubReadout.notice(for: nil), "no failure rendered a notice")

        // And the half a placement and a hint cannot say: each notice names the tool it is about.
        for row in table where row.name.hasPrefix("git ") {
            let notice = try XCTUnwrap(GitHubReadout.notice(for: row.failure))
            XCTAssertFalse(notice.message.contains("GitHub CLI"),
                           "\(row.name) was worded for the other tool")
        }
    }

    // MARK: - 10. supersession: two overlapping cycles, one document

    /// A read that loses to a later one writes **nothing**.
    ///
    /// The interleaving is forced rather than raced: the branch-scoped cycle is held inside its
    /// `pr list` while a whole *All open* cycle runs to completion, and only then does it resume.
    /// Without a generation claimed before the first await, the loser resumes and assigns its own
    /// list — a branch-scoped list under an *All open* control, with every row saying its checks
    /// were not read because the winner's scope was read after the loser's document.
    func testAReadSupersededByAScopeChangeAssignsNothingWhenItResumes() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let stub = StubRunner(
            // The branch-scoped vector is the one carrying `--head`; the all-open vector is the
            // same verb without it, which is what makes these two prefixes distinguish the cycles.
            [("pr list --state open --limit \(GitHubModel.pullRequestLimit) --head",
              .document(try GhSamples.data("branch-pull-requests"))),
             ("pr list", .document(try GhSamples.data("all-open-pull-requests"))),
             ("pr checks", .document(try GhSamples.data("checks-passing"))),
             ("issue list", .document(try GhSamples.data("issues")))])

        let holder = ModelHolder()
        let hooked = HookRunner(underlying: stub, firstMatching: "pr list") { [holder] in
            guard let model = holder.model else { return }
            // The user clicks *All open* while the branch-scoped list is still in flight, and that
            // cycle runs to its end before the first one is answered.
            await Task { @MainActor in await model.select(scope: .allOpen) }.value
        }
        let git = RecordingRunner(underlying: ToolRunner())
        let model = GitHubModel(cwd: repo.root, environment: repo.environment,
                                runner: SplitRunner(git: git, gh: hooked))
        holder.model = model

        await model.appear()

        let readout = model.readout
        XCTAssertEqual(readout.scope, .allOpen)
        XCTAssertEqual(readout.pullRequests.map(\.number), [204, 207, 199],
                       "the superseded branch-scoped read overwrote the list it lost to")
        XCTAssertFalse(readout.isLoading, "a superseded cycle left the tab loading")
        XCTAssertTrue(readout.hasRead)
        assertOnlyGhReadVerbs(stub, atLeast: 3)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    // MARK: - 11. a cancelled read is not an empty tab

    /// A cancelled read leaves what was on screen and does not latch `hasRead`.
    ///
    /// `.cancelled` classifies to no notice at all, which is right — the panel asked the read to
    /// stop — but a cycle that then cleared the document and latched showed an empty tab with
    /// nothing said about it, and `appear()` never read again.
    func testACancelledReadLeavesThePreviousStateAndDoesNotLatch() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        // The machine's `git` behind it, so the reads this test does not cancel are the real ones.
        let git = ScriptedRunner(underlying: ToolRunner())
        git.thrown = .cancelled(tool: .git)
        let (model, _, _) = model(repo, gh: try happyScript(), git: git)

        await model.appear()
        XCTAssertFalse(model.hasRead,
                       "a cancelled read latched hasRead, so the tab will never read again")
        XCTAssertNil(model.readout.notice, "a cancelled read put a notice on the panel")

        // It reads on the next appearance, because the first one never counted.
        git.thrown = nil
        await model.appear()
        XCTAssertEqual(model.readout.pullRequests.count, 2)
        XCTAssertTrue(model.hasRead)

        // And a cancelled read over a loaded tab leaves the tab loaded.
        git.thrown = .cancelled(tool: .git)
        await model.refresh()
        XCTAssertEqual(model.readout.pullRequests.count, 2,
                       "a cancelled read emptied a tab that had read perfectly well")
        XCTAssertNil(model.readout.notice)
        XCTAssertFalse(model.readout.isLoading, "a cancelled read left the tab loading forever")
    }

    // MARK: - 12. a selection the new list no longer holds

    func testARefreshDropsASelectionTheNewListNoLongerHolds() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let gh = ScriptedRunner(try happyScript())
        let model = GitHubModel(cwd: repo.root, environment: repo.environment,
                                runner: SplitRunner(git: ToolRunner(), gh: gh))

        await model.appear()
        await model.select(pullRequest: 204)
        XCTAssertEqual(model.readout.selectedPullRequest, 204)

        // 204 merges, so the branch has nothing open on it any more.
        gh.script = [("pr list", .document(Data("[]".utf8))),
                     ("issue list", .document(try GhSamples.data("issues")))]
        await model.refresh()

        XCTAssertTrue(model.readout.pullRequests.isEmpty)
        XCTAssertNil(model.readout.selectedPullRequest,
                     "the readout still names a pull request no row can highlight")
        XCTAssertTrue(model.readout.selectedChecks.isEmpty)
    }

    func testABranchChangeDropsASelectionTheNewListNoLongerHolds() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let gh = ScriptedRunner(try happyScript())
        let model = GitHubModel(cwd: repo.root, environment: repo.environment,
                                runner: SplitRunner(git: ToolRunner(), gh: gh))

        await model.appear()
        await model.select(pullRequest: 207)
        XCTAssertEqual(model.readout.selectedPullRequest, 207)

        gh.script = [("pr list", .document(Data("[]".utf8))),
                     ("issue list", .document(try GhSamples.data("issues")))]
        await model.branchDidChange(to: "other/branch")

        XCTAssertNil(model.readout.selectedPullRequest,
                     "a branch change carried a selection into a list that does not hold it")
        XCTAssertTrue(model.readout.selectedChecks.isEmpty)
    }

    // MARK: - 13. Open emits a link and builds no URL (G2.3's headless half at this leaf)

    /// *Open* emits exactly `.pullRequest(number)` with the destination it was given, and this
    /// leaf builds no URL and registers no target (Design §9, W5).
    func testOpenEmitsExactlyThePullRequestLinkAndBuildsNoURL() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let router = RecordingLinkRouter()
        let (model, _, _) = model(repo, gh: try happyScript(), links: router)

        await model.appear()
        await model.open(pullRequest: 207, from: .newWindow)

        XCTAssertEqual(router.opened.count, 1, "Open emitted \(router.opened.count) links, not one")
        XCTAssertEqual(router.opened.first?.link, .pullRequest(207))
        XCTAssertEqual(router.opened.first?.destination, .newWindow)
        for opened in router.opened {
            if case .url = opened.link { XCTFail("this leaf turned a pull request into a URL") }
        }
        XCTAssertTrue(router.registrations.isEmpty,
                      "this leaf registered a link target; Design §9 says it emits and does not "
                      + "register")

        // The default destination is the panel the user is looking at.
        await model.open(pullRequest: 204)
        XCTAssertEqual(router.opened.last?.destination, .currentPanel)
        XCTAssertEqual(router.opened.last?.link, .pullRequest(204))
    }

    // MARK: - 14. a detached HEAD asks no question it was not asked

    /// In the branch scope with no branch, the list stays empty and **no `pr list` runs at all**.
    ///
    /// Filtering on nothing is the *All open* list, which is a different question silently
    /// answered; the assertion is on the invocation and not only on the rows, because a list that
    /// happened to come back empty would pass a row-count assertion while asking it.
    func testADetachedHeadListsNothingAndAsksNoAllOpenQuestion() async throws {
        let (tree, repo) = try await repository(detached: true)
        defer { tree.remove() }
        let (model, stub, git) = model(repo, gh: try happyScript())

        await model.appear()
        let readout = model.readout
        XCTAssertTrue(readout.isDetachedHead)
        XCTAssertNil(readout.branch)
        XCTAssertTrue(readout.pullRequests.isEmpty)
        XCTAssertNil(readout.notice, "a detached HEAD is a state, not a failure")
        // The issues are still worth reading, and are still read.
        XCTAssertEqual(readout.issues.count, 2)
        XCTAssertTrue(stub.invocations.filter { $0.arguments.starts(with: ["pr", "list"]) }.isEmpty,
                      "a detached HEAD listed pull requests with no head filter — the all-open "
                      + "question, silently answered in the branch scope")
        assertOnlyGhReadVerbs(stub, atLeast: 1)
        assertOnlyGitReadVerbs(git, atLeast: 2)
    }

    // MARK: - the live leg (conditional, G2's live half; tracker 118)

    /// Gate G2's live leg: the three verbs against a **real, public** repository return documents
    /// this leaf's models decode.
    ///
    /// Skipped with a named reason unless a `gh` on this machine can read a public repository,
    /// which is the same condition `SourceControlCoreTests/GitHubLiveTests` gates on and the same
    /// skip discipline: the suite has to pass from a clean checkout with no network and no login,
    /// and a skipped leg says in words why it was skipped.
    ///
    /// **The gate is a read of one of the three allowed verbs, not `gh auth status`.** That is a
    /// deliberate departure from C7.3's file: no `auth` verb may exist anywhere in this leaf's
    /// diff, and a gate that spelled one would be the single counterexample to the structural
    /// claim G3 makes. `issue list` failing covers exactly the same three causes — no `gh`, no
    /// login, no network — and the skip reason names all three.
    ///
    /// **The repository is named through `GH_REPO`**, which is environment rather than a command
    /// line: W7 leaves this target no `--repo` to pass and no `git clone` to write, and `gh`
    /// resolves a repository from that variable outside a working tree.
    ///
    /// **It asserts no value.** Everything it reads belongs to a real account, so the assertions
    /// are counts and shapes only (§6.3, §11).
    func testTheLiveReadsDecodeIntoThisLeafsModels() async throws {
        // A directory this test created, and never one it merely found: `gh` is spawned with this
        // as its cwd, and handing a child a directory nobody owns is what the spec's TCC clause is
        // about. `ScratchTree` also refuses to sit inside a config home (X9).
        let tree = try ScratchTree()
        defer { tree.remove() }
        let runner = RecordingRunner()
        // `cli/cli` for the reason C7.3 chose it: large, public, reliably carrying open pull
        // requests, and `gh`'s own project — so a field it stopped emitting is a real break.
        var environment = ProcessInfo.processInfo.environment
        environment["GH_REPO"] = "cli/cli"
        let root = tree.root

        // **The whole leg is inside the gate, not just its first read.** A network that dropped
        // between the issue list and a pull request's checks failed a suite whose floor is that it
        // passes from a clean checkout with no network and no login; every read here is subject to
        // the same three conditions, so every read is skipped by the same named reason.
        var reachedACheckInFlight = false
        do {
            let issues = try await GhCommands.issues(root: root, limit: 5,
                                                     environment: environment, runner: runner)
            XCTAssertGreaterThanOrEqual(issues.count, 0)

            let pulls = try await GhCommands.pullRequests(root: root, head: nil, state: "open",
                                                          limit: 5, environment: environment,
                                                          runner: runner)
            XCTAssertGreaterThanOrEqual(pulls.count, 0)

            for pull in pulls {
                let checks = try await GhCommands.checks(root: root, pullRequest: pull.number,
                                                         environment: environment, runner: runner)
                XCTAssertGreaterThanOrEqual(checks.count, 0)
                if CheckRollup.of(checks) == .pending { reachedACheckInFlight = true }
            }
        } catch {
            throw XCTSkip("gh could not read a public repository — it is not installed, not "
                          + "logged in, or there is no network; G2's live leg needs all three")
        }
        // The live leg's own invocations belong to the same universe as every other one in this
        // file: the vectors it produced are read verbs, and the count says it produced some.
        let vectors = runner.invocations(of: .gh).map { $0.arguments.joined(separator: " ") }
        XCTAssertGreaterThanOrEqual(vectors.count, 2,
                                    "the live leg asserted its argv over \(vectors.count) "
                                    + "invocations")
        for vector in vectors {
            XCTAssertTrue(Self.allowedGhPrefixes.contains { vector.hasPrefix($0) },
                          "a live gh vector began with none of \(Self.allowedGhPrefixes)")
        }
        // Reported, never asserted: tracker 118 closes only if a check in flight was reached, and
        // whether one was is a property of GitHub at this moment rather than of this leaf.
        print("live leg: reached a check in flight = \(reachedACheckInFlight)")
    }
}

/// A `LinkRouterCapability` that records instead of routing.
///
/// The seam `open(pullRequest:from:)` is written against, so a test asserts the **link and the
/// destination** that left this leaf rather than a page that arrived somewhere. T6 drives the same
/// emission through a real `LinkRouter`; this is the unit half, and it is also what makes
/// "registers nothing" (Design §9) an assertion rather than a claim.
private final class RecordingLinkRouter: LinkRouterCapability, @unchecked Sendable {

    struct Opened: Sendable {
        let link: WorkspaceLink
        let destination: LinkDestination
    }

    private let lock = NSLock()
    private var _opened: [Opened] = []
    private var _registrations: [PanelTabID] = []

    var opened: [Opened] { lock.withLock { _opened } }
    var registrations: [PanelTabID] { lock.withLock { _registrations } }

    func register(_ target: LinkTarget) async {
        lock.withLock { _registrations.append(target.tab) }
    }

    func unregister(tab: PanelTabID) async {}

    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        lock.withLock { _opened.append(Opened(link: link, destination: destination)) }
    }
}

/// A `ToolRunning` whose script a test can **replace between reads**, and which can be made to
/// throw one error for everything.
///
/// `StubRunner`'s script is fixed at construction, which is exactly right for a single read and
/// cannot express the two shapes a multi-cycle test needs: a list that answers differently the
/// second time (a pull request merged between two reads) and a tool that starts failing partway
/// through a session.
private final class ScriptedRunner: ToolRunning, @unchecked Sendable {

    private let lock = NSLock()
    private var _script: [(needle: String, answer: StubRunner.Answer)]
    private var _thrown: ToolError?
    private var _invocations: [RecordingRunner.Invocation] = []
    /// Answers whatever the script does not, so a test can make one tool fail for a while and
    /// leave the rest of a real read alone.
    private let underlying: (any ToolRunning)?

    init(_ script: [(String, StubRunner.Answer)] = [], underlying: (any ToolRunning)? = nil) {
        _script = script.map { (needle: $0.0, answer: $0.1) }
        self.underlying = underlying
    }

    /// Matched **anywhere** in the invocation's arguments rather than at their head: a `git`
    /// command line begins with the `-c` settings its reader pins, so a prefix match would look
    /// for the verb where the configuration is.
    var script: [(String, StubRunner.Answer)] {
        get { lock.withLock { _script.map { ($0.needle, $0.answer) } } }
        set { lock.withLock { _script = newValue.map { (needle: $0.0, answer: $0.1) } } }
    }

    /// When set, every invocation throws it and the script is not consulted.
    var thrown: ToolError? {
        get { lock.withLock { _thrown } }
        set { lock.withLock { _thrown = newValue } }
    }

    var invocations: [RecordingRunner.Invocation] { lock.withLock { _invocations } }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        let (thrown, script) = lock.withLock {
            _invocations.append(RecordingRunner.Invocation(tool: tool, arguments: arguments))
            return (_thrown, _script)
        }
        if let thrown { throw thrown }
        let line = arguments.joined(separator: " ")
        guard let match = script.first(where: { line.contains($0.needle) }) else {
            if let underlying {
                return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                                environment: environment, timeout: timeout)
            }
            throw ToolError.commandFailed(tool: tool, exitCode: 127,
                                          stderrTail: "the script has no answer for this invocation")
        }
        switch match.answer {
        case .document(let data):
            return ToolOutput(stdout: data, stderr: Data(), exitCode: 0, timedOut: false)
        case .failure(let code, let stderr):
            return ToolOutput(stdout: Data(), stderr: Data(stderr.utf8), exitCode: code,
                              timedOut: false)
        case .binaryNotFound:
            throw ToolError.binaryNotFound(tool: tool)
        }
    }
}

/// A `ToolRunning` that runs `hook` to completion the **first** time an invocation matches
/// `prefix`, and then answers from `underlying`.
///
/// It is how a supersession test forces an interleaving instead of racing for one: the losing
/// cycle is held inside a real await while the winning cycle runs whole, which is the ordering the
/// defect needs and the one a `Task` and a sleep can only make likely.
private final class HookRunner: ToolRunning, @unchecked Sendable {

    private let underlying: any ToolRunning
    private let prefix: String
    private let hook: @Sendable () async -> Void
    private let lock = NSLock()
    private var fired = false

    init(underlying: any ToolRunning, firstMatching prefix: String,
         hook: @escaping @Sendable () async -> Void) {
        self.underlying = underlying
        self.prefix = prefix
        self.hook = hook
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        let matched = arguments.joined(separator: " ").hasPrefix(prefix)
        let shouldFire = lock.withLock {
            guard matched, !fired else { return false }
            fired = true
            return true
        }
        if shouldFire { await hook() }
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }
}

/// A box for the model a hook has to reach, which cannot be captured before it exists.
private final class ModelHolder: @unchecked Sendable {
    var model: GitHubModel?
}

/// A `ToolRunning` that sends `git` to one runner and `gh` to another.
///
/// The `git` half of these tests is real — the branch a list is scoped to has to come from a real
/// repository — while the `gh` half must never be, because the machine's `gh` holds the author's
/// token. One runner cannot be both, and neither of Support's two is: this is the seam between
/// them, in this task's own file as the brief requires.
///
/// `pendingChecks`, when set, answers `gh pr checks` with **exit 8 and the rows behind it** — the
/// one shape `StubRunner`'s script cannot express, because its `.failure` carries no stdout and
/// `gh`'s pending exit does (C7.3's D3).
private final class SplitRunner: ToolRunning, @unchecked Sendable {
    private let git: any ToolRunning
    private let gh: any ToolRunning
    private let pendingChecks: Data?

    init(git: any ToolRunning, gh: any ToolRunning, pendingChecks: Data? = nil) {
        self.git = git
        self.gh = gh
        self.pendingChecks = pendingChecks
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        if tool == .gh, let pendingChecks, arguments.starts(with: ["pr", "checks"]) {
            return ToolOutput(stdout: pendingChecks, stderr: Data(), exitCode: 8, timedOut: false)
        }
        let underlying = tool == .gh ? gh : git
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }
}
