import Foundation

/// Reads a repository's commit graph and turns it into `[GitCommit]`.
///
/// Contract W7 fixes the command line and the format string; ledger D5 adds the window. Nothing
/// here knows about lanes — that is `LaneAssignment`'s work, and it depends only on the ordering
/// guarantee `--topo-order` makes.
public enum GitLog {

    /// Contract W7's format, as amended on 2026-09-08: six fields separated by **NUL**.
    ///
    /// W7 originally separated the fields with `US` (`%x1f`) and terminated the record with `RS`
    /// (`%x1e`), on the reasoning that neither byte appears in a ref name. Neither byte appears in
    /// a *ref name*; both are perfectly legal in a **commit subject**, and `%s` does not escape
    /// them. One such subject — in any repository a user might clone — split its own record into
    /// seven fields, or into two records, and the field-count guard then rejected the whole
    /// history window rather than the one commit: the panel went blank for the repository.
    ///
    /// NUL is the one byte git guarantees cannot occur in commit metadata, which is why `-z` is
    /// git's own answer everywhere else in this module (D7). With `-z` on the command line git
    /// also terminates each *commit* with NUL instead of a newline, so the whole output is a flat
    /// run of NUL-terminated fields and the frame is the **count**: six fields per record, always.
    /// `testASubjectCarryingTheOldFramingBytesDecodesAsOneRecord` pins that against the machine's
    /// own `git` with a subject carrying both of the old separators and a newline.
    public static let format = "%H%x00%P%x00%D%x00%an%x00%at%x00%s"

    /// The number of fields `format` prints per commit, which is the whole of the framing.
    static let fieldsPerRecord = 6

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
    /// The command is contract W7's plus the window and two configuration pins. `--parents` is
    /// redundant with `%P` in the format and is kept because W7 names it and it costs nothing.
    ///
    /// **The pins (D45).** Production runs the user's own `git` with the user's own configuration
    /// — contract X11's whole point, so that hooks, credential helpers and worktrees behave — while
    /// the fixtures run with it disabled (D14). Anything the user can set that changes these bytes
    /// is therefore invisible to the suite unless it is pinned here or attacked in
    /// `AdverseConfigurationTests`. Two settings measured on `git` 2.55.0 do change them:
    ///
    /// - `log.decorate` changes which form `%D` prints. `--decorate=full` pins the *full* form —
    ///   `refs/heads/…`, `refs/remotes/<remote>/…`, `refs/tags/…` — which is the one form that
    ///   says which namespace a ref came from, and is what `refs(from:)` strips. A user holding
    ///   `log.decorate=short` is the adverse value in this direction: the shortened form drops the
    ///   namespace and a local branch named `origin/feature` becomes the remote-tracking one.
    /// - `i18n.logOutputEncoding` re-encodes the whole of the output, so a user whose terminal is
    ///   not UTF-8 would hand `parse` bytes that are not the format's — measured as a
    ///   `decodeFailed` on the timestamp field under `UTF-16`. `--encoding=UTF-8` pins what
    ///   `stdoutText` decodes, and is a no-op under the default, which already converts to UTF-8.
    ///
    /// A third, added by R5 (D47) and the worst shape of the class so far:
    ///
    /// - `log.showSignature=true` makes git run its signature check on every **signed** commit and
    ///   print the verdict on stdout *before* the record the format asked for — measured on `git`
    ///   2.55.0 as a `Good "git" signature for …` line, or `No signature` where the signature
    ///   cannot be verified. A custom `--format` does not suppress it. The record still splits into
    ///   exactly six fields, so `parse` does not throw: the verdict line lands **inside**
    ///   `GitCommit.hash`, every parent match fails, and every lookup by hash misses. That is a
    ///   silent wrong answer, not a failure. `--no-show-signature` pins the default and prints
    ///   nothing extra under it. R4 ruled this setting out because every adverse-configuration
    ///   fixture was *unsigned*, which is the §17.7 shape: the tripwire was green because the
    ///   fixture could not make it red.
    ///
    /// W7 was amended on 2026-09-08 (ledger D52) to take `--decorate=full`, which is what closed
    /// tracker 115; the pin stays explicit because `log.decorate=short` is adverse to it.
    public static func commits(root: URL, environment: [String: String],
                               runner: any ToolRunning, limit: Int = defaultLimit,
                               skip: Int = 0) async throws -> [GitCommit] {
        let root = try await GitCommands.repositoryRoot(cwd: root, environment: environment,
                                                        runner: runner, timeout: readTimeout)
        let output = try await runner.run(.git,
                                          arguments: ["log", "--topo-order", "--all", "--parents",
                                                      "--decorate=full", "-z", "--encoding=UTF-8",
                                                      "--no-show-signature",
                                                      "--format=\(format)",
                                                      "-n", "\(limit)", "--skip", "\(skip)"],
                                          cwd: root, environment: environment,
                                          timeout: readTimeout)
        try output.requireCompleted(tool: .git, timeout: readTimeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return try parse(output.stdoutText)
    }

    /// Decodes the bytes `format` produces.
    ///
    /// Under `-z` there is no record separator to find: git terminates every field and every
    /// commit with NUL, so the output is one flat run of fields and a record is **exactly six** of
    /// them. A field count that is not a multiple of six throws `.decodeFailed`; no record is ever
    /// skipped. Silently dropping the record a test exists to compare is root spec §17.7's seventh
    /// named failure instance, and it is what makes such a test unfalsifiable.
    ///
    /// The one empty tail after the final terminator is dropped; an empty field anywhere else is a
    /// legitimate value — a root commit has no parents, an undecorated commit has no refs, and a
    /// commit may have an empty subject — and is carried as one.
    public static func parse(_ text: String) throws -> [GitCommit] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % fieldsPerRecord == 0 else {
            throw ToolError.decodeFailed(subject: "git log record",
                                         message: "the output holds \(fields.count) NUL-separated "
                                                + "fields, which is not a whole number of "
                                                + "\(fieldsPerRecord)-field records")
        }

        return try stride(from: 0, to: fields.count, by: fieldsPerRecord).map { start in
            let record = fields[start..<(start + fieldsPerRecord)]
            let field = { record[start + $0] }
            guard let seconds = TimeInterval(field(4)) else {
                throw ToolError.decodeFailed(subject: "git log record",
                                             message: "the author timestamp is not a number")
            }
            return GitCommit(hash: String(field(0)),
                             parents: field(1).split(separator: " ").map(String.init),
                             refs: self.refs(from: field(2)),
                             authorName: String(field(3)),
                             authorTimestamp: Date(timeIntervalSince1970: seconds),
                             subject: String(field(5)))
        }
    }

    /// Decodes one `%D` decoration list.
    ///
    /// Measured on `git` 2.55.0 under `--decorate=full`: decorations are comma-and-space
    /// separated; every ref arrives as its full path — `refs/heads/x`, `refs/remotes/origin/x`,
    /// `refs/tags/v9` — a tag is additionally prefixed `tag: `; an attached `HEAD` prints
    /// `HEAD -> refs/heads/main`, which is two refs, not one; a detached `HEAD` prints a bare
    /// `HEAD`, and a detached `HEAD` that also carries a tag and sits on a branch prints
    /// `HEAD, tag: refs/tags/v9, refs/heads/main`.
    ///
    /// The full form is what closed tracker 115: under the shortened form a local branch named
    /// `origin/feature` and the remote-tracking `origin/feature` printed the same bytes, and a
    /// local `feature/x` had to be guessed at as a remote `feature`'s branch `x`. The namespace
    /// now says which is which and no guess is left.
    ///
    /// One narrower ambiguity survives and cannot be read out of `%D` at all: a remote whose own
    /// name contains a slash. `refs/remotes/a/b/x` is the branch `b/x` of a remote `a` or the
    /// branch `x` of a remote `a/b`, and the ref path does not record where the boundary is; the
    /// first slash is taken, which is right for every remote name without one.
    static func refs(from decoration: some StringProtocol) -> [GitRef] {
        decoration.components(separatedBy: ", ").flatMap { component -> [GitRef] in
            if component.isEmpty { return [] }
            if let arrow = component.range(of: " -> ") {
                return [GitRef(kind: .head, name: String(component[component.startIndex..<arrow.lowerBound])),
                        ref(atFullPath: String(component[arrow.upperBound...]))]
            }
            if component == "HEAD" { return [GitRef(kind: .head, name: "HEAD")] }
            if component.hasPrefix("tag: ") { return [ref(atFullPath: String(component.dropFirst(5)))] }
            return [ref(atFullPath: component)]
        }
    }

    /// Turns one full ref path into a `GitRef`.
    ///
    /// A path under none of the three namespaces keeps its whole path as the name of a
    /// `.branch` — `refs/stash` is the one `--all` actually reaches, and it prints identically
    /// under both decoration forms because git shortens only the three. Naming it verbatim is
    /// the honest answer: `GitRef.Kind` has no case for it, and inventing a remote called `refs`
    /// out of the slash is the very reading tracker 115 was about.
    private static func ref(atFullPath path: String) -> GitRef {
        if let name = path.dropping("refs/heads/") { return GitRef(kind: .branch, name: name) }
        if let name = path.dropping("refs/tags/") { return GitRef(kind: .tag, name: name) }
        if let rest = path.dropping("refs/remotes/"), let slash = rest.firstIndex(of: "/") {
            return GitRef(kind: .remoteBranch(remote: String(rest[rest.startIndex..<slash])),
                          name: String(rest[rest.index(after: slash)...]))
        }
        return GitRef(kind: .branch, name: path)
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when the string does not carry it.
    func dropping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
