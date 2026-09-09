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
    /// the exit code, which is a number the tool returned rather than a byte it printed — the same
    /// line C7.6's `BrowserLinkError` draws.
    ///
    /// **Every case that can be either tool's carries which one it was**, exactly as C7.3's
    /// `RepositoryError` does. Two of this tab's three reads are `git`'s, and a failure value that
    /// dropped the tool left every notice worded for the other one: a `git` that never answered
    /// told the user GitHub CLI did not answer in time, sending them to look at a tool that was
    /// working.
    public enum Failure: Hashable, Sendable {
        case notARepository
        case toolMissing(Tool)
        /// `gh` is not signed in — and only ever `gh`. `git` prints "authentication failed" for a
        /// credential helper, a private remote and an expired key alike, and none of those is what
        /// `gh auth login` fixes (G3's binding clause).
        case notAuthenticated
        case commandFailed(tool: Tool, exitCode: Int32)
        case timedOut(tool: Tool)
        /// A document that did not have the shape this panel decodes.
        case unreadable(tool: Tool)
        /// The tool could not be run to an answer at all — a spawn failure, an output cap.
        case unavailable(tool: Tool)
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
    ///
    /// A read that was attempted and **failed** is a third thing again, and it is a case here
    /// rather than another absence: stored as one, the panel went on to say "no checks were
    /// reported for this pull request", which is an affirmative statement about a repository it
    /// could not read. It names the tool for the reason every other notice does (§10).
    public private(set) var checks: [Int: ChecksRead] = [:]

    /// What one pull request's check read produced.
    public enum ChecksRead: Hashable, Sendable {
        case read([CheckRun])
        case failed(tool: Tool)
    }
    public private(set) var issues: [Issue] = []
    public private(set) var selectedPullRequest: Int?
    public private(set) var isLoading = false
    public private(set) var failure: Failure?
    /// Whether a read cycle has ever finished, so `appear()` is idempotent across the redraws a
    /// channel switch causes. A **cancelled** cycle does not finish and does not latch it.
    public private(set) var hasRead = false

    /// The cycle that owns the document. Claimed synchronously at the top of `read()`, before any
    /// await, and checked after every one: four doors open a read and each of them is a suspension
    /// the next can start inside.
    ///
    /// Without it two cycles interleave and the *loser* writes last — the user switches to *All
    /// open*, that cycle finishes, and the branch-scoped cycle it superseded then resumes and
    /// assigns its own list under an *All open* control, with every row saying its checks were not
    /// read because the winner's scope was read after the loser's document. The same defect ran
    /// through `isLoading` and `failure`.
    private var generation = 0

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
        guard let pullRequest, let root else { return }
        // A read that failed is asked again when the user selects the row again — the click is a
        // question, and the failure was about a moment rather than about this pull request.
        if case .read = checks[pullRequest] { return }
        // Under the cycle that produced the list this row belongs to: a read starting while this
        // round trip is in flight owns the document from then on, and this answer is about a list
        // that is being replaced.
        await readChecks(for: [pullRequest], root: root, generation: generation)
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
        // Claimed before the first await, because that is the only place it means anything.
        generation += 1
        let mine = generation
        isLoading = true

        let root: URL
        do {
            root = try await GitCommands.repositoryRoot(cwd: cwd, environment: environment,
                                                        runner: runner)
        } catch {
            abandon(error, tool: .git, generation: mine)
            return
        }
        guard mine == generation else { return }
        self.root = root

        let status: WorkingTreeStatus
        do {
            status = try await WorkingTreeStatus.read(root: root, environment: environment,
                                                      runner: runner)
        } catch {
            abandon(error, tool: .git, generation: mine)
            return
        }
        guard mine == generation else { return }
        branch = status.branch
        isDetachedHead = status.branch == nil

        // A detached `HEAD` in the branch scope has no head to filter on, and filtering on nothing
        // is the *all open* list — a different question, silently answered. The list stays empty
        // and the readout says why; the issues are still worth reading.
        var head: String?
        if scope == .branch {
            guard let branch = status.branch else {
                pullRequests = []
                checks = [:]
                reconcileSelection()
                let failed = await readIssues(root: root, generation: mine)
                guard mine == generation else { return }
                settle(failed)
                return
            }
            head = branch
        }

        var failed: Failure?
        do {
            let listed = try await GhCommands.pullRequests(root: root, head: head, state: "open",
                                                           limit: Self.pullRequestLimit,
                                                           environment: environment,
                                                           runner: runner)
            guard mine == generation else { return }
            pullRequests = listed
        } catch {
            guard mine == generation else { return }
            failed = Self.failure(for: error, tool: .gh)
            pullRequests = []
        }

        checks = [:]
        // A pull request that merged between two reads is not in the list any more, and a
        // selection pointing at it highlights nothing while the readout goes on naming it. Every
        // door reconciles here; `select(scope:)` drops its selection outright because the other
        // list's rows are a different question entirely.
        reconcileSelection()
        // Branch-scoped, the list is ordinarily zero or one pull request, so reading every row's
        // checks is bounded by the branch rather than by the repository. Otherwise only the
        // selected row earns a round trip (Design §8).
        let wanted = scope == .branch ? pullRequests.map(\.number)
                                      : [selectedPullRequest].compactMap { $0 }
        await readChecks(for: wanted, root: root, generation: mine)
        guard mine == generation else { return }
        let issuesFailure = await readIssues(root: root, generation: mine)
        guard mine == generation else { return }
        settle(failed ?? issuesFailure)
    }

    /// Ends the cycle that owns the document: one failure or none, not loading, and read.
    ///
    /// The failure published is the **first** of the cycle. Later ones are consequences of it — a
    /// missing `gh` fails all three reads — and the panel has one area.
    private func settle(_ failed: Failure?) {
        failure = failed
        isLoading = false
        hasRead = true
    }

    /// Ends a cycle that failed before it could list anything.
    ///
    /// A **cancelled** read is neither a failure nor a finished cycle: the panel asked it to stop,
    /// so it leaves the document that was on screen, says nothing, and does not latch `hasRead` —
    /// otherwise the tab shows an empty list with no notice and `appear()` never reads again.
    private func abandon(_ error: any Error, tool: Tool, generation mine: Int) {
        guard mine == generation else { return }
        isLoading = false
        guard let classified = Self.failure(for: error, tool: tool) else { return }
        failure = classified
        clear()
        hasRead = true
    }

    /// Drops a selection the current list does not hold.
    private func reconcileSelection() {
        guard let selected = selectedPullRequest else { return }
        if !pullRequests.contains(where: { $0.number == selected }) { selectedPullRequest = nil }
    }

    /// Checks for each of `numbers`, sequentially. A pull request whose read fails keeps no entry,
    /// which is what makes its row say "not read" instead of claiming a rollup.
    private func readChecks(for numbers: [Int], root: URL, generation mine: Int) async {
        for number in numbers {
            do {
                // Exit 8 — checks still pending, rows printed — is a normal answer that
                // `GhCommands` already accepts (C7.3's D3). It arrives here as rows, not as a
                // failure, and rolls up to `.pending`.
                let read = try await GhCommands.checks(root: root, pullRequest: number,
                                                       environment: environment, runner: runner)
                guard mine == generation else { return }
                checks[number] = .read(read)
            } catch {
                // Deliberately not recorded as the tab's failure: one pull request's checks
                // failing is a fact about that row, and turning it into the tab's error state
                // would empty a list that read perfectly well. It **is** recorded on the row,
                // because a failure stored as an absence is rendered as an absence of checks.
                guard mine == generation else { return }
                // A cancelled read is one this panel asked to stop and says nothing at all.
                guard let classified = Self.failure(for: error, tool: .gh) else {
                    checks[number] = nil
                    continue
                }
                checks[number] = .failed(tool: Self.tool(of: classified) ?? .gh)
            }
        }
    }

    /// Reads the issue section, and answers with how it failed rather than publishing it: the
    /// cycle that owns the document decides which failure the panel's one area shows.
    private func readIssues(root: URL, generation mine: Int) async -> Failure? {
        do {
            let read = try await GhCommands.issues(root: root, limit: Self.issueLimit,
                                                   environment: environment, runner: runner)
            guard mine == generation else { return nil }
            issues = read
            return nil
        } catch {
            guard mine == generation else { return nil }
            issues = []
            return Self.failure(for: error, tool: .gh)
        }
    }

    private func clear() {
        pullRequests = []
        checks = [:]
        issues = []
        selectedPullRequest = nil
    }

    // MARK: - classification

    /// A `ToolError` as a panel state, worded for the tool that produced it.
    ///
    /// The stderr tail is an operand here and never a result: it decides whether this is the
    /// logged-out case and is then dropped, so no byte a tool printed can reach a rendered string
    /// (§6.3, §11). The same classification lives in C7.6's `PullRequestURLResolver` and cannot be
    /// imported across panel targets; the duplication is filed rather than worked around
    /// (Design §8).
    ///
    /// `tool` is the caller's — which read this was — and is used only for the errors that name no
    /// tool of their own, exactly as `RepositoryError`'s parameter is. Where the error carries one,
    /// the error's is authoritative.
    static func failure(for error: any Error, tool: Tool) -> Failure? {
        guard let error = error as? ToolError else { return .unavailable(tool: tool) }
        switch error {
        // A cancelled read is one the panel asked to stop, not a failure the user is owed a row
        // about.
        case .cancelled:
            return nil
        case .notARepository:
            return .notARepository
        case .binaryNotFound(let tool):
            return .toolMissing(tool)
        case .timedOut(let tool, _):
            return .timedOut(tool: tool)
        case .commandFailed(let tool, let exitCode, let stderrTail):
            // **`gh` only.** `git` prints "authentication failed" for a credential helper, a
            // private remote and an expired key, and `gh auth login` fixes none of them; G3's
            // clause is that the panel does not offer one remedy for every failure.
            return tool == .gh && mentionsAuthentication(stderrTail)
                 ? .notAuthenticated
                 : .commandFailed(tool: tool, exitCode: exitCode)
        case .decodeFailed:
            return .unreadable(tool: tool)
        case .spawnFailed(let tool, _), .outputLimitExceeded(let tool, _):
            return .unavailable(tool: tool)
        case .pathOutsideRepository, .unreadableWorkingTreeEntry:
            return .unavailable(tool: tool)
        }
    }

    /// Which tool a classified failure was about, where it names one.
    static func tool(of failure: Failure) -> Tool? {
        switch failure {
        case .toolMissing(let tool), .commandFailed(let tool, _), .timedOut(let tool),
             .unreadable(let tool), .unavailable(let tool):
            return tool
        case .notAuthenticated:
            return .gh
        case .notARepository:
            return nil
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

/// The connection Design §8 asks for: one channel's Source Control panel tells that channel's
/// GitHub tab when the branch changed, so a checkout made outside the app is re-read instead of
/// leaving a retained tab on the branch it first saw.
///
/// It is a small registry rather than a reference either session holds, because the two tabs share
/// no state (Design §2) and neither may keep the other alive: X7 retains sessions per (tab,
/// channel) under an LRU, and a strong hold from one to the other would make the pair evictable
/// only together. Both sides are weak, and an entry whose sessions have both gone is dropped.
///
/// The app owns one of these and feeds it every session the panel host builds; nothing here knows
/// about the host, and the panel package holds no reference to the app.
///
/// `Channel` is generic because the app's channel key is FleetKit's and this package does not
/// import FleetKit (X1's package edges, W1's dependency row): the identity of a channel is the
/// app's to name and all this type needs of it is equality.
@MainActor
public final class BranchChangeLink<Channel: Hashable> {

    private struct Pair {
        weak var sourceControl: SourceControlModel?
        weak var github: GitHubModel?
    }

    private var pairs: [Channel: Pair] = [:]

    public init() {}

    /// Records a session the host has just built for `channel`, and connects the pair when both
    /// halves of one channel exist. A session of any other kind is not this type's business.
    public func sessionWasMade(_ session: any PanelTabSession, for channel: Channel) {
        var pair = pairs[channel] ?? Pair()
        switch session {
        case let source as SourceControlModel: pair.sourceControl = source
        case let github as GitHubModel: pair.github = github
        default: return
        }
        pairs[channel] = pair
        connect(channel)
        pairs = pairs.filter { $0.value.sourceControl != nil || $0.value.github != nil }
    }

    /// How many channels are connected. A count and nothing identifying, for a diagnostic and for
    /// the test of the weak half.
    public var channelCount: Int { pairs.count }

    private func connect(_ channel: Channel) {
        guard let source = pairs[channel]?.sourceControl else { return }
        source.onBranchChange = { [weak self] (branch: String?) in
            // Resolved at delivery, weakly, through the registry: the GitHub tab for this channel
            // may not have been visited yet, and may have been evicted since.
            guard let github = self?.pairs[channel]?.github else { return }
            // `branchDidChange(to:)` is `async` and this is not, so the read is spawned; it does
            // nothing at all when the branch it is told about is the one it already holds.
            Task { @MainActor in await github.branchDidChange(to: branch) }
        }
    }
}
