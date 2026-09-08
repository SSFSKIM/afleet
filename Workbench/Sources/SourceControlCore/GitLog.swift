import Foundation

/// Reads a repository's commit graph and turns it into `[GitCommit]`.
///
/// Contract W7 fixes the command line and the format string; ledger D5 adds the window. Nothing
/// here knows about lanes — that is `LaneAssignment`'s work, and it depends only on the ordering
/// guarantee `--topo-order` makes.
public enum GitLog {

    /// Contract W7's format, unchanged.
    ///
    /// Six fields separated by `US` (`%x1f`, U+001F) and terminated by `RS` (`%x1e`, U+001E),
    /// because neither byte can appear in a ref name and neither is produced by git's own quoting.
    /// A separator a human would reach for — a pipe, a tab — appears in real commit subjects; that
    /// is what `testASubjectWithAPipeATabAndANonASCIICharacterSurvives` pins.
    public static let format = "%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s%x1e"

    /// The default number of commits read in one call (D5). A window rather than the whole of
    /// `--all`, because `--all` on a large repository is unbounded while the panel draws a
    /// viewport. Pagination is advisory under W7, so this is a default and not a law.
    public static let defaultLimit = 2000

    /// How long a local `git log` may take before the runner gives up (D4). Local reads are
    /// milliseconds; thirty seconds is the budget for a cold cache on a very large repository,
    /// and anything past it is a hang rather than a slow read.
    static let readTimeout: Duration = .seconds(30)

    /// The window of the repository's commit graph reachable from any ref, newest first in
    /// topological order.
    ///
    /// The command is contract W7's plus the window. `--parents` is redundant with `%P` in the
    /// format and is kept because W7 names it and it costs nothing.
    public static func commits(root: URL, environment: [String: String],
                               runner: any ToolRunning, limit: Int = defaultLimit,
                               skip: Int = 0) async throws -> [GitCommit] {
        let output = try await runner.run(.git,
                                          arguments: ["log", "--topo-order", "--all", "--parents",
                                                      "--format=\(format)",
                                                      "-n", "\(limit)", "--skip", "\(skip)"],
                                          cwd: root, environment: environment,
                                          timeout: readTimeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return try parse(output.stdoutText)
    }

    /// Decodes the bytes `format` produces.
    ///
    /// Records are `RS`-separated and git emits a newline after each one, so every record but the
    /// first arrives with a leading newline that is not part of any field. A record must split
    /// into **exactly six** fields; one that does not throws `.decodeFailed` and is never skipped.
    /// Silently dropping the record a test exists to compare is root spec §17.7's seventh named
    /// failure instance, and it is what makes such a test unfalsifiable.
    public static func parse(_ text: String) throws -> [GitCommit] {
        var records = text.split(separator: "\u{1e}", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == "\n" || $0 == "\r" } }
        // The trailing newline after the final record separator, and nothing else: an empty
        // record anywhere else falls through to the field-count guard below.
        if records.last?.isEmpty == true { records.removeLast() }

        return try records.map { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 6 else {
                throw ToolError.decodeFailed(subject: "git log record",
                                             message: "expected 6 fields, found \(fields.count)")
            }
            guard let seconds = TimeInterval(fields[4]) else {
                throw ToolError.decodeFailed(subject: "git log record",
                                             message: "the author timestamp is not a number")
            }
            return GitCommit(hash: String(fields[0]),
                             parents: fields[1].split(separator: " ").map(String.init),
                             refs: self.refs(from: fields[2]),
                             authorName: String(fields[3]),
                             authorTimestamp: Date(timeIntervalSince1970: seconds),
                             subject: String(fields[5]))
        }
    }

    /// Decodes one `%D` decoration list.
    ///
    /// Measured on `git` 2.55.0: decorations are comma-and-space separated; a tag is prefixed
    /// `tag: `; an attached `HEAD` prints `HEAD -> main`, which is two refs, not one; a detached
    /// `HEAD` prints a bare `HEAD`, and a detached `HEAD` that also carries a tag and sits on a
    /// branch prints `HEAD, tag: v9, main`; a remote-tracking branch prints `origin/main`.
    ///
    /// The one thing the shortened form cannot express: `origin/main` and a local branch literally
    /// named `origin/main` print identically, so a slash is read as a remote separator. A local
    /// branch with a slash in its name — `feature/x` — is therefore reported as a remote-tracking
    /// branch of a remote named `feature`. The fix is `--decorate=full`, which prints
    /// `refs/heads/…` and `refs/remotes/…` unambiguously, but that is a change to W7's command
    /// line, so it is filed as tech debt rather than taken here. The arrow form is exempt:
    /// `HEAD -> feature/x` names a local branch by construction and is read as one.
    static func refs(from decoration: some StringProtocol) -> [GitRef] {
        decoration.components(separatedBy: ", ").flatMap { component -> [GitRef] in
            if component.isEmpty { return [] }
            if let arrow = component.range(of: " -> ") {
                return [GitRef(kind: .head, name: String(component[component.startIndex..<arrow.lowerBound])),
                        GitRef(kind: .branch, name: String(component[arrow.upperBound...]))]
            }
            if component == "HEAD" { return [GitRef(kind: .head, name: "HEAD")] }
            if component.hasPrefix("tag: ") { return [GitRef(kind: .tag, name: String(component.dropFirst(5)))] }
            if let slash = component.firstIndex(of: "/") {
                return [GitRef(kind: .remoteBranch(remote: String(component[component.startIndex..<slash])),
                               name: String(component[component.index(after: slash)...]))]
            }
            return [GitRef(kind: .branch, name: component)]
        }
    }
}
