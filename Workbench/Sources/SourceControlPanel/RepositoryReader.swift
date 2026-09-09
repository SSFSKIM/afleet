// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §1, §3, §6. Gates G1.1, G1.3 and G4's argv half.
import Foundation
import AfleetCore
import SourceControlCore

/// One panel-local error row: which tool failed, and what it exited with.
///
/// Root spec §10 makes every `git` failure a state the panel renders in its own area rather than
/// an exception crossing into the conversation, which is why nothing in this file throws past its
/// own return type. §6.3 and §11 fix what such a row may *carry*: the tool's name, its exit code
/// where there was one, and a description in this module's own words. Never the tool's output —
/// `ToolError.commandFailed` carries a `stderrTail` and it is read here only to be discarded, because
/// a rendered error is a published byte and stderr from a command run in the user's own repository
/// is the user's.
public struct RepositoryError: Hashable, Sendable {

    /// The tool whose invocation failed. Always `.git` from this reader; carried rather than
    /// assumed so that a row reads the same when the GitHub tab's reader produces one.
    public var tool: Tool
    /// The child's exit status, and nil for every failure that happened before or instead of an
    /// exit — an unresolvable binary, a spawn that failed, a budget that expired, a cancellation.
    public var exitCode: Int32?
    /// What went wrong, in this module's words.
    public var detail: String

    /// The one detail a test can name without quoting a message the reader composed at runtime.
    public static let binaryNotFoundDetail = "not found on the resolved PATH"

    public init(tool: Tool, exitCode: Int32?, detail: String) {
        self.tool = tool
        self.exitCode = exitCode
        self.detail = detail
    }

    /// Turns a thrown `ToolError` into a row.
    ///
    /// `.notARepository` never reaches here: it is the panel's *empty* state and each caller
    /// intercepts it before this initialiser sees it (D13). It is nonetheless mapped, rather than
    /// left to the fallback, so that a future caller that forgets produces a truthful row instead
    /// of "a reason this reader does not name".
    public init(_ error: any Error, tool: Tool = .git) {
        switch error {
        case ToolError.binaryNotFound(let tool):
            self.init(tool: tool, exitCode: nil, detail: Self.binaryNotFoundDetail)
        case ToolError.spawnFailed(let tool, _):
            // The message is the operating system's and may name a path; dropped for §6.3.
            self.init(tool: tool, exitCode: nil, detail: "could not be started")
        case ToolError.timedOut(let tool, let afterMs):
            self.init(tool: tool, exitCode: nil, detail: "exceeded its \(afterMs) ms budget")
        case ToolError.cancelled(let tool):
            self.init(tool: tool, exitCode: nil, detail: "was cancelled")
        case ToolError.outputLimitExceeded(let tool, let limitBytes):
            self.init(tool: tool, exitCode: nil,
                      detail: "produced more than the \(limitBytes) byte cap")
        case ToolError.commandFailed(let tool, let exitCode, _):
            // `stderrTail` is bound and dropped deliberately: it is read to classify, never to
            // render (§6.3, G3's clause, which G4's half of this leaf holds to as well).
            self.init(tool: tool, exitCode: exitCode, detail: "exited \(exitCode)")
        case ToolError.notARepository:
            self.init(tool: tool, exitCode: nil, detail: "is not inside a repository")
        case ToolError.pathOutsideRepository(let reason):
            self.init(tool: tool, exitCode: nil, detail: reason)
        case ToolError.unreadableWorkingTreeEntry(let reason):
            self.init(tool: tool, exitCode: nil, detail: reason)
        case ToolError.decodeFailed(let subject, _):
            self.init(tool: tool, exitCode: nil, detail: "printed output \(subject) does not parse")
        default:
            self.init(tool: tool, exitCode: nil, detail: "failed for a reason this reader does not name")
        }
    }
}

/// Everything one read cycle produces (spec §3), as one value.
///
/// The three states are distinguished by which fields are populated rather than by an enum,
/// because the model above this holds exactly one of these and a view draws from all of it:
///
/// - **loaded** — `root` and `status` set, `error` nil;
/// - **empty** — every field at its default, which is `.notARepository`: the directory the channel
///   was opened at is in no repository, or is a bare one. Not an error row (D13);
/// - **failed** — `error` set. `root` may be set with it, because the root resolves before the two
///   reads that can fail on their own.
public struct RepositoryState: Hashable, Sendable {

    /// The physical working-tree root `rev-parse --show-toplevel` printed. Nil in the empty state,
    /// and in a failure that happened resolving it.
    public var root: URL?
    /// `headOID`, `branch`, `upstream`, `ahead`/`behind` and `isClean`. **Not** the changed-file
    /// list: `entries` answers a different question from `git diff HEAD` and §6 keeps the two
    /// apart. `workingTreeChanges()` is the list.
    public var status: WorkingTreeStatus?
    /// The window `GitLog` read, newest first, extended by `page(after:)`.
    public var commits: [GitCommit] = []
    /// C7.3's lanes over that window, with row zero the working tree exactly when it is dirty.
    public var assignment = LaneAssignment(rows: [], laneCount: 0)
    /// The one panel-local row, or nil.
    public var error: RepositoryError?

    /// True when the channel's directory resolved to no repository at all — the empty state, which
    /// a view renders as "no repository here" and never as a failure.
    public var isEmptyState: Bool { root == nil && error == nil }

    public init(root: URL? = nil, status: WorkingTreeStatus? = nil, commits: [GitCommit] = [],
                assignment: LaneAssignment = LaneAssignment(rows: [], laneCount: 0),
                error: RepositoryError? = nil) {
        self.root = root
        self.status = status
        self.commits = commits
        self.assignment = assignment
        self.error = error
    }
}

/// The same three states for the reads that answer with something other than a whole cycle.
public enum RepositoryResult<Value: Hashable & Sendable>: Hashable, Sendable {
    case value(Value)
    /// `.notARepository`: the empty state, and not an error row (D13).
    case notARepository
    case failed(RepositoryError)
}

/// Every read this leaf makes, and the place W7's "no second git reader" is visibly true.
///
/// It writes **no command line**. Each function below is one call into `GitCommands`, `GitLog`,
/// `WorkingTreeStatus` or `GitDiff`, and the argument vectors those produce are the only ones this
/// leaf can ever emit — which is what G4's argv assertion is an assertion about.
///
/// `cwd` is the *channel's* directory and is not necessarily a repository root (C7.3's D13).
/// `load()` starts from it and lets `SourceControlCore` resolve the root, so a channel opened at a
/// subdirectory reads the repository it belongs to and recombines git's root-relative paths
/// against the right anchor.
///
/// **Every other read takes that resolved root as an argument, and never `cwd` a second time.**
/// The two name the same repository until they do not: a `claude` session that runs `git init` in
/// the channel's own directory makes `cwd` resolve somewhere else, and a window or a file list
/// read from there would be paired with a `RepositoryState.root` that no longer describes it —
/// `root` is what a `.diff` link carries as `DiffRef.repository`, so C7.5's resolver would be
/// handed a repository and a path that were never read together.
public struct RepositoryReader: Sendable {

    public let cwd: URL
    public let environment: ResolvedEnvironment
    public let runner: any ToolRunning

    public init(cwd: URL, environment: ResolvedEnvironment, runner: any ToolRunning) {
        self.cwd = cwd
        self.environment = environment
        self.runner = runner
    }

    private var variables: [String: String] { environment.variables }

    // MARK: - the read cycle

    /// Spec §3's four steps: resolve the root, read the status and the window together, assign
    /// lanes over both.
    ///
    /// The two reads are issued together because neither depends on the other and each is a
    /// process; they are joined here, and a failure of either is *one* row rather than two — the
    /// second is discarded with the task that produced it, since a panel that reported the same
    /// outage twice would be reporting the count of reads it happened to make.
    public func load(limit: Int = GitLog.defaultLimit) async -> RepositoryState {
        let root: URL
        do {
            root = try await GitCommands.repositoryRoot(cwd: cwd, environment: variables,
                                                        runner: runner)
        } catch ToolError.notARepository {
            return RepositoryState()
        } catch {
            return RepositoryState(error: RepositoryError(error))
        }

        async let statusRead = WorkingTreeStatus.read(root: root, environment: variables,
                                                      runner: runner)
        async let commitsRead = GitLog.commits(root: root, environment: variables, runner: runner,
                                               limit: limit)
        do {
            let status = try await statusRead
            let commits = try await commitsRead
            return RepositoryState(
                root: root, status: status, commits: commits,
                assignment: LaneAssignment.assign(commits: commits, headOID: status.headOID,
                                                  workingTreeIsDirty: !status.isClean))
        } catch ToolError.notARepository {
            // The root resolved and then stopped being a repository between two reads — a
            // directory replaced under the panel. The empty state is the truthful answer.
            return RepositoryState()
        } catch {
            return RepositoryState(root: root, error: RepositoryError(error))
        }
    }

    // MARK: - paging the window

    /// A window `limit` commits longer than `window`, **re-read whole** rather than extended by a
    /// suffix.
    ///
    /// A suffix at `skip: window.count` is what `--skip` invites, and it is wrong here, because
    /// `git log --topo-order --all` lists the repository *as it is now* and this app's
    /// repositories change while the panel is open — a `claude` session commits on its own branch
    /// between the two reads. A new tip re-orders the listing, so a suffix taken at the old `skip`
    /// can carry a commit whose child is already in the held window and append it *below* that
    /// child. `LaneAssignment.assign` depends on exactly one property of its input — that no
    /// commit is listed before all of its children — and a window assembled that way violates it,
    /// drawing lanes and edges backwards. A commit that disappeared between the reads (a branch
    /// deleted, a `gc`) shifts the same `skip` the other way and drops one silently.
    ///
    /// One read at the grown limit removes both by construction, and needs no de-duplication: a
    /// single listing repeats no commit. It costs one more walk of a history git produces in a
    /// single pass.
    ///
    /// `root` is `RepositoryState.root` — the root `load()` resolved, and not `cwd`, which may
    /// since have become the root of a repository this panel is not showing.
    public func page(after window: [GitCommit], root: URL,
                     limit: Int = GitLog.defaultLimit) async -> RepositoryResult<[GitCommit]> {
        do {
            return .value(try await GitLog.commits(root: root, environment: variables,
                                                   runner: runner, limit: window.count + limit))
        } catch ToolError.notARepository {
            return .notARepository
        } catch {
            return .failed(RepositoryError(error))
        }
    }

    // MARK: - the two changed-file lists

    /// The files `commitHash` changed, against its **first parent** (spec §6).
    ///
    /// One invocation, C7.3's `.commitAgainstParent` mapping to `git show --first-parent --root`:
    /// already right for a merge, whose default listing is a combined diff nothing here could
    /// read, and for a root commit, which has no `^` to diff against and lists its whole tree.
    public func changes(in commitHash: String, root: URL) async -> RepositoryResult<[FileChange]> {
        await changes(base: .commitAgainstParent(commitHash), root: root)
    }

    /// What the working tree holds that `HEAD` does not — staged and unstaged together.
    ///
    /// This, and never `WorkingTreeStatus.entries`, is the working tree's file list (§6). Porcelain
    /// v2 reports an index side and a working-tree side, so a path staged and then edited again is
    /// two sides of one entry there and one row here; the status answers "what is where" and this
    /// answers "what has changed", and only this one pairs with a `.diff` link that resolves.
    public func workingTreeChanges(root: URL) async -> RepositoryResult<[FileChange]> {
        await changes(base: .workingTreeAgainstHEAD, root: root)
    }

    private func changes(base: DiffRef.Base, root: URL) async -> RepositoryResult<[FileChange]> {
        do {
            return .value(try await GitDiff.changes(root: root, base: base, environment: variables,
                                                    runner: runner))
        } catch ToolError.notARepository {
            return .notARepository
        } catch {
            return .failed(RepositoryError(error))
        }
    }
}
