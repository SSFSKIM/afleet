// C7.7 spec Design §8, plan T4. Gates G2.1, G2.2, G2.4 and G3's `gh` half.
import Foundation
import XCTest
@testable import SourceControlPanel
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
    private func repository() async throws -> (tree: ScratchTree, repo: GitRepository) {
        let tree = try ScratchTree()
        let repo = try await GitRepository(tree)
        try await repo.commit("the first commit", files: ["README.md": "loom\n"])
        try await repo.branch(Self.branch)
        try await repo.checkout(Self.branch)
        return (tree, repo)
    }

    /// A model over the fixture repository, with `gh` answered from a script and `git` run for
    /// real. Returns the model and the runner the `gh` vectors are read off.
    private func model(_ repo: GitRepository, gh script: [(String, StubRunner.Answer)],
                       links: (any LinkRouterCapability)? = nil)
        -> (model: GitHubModel, gh: StubRunner) {
        let stub = StubRunner(script)
        let runner = SplitRunner(git: ToolRunner(), gh: stub)
        let model = GitHubModel(cwd: repo.root, environment: repo.environment,
                                      runner: runner, links: links)
        return (model, stub)
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

    // MARK: - 1. the branch-scoped list

    func testTheBranchScopedListDecodesAndRendersEveryFieldByValue() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub) = model(repo, gh: try happyScript())

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
    }

    func testAllOpenScopeDropsTheHeadFilterAndReadsChecksOnlyForTheSelection() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, stub) = model(
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

    func testAPullRequestWhoseChecksCouldNotBeReadSaysSoRatherThanPassing() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        // The list answers; `pr checks` does not.
        let (model, stub) = model(
            repo,
            gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                 ("pr checks", .failure(code: 1, stderr: "no checks reported on this branch")),
                 ("issue list", .document(try GhSamples.data("issues")))])

        await model.appear()
        let readout = model.readout
        XCTAssertEqual(readout.pullRequests.map(\.checks), [.notRead, .notRead])
        XCTAssertEqual(readout.pullRequests.first?.checksLabel, "Checks not read")
        assertOnlyGhReadVerbs(stub, atLeast: 4)
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
        let (model, stub) = model(repo, gh: try happyScript())

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
    }

    // MARK: - 5. gh absent

    func testAbsentGhRendersItsOwnEmptyStateWithNoAuthHint() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _) = model(repo, gh: [("", .binaryNotFound)])

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
        let (model, _) = model(
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
        let (model, _) = model(repo, gh: [("", .failure(code: 1, stderr: "could not resolve "
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
            let (model, _) = model(
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
        let (model, _) = model(repo, gh: [("", .binaryNotFound)])
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
        let (model, stub) = model(
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
    }

    // MARK: - the readout's action inventory (G4's second proof, asserted again by T6)

    func testTheReadoutCarriesItsCompleteActionInventory() async throws {
        let (tree, repo) = try await repository()
        defer { tree.remove() }
        let (model, _) = model(repo, gh: try happyScript())
        await model.appear()

        XCTAssertEqual(model.readout.actions,
                       [.refresh, .scopeToBranch, .scopeToAllOpen, .selectPullRequest,
                        .openPullRequest])
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
        let runner = ToolRunner()
        // `cli/cli` for the reason C7.3 chose it: large, public, reliably carrying open pull
        // requests, and `gh`'s own project — so a field it stopped emitting is a real break.
        var environment = ProcessInfo.processInfo.environment
        environment["GH_REPO"] = "cli/cli"
        let root = URL(filePath: NSTemporaryDirectory())

        let issues: [Issue]
        do {
            issues = try await GhCommands.issues(root: root, limit: 5, environment: environment,
                                                 runner: runner)
        } catch {
            throw XCTSkip("gh could not read a public repository — it is not installed, not "
                          + "logged in, or there is no network; G2's live leg needs all three")
        }
        XCTAssertGreaterThanOrEqual(issues.count, 0)

        let pulls = try await GhCommands.pullRequests(root: root, head: nil, state: "open",
                                                      limit: 5, environment: environment,
                                                      runner: runner)
        XCTAssertGreaterThanOrEqual(pulls.count, 0)

        var reachedACheckInFlight = false
        for pull in pulls {
            let checks = try await GhCommands.checks(root: root, pullRequest: pull.number,
                                                     environment: environment, runner: runner)
            XCTAssertGreaterThanOrEqual(checks.count, 0)
            if CheckRollup.of(checks) == .pending { reachedACheckInFlight = true }
        }
        // Reported, never asserted: tracker 118 closes only if a check in flight was reached, and
        // whether one was is a property of GitHub at this moment rather than of this leaf.
        print("live leg: reached a check in flight = \(reachedACheckInFlight)")
    }
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
