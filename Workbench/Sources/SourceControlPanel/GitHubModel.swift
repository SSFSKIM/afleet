// C7.7 spec Design §8: the GitHub tab's session — what it reads, when, and what it never runs.
import Foundation
import Observation
import AfleetCore
import PanelHostAPI
import SourceControlCore

/// The `PanelTabSession` X7's host retains for (`.github`, channel): the branch, the pull requests,
/// their checks, the issues, and the panel-local empty and error states.
///
/// **Every invocation goes through `GhCommands` or C7.3's git readers** (W7). This file contains no
/// `gh` and no `git` command line, which is what makes G3's claim structural rather than a promise:
/// the verb `auth` is not merely unused here, there is no seam through which it could be spelled.
/// afleet holds no token, runs no login flow, and never prompts for one.
///
/// **No polling** (Design §8). These are network round trips on the user's own rate limit, and a
/// panel that refreshed them on a timer would spend it while the user reads. Three doors open a
/// read: `appear()` on the tab's first appearance for a channel, `branchDidChange(to:)` which the
/// working-tree watch calls, and `refresh()` which is the user's own.
@MainActor
@Observable
public final class GitHubModel: PanelTabSession {

    /// Which pull requests the list is asking for. The branch is the default because the question
    /// this tab exists to answer is about the branch the channel is on.
    public enum Scope: String, Hashable, Sendable, CaseIterable {
        case branch
        case allOpen
    }

    /// Everything the panel's own area can be saying, and nothing a tool printed.
    ///
    /// The cases are the classification of a `ToolError`, not a copy of one: `stderrTail` is read
    /// to decide *which* of these it is and is then dropped (§6.3, §11). `commandFailed` carries
    /// the exit code, which is a number `gh` returned rather than a byte it printed — the same line
    /// C7.6's `BrowserLinkError` draws.
    public enum Failure: Hashable, Sendable {
        case notARepository
        case toolMissing(Tool)
        case notAuthenticated
        case commandFailed(exitCode: Int32)
        case timedOut
        /// A document that did not have the shape this panel decodes.
        case unreadable
        /// The tool could not be run to an answer at all — a spawn failure, an output cap.
        case unavailable
    }

    /// How many of each the tab asks for. A window rather than everything: a repository with
    /// thousands of open issues is one page of rows the user will never scroll, bought with a
    /// slower read (the pagination half is tracker 114's).
    public static let pullRequestLimit = 30
    public static let issueLimit = 30

    private let cwd: URL
    private let environment: [String: String]
    private let runner: any ToolRunning
    /// The routing seam, so *Open* emits `.pullRequest(number)` and this leaf never builds a URL
    /// (Design §9: the Browser's resolver is the only thing that turns a number into a page).
    private let links: (any LinkRouterCapability)?

    /// The repository root, resolved once per read cycle. `gh` runs here rather than in the
    /// channel's cwd, which is commonly a subdirectory (C7.3's D13).
    private var root: URL?

    public private(set) var scope: Scope = .branch
    public private(set) var branch: String?
    /// `HEAD` is detached, so there is no branch to scope a list to. Not an error and not an empty
    /// repository: a state the panel says out loud rather than silently listing everything.
    public private(set) var isDetachedHead = false
    public private(set) var pullRequests: [PullRequest] = []
    /// Checks by pull-request number, and **absence means "not read"** rather than "none": a row
    /// whose checks have not been read says so and never shows a rollup it does not have.
    public private(set) var checks: [Int: [CheckRun]] = [:]
    public private(set) var issues: [Issue] = []
    public private(set) var selectedPullRequest: Int?
    public private(set) var isLoading = false
    public private(set) var failure: Failure?
    /// Whether a read cycle has ever finished, so `appear()` is idempotent across the redraws a
    /// channel switch causes.
    public private(set) var hasRead = false

    public init(cwd: URL, environment: [String: String], runner: any ToolRunning = ToolRunner(),
                links: (any LinkRouterCapability)? = nil) {
        self.cwd = cwd
        self.environment = environment
        self.runner = runner
        self.links = links
    }

    public convenience init(context: ChannelContext, runner: any ToolRunning = ToolRunner()) {
        self.init(cwd: context.cwd, environment: context.environment.variables, runner: runner,
                  links: context.links)
    }

    public var readout: GitHubReadout { GitHubReadout(session: self) }

    // MARK: - the four doors

    /// The tab has been shown for this channel. Reads once and not again.
    public func appear() async {
        guard !hasRead, !isLoading else { return }
        await read()
    }

    /// The user asked. Always reads.
    public func refresh() async {
        await read()
    }

    /// The scope control. Switching scope changes which pull requests are listed and therefore
    /// which checks are worth a round trip, so it re-reads rather than filtering what it holds.
    public func select(scope: Scope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        // The selection belonged to the other list; carrying it over would leave a rollup on
        // screen for a pull request the user can no longer see.
        selectedPullRequest = nil
        await read()
    }

    /// A row was selected. In the all-open scope this is what earns a pull request its checks —
    /// one round trip for the row the user is looking at, rather than one per row in the
    /// repository (Design §8).
    public func select(pullRequest: Int?) async {
        selectedPullRequest = pullRequest
        guard let pullRequest, let root, checks[pullRequest] == nil else { return }
        await readChecks(for: [pullRequest], root: root)
    }

    /// The working-tree watch reports a branch change (Design §5 and §8). A different branch is a
    /// different question, so it re-reads; the same branch is not, so it does nothing.
    public func branchDidChange(to branch: String?) async {
        guard branch != self.branch else { return }
        await read()
    }

    /// Open a pull request. It emits `.pullRequest(number)` and builds no URL: this leaf registers
    /// no `.pullRequest` target and the Browser's resolver is what turns the number into a page
    /// (Design §9, W5).
    public func open(pullRequest number: Int,
                     from destination: LinkDestination = .currentPanel) async {
        await links?.open(.pullRequest(number), from: destination)
    }

    // MARK: - one read cycle

    private func read() async {
        isLoading = true
        failure = nil
        defer {
            isLoading = false
            hasRead = true
        }

        let root: URL
        do {
            root = try await GitCommands.repositoryRoot(cwd: cwd, environment: environment,
                                                        runner: runner)
        } catch {
            record(error)
            clear()
            return
        }
        self.root = root

        do {
            let status = try await WorkingTreeStatus.read(root: root, environment: environment,
                                                          runner: runner)
            branch = status.branch
            isDetachedHead = status.branch == nil
        } catch {
            record(error)
            clear()
            return
        }

        // A detached `HEAD` in the branch scope has no head to filter on, and filtering on nothing
        // is the *all open* list — a different question, silently answered. The list stays empty
        // and the readout says why; the issues are still worth reading.
        var head: String?
        if scope == .branch {
            guard let branch else {
                pullRequests = []
                checks = [:]
                await readIssues(root: root)
                return
            }
            head = branch
        }

        do {
            pullRequests = try await GhCommands.pullRequests(root: root, head: head, state: "open",
                                                             limit: Self.pullRequestLimit,
                                                             environment: environment,
                                                             runner: runner)
        } catch {
            record(error)
            pullRequests = []
        }

        checks = [:]
        // Branch-scoped, the list is ordinarily zero or one pull request, so reading every row's
        // checks is bounded by the branch rather than by the repository. Otherwise only the
        // selected row earns a round trip (Design §8).
        let wanted = scope == .branch ? pullRequests.map(\.number)
                                      : [selectedPullRequest].compactMap { $0 }
        await readChecks(for: wanted, root: root)
        await readIssues(root: root)
    }

    /// Checks for each of `numbers`, sequentially. A pull request whose read fails keeps no entry,
    /// which is what makes its row say "not read" instead of claiming a rollup.
    private func readChecks(for numbers: [Int], root: URL) async {
        for number in numbers {
            do {
                // Exit 8 — checks still pending, rows printed — is a normal answer that
                // `GhCommands` already accepts (C7.3's D3). It arrives here as rows, not as a
                // failure, and rolls up to `.pending`.
                checks[number] = try await GhCommands.checks(root: root, pullRequest: number,
                                                             environment: environment,
                                                             runner: runner)
            } catch {
                // Deliberately not `record(error)`: one pull request's checks failing is a fact
                // about that row, and turning it into the tab's error state would empty a list
                // that read perfectly well.
                checks[number] = nil
            }
        }
    }

    private func readIssues(root: URL) async {
        do {
            issues = try await GhCommands.issues(root: root, limit: Self.issueLimit,
                                                 environment: environment, runner: runner)
        } catch {
            record(error)
            issues = []
        }
    }

    private func clear() {
        pullRequests = []
        checks = [:]
        issues = []
        selectedPullRequest = nil
    }

    // MARK: - classification

    /// The first failure of a cycle is the one the panel reports. Later ones in the same cycle are
    /// consequences of it — a missing `gh` fails all three reads — and the panel has one area.
    private func record(_ error: any Error) {
        guard failure == nil, let classified = Self.failure(for: error) else { return }
        failure = classified
    }

    /// A `ToolError` as a panel state.
    ///
    /// The stderr tail is an operand here and never a result: it decides whether this is the
    /// logged-out case and is then dropped, so no byte `gh` printed can reach a rendered string
    /// (§6.3, §11). The same classification lives in C7.6's `PullRequestURLResolver` and cannot be
    /// imported across panel targets; the duplication is filed rather than worked around
    /// (Design §8).
    static func failure(for error: any Error) -> Failure? {
        guard let error = error as? ToolError else { return .unavailable }
        switch error {
        // A cancelled read is one the panel asked to stop, not a failure the user is owed a row
        // about.
        case .cancelled:
            return nil
        case .notARepository:
            return .notARepository
        case .binaryNotFound(let tool):
            return .toolMissing(tool)
        case .timedOut:
            return .timedOut
        case .commandFailed(_, let exitCode, let stderrTail):
            return mentionsAuthentication(stderrTail) ? .notAuthenticated
                                                      : .commandFailed(exitCode: exitCode)
        case .decodeFailed:
            return .unreadable
        case .spawnFailed, .outputLimitExceeded, .pathOutsideRepository,
             .unreadableWorkingTreeEntry:
            return .unavailable
        }
    }

    /// Whether a `gh` failure is about not being signed in.
    ///
    /// Matched on the phrases rather than on an exit code, because `gh` exits 1 for a missing login
    /// and for a repository it cannot resolve alike, and offering the login remedy for the second
    /// would send the user to re-authenticate over a typo. The tail is read here and nowhere else.
    static func mentionsAuthentication(_ stderrTail: String) -> Bool {
        let lowered = stderrTail.lowercased()
        return lowered.contains("gh auth login")
            || lowered.contains("authentication")
            || lowered.contains("not logged in")
            || lowered.contains("no authentication token")
    }
}
