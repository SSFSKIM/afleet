// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §1, §3, §6, §7: what the Source Control tab shows and every action it offers, as a value.
import Foundation
import AfleetCore
import SourceControlCore

/// Everything `SourceControlPanelView` draws, reduced to a value.
///
/// It exists for the reason C5's `PlaceholderReadout`, C7.5's `FilesPanelReadout` and this leaf's
/// own `GitHubReadout` exist: a rendered `Text` is not an assertion. The view reads these fields
/// and formats nothing else, so a test asserting on a readout is asserting on what the user sees —
/// which rows are on screen, which of them is the working tree's, what the detail lists, which
/// rows offer a diff and what the panel's own area is saying.
///
/// **No field here can carry a byte a tool printed on stderr.** Paths, hashes, author names and
/// subjects are stdout — they are the panel's content and rendering them is the point — but every
/// message and every reason below is written in this file or in `SourceControlModel`. A
/// `ToolError`'s `stderrTail` is read to classify and then dropped, in `RepositoryError`, and
/// nothing downstream of it can reach a rendered string (§6.3, §11).
@MainActor
public struct SourceControlReadout: Equatable, Sendable {

    /// Every action any surface of this tab offers, complete.
    ///
    /// It is the **inventory** and not a sample of what is enabled right now: §9.2 is binding —
    /// no staging, commit, branch, checkout, stash, push or merge action exists in this panel, and
    /// this leaf is a reader — and a proof by sample would pass on a screen where the forbidden
    /// action merely happened to be disabled. `CaseIterable` is what makes G4's second proof an
    /// assertion about a universe: an action added to a view and not to this enum fails the readout
    /// test it was added to, and one added to both fails the inventory assertion.
    public enum Action: String, Hashable, Sendable, CaseIterable {
        /// Re-run the read cycle. The user's own door; the watch opens the same one unattended.
        case refresh
        /// Select a commit row, which loads its detail.
        case selectCommit
        /// Select row zero, the working tree's.
        case selectWorkingTree
        /// Select a parent of the commit on screen — a navigation between two rows, not a
        /// repository operation.
        case selectParentCommit
        /// Click a changed file, which emits a `.diff` link and does nothing else (Design §6).
        case openFileDiff
    }

    /// One row of a changed-file list, in either detail.
    public struct FileRow: Hashable, Sendable {
        public let path: String
        public let status: FileChange.Status
        public let kind: FileChange.Kind
        /// Lines added, and nil for a binary file, which git counts as `-`.
        public let additions: Int?
        public let deletions: Int?
        public let isBinary: Bool
        /// Whether clicking this row emits a `.diff` link at all (Design §6's two exclusions).
        public let opensADiff: Bool
        /// Why it does not, in this panel's words. Nil exactly when `opensADiff` is true — the row
        /// says why rather than offering a link that resolves to nothing.
        public let exclusionReason: String?

        public init(change: FileChange) {
            path = change.path
            status = change.status
            kind = change.kind
            additions = change.additions
            deletions = change.deletions
            isBinary = change.isBinary
            let reason = SourceControlReadout.exclusionReason(for: change)
            opensADiff = reason == nil
            exclusionReason = reason
        }
    }

    /// One row of the graph, with everything the row and its lane column draw.
    ///
    /// The edges are carried as C7.3 emits them — a **sequence**, never keyed by lane — because a
    /// row may hold two edges arriving in one `toLane` and both are drawn (tracker 121). The
    /// geometry that turns them into segments is `GraphGeometry`'s and is not repeated here.
    public struct Row: Hashable, Sendable {
        public let content: GraphRow.Content
        public let lane: Int
        public let edges: [GraphRow.Edge]
        public let badges: [RefBadge]
        public let isSelected: Bool

        public var commit: GitCommit? {
            if case .commit(let commit) = content { return commit }
            return nil
        }
        public var isWorkingTree: Bool { content == .workingTree }
        /// What a row draws instead of the full hash. Nil for the working tree's row, which has
        /// none.
        public var abbreviatedHash: String? { commit.map { String($0.hash.prefix(8)) } }
    }

    /// A selected commit's detail (Design §6).
    public struct CommitDetail: Hashable, Sendable {
        public let hash: String
        public let abbreviatedHash: String
        /// The three fields that come from the commit's own row in the window, and are **nil**
        /// when this panel does not hold that row — a commit selected and then paged out of the
        /// window. An empty author, an empty subject and the epoch are values git never reported,
        /// and inventing them is the mirror of §6.3's failure; the pane draws the hash and the
        /// file list it does hold, and says nothing about the rest.
        public let authorName: String?
        public let authorDate: Date?
        public let subject: String?
        /// Selectable rows in the view; selecting one is `Action.selectParentCommit`.
        public let parents: [String]
        public let badges: [RefBadge]
        public let files: [FileRow]
    }

    /// The working tree's detail — the same surface over `git diff HEAD`.
    ///
    /// Its files are `GitDiff.changes(base: .workingTreeAgainstHEAD)` and **never**
    /// `WorkingTreeStatus.entries`: the status answers "what is where" and this answers "what has
    /// changed", and only this one pairs with a `.diff` link that resolves (Design §6).
    public struct WorkingTreeDetail: Hashable, Sendable {
        public let files: [FileRow]
    }

    public enum Detail: Hashable, Sendable {
        case commit(CommitDetail)
        case workingTree(WorkingTreeDetail)

        public var files: [FileRow] {
            switch self {
            case .commit(let detail): detail.files
            case .workingTree(let detail): detail.files
            }
        }
    }

    /// The panel's own area (root spec §10). None of it crosses into the conversation.
    public struct Notice: Equatable, Sendable {
        /// Whether this replaces the tab's content or sits above it. A directory in no repository
        /// has nothing to put behind a row; a read that failed after the graph was drawn does.
        public enum Placement: Hashable, Sendable {
            case emptyState
            case row
        }

        public let placement: Placement
        public let message: String
        /// The one thing the user can do, when there is one, and nothing when there is not.
        public let hint: String?
    }

    /// The reason a submodule row offers no diff. Named so a test asserts the reason rather than a
    /// paraphrase of it.
    public nonisolated static let submoduleReason =
        "A submodule's two sides are a commit and a directory, so there is no file to diff."
    /// The reason a binary row offers none.
    public nonisolated static let binaryReason =
        "Git counted no lines in this file, so there is no text diff to show."
    /// The remedy for a watch that could not be armed: the panel says the rows are not refreshing
    /// themselves rather than presenting a stale tree as a fresh one.
    public nonisolated static let refreshHint = "Choose Refresh to re-read this repository."
    /// The empty state's own remedy (§5, as amended). A root that was deleted, moved or replaced
    /// reaches the empty state routinely, and an empty state with no way out is a panel that has
    /// to be restarted — so it carries the one action that recovers it.
    public nonisolated static let lookAgainHint = "Choose Refresh to look for a repository again."

    public let isEmptyState: Bool
    public let isLoading: Bool
    public let hasRead: Bool
    public let branch: String?
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    /// `HEAD` is on no branch. Not an error and not an empty repository.
    public let isDetachedHead: Bool
    public let rows: [Row]
    public let laneCount: Int
    /// Row zero is the working tree's exactly when the tree is dirty — C7.3's rule, restated here
    /// as the one field G1.5's bounded wait reads.
    public var hasWorkingTreeRow: Bool { rows.first?.isWorkingTree ?? false }
    public let selection: SourceControlModel.Selection?
    public let detail: Detail?
    public let isLoadingDetail: Bool
    public let notice: Notice?
    public let actions: [Action]

    public init(session: SourceControlModel) {
        let state = session.state
        isEmptyState = state.isEmptyState
        isLoading = session.isLoading
        hasRead = session.hasRead
        branch = state.status?.branch
        upstream = state.status?.upstream
        ahead = state.status?.ahead
        behind = state.status?.behind
        isDetachedHead = state.status != nil && state.status?.branch == nil
        let selection = session.selection
        self.selection = selection
        rows = state.assignment.rows.map { row in
            Row(content: row.content, lane: row.lane, edges: row.edges,
                badges: {
                    if case .commit(let commit) = row.content { return GraphGeometry.badges(for: commit) }
                    return []
                }(),
                isSelected: Self.isSelected(row.content, selection))
        }
        laneCount = state.assignment.laneCount
        detail = Self.detail(of: session)
        isLoadingDetail = session.isLoadingDetail
        notice = Self.notice(for: session)
        // Complete, always, for the reason `Action` states.
        actions = Action.allCases
    }

    private static func isSelected(_ content: GraphRow.Content,
                                   _ selection: SourceControlModel.Selection?) -> Bool {
        switch (content, selection) {
        case (.workingTree, .workingTree): true
        case (.commit(let commit), .commit(let hash)): commit.hash == hash
        default: false
        }
    }

    private static func detail(of session: SourceControlModel) -> Detail? {
        let files = session.changes.map(FileRow.init(change:))
        switch session.selection {
        case .none:
            return nil
        case .workingTree:
            return .workingTree(WorkingTreeDetail(files: files))
        case .commit(let hash):
            guard let commit = session.state.commits.first(where: { $0.hash == hash }) else {
                // Selected and then paged out of the window — the detail is still the commit's,
                // and the row's own fields are what this panel no longer holds. They are **nil**
                // and not blank: an empty author, an empty subject and the epoch are values git
                // never reported, and drawing them beside a real hash is the same fabrication
                // §6.3 forbids on the other side.
                return .commit(CommitDetail(hash: hash, abbreviatedHash: String(hash.prefix(8)),
                                            authorName: nil, authorDate: nil, subject: nil,
                                            parents: [], badges: [], files: files))
            }
            return .commit(CommitDetail(hash: commit.hash,
                                        abbreviatedHash: String(commit.hash.prefix(8)),
                                        authorName: commit.authorName,
                                        authorDate: commit.authorTimestamp,
                                        subject: commit.subject,
                                        parents: commit.parents,
                                        badges: GraphGeometry.badges(for: commit),
                                        files: files))
        }
    }

    /// Why a changed file offers no diff, or nil (Design §6).
    ///
    /// Two kinds and no more: a **gitlink**, whose two sides are a commit object and a directory
    /// and neither of which is blob-readable, and a **binary** file, for which git counted no
    /// lines because there are none. Everything else — a symlink included, whose blob is its
    /// destination text — is a pair C7.5's resolver can open.
    public nonisolated static func exclusionReason(for change: FileChange) -> String? {
        if change.kind == .gitlink { return submoduleReason }
        if change.isBinary { return binaryReason }
        return nil
    }

    /// The panel's one area, in precedence order.
    ///
    /// A delivery notice comes first: it is the answer to something the user just did — a
    /// `.commit` link clicked in the timeline — and every one of its cases already says what state
    /// the panel is in. The empty state is next, because there is nothing behind it. Then a tool
    /// failure, and last the watch that could not be armed, because a panel that cannot read at
    /// all has a bigger thing to say than one that merely will not re-read by itself.
    static func notice(for session: SourceControlModel) -> Notice? {
        // Before the empty state, deliberately: a `.commit` link delivered into a channel that is
        // in no repository is still owed the answer to what the user just clicked, and the row for
        // it says the folder is not a repository anyway.
        if let delivery = session.deliveryNotice { return notice(for: delivery) }
        if session.state.isEmptyState {
            return Notice(placement: .emptyState,
                          message: "This channel's folder is not a Git repository, so there is no "
                                 + "history to show.",
                          // §5, as amended: the empty state is reached by a root that was moved,
                          // replaced or pruned as routinely as by a folder that was never in a
                          // repository, so it carries the action that gets out of it.
                          hint: lookAgainHint)
        }
        if let error = session.state.error { return notice(for: error) }
        if session.watchFailedToArm {
            return Notice(placement: .row,
                          message: "This panel is not watching the repository for changes, so the "
                                 + "working-tree row will not update by itself.",
                          hint: refreshHint)
        }
        return nil
    }

    /// A `.commit` link that selected nothing, as the row it is owed (Design §7). Never a silent
    /// no-op: a link that reached a live target and produced nothing on screen is what §17.7
    /// exists to prevent.
    static func notice(for delivery: SourceControlModel.DeliveryNotice) -> Notice {
        switch delivery {
        case .commitNotFound(let hash):
            return Notice(placement: .row,
                          message: "Commit \(abbreviate(hash)) is not in the history this panel "
                                 + "searched.",
                          hint: refreshHint)
        case .ambiguousPrefix(let prefix, let matches):
            return Notice(placement: .row,
                          message: "\(abbreviate(prefix)) names \(matches) commits in this "
                                 + "history, so this panel did not pick one.",
                          hint: nil)
        case .noRepository(let hash):
            // The **empty state** and not a row: there is nothing behind this notice to float it
            // over, and the placement rule this type states is about exactly that. The message
            // carries both halves — what the folder is, and what became of the commit clicked —
            // because it replaces the empty state's own message rather than sitting above it.
            return Notice(placement: .emptyState,
                          message: "This channel's folder is not a Git repository, so commit "
                                 + "\(abbreviate(hash)) cannot be shown.",
                          hint: lookAgainHint)
        case .notReadable(let hash, let tool):
            return Notice(placement: .row,
                          message: "Commit \(abbreviate(hash)) cannot be shown: "
                                 + "\(name(of: tool)) could not read this repository.",
                          hint: refreshHint)
        case .searchInterrupted(let hash):
            return Notice(placement: .row,
                          message: "This panel did not finish looking for commit "
                                 + "\(abbreviate(hash)); the repository was being re-read.",
                          hint: refreshHint)
        }
    }

    /// One line for each way a `git` read can fail, worded for the tool it was about.
    ///
    /// `RepositoryError` carries the tool for exactly this reason, and the exit code is a number
    /// the tool returned rather than a byte it printed. `detail` is `RepositoryError`'s own words —
    /// it is composed from a `ToolError`'s *shape*, never from its output.
    static func notice(for error: RepositoryError) -> Notice {
        switch (error.tool, error.exitCode) {
        case (let tool, .some(let code)):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) could not read this repository "
                                 + "(exit \(code)).",
                          hint: refreshHint)
        case (let tool, .none) where error.detail == RepositoryError.binaryNotFoundDetail:
            return Notice(placement: .emptyState,
                          message: "\(name(of: tool)) is not on this session's PATH, so this "
                                 + "channel's repository cannot be read.",
                          hint: nil)
        case (let tool, .none):
            return Notice(placement: .row,
                          message: "\(name(of: tool)) \(error.detail).",
                          hint: refreshHint)
        }
    }

    /// A tool's name in the words this panel uses for it, never the executable's.
    static func name(of tool: Tool) -> String {
        switch tool {
        case .git: "Git"
        case .gh: "GitHub CLI"
        }
    }

    private static func abbreviate(_ hash: String) -> String { String(hash.prefix(12)) }
}
