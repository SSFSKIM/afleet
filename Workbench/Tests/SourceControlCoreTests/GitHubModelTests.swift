import Foundation
import XCTest
@testable import SourceControlCore

/// Milestone 6: `gh --json` documents decode into this module's models.
///
/// The three documents under `Samples/` are **authored**, not recorded: `gh`'s real field names —
/// taken from `gh pr list --json`, `gh pr checks --json` and `gh issue list --json` on `gh` 2.96.0
/// — carrying invented logins, invented titles and an invented repository path in every URL. Root
/// spec §11's rule is about the byte's origin rather than its directory, so piping a real account's
/// response into a committed file would publish a real login (ledger D9).
///
/// Because every value here is authored, every value here is compared directly: nothing in this
/// file reaches a runtime path, an environment or an identity from this machine (§6.3, §11).
final class GitHubModelTests: XCTestCase {

    // MARK: - the pull-request document

    /// Every field of the pull-request model, read back from the sample.
    func testThePullRequestSampleDecodesEveryFieldToItsAuthoredValue() throws {
        let pulls = try GhCommands.decodePullRequests(Sample.data("pull-requests"))

        // The floor: an empty array satisfies every `first(where:)` assertion below vacuously.
        XCTAssertEqual(pulls.count, 3, "the sample does not hold the number of pull requests it was authored with")

        let first = try XCTUnwrap(pulls.first)
        XCTAssertEqual(first.number, 12)
        XCTAssertEqual(first.title, "Redraw the source control tab when the window regains focus")
        XCTAssertEqual(first.state, "OPEN")
        XCTAssertFalse(first.isDraft)
        XCTAssertEqual(first.author.login, "willow-mint")
        XCTAssertEqual(first.headRefName, "feature/redraw-on-focus")
        XCTAssertEqual(first.baseRefName, "main")
        XCTAssertEqual(first.url.absoluteString, "https://github.com/octo-invented/sample-repo/pull/12")
        XCTAssertEqual(first.createdAt, Date(timeIntervalSince1970: 1_775_121_300))  // 2026-04-02T09:15:00Z
        XCTAssertEqual(first.updatedAt, Date(timeIntervalSince1970: 1_775_214_151))  // 2026-04-03T11:02:31Z
        XCTAssertEqual(first.reviewDecision, .approved)
        XCTAssertEqual(first.mergeStateStatus, .clean)
        XCTAssertEqual(first.mergeable, .mergeable)
        XCTAssertEqual(first.labels, [GitHubLabel(name: "enhancement", color: "a2eeef")])
        XCTAssertEqual(first.additions, 128)
        XCTAssertEqual(first.deletions, 42)
        XCTAssertEqual(first.changedFiles, 6)

        // The draft, the empty review decision and the empty label array in one record.
        let draft = try XCTUnwrap(pulls.first { $0.number == 13 })
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(draft.reviewDecision, .notRequested,
                       "gh emits an empty string when no review has been requested")
        XCTAssertEqual(draft.mergeStateStatus, .blocked)
        XCTAssertEqual(draft.mergeable, .reportedUnknown)
        XCTAssertEqual(draft.labels, [])
        XCTAssertEqual(draft.additions, 3)
        XCTAssertEqual(draft.deletions, 0)

        // The closed record: a state other than OPEN, two labels in order, a conflicting merge.
        let merged = try XCTUnwrap(pulls.first { $0.number == 9 })
        XCTAssertEqual(merged.state, "MERGED")
        XCTAssertEqual(merged.author.login, "sample-bot")
        XCTAssertEqual(merged.reviewDecision, .changesRequested)
        XCTAssertEqual(merged.mergeStateStatus, .dirty)
        XCTAssertEqual(merged.mergeable, .conflicting)
        XCTAssertEqual(merged.labels.map(\.name), ["chore", "needs-rebase"])
        XCTAssertEqual(merged.changedFiles, 3)
    }

    /// An enum value `gh` has never emitted is carried, not fatal (D9): the three fields GitHub
    /// documents as open-ended keep an `.unknown(String)` case, and its payload is the raw value.
    func testAnUnfamiliarEnumValueIsCarriedRatherThanFatal() throws {
        let mutated = try Sample.pullRequests { records in
            records[0]["reviewDecision"] = "REVIEW_DELEGATED"
            records[0]["mergeStateStatus"] = "QUEUED"
            records[0]["mergeable"] = "PENDING"
        }
        let pulls = try GhCommands.decodePullRequests(mutated)

        XCTAssertEqual(pulls.count, 3)
        let first = try XCTUnwrap(pulls.first)
        XCTAssertEqual(first.reviewDecision, .unknown("REVIEW_DELEGATED"))
        XCTAssertEqual(first.mergeStateStatus, .unknown("QUEUED"))
        XCTAssertEqual(first.mergeable, .unknown("PENDING"))
        // The raw value round-trips, which is what a panel renders when it has no case for it.
        XCTAssertEqual(first.reviewDecision.rawValue, "REVIEW_DELEGATED")
        XCTAssertEqual(first.mergeStateStatus.rawValue, "QUEUED")
        XCTAssertEqual(first.mergeable.rawValue, "PENDING")
    }

    /// Gate G3's "decodes with no missing key" has to be falsifiable: with the key gone the decode
    /// must throw rather than fill in a default (§17.7).
    func testRemovingARequiredKeyFromAPullRequestMakesTheDecodeThrow() throws {
        for key in ["number", "title", "state", "isDraft", "author", "headRefName", "baseRefName",
                    "url", "createdAt", "updatedAt", "reviewDecision", "mergeStateStatus",
                    "mergeable", "labels", "additions", "deletions", "changedFiles"] {
            let mutated = try Sample.pullRequests { $0[0].removeValue(forKey: key) }
            XCTAssertThrowsError(try GhCommands.decodePullRequests(mutated),
                                 "removing \(key) still decoded") { error in
                guard case ToolError.decodeFailed(let subject, _) = error else {
                    return XCTFail("removing \(key) threw something other than .decodeFailed")
                }
                XCTAssertEqual(subject, "pull requests")
            }
        }
    }

    // MARK: - the checks document

    /// Every field of the check model, including the two shapes `gh` uses for "there is no value".
    ///
    /// Measured against `gh` 2.96.0 and its source: `pkg/cmd/pr/checks/aggregate.go` declares
    /// `check` with `Link`, `Event`, `Workflow` and `Description` as `string` and `StartedAt` /
    /// `CompletedAt` as `time.Time`, and `output.go` branches on `IsZero()`. So an absent string
    /// arrives as `""` and an absent timestamp as Go's zero instant `0001-01-01T00:00:00Z` —
    /// never as `null`, and never as a missing key. Both become `nil` here (ledger D22).
    func testTheChecksSampleDecodesIncludingEmptyStringsAndTheZeroTimestamp() throws {
        let checks = try GhCommands.decodeChecks(Sample.data("checks"))

        XCTAssertEqual(checks.count, 3, "the sample does not hold the number of checks it was authored with")

        let build = try XCTUnwrap(checks.first)
        XCTAssertEqual(build.name, "build (macos-26)")
        XCTAssertEqual(build.state, "SUCCESS")
        XCTAssertEqual(build.bucket, "pass")
        XCTAssertEqual(build.workflow, "CI")
        XCTAssertEqual(build.link?.absoluteString,
                       "https://github.com/octo-invented/sample-repo/actions/runs/1001/job/2001")
        XCTAssertEqual(build.startedAt, Date(timeIntervalSince1970: 1_775_213_463))   // 2026-04-03T10:51:03Z
        XCTAssertEqual(build.completedAt, Date(timeIntervalSince1970: 1_775_213_921)) // 2026-04-03T10:58:41Z
        XCTAssertNil(build.description, "an empty description is no description")
        XCTAssertEqual(build.event, "pull_request")

        let cla = try XCTUnwrap(checks.first { $0.name == "license/cla" })
        XCTAssertNil(cla.workflow, "an empty workflow is no workflow — gh emits it for a status context")
        XCTAssertNil(cla.event)
        XCTAssertEqual(cla.description, "All contributors have signed the agreement")

        let pending = try XCTUnwrap(checks.first { $0.bucket == "pending" })
        XCTAssertEqual(pending.state, "IN_PROGRESS")
        XCTAssertNotNil(pending.startedAt)
        XCTAssertNil(pending.completedAt, "Go's zero instant means the check has not completed")
        XCTAssertNil(pending.link, "an empty link is no link")
    }

    func testRemovingARequiredKeyFromACheckMakesTheDecodeThrow() throws {
        for key in ["name", "state", "bucket", "workflow", "link", "startedAt", "completedAt",
                    "description", "event"] {
            let mutated = try Sample.mutate("checks") { $0[0].removeValue(forKey: key) }
            XCTAssertThrowsError(try GhCommands.decodeChecks(mutated),
                                 "removing \(key) still decoded") { error in
                guard case ToolError.decodeFailed(let subject, _) = error else {
                    return XCTFail("removing \(key) threw something other than .decodeFailed")
                }
                XCTAssertEqual(subject, "checks")
            }
        }
    }

    /// A link that is neither empty nor a URL is a decode failure rather than a silent `nil`: a
    /// check whose link is dropped on the floor is a check the panel cannot open.
    func testALinkThatIsNeitherEmptyNorAURLIsRejected() throws {
        let mutated = try Sample.mutate("checks") { $0[0]["link"] = "http://\u{7f} not a url" }
        XCTAssertThrowsError(try GhCommands.decodeChecks(mutated))
    }

    // MARK: - the issues document

    func testTheIssuesSampleDecodesEveryFieldToItsAuthoredValue() throws {
        let issues = try GhCommands.decodeIssues(Sample.data("issues"))

        XCTAssertEqual(issues.count, 3, "the sample does not hold the number of issues it was authored with")

        let first = try XCTUnwrap(issues.first)
        XCTAssertEqual(first.number, 41)
        XCTAssertEqual(first.title, "The graph draws a lane twice after a force-push")
        XCTAssertEqual(first.state, "OPEN")
        XCTAssertEqual(first.author.login, "birch-quill")
        XCTAssertEqual(first.labels, [GitHubLabel(name: "bug", color: "d73a4a")])
        XCTAssertEqual(first.assignees.map(\.login), ["willow-mint"])
        XCTAssertEqual(first.updatedAt, Date(timeIntervalSince1970: 1_775_395_209))  // 2026-04-05T13:20:09Z
        XCTAssertEqual(first.url.absoluteString, "https://github.com/octo-invented/sample-repo/issues/41")

        let unassigned = try XCTUnwrap(issues.first { $0.number == 38 })
        XCTAssertEqual(unassigned.assignees, [])
        XCTAssertEqual(unassigned.labels, [])

        let closed = try XCTUnwrap(issues.first { $0.number == 17 })
        XCTAssertEqual(closed.state, "CLOSED")
        XCTAssertEqual(closed.assignees.map(\.login), ["birch-quill", "sample-bot"])
    }

    func testRemovingARequiredKeyFromAnIssueMakesTheDecodeThrow() throws {
        for key in ["number", "title", "state", "author", "labels", "assignees", "updatedAt", "url"] {
            let mutated = try Sample.mutate("issues") { $0[0].removeValue(forKey: key) }
            XCTAssertThrowsError(try GhCommands.decodeIssues(mutated),
                                 "removing \(key) still decoded") { error in
                guard case ToolError.decodeFailed(let subject, _) = error else {
                    return XCTFail("removing \(key) threw something other than .decodeFailed")
                }
                XCTAssertEqual(subject, "issues")
            }
        }
    }

    // MARK: - the field lists and the samples agree

    /// The `--json` list and the sample are two halves of one claim: `gh` prints exactly the fields
    /// asked for, so a field named in the list and missing from the sample would mean the sample
    /// is not what the command produces, and a field in the sample and not in the list would never
    /// arrive at run time. Compared in both directions, per document.
    func testEachFieldListIsExactlyWhatItsSampleCarries() throws {
        for (list, sample) in [(GhCommands.pullRequestFields, "pull-requests"),
                               (GhCommands.checkFields, "checks"),
                               (GhCommands.issueFields, "issues")] {
            let records = try Sample.records(sample)
            XCTAssertFalse(records.isEmpty, "\(sample) holds no records")
            XCTAssertFalse(list.isEmpty, "the field list for \(sample) is empty")
            for record in records {
                XCTAssertEqual(Set(record.keys), Set(list),
                               "\(sample): the sample's keys and the --json list differ")
            }
        }
    }

    // MARK: - the command lines

    func testThePullRequestCommandCarriesTheFieldListTheStateAndTheWindow() async throws {
        let runner = GhRecordingRunner(stdout: try Sample.data("pull-requests"))
        _ = try await GhCommands.pullRequests(root: Self.root, head: "feature/redraw-on-focus",
                                              state: "open", limit: 25,
                                              environment: [:], runner: runner)

        XCTAssertEqual(runner.invocations.count, 1)
        let call = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(call.tool, .gh)
        XCTAssertEqual(call.arguments,
                       ["pr", "list", "--state", "open", "--limit", "25",
                        "--head", "feature/redraw-on-focus",
                        "--json", GhCommands.pullRequestFields.joined(separator: ",")])
    }

    func testTheChecksAndIssuesCommandsCarryTheirFieldListsAndTheirSubjects() async throws {
        let checks = GhRecordingRunner(stdout: try Sample.data("checks"))
        _ = try await GhCommands.checks(root: Self.root, pullRequest: 12, environment: [:], runner: checks)
        XCTAssertEqual(try XCTUnwrap(checks.invocations.first).arguments,
                       ["pr", "checks", "12", "--json", GhCommands.checkFields.joined(separator: ",")])

        let issues = GhRecordingRunner(stdout: try Sample.data("issues"))
        _ = try await GhCommands.issues(root: Self.root, limit: 50, environment: [:], runner: issues)
        XCTAssertEqual(try XCTUnwrap(issues.invocations.first).arguments,
                       ["issue", "list", "--limit", "50", "--json", GhCommands.issueFields.joined(separator: ",")])
    }

    /// `gh pr checks` exits **8** while checks are still pending, and prints the checks anyway —
    /// documented under `gh help exit-codes` and in the command's own help on 2.96.0 ("Additional
    /// exit codes: 8: Checks pending"). Treating it as a failure would empty the panel exactly
    /// while CI is running, which is when it is being watched.
    func testAPendingExitCodeOfEightIsAcceptedByChecksAndOnlyByChecks() async throws {
        let pending = GhRecordingRunner(stdout: try Sample.data("checks"), exitCode: 8)
        let runs = try await GhCommands.checks(root: Self.root, pullRequest: 12,
                                               environment: [:], runner: pending)
        XCTAssertEqual(runs.count, 3, "exit 8 is pending, not failure: the output still decodes")

        // Every other verb accepts 0 alone, so the same code from `pr list` is a failure.
        let lister = GhRecordingRunner(stdout: try Sample.data("pull-requests"), exitCode: 8)
        do {
            _ = try await GhCommands.pullRequests(root: Self.root, head: nil, state: "open",
                                                  limit: 5, environment: [:], runner: lister)
            XCTFail("pr list accepted exit code 8")
        } catch let error as ToolError {
            guard case .commandFailed(let tool, let code, _) = error else {
                return XCTFail("pr list did not fail with .commandFailed")
            }
            XCTAssertEqual(tool, .gh)
            XCTAssertEqual(code, 8)
        }
    }

    /// A non-zero exit becomes a panel-local `.commandFailed` carrying the tail of stderr, never a
    /// decode attempt over whatever the tool printed (§10, D3).
    func testAFailingExitCodeBecomesCommandFailedRatherThanADecodeAttempt() async throws {
        let runner = GhRecordingRunner(stdout: Data("not json".utf8),
                                       stderr: Data("gh: could not determine the repository\n".utf8),
                                       exitCode: 1)
        do {
            _ = try await GhCommands.issues(root: Self.root, limit: 5, environment: [:], runner: runner)
            XCTFail("a failing exit code was not reported")
        } catch let error as ToolError {
            guard case .commandFailed(let tool, let code, let tail) = error else {
                return XCTFail("the failure was not .commandFailed")
            }
            XCTAssertEqual(tool, .gh)
            XCTAssertEqual(code, 1)
            XCTAssertTrue(tail.contains("could not determine the repository"))
        }
    }

    // MARK: - R7/1e the process layer's facts are read before the exit code

    /// A budget that expired is not visible in an exit code, and both shapes it takes are wrong to
    /// accept. A `gh` that handles `SIGTERM` and exits 0 leaves a zero here with half a document
    /// behind it, and one killed outright leaves a signal number that reads as an ordinary
    /// failure. The first is the dangerous one: the panel would render a truncated list as the
    /// whole truth. The wrapper therefore asks the output whether it completed *before* it looks
    /// at the code.
    func testAGhCallWhoseBudgetExpiredIsTimedOutRatherThanAccepted() async throws {
        let runner = GhRecordingRunner(stdout: Data("[]".utf8), exitCode: 0, timedOut: true)
        do {
            _ = try await GhCommands.issues(root: Self.root, limit: 5, environment: [:], runner: runner)
            XCTFail("a gh call whose budget expired was accepted because it exited zero")
        } catch let error as ToolError {
            guard case .timedOut(let tool, let afterMs) = error else {
                return XCTFail("an expired budget produced an error other than .timedOut")
            }
            XCTAssertEqual(tool, .gh)
            XCTAssertEqual(afterMs, 60_000, "the error named a budget other than the gh read timeout")
        }
    }

    /// The same seam for the retained-output cap, which a `gh` document can reach on a repository
    /// with a very large listing: the output is partial by construction and is never decoded.
    func testAGhCallThatReachedTheOutputCapIsReportedRatherThanDecoded() async throws {
        let runner = GhRecordingRunner(stdout: Data("[".utf8), exitCode: 0, outputLimitBytes: 1024)
        do {
            _ = try await GhCommands.pullRequests(root: Self.root, head: nil, state: "open",
                                                  limit: 5, environment: [:], runner: runner)
            XCTFail("a gh call that reached the output cap was decoded anyway")
        } catch let error as ToolError {
            guard case .outputLimitExceeded(let tool, let limitBytes) = error else {
                return XCTFail("the cap produced an error other than .outputLimitExceeded")
            }
            XCTAssertEqual(tool, .gh)
            XCTAssertEqual(limitBytes, 1024)
        }
    }

    /// And an ordinary reply is still accepted, so the two above refuse something rather than
    /// everything.
    func testAnOrdinaryGhReplyIsStillAccepted() async throws {
        let runner = GhRecordingRunner(stdout: Data("[]".utf8), exitCode: 0)
        let issues = try await GhCommands.issues(root: Self.root, limit: 5, environment: [:],
                                                 runner: runner)
        XCTAssertEqual(issues.count, 0, "an empty listing did not decode to no issues")
    }

    // MARK: - R7/1f the nested label carries its colour

    /// The module's invariant is that a field `gh` always emits is non-optional, so that a missing
    /// key is a decode error rather than a default (D9) — and that is what makes gate G3
    /// falsifiable. `color` is non-null in GitHub's schema and was the one field that escaped the
    /// rule by being nested one level down, where the record-level key sweep above does not reach:
    /// an omitted key and an explicit null both decoded to `nil`.
    func testALabelMissingItsColourOrNamedNullDoesNotDecode() throws {
        let labelMutations: [(String, (inout [String: Any]) -> Void)] = [
            ("no color key", { $0.removeValue(forKey: "color") }),
            ("a null color", { $0["color"] = NSNull() }),
            ("no name key", { $0.removeValue(forKey: "name") }),
        ]
        for (description, edit) in labelMutations {
            let mutated = try Sample.pullRequests { records in
                var labels = records[0]["labels"] as? [[String: Any]] ?? []
                edit(&labels[0])
                records[0]["labels"] = labels
            }
            XCTAssertThrowsError(try GhCommands.decodePullRequests(mutated),
                                 "a label with \(description) still decoded") { error in
                guard case ToolError.decodeFailed(let subject, _) = error else {
                    return XCTFail("a label with \(description) threw something other than .decodeFailed")
                }
                XCTAssertEqual(subject, "pull requests")
            }
        }
    }

    /// The cwd every `gh` call runs in, invented rather than taken from this machine: the recording
    /// runner never spawns anything, and §6.3 keeps a real path out of an assertion's operands.
    private static let root = URL(filePath: "/invented/sample-repo")
}

// MARK: - support

/// Reads the authored `gh` documents out of the test bundle, and produces mutated copies of them
/// **in memory** — a sample is never rewritten on disk, so the committed bytes stay the ones that
/// were reviewed.
private enum Sample {

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "the sample \(name).json is not in the test bundle" }
    }

    static func url(_ name: String) throws -> URL {
        guard let resources = Bundle.module.resourceURL else { throw Missing(name: name) }
        return resources.appending(path: "Samples").appending(path: name + ".json")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func records(_ name: String) throws -> [[String: Any]] {
        guard let records = try JSONSerialization.jsonObject(with: data(name)) as? [[String: Any]] else {
            throw Missing(name: name)
        }
        return records
    }

    /// A copy of the sample with `edit` applied to its records, re-encoded.
    static func mutate(_ name: String, _ edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var records = try records(name)
        edit(&records)
        return try JSONSerialization.data(withJSONObject: records)
    }

    static func pullRequests(_ edit: (inout [[String: Any]]) -> Void) throws -> Data {
        try mutate("pull-requests", edit)
    }
}

/// A `ToolRunning` that records what it was asked to run and returns a fixed result, so that the
/// argument vector and the exit-code contract can be asserted without a process or a network.
private final class GhRecordingRunner: ToolRunning, @unchecked Sendable {

    struct Invocation: Sendable {
        let tool: Tool
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let stdout: Data
    private let stderr: Data
    private let exitCode: Int32
    private let timedOut: Bool
    private let outputLimitBytes: Int?

    /// `timedOut` and `outputLimitBytes` are the two process-layer facts a `ToolOutput` carries
    /// besides its exit code, and a stub that could not produce them could not show that a wrapper
    /// reads them at all.
    init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0,
         timedOut: Bool = false, outputLimitBytes: Int? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.outputLimitBytes = outputLimitBytes
    }

    var invocations: [Invocation] { lock.withLock { recorded } }

    func run(_ tool: Tool, arguments: [String], cwd: URL,
             environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(Invocation(tool: tool, arguments: arguments)) }
        return ToolOutput(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut,
                          outputLimitBytes: outputLimitBytes)
    }
}
