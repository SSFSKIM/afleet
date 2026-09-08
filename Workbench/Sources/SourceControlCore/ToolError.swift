import Foundation

/// The command-line tools this module runs. Both are the user's own, resolved through the
/// resolved environment's `PATH` and never through a hard-coded location: a different `git` means
/// different hooks and credential helpers, and a different `gh` means a different stored token
/// (ledger D2).
public enum Tool: String, Sendable, CaseIterable {
    case git
    case gh
}

/// Everything a source-control read can fail with.
///
/// Root spec §10: "Git and PTY failures: panel-local error states that never take the channel
/// down". Every case here is a value the panel renders in its own area; none of them is an
/// exception that crosses into the conversation. The cases carry tool names, exit codes and short
/// message tails — never a path, an environment or an identity, because a rendered error is a
/// published byte (§6.3, §11).
public enum ToolError: Error, Equatable, Sendable {
    /// No executable of that name on the passed environment's `PATH`. There is no fallback to
    /// `/usr/bin`, to Homebrew's prefix or to this process's own environment (D2), so this is the
    /// whole of "the tool is not installed, or the captured environment does not see it".
    case binaryNotFound(tool: Tool)
    /// The process could not be started at all — the one thing the runner itself throws besides
    /// `binaryNotFound`.
    case spawnFailed(tool: Tool, message: String)
    /// The child outlived its budget and was terminated. `afterMs` is the budget, not the elapsed
    /// time.
    case timedOut(tool: Tool, afterMs: Int)
    /// The awaiting task was cancelled, so the child was terminated and no result was produced.
    /// A cancelled read is not a failure the panel reports; it is a read the panel asked to stop.
    case cancelled(tool: Tool)
    /// The child produced more output than the runner retains for one command, so it was
    /// terminated exactly as a timeout terminates it. `limitBytes` is the cap, not the amount
    /// produced: the amount is unbounded by definition, which is why the cap exists.
    case outputLimitExceeded(tool: Tool, limitBytes: Int)
    /// The command ran and exited with a code its wrapper does not accept. The runner never
    /// produces this: exit codes are data at the process layer and only a command wrapper knows
    /// which of them mean failure — `gh pr checks` exits 8 while checks are pending, and that is
    /// not a failure (D3).
    case commandFailed(tool: Tool, exitCode: Int32, stderrTail: String)
    /// The directory the panel was pointed at is not inside a git repository. The panel's empty
    /// state, not an error to report (D13).
    case notARepository
    /// A working-tree read was asked for a path that does not resolve inside the repository it
    /// was asked of: an absolute path, one carrying a `..` component, one whose parent chain
    /// resolves outside the root through a symbolic link in the ancestry, or one whose parent
    /// chain does not resolve at all. The refusal is the panel's, not git's — `workingTreeFile`
    /// reads the file system directly and the path reaches it from a rendered row (D54/4).
    ///
    /// `reason` names *which* of those it was, in this module's own words. It carries no path, for
    /// the reason stated above: the offending path is the caller's byte and a rendered error is a
    /// published one (§6.3, §11).
    case pathOutsideRepository(reason: String)
    /// Output that did not have the shape the parser requires. `subject` names what was being
    /// decoded; a parser that silently skipped the record it could not read would make the test
    /// that compares it unfalsifiable (§17.7).
    case decodeFailed(subject: String, message: String)
}
