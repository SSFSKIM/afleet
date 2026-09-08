import Foundation
import XCTest
@testable import SourceControlCore

/// Gate **G3**: this leaf's pull-request model decodes what the live GitHub API actually returns.
///
/// The samples in `GitHubModelTests` are authored, so they can only prove that the parsers read
/// the shape their author believed in. G3 is the other half — it asks the real `gh` for real
/// pull requests and decodes them with the same model and the same `--json` list. A field `gh`
/// stopped emitting, or started emitting in another shape, fails here rather than in a panel.
///
/// **It must not run offline or logged out**, because the parent's acceptance requires the suite
/// to pass from a clean checkout with no network. The gate is `gh auth status`, which on `gh`
/// 2.96.0 validates the token against the API and therefore exits non-zero in exactly those two
/// cases (ledger D10). Non-zero produces a named `XCTSkip`.
///
/// Every call this file makes is a read. Nothing prompts for a login, nothing writes to `gh`'s
/// configuration, nothing mutates anything on GitHub. The assertions are over counts and booleans:
/// no login and no pull-request title from a real account is ever an operand (§6.3, §11).
final class GitHubLiveTests: XCTestCase {

    /// The repository G3 reads: large, public, reliably carrying open pull requests, and the `gh`
    /// project itself — so a field this test names that `gh` stopped emitting is a real break.
    private static let repository = "cli/cli"

    // MARK: - G3

    func testTheLivePullRequestListDecodesIntoTheModel() async throws {
        let runner = ToolRunner()
        let environment = ProcessInfo.processInfo.environment

        switch await LiveGate.evaluate(environment: environment, runner: runner) {
        case .unavailable(let reason):
            throw XCTSkip(reason)
        case .ready:
            break
        }

        let output = try await runner.run(.gh,
                                          arguments: ["pr", "list",
                                                      "--repo", Self.repository,
                                                      "--state", "open",
                                                      "--limit", "5",
                                                      "--json", GhCommands.pullRequestFields.joined(separator: ",")],
                                          cwd: URL(filePath: NSTemporaryDirectory()),
                                          environment: environment,
                                          timeout: GhCommands.readTimeout)
        XCTAssertEqual(output.exitCode, 0, "gh pr list did not succeed")

        let pulls = try GhCommands.decodePullRequests(output.stdout)

        // The floor: an empty array satisfies every `allSatisfy` below vacuously.
        XCTAssertFalse(pulls.isEmpty, "the live repository returned no open pull requests")
        XCTAssertLessThanOrEqual(pulls.count, 5, "the window was not honoured")
        XCTAssertTrue(pulls.allSatisfy { $0.number > 0 }, "a pull request came back without a number")
        XCTAssertTrue(pulls.allSatisfy { !$0.headRefName.isEmpty }, "a pull request came back without a head ref")
        XCTAssertTrue(pulls.allSatisfy { !$0.baseRefName.isEmpty }, "a pull request came back without a base ref")
        XCTAssertTrue(pulls.allSatisfy { $0.state == "OPEN" }, "--state open returned something else")
        XCTAssertTrue(pulls.allSatisfy { $0.url.scheme == "https" }, "a pull request URL was not https")
        XCTAssertTrue(pulls.allSatisfy { $0.createdAt <= $0.updatedAt }, "a pull request was updated before it was created")
        // The enums: a value none of the cases knows is carried rather than fatal, so the decode
        // above cannot fail on one — but an `.unknown` here means GitHub has grown a value the
        // panel has no rendering for, which is worth a named failure rather than silence.
        XCTAssertTrue(pulls.allSatisfy { !$0.reviewDecision.isUnknown },
                      "the live API returned a review decision this model has no case for")
        XCTAssertTrue(pulls.allSatisfy { !$0.mergeStateStatus.isUnknown },
                      "the live API returned a merge state this model has no case for")
        XCTAssertTrue(pulls.allSatisfy { !$0.mergeable.isUnknown },
                      "the live API returned a mergeability this model has no case for")
    }

    // MARK: - the gate itself

    /// The skip path, exercised without needing to be offline: a `PATH` holding no `gh` at all is
    /// the same "the gate could not be satisfied" branch a logged-out machine takes, and it is the
    /// one branch a logged-in machine would otherwise never execute. The reason must name why, so
    /// that a skipped G3 in a log is legible rather than a silent absence.
    func testTheGateReportsUnavailableWithANamedReasonWhenGhCannotBeRun() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let empty = try tree.directory("no-tools")

        let gate = await LiveGate.evaluate(environment: ["PATH": empty.path(percentEncoded: false)],
                                           runner: ToolRunner())

        guard case .unavailable(let reason) = gate else {
            return XCTFail("the gate reported ready with no gh on the passed PATH")
        }
        XCTAssertTrue(reason.contains("gh"), "the skip reason does not name the tool")
        XCTAssertTrue(reason.contains("G3"), "the skip reason does not name the gate it disables")
        // §6.3: the reason is printed by the test runner, so it carries no path and no environment.
        XCTAssertFalse(reason.contains("/"), "the skip reason carries a path")
    }

    /// The other unavailable branch, the one D10 is actually about: `gh` runs and `gh auth status`
    /// exits non-zero — logged out, or a token that cannot be validated because there is no
    /// network, which on 2.96.0 is the same exit. The reason names the code, so a skipped G3 says
    /// which of the two happened without the reader re-running anything.
    func testTheGateReportsTheExitCodeWhenGhAuthStatusFails() async throws {
        let gate = await LiveGate.evaluate(environment: [:], runner: FixedExitRunner(exitCode: 1))

        guard case .unavailable(let reason) = gate else {
            return XCTFail("the gate reported ready after gh auth status failed")
        }
        XCTAssertTrue(reason.contains("exited 1"), "the skip reason does not name the exit code")
        XCTAssertTrue(reason.contains("G3"), "the skip reason does not name the gate it disables")
        XCTAssertFalse(reason.contains("/"), "the skip reason carries a path")

        // And zero is the only code that opens the gate.
        guard case .ready = await LiveGate.evaluate(environment: [:],
                                                    runner: FixedExitRunner(exitCode: 0)) else {
            return XCTFail("the gate refused a successful gh auth status")
        }
    }
}

/// A `ToolRunning` that spawns nothing and returns one fixed exit code, so that both sides of the
/// gate's exit-code branch are reachable without a logged-out machine.
private struct FixedExitRunner: ToolRunning {
    let exitCode: Int32

    func run(_ tool: Tool, arguments: [String], cwd: URL,
             environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        ToolOutput(stdout: Data(), stderr: Data(), exitCode: exitCode, timedOut: false)
    }
}

/// Decides whether G3 may run. Separate from the test so that both of its branches are reachable:
/// the ready branch on this machine, the unavailable branch from the test above.
private enum LiveGate {

    enum Verdict: Sendable {
        case ready
        case unavailable(reason: String)
    }

    static func evaluate(environment: [String: String], runner: any ToolRunning) async -> Verdict {
        do {
            let output = try await runner.run(.gh, arguments: ["auth", "status"],
                                              cwd: URL(filePath: NSTemporaryDirectory()),
                                              environment: environment,
                                              timeout: GhCommands.readTimeout)
            guard output.exitCode == 0 else {
                return .unavailable(reason: "gh auth status exited \(output.exitCode); "
                                    + "G3 needs a logged-in gh and network")
            }
            return .ready
        } catch {
            // `binaryNotFound`, a spawn failure or a timeout — the same "cannot ask GitHub" verdict.
            // The error is named by case, never interpolated: `.spawnFailed` carries a message that
            // can hold a path (§6.3).
            let cause: String
            switch error as? ToolError {
            case .binaryNotFound: cause = "gh is not on the passed PATH"
            case .timedOut: cause = "gh auth status timed out"
            default: cause = "gh auth status could not be run"
            }
            return .unavailable(reason: "\(cause); G3 needs a logged-in gh and network")
        }
    }
}
