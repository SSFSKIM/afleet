// C7.7 spec Design §1 and §8: what the GitHub tab shows and every action it offers, as a value.
import Foundation
import SourceControlCore

/// Everything `GitHubPanelView` draws, reduced to a value.
///
/// It exists for the reason C5's `PlaceholderReadout` and C7.5's `FilesPanelReadout` exist: a
/// rendered `Text` is not an assertion. The view reads these fields and formats nothing else, so a
/// test asserting on a readout is asserting on what the user sees — which rows are on screen, what
/// each one says about its checks, and what the panel's own area is saying.
///
/// **No field here can carry a byte a tool printed on stderr.** Titles, logins and labels are
/// stdout — they are the panel's content and rendering them is the point — but every message and
/// every hint below is written in this file. `gh`'s stderr is read once, in
/// `GitHubModel.failure(for:)`, to decide which notice this is, and is then dropped (§6.3, §11).
@MainActor
public struct GitHubReadout: Equatable, Sendable {

    /// Every action any surface of this tab offers, complete.
    ///
    /// It is the **inventory** and not a sample of what is enabled right now: §9.2 is binding —
    /// no staging, commit, branch, checkout, stash, push or merge action exists in this panel —
    /// and a proof by sample would pass on a screen where the forbidden action happened to be
    /// disabled. An action added to a view and not to this enum fails the readout test it was
    /// added to; one added to both fails T6's inventory assertion.
    public enum Action: String, Hashable, Sendable, CaseIterable {
        case refresh
        case scopeToBranch
        case scopeToAllOpen
        case selectPullRequest
        case openPullRequest
    }

    /// What a row knows about its checks. Two cases and not an optional rollup, so that "we have
    /// not asked" is a state the view has to render rather than a `nil` it can coalesce into
    /// something reassuring.
    public enum ChecksState: Hashable, Sendable {
        case notRead
        case read(CheckRollup)
        /// Read, and the read failed. Deliberately not folded into either of the others: "nobody
        /// asked" and "there are none" are both statements this panel would be making without
        /// having read anything, and the second of them is the reassuring one.
        case failed(tool: Tool)

        public var label: String {
            switch self {
            case .notRead: "Checks not read"
            case .read(let rollup): rollup.label
            case .failed(let tool): "\(GitHubReadout.name(of: tool)) could not read these checks"
            }
        }
    }

    /// One row of the pull-request list.
    public struct PullRequestRow: Hashable, Sendable {
        public let number: Int
        public let title: String
        /// The author's login, which is what `gh` gives and what a row shows.
        public let author: String
        public let isDraft: Bool
        /// The review decision as this panel words it, never as GitHub spells it.
        public let reviewDecision: String
        public let labels: [String]
        public let checks: ChecksState
        public let isSelected: Bool

        public var checksLabel: String { checks.label }
    }

    /// One check of the selected pull request.
    public struct CheckRow: Hashable, Sendable {
        public let name: String
        /// The workflow it belongs to, when `gh` reported one.
        public let workflow: String?
        public let bucket: CheckBucket

        public var label: String { bucket.label }
    }

    /// One row of the issue section.
    public struct IssueRow: Hashable, Sendable {
        public let number: Int
        public let title: String
        public let author: String
        public let labels: [String]
        public let updatedAt: Date
    }

    /// The panel's own area (root spec §10). None of it crosses into the conversation.
    public struct Notice: Equatable, Sendable {
        /// Whether this replaces the tab's content or sits above it. A tab that cannot read
        /// GitHub at all has nothing to put behind a row, and one that failed a single read still
        /// has its branch and its list.
        public enum Placement: Hashable, Sendable {
            case emptyState
            case row
        }

        public let placement: Placement
        public let message: String
        /// The one thing the user can do, when there is one, and nothing when there is not. A panel
        /// that offered the same remedy for every failure would send the user to re-authenticate
        /// over a missing binary.
        public let hint: String?
    }

    /// The remedy for a `gh` that is not signed in, in the words the user types. Named so that a
    /// test asserts the hint rather than a paraphrase of it.
    public static let authenticationHint =
        "Run `gh auth login` in a terminal, then choose Refresh."

    /// The remedy for a `gh` that is not there. Deliberately not the one above.
    public static let installHint =
        "Install GitHub CLI from cli.github.com and reopen this channel, so the session's PATH "
        + "finds it."

    public let branch: String?
    public let isDetachedHead: Bool
    public let scope: GitHubModel.Scope
    public let isLoading: Bool
    public let hasRead: Bool
    public let pullRequests: [PullRequestRow]
    public let selectedPullRequest: Int?
    /// The selected pull request's checks, in the order `gh` printed them. Empty when nothing is
    /// selected, when its checks have not been read, and when reading them failed.
    public let selectedChecks: [CheckRow]
    /// **Why** `selectedChecks` is empty, which the rows alone cannot say. The three cases are the
    /// whole of it: nobody asked, the read failed, or the read found none.
    public let selectedChecksState: ChecksState
    public let issues: [IssueRow]
    public let notice: Notice?
    public let actions: [Action]

    public init(session: GitHubModel) {
        branch = session.branch
        isDetachedHead = session.isDetachedHead
        scope = session.scope
        isLoading = session.isLoading
        hasRead = session.hasRead
        selectedPullRequest = session.selectedPullRequest
        pullRequests = session.pullRequests.map { pull in
            PullRequestRow(number: pull.number,
                           title: pull.title,
                           author: pull.author.login,
                           isDraft: pull.isDraft,
                           reviewDecision: Self.label(for: pull.reviewDecision),
                           labels: pull.labels.map(\.name),
                           checks: Self.state(of: session.checks[pull.number]),
                           isSelected: pull.number == session.selectedPullRequest)
        }
        let selected = session.selectedPullRequest.flatMap { session.checks[$0] }
        selectedChecksState = Self.state(of: selected)
        selectedChecks = (Self.runs(of: selected) ?? [])
            .map { CheckRow(name: $0.name, workflow: $0.workflow,
                            bucket: CheckBucket(bucket: $0.bucket)) }
        issues = session.issues.map {
            IssueRow(number: $0.number, title: $0.title, author: $0.author.login,
                     labels: $0.labels.map(\.name), updatedAt: $0.updatedAt)
        }
        notice = Self.notice(for: session.failure)
        // Complete, always, for the reason `Action` states.
        actions = Action.allCases
    }

    /// One row's check state: absent is "nobody asked", and the two read outcomes are their own.
    static func state(of read: GitHubModel.ChecksRead?) -> ChecksState {
        switch read {
        case .none: .notRead
        case .read(let runs): .read(CheckRollup.of(runs))
        case .failed(let tool): .failed(tool: tool)
        }
    }

    static func runs(of read: GitHubModel.ChecksRead?) -> [CheckRun]? {
        guard case .read(let runs) = read else { return nil }
        return runs
    }

    /// GitHub's review decision in this panel's words.
    ///
    /// A value this model has no case for is named as such rather than printed: the panel has no
    /// rendering for a decision it has never seen, and passing the raw enumerator through would put
    /// GitHub's vocabulary in front of the user in the one place it is least legible.
    static func label(for decision: ReviewDecision) -> String {
        switch decision {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .notRequested: "No review requested"
        case .unknown: "Review state not recognised"
        }
    }

    /// One line for each way this tab can fail, and the hint where there is one.
    ///
    /// The mapping is the whole of Design §8's failure clause: a missing binary and a missing login
    /// are different problems with different remedies, and everything else is a row with no remedy
    /// at all rather than a guess at one.
    static func notice(for failure: GitHubModel.Failure?) -> Notice? {
        switch failure {
        case .none:
            return nil
        case .notARepository:
            return Notice(placement: .emptyState,
                          message: "This channel's folder is not a Git repository, so there is no "
                                 + "GitHub repository to read.",
                          hint: nil)
        case .toolMissing(.gh):
            return Notice(placement: .emptyState,
                          message: "GitHub CLI (gh) is not on this session's PATH, so this tab "
                                 + "cannot read GitHub.",
                          hint: installHint)
        case .toolMissing(.git):
            return Notice(placement: .emptyState,
                          message: "Git is not on this session's PATH, so this channel's "
                                 + "repository cannot be found.",
                          hint: nil)
        case .notAuthenticated:
            return Notice(placement: .emptyState,
                          message: "GitHub CLI is not signed in, so this tab could not read "
                                 + "GitHub.",
                          hint: authenticationHint)
        case .commandFailed(let tool, let exitCode):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) could not read this repository "
                                 + "(exit \(exitCode)).",
                          hint: nil)
        case .timedOut(let tool):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) did not answer in time.",
                          hint: nil)
        case .unreadable(let tool):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) answered with something this panel could "
                                 + "not read.",
                          hint: nil)
        case .unavailable(let tool):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) could not be run.",
                          hint: nil)
        }
    }

    /// A tool's name in the words this panel uses for it, never the executable's.
    ///
    /// Every notice that can be about either tool is worded from here. Two of this tab's three
    /// reads are `git`'s, and a notice that named the other one sent the user to look at a tool
    /// that was working.
    nonisolated static func name(of tool: Tool) -> String {
        switch tool {
        case .gh: "GitHub CLI"
        case .git: "Git"
        }
    }
}
