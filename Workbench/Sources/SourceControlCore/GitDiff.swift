import Foundation
import AfleetCore

/// One path a diff changed, with everything a changed-file list draws for it.
///
/// Deliberately not a hunk, a patch or a text (ledger D8). Contract W4 renders diffs through
/// Monaco's diff editor, which takes two whole texts — original and modified — rather than a
/// unified patch, so what a panel needs from this module is the *list* plus a way to fetch either
/// side's bytes. `GitDiff.blob` and `GitDiff.workingTreeFile` are that way; a unified-diff parser
/// is explicitly not built, and the case that would need one (a binary file) is flagged with
/// `isBinary` rather than diffed.
public struct FileChange: Hashable, Sendable {

    /// What the diff did to the path, as `git diff --raw --find-renames` reports it.
    ///
    /// `renamed` and `copied` carry the path the content came from and git's similarity score
    /// (`R100` is an exact rename, `R087` a rename with edits), because a rename with a low score
    /// is a rename a panel may want to draw differently from an exact one.
    public enum Status: Hashable, Sendable {
        case added
        case modified
        case deleted
        case renamed(from: String, score: Int)
        case copied(from: String, score: Int)
        case typeChanged
    }

    /// What kind of entry the path names, read from the file modes `--raw` prints beside it.
    ///
    /// The one that is not a file is why this exists. A **gitlink** — a submodule, mode `160000` —
    /// is a commit object recorded in the superproject's tree, and neither side of it can be read
    /// the way a file's side is read: `git cat-file blob <rev>:<path>` refuses the object because
    /// it is a commit, and the working-tree side is a *directory*. `--numstat` nevertheless prints
    /// ordinary numeric counts for it, so nothing downstream of the counts can tell a submodule
    /// from a one-line text file. A panel reads this instead and draws the entry without offering
    /// either side.
    public enum Kind: Hashable, Sendable {
        case file
        /// Mode `120000`. Both sides are readable: git stores the destination text as the blob and
        /// `workingTreeFile` returns the same bytes for the working-tree side (D42).
        case symlink
        /// Mode `160000` — a submodule. Never blob-read.
        case gitlink
    }

    /// Repository-relative, and for a rename or a copy the **new** path — the one the change
    /// lands on. Raw bytes decoded as UTF-8, never git's C-quoted form, which is what `-z` buys
    /// (ledger D7).
    public var path: String
    public var status: Status
    /// Lines added, or nil for a binary file, which git reports as `-` because it has no lines to
    /// count.
    public var additions: Int?
    /// Lines deleted, nil under the same condition.
    public var deletions: Int?
    /// True exactly when git reported `-` for both counts. A panel shows a binary change as a
    /// change without offering a text diff of it.
    public var isBinary: Bool
    /// Defaults to `.file`, which is what every mode but two is.
    public var kind: Kind

    public init(path: String, status: Status, additions: Int?, deletions: Int?, isBinary: Bool,
                kind: Kind = .file) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.kind = kind
    }
}

/// The changed-file list for a `DiffRef.Base`, and access to either side's bytes.
///
/// **One invocation, not two.** Measured on `git` 2.55.0: `--name-status` and `--numstat` given to
/// the same command do not both print — the last one wins and no section of the other appears at
/// all, which is why this module first read the two listings separately and joined them by path.
/// That join was over **two** reads of the same repository, each resolving `HEAD`, the index and
/// the working tree for itself: an edit landing between them produced either a `.decodeFailed`
/// naming a path present in one listing and absent from the other, or — when the edit merely
/// changed a file's counts — a record silently mixing one instant's status with another's counts.
///
/// `--raw` is the listing that does print alongside `--numstat`: git emits the raw section, then
/// the numstat section, from one traversal of one snapshot. It carries the same status codes and
/// rename information `--name-status` does *and* the file modes, which is where
/// `FileChange.Kind` comes from. `GitDiffTests.testRawAndNumstatGivenTogetherBothPrintOneSnapshot`
/// pins both halves of that fact against the machine's own `git`, so a future git whose bytes
/// differ fails a named test rather than mis-parsing here.
public enum GitDiff {

    /// A read of the object database and the working tree, so it is bounded by disk rather than
    /// by network; 30 s is the same budget the other readers take, for the same reason (D4).
    /// Per-call overridable.
    public static let readTimeout: Duration = .seconds(30)

    /// The subject every `.decodeFailed` from this parser carries.
    private static let subject = "git diff --raw/--numstat"

    // MARK: - the command line

    /// The exact invocation for one base.
    ///
    /// The three `DiffRef.Base` cases (root spec §9.6) are mapped here and nowhere else:
    ///
    /// - `.workingTreeAgainstHEAD` → `git diff HEAD`, the whole of what is uncommitted, staged
    ///   or not.
    /// - `.commit(h)` → `git diff <h>`, the working tree against that commit.
    /// - `.commitAgainstParent(h)` → `git show --format= --first-parent <h>`, *not*
    ///   `git diff <h>^ <h>`. A **root commit** has no `<h>^`, so the parent form fails on the
    ///   first commit of every repository; `git show` lists that commit's whole tree as added
    ///   instead. `--format=` suppresses the commit header, leaving the file listing alone.
    ///
    ///   `--first-parent` is required rather than decorative, and is the one thing this mapping
    ///   adds to `git show`'s defaults (D41). Measured on `git` 2.55.0, a **merge** commit's
    ///   default listing is git's *combined* diff, whose status field carries one letter per
    ///   parent (`MM`) — a code the parser rejects — and which is not the question a panel is
    ///   asking. `--first-parent` produces the ordinary shape and answers what the branch this
    ///   merge landed on gained by it.
    ///
    ///   `--root` is required for the same class of reason and is the R4 wave's pin (D45).
    ///   `log.showRoot=false` — a setting a user may hold for their own `git log -p` — makes this
    ///   `git show` print *nothing* for a root commit, so `changes` returns "no changed files" for
    ///   a non-empty initial tree: a silent wrong answer rather than a failure. `--root` pins the
    ///   default and changes nothing under it.
    ///
    /// `-z` because without it git C-quotes any path containing a space, a quote, a backslash or
    /// a non-ASCII byte, and this parser would have to reimplement git's quoting rules to be
    /// correct on an ordinary macOS path (D7). `--find-renames` explicitly, because the fixture
    /// environment disables the user's configuration and a repository that set `diff.renames`
    /// off would otherwise report every rename as a delete and an add.
    ///
    /// **The R5 pins (D47, D48).** Two more settings measured on `git` 2.55.0 to change these
    /// bytes, both invisible to R4 because its fixtures were too plain to exhibit them:
    ///
    /// - `log.showSignature=true` makes `git show` print its signature verdict on stdout ahead of
    ///   the listing whenever the commit is **signed** — a line the raw parser reads as a record
    ///   and rejects with `.decodeFailed`. `--no-show-signature` pins the default and is a no-op
    ///   under it. It is passed only on the `show` form: the setting is a `log`/`show` one, and
    ///   `git diff` never consults it.
    /// - `diff.renameLimit`, set low, makes git skip the *inexact* half of rename detection, so a
    ///   rename that also edited the file comes back as a delete and an add — the same two rows for
    ///   one change that `--find-renames` exists to prevent, reached by the other door. R4 ruled the
    ///   setting out on a fixture whose only rename was **exact**, and exact renames are paired
    ///   before the limit applies. `-l<limit>` pins git's own documented default.
    ///
    /// **The wave-2 pin.** `diff.ignoreSubmodules=all` — a setting users hold precisely because a
    /// dirty submodule is noisy — makes a submodule-only change print *nothing at all*, in both
    /// sections at once, so the parse agrees on "no changed files" and the panel shows a clean tree
    /// over a real change. `--ignore-submodules=none` pins git's own default and is a no-op under
    /// it. The same pin is on `WorkingTreeStatus`'s command line, for the same setting.
    ///
    /// **`--end-of-options` before the revision.** `DiffRef.Base` carries a `String` that reaches
    /// this module from a rendered row, exactly as `workingTreeFile`'s path does, and until it was
    /// pinned here a base spelled like an option — `--output=<path>` — was appended to the command
    /// line and *executed as one*: git exited 0 and wrote the diff to a file of the caller's
    /// choosing. `--end-of-options` is git's own answer to that (2.24 and later), and it is the
    /// second half of the fix rather than the whole of it: the base is resolved to an object name
    /// first (`resolvedBase`), so this line is what holds when a future spelling slips past.
    static func arguments(for base: DiffRef.Base) -> [String] {
        // `--raw` before `--numstat` only for readability: git prints the raw section first
        // whichever order they are given in, and the parser reads sections rather than positions.
        let tail = ["--raw", "--numstat", "-z", "--find-renames", "-l\(renameLimit)",
                    "--ignore-submodules=none", "--end-of-options"]
        switch base {
        case .workingTreeAgainstHEAD:
            return ["diff"] + tail + ["HEAD"]
        case .commit(let hash):
            return ["diff"] + tail + [hash]
        case .commitAgainstParent(let hash):
            return ["show", "--format=", "--first-parent", "--root", "--no-show-signature"]
                + tail + [hash]
        }
    }

    /// git's own documented default for `diff.renameLimit`: the number of paths past which the
    /// exhaustive, inexact half of rename detection is skipped.
    ///
    /// Pinned rather than lifted (`-l0`, unlimited) deliberately. A user who lowered the limit did
    /// it for speed on a large repository, and the panel's answer should be git's default answer,
    /// not a slower one no configuration would ever have produced.
    static let renameLimit = 1000

    // MARK: - the changed-file list

    /// Every path `base` changed, in the order git printed them.
    ///
    /// `root` is resolved through `GitCommands.repositoryRoot` first, so a channel whose directory
    /// is a **subdirectory** of the repository is read at the repository root: git prints
    /// root-relative paths whatever directory it runs in, so a listing taken from a subdirectory
    /// and a `root` that is that subdirectory cannot be recombined into a readable path (D13, and
    /// the wave-2 decision below it). A directory in no repository is `.notARepository` rather than
    /// a generic command failure.
    ///
    /// Only exit 0 is accepted; anything else becomes `.commandFailed`, a value the panel renders
    /// in its own area rather than an exception crossing into the conversation (§10, D3).
    public static func changes(root: URL, base: DiffRef.Base, environment: [String: String],
                               runner: any ToolRunning,
                               timeout: Duration = readTimeout) async throws -> [FileChange] {
        let root = try await GitCommands.repositoryRoot(cwd: root, environment: environment,
                                                        runner: runner, timeout: timeout)
        let resolved = try await resolvedBase(base, root: root, environment: environment,
                                              runner: runner, timeout: timeout)
        let base = try await resolvingAnUnbornHead(resolved, root: root, environment: environment,
                                                   runner: runner, timeout: timeout)
        return try parse(await read(root: root, base: base, environment: environment,
                                    runner: runner, timeout: timeout))
    }

    /// The base's commit, resolved to a full object name **before** any diff command is built.
    ///
    /// `DiffRef.Base` carries a `String` the panel composed, and this module appended it to a git
    /// command line unchecked: a base spelled `--output=<path>` was read by git as the option of
    /// that name, so a diff a panel merely *listed* wrote a file wherever the caller pointed it and
    /// exited 0. Two answers, and both are needed. Here: a base beginning with `-` is refused
    /// before a command runs, and anything that is not already a full object name is put through
    /// `rev-parse --verify --end-of-options <base>^{commit}`, whose answer — an object name, or
    /// nothing — is what the diff is asked for. On the command line: `--end-of-options` ahead of
    /// the revision, so that no spelling can be parsed as an option even if it reaches it.
    ///
    /// `^{commit}` rather than a bare verify, for the reason `resolvingAnUnbornHead` uses it: the
    /// two bases here name a *commit*, and a tag or a tree that cannot be one is refused for what
    /// it is rather than mis-diffed. `.workingTreeAgainstHEAD` carries no caller byte at all and is
    /// returned untouched, and this runs **before** the unborn-HEAD substitution, whose replacement
    /// is git's own empty-tree object name and is not a commit.
    private static func resolvedBase(_ base: DiffRef.Base, root: URL,
                                     environment: [String: String], runner: any ToolRunning,
                                     timeout: Duration) async throws -> DiffRef.Base {
        switch base {
        case .workingTreeAgainstHEAD:
            return base
        case .commit(let hash):
            return .commit(try await resolvedCommit(hash, root: root, environment: environment,
                                                    runner: runner, timeout: timeout))
        case .commitAgainstParent(let hash):
            return .commitAgainstParent(try await resolvedCommit(hash, root: root,
                                                                 environment: environment,
                                                                 runner: runner, timeout: timeout))
        }
    }

    /// One base revision as a full object name, or a refusal. Runs no command for a revision that
    /// is already one.
    private static func resolvedCommit(_ rev: String, root: URL, environment: [String: String],
                                       runner: any ToolRunning,
                                       timeout: Duration) async throws -> String {
        guard !rev.isEmpty, !rev.hasPrefix("-") else {
            throw fail("a diff base that is empty or begins with a dash cannot name a commit")
        }
        if isFullObjectName(rev) { return rev }
        let resolved = try await runner.run(.git,
                                            arguments: ["rev-parse", "--verify", "--quiet",
                                                        "--end-of-options", "\(rev)^{commit}"],
                                            cwd: root, environment: environment, timeout: timeout)
        try resolved.requireCompleted(tool: .git, timeout: timeout)
        guard resolved.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: resolved.exitCode,
                                          stderrTail: resolved.stderrTail)
        }
        let name = resolved.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFullObjectName(name) else {
            throw fail("rev-parse did not resolve the diff base to an object name")
        }
        return name
    }

    /// `.workingTreeAgainstHEAD` in a repository that has **no first commit**, compared against
    /// git's empty tree instead of against `HEAD` (R6/F2).
    ///
    /// In a freshly initialised repository `HEAD` names a branch that holds no commit, so it
    /// resolves to no object and `git diff HEAD` exits 128 — while the staged files are additions
    /// and there is nothing ambiguous about them. `WorkingTreeStatus` already reads this state and
    /// reports it (`headOID` nil), so leaving it failing here means two readers of one repository
    /// disagreeing about whether it can be read at all.
    ///
    /// Resolved **before** the listing runs rather than by retrying a failure, so that the base is
    /// fixed before the snapshot is taken. The cost is one `rev-parse` per call on this base and
    /// nothing on the other two.
    ///
    /// The empty tree's object name is **asked of git** rather than written down. The familiar
    /// `4b825dc…` is the SHA-1 one, and a repository initialised with `--object-format=sha256` has
    /// a different one; a hard-coded constant would exit 128 there, which is the defect being fixed.
    private static func resolvingAnUnbornHead(_ base: DiffRef.Base, root: URL,
                                              environment: [String: String], runner: any ToolRunning,
                                              timeout: Duration) async throws -> DiffRef.Base {
        guard case .workingTreeAgainstHEAD = base else { return base }
        // `--verify --quiet` so that an unresolvable HEAD is a bare non-zero exit rather than a
        // diagnostic; `^{commit}` so that a HEAD pointing at a branch with no commit is refused
        // for the reason it is unusable here.
        let head = try await runner.run(.git, arguments: ["rev-parse", "--verify", "--quiet",
                                                          "HEAD^{commit}"],
                                        cwd: root, environment: environment, timeout: timeout)
        // Before the unborn guard, not after it: a killed `rev-parse` exits non-zero, and this
        // guard reads a non-zero exit as "HEAD is unborn" — so an unread timeout would not fail
        // here, it would silently diff a repository with a history against the empty tree.
        try head.requireCompleted(tool: .git, timeout: timeout)
        guard head.exitCode != 0 else { return base }
        return .commit(try await emptyTreeObjectName(root: root, environment: environment,
                                                     runner: runner, timeout: timeout))
    }

    /// The object name of the empty tree in this repository's own hash algorithm.
    ///
    /// `hash-object` without `-w` computes and prints; it writes nothing into the object database,
    /// which matters because a read of a repository must stay a read.
    private static func emptyTreeObjectName(root: URL, environment: [String: String],
                                            runner: any ToolRunning,
                                            timeout: Duration) async throws -> String {
        let output = try await runner.run(.git, arguments: ["hash-object", "-t", "tree", "/dev/null"],
                                          cwd: root, environment: environment, timeout: timeout)
        try output.requireCompleted(tool: .git, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        let name = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw fail("git named no empty tree object") }
        return name
    }

    private static func read(root: URL, base: DiffRef.Base,
                             environment: [String: String], runner: any ToolRunning,
                             timeout: Duration) async throws -> Data {
        let output = try await runner.run(.git, arguments: arguments(for: base),
                                          cwd: root, environment: environment, timeout: timeout)
        try output.requireCompleted(tool: .git, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return output.stdout
    }

    // MARK: - parsing

    /// One record of the `--raw` section: what changed, and the modes that say what the path is.
    struct RawRecord: Hashable, Sendable {
        var path: String
        var status: FileChange.Status
        /// `100644`, `120000`, `160000`, or `000000` for a side that does not exist.
        var sourceMode: String
        var destinationMode: String

        /// The mode that describes what the path *is* after the change, falling back to the source
        /// mode for a deletion, where there is no destination.
        var kind: FileChange.Kind {
            switch destinationMode == "000000" ? sourceMode : destinationMode {
            case "160000": .gitlink
            case "120000": .symlink
            default: .file
            }
        }
    }

    /// Decodes one `--raw --numstat -z` output into the changed-file list.
    ///
    /// **Measured on `git` 2.55.0**, NULs shown as `^@`, for a modification, a type change, an
    /// inexact rename and an addition:
    ///
    ///     :100644 100644 eaf36c1 2379b8e M^@b.bin^@:120000 100644 3fe175b 05c1e3e T^@link^@
    ///     :100644 100644 7a28df3 aba7e16 R082^@carried.txt^@moved.txt^@
    ///     :000000 100644 0000000 3e75765 A^@n.txt^@
    ///     -\t-\tb.bin^@1\t1\tlink^@1\t0\t^@carried.txt^@moved.txt^@1\t0\tn.txt^@
    ///
    /// The whole raw section comes first and the whole numstat section follows, from one traversal
    /// of one snapshot. The boundary is read from the records themselves rather than counted: a raw
    /// record's first field always begins with `:` — it is the metadata field, `:<src mode> <dst
    /// mode> <src oid> <dst oid> <status>` — and a numstat record's never does, since it begins
    /// with a count or a `-`. The object ids are *abbreviated* here and are deliberately unread:
    /// the modes are the only part this module needs, and an abbreviation's length depends on the
    /// repository's hash algorithm and object count.
    ///
    /// The two sections are joined by path, strictly (D31): a path in one and not the other is an
    /// inconsistency inside a single snapshot and is reported rather than papered over.
    public static func parse(_ bytes: Data) throws -> [FileChange] {
        let fields = split(bytes)
        var index = 0
        let raw = try parseRaw(fields, from: &index)
        let counts = try parseNumstat(fields, from: &index)
        return try join(raw: raw, numstat: counts)
    }

    /// Decodes the `--raw` section, stopping at the first field that is not a raw record.
    ///
    /// A record is `:<modes and object names> <status>\0<path>\0`, and for a rename or a copy
    /// `…R<score>\0<old>\0<new>\0` — **two** path fields, the original first. A status letter this
    /// switch does not name throws rather than being skipped: a parser that dropped the record a
    /// test exists to compare would make that test unfalsifiable (§17.7). `U` is not among them
    /// deliberately — measured on the same git, a tree with an unresolved merge conflict reports
    /// the conflicted path as an ordinary `M` under `git diff HEAD`, never as `U`.
    static func parseRaw(_ fields: [String], from index: inout Int) throws -> [RawRecord] {
        var result: [RawRecord] = []
        while index < fields.count, fields[index].hasPrefix(":") {
            let metadata = fields[index].dropFirst().split(separator: " ",
                                                           omittingEmptySubsequences: false)
            index += 1
            guard metadata.count == 5 else {
                throw fail("a raw record's metadata field did not carry two modes, two object "
                           + "names and a status")
            }
            let code = String(metadata[4])
            guard let letter = code.first else {
                throw fail("a raw record carried an empty status field")
            }
            func nextPath(_ what: String) throws -> String {
                guard index < fields.count, !fields[index].isEmpty else {
                    throw fail("a raw record had no \(what) after its status field")
                }
                defer { index += 1 }
                return fields[index]
            }
            func record(_ path: String, _ status: FileChange.Status) -> RawRecord {
                RawRecord(path: path, status: status,
                          sourceMode: String(metadata[0]), destinationMode: String(metadata[1]))
            }
            switch letter {
            case "A", "M", "D", "T":
                guard code.count == 1 else {
                    throw fail("a raw record carried a score on a status that has none")
                }
                let status: FileChange.Status = switch letter {
                case "A": .added
                case "M": .modified
                case "D": .deleted
                default: .typeChanged
                }
                result.append(record(try nextPath("path"), status))
            case "R", "C":
                guard let score = Int(code.dropFirst()), score >= 0 else {
                    throw fail("a rename or copy record's similarity score is not a number")
                }
                let original = try nextPath("original path")
                let path = try nextPath("new path")
                result.append(record(path, letter == "R" ? .renamed(from: original, score: score)
                                                         : .copied(from: original, score: score)))
            default:
                throw fail("a raw record carried a status letter this format does not define")
            }
        }
        return result
    }

    /// Decodes the `--numstat` section into `(path, additions, deletions)`.
    ///
    /// A record is `<adds>\t<dels>\t<path>`, and for a rename or a copy the path field is
    /// **empty** and two path fields follow, the original first — the fact a parser reading one
    /// path per record silently mis-joins on. `-` for both counts is how a binary file is
    /// reported, and is where `FileChange.isBinary` comes from. A rename is returned under its
    /// **new** path, so that the join with the raw section has one key per change.
    static func parseNumstat(_ fields: [String],
                             from index: inout Int) throws -> [(String, Int?, Int?)] {
        var result: [(String, Int?, Int?)] = []
        while index < fields.count {
            let record = fields[index]
            index += 1
            // Exactly two splits, so a path containing a tab stays whole.
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                throw fail("a numstat record did not carry <additions> <deletions> <path>")
            }
            let additions = try count(parts[0])
            let deletions = try count(parts[1])
            var path = String(parts[2])
            if path.isEmpty {
                guard index + 1 < fields.count,
                      !fields[index].isEmpty, !fields[index + 1].isEmpty else {
                    throw fail("a numstat record with an empty path field was not followed by "
                               + "two paths")
                }
                path = fields[index + 1]
                index += 2
            }
            result.append((path, additions, deletions))
        }
        return result
    }

    /// Joins the two sections by path.
    ///
    /// A path in one section and not the other is reported rather than papered over: a change
    /// carrying no counts is exactly how a *binary* file is represented, so inventing one for a
    /// path numstat did not mention would make every such defect look like a legitimate binary.
    static func join(raw: [RawRecord], numstat: [(String, Int?, Int?)]) throws -> [FileChange] {
        var counts: [String: (Int?, Int?)] = [:]
        for (path, additions, deletions) in numstat { counts[path] = (additions, deletions) }
        guard counts.count == numstat.count else {
            throw fail("the numstat section named the same path twice")
        }
        let changes = try raw.map { record -> FileChange in
            guard let entry = counts.removeValue(forKey: record.path) else {
                throw fail("a path in the raw section is absent from the numstat section")
            }
            return FileChange(path: record.path, status: record.status,
                              additions: entry.0, deletions: entry.1,
                              isBinary: entry.0 == nil && entry.1 == nil,
                              kind: record.kind)
        }
        guard counts.isEmpty else {
            throw fail("\(counts.count) path(s) in the numstat section are absent from the "
                       + "raw section")
        }
        return changes
    }

    /// One numstat count: a number, or `-` for a binary file.
    private static func count(_ field: Substring) throws -> Int? {
        if field == "-" { return nil }
        guard let value = Int(field), value >= 0 else {
            throw fail("a numstat count was neither a number nor a dash")
        }
        return value
    }

    /// Splits on NUL and decodes each field as UTF-8.
    ///
    /// The split is over bytes rather than a `String`, because a path on macOS need not be valid
    /// UTF-8 and slicing after a lossy decode would slice the replacement characters. The final
    /// terminator leaves no empty tail: only a non-empty remainder is appended.
    static func split(_ bytes: Data) -> [String] {
        var fields: [String] = []
        var start = bytes.startIndex
        for position in bytes.indices where bytes[position] == 0 {
            fields.append(String(decoding: bytes[start..<position], as: UTF8.self))
            start = bytes.index(after: position)
        }
        if start < bytes.endIndex {
            fields.append(String(decoding: bytes[start..<bytes.endIndex], as: UTF8.self))
        }
        return fields
    }

    /// The message names the shape that was violated and never quotes the record: a path is a
    /// published byte the moment it reaches a rendered error (§6.3, §11).
    private static func fail(_ message: String) -> ToolError {
        .decodeFailed(subject: subject, message: message)
    }

    // MARK: - the two sides of a diff

    /// A full object name, which is the one revision spelling that needs no resolution: 40 hex
    /// characters for SHA-1, 64 for SHA-256.
    static func isFullObjectName(_ rev: String) -> Bool {
        (rev.count == 40 || rev.count == 64)
            && rev.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The bytes of `path` as of `rev`.
    ///
    /// `cat-file blob` rather than `git show <rev>:<path>`, because the former is the stored
    /// object and the latter can be rewritten by a `textconv` filter the repository configured —
    /// and what Monaco is handed must be the file, not a rendering of it. A revision that does
    /// not carry the path exits non-zero and becomes `.commandFailed`, never empty `Data` that a
    /// panel would draw as an empty file.
    ///
    /// **The object name is composed, not concatenated.** `<rev>:<path>` is parsed by git at the
    /// *first* colon, so a revision that itself contains one — `HEAD:Workbench`, which is the
    /// spelling for a subtree — makes git read everything after that colon as the path and answer
    /// about an object nobody asked for. A rev carrying a colon is therefore refused before any
    /// command runs; anything that is not already a full object name is resolved through
    /// `rev-parse --verify` and the *resolved* name is what the blob is asked for. A leading `-`
    /// is refused for the adjacent reason: it would be read as an option rather than a revision.
    public static func blob(root: URL, rev: String, path: String, environment: [String: String],
                            runner: any ToolRunning,
                            timeout: Duration = readTimeout) async throws -> Data {
        guard !rev.isEmpty, !rev.contains(":"), !rev.hasPrefix("-") else {
            throw fail("a revision carrying a colon or a leading dash cannot name a blob")
        }
        var name = rev
        if !isFullObjectName(rev) {
            let resolved = try await runner.run(.git,
                                                arguments: ["rev-parse", "--verify", "--quiet", rev],
                                                cwd: root, environment: environment, timeout: timeout)
            try resolved.requireCompleted(tool: .git, timeout: timeout)
            guard resolved.exitCode == 0 else {
                throw ToolError.commandFailed(tool: .git, exitCode: resolved.exitCode,
                                              stderrTail: resolved.stderrTail)
            }
            name = resolved.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isFullObjectName(name) else {
                throw fail("rev-parse did not resolve the revision to an object name")
            }
        }
        let output = try await runner.run(.git, arguments: ["cat-file", "blob", "\(name):\(path)"],
                                          cwd: root, environment: environment, timeout: timeout)
        try output.requireCompleted(tool: .git, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return output.stdout
    }

    /// The bytes of `path` as it stands in the working tree — the other side of every diff whose
    /// base is `.workingTreeAgainstHEAD` or `.commit`.
    ///
    /// `root` must be the **resolved** repository root (`GitCommands.repositoryRoot`), because
    /// `path` is repository-relative: git prints root-relative paths whatever directory it ran in.
    ///
    /// Read directly rather than through `git`, because the working tree is a file and git has
    /// nothing to add to reading one — with one exception this function exists to handle. For a
    /// **symbolic link** git stores the link's *destination text* as the blob, so `blob` returns
    /// `"a.txt"` while an ordinary read follows the link and returns the bytes of `a.txt`. The
    /// two sides of the diff would then be different kinds of thing: retargeting a link would
    /// draw as a whole-file rewrite, and a dangling link — a change git tracks perfectly well —
    /// would throw. So a link is detected with `lstat` and its destination returned, which is the
    /// same git object type `blob` returns for the other side (D42).
    ///
    /// **`path` is confined to the repository.** It is a public `String` and the caller that
    /// supplies it — a panel, ultimately a rendered diff row — is not a trusted source of file
    /// system paths: `../sibling/secret` appended to a root reads a file the repository does not
    /// contain. Two checks, because either alone is insufficient:
    ///
    /// - the path is rejected outright when it is absolute or carries a `..` component, which is
    ///   the lexical half and is what makes the refusal explainable;
    /// - the path's **parent chain is resolved** (`realpath`) and compared against the resolved
    ///   root, which is the half that catches a *symbolic link* in the ancestry — `lstat` on the
    ///   final component says nothing about the directories above it, so `a/link-elsewhere/x`
    ///   passes the lexical check and still leaves the repository. The final component is
    ///   deliberately *not* resolved: a link is what this function returns the destination of.
    ///
    /// Either refusal is `.pathOutsideRepository`, which is the module's own answer about the path
    /// it was handed rather than a `.decodeFailed` about output git never produced: this function
    /// runs no command at all.
    /// **The entry is opened once, and the descriptor is what everything else is asked of.** An
    /// `lstat` followed by a separate read is two questions about a name, and between them a local
    /// writer — the user's own editor, a build — can put something else there; and the read that
    /// followed was `Data(contentsOf:)`, which has no bound and no notion of what it is reading. So
    /// a tracked path replaced by a **FIFO** blocked the caller inside `open` for as long as no
    /// writer appeared, and a tracked file of any size was loaded whole, past the cap the process
    /// layer holds every `git` invocation to. One `open` with `O_NOFOLLOW | O_NONBLOCK` and an
    /// `fstat` on its descriptor answer all three: a link at the final component cannot be
    /// followed by the call that would have followed it, a FIFO returns rather than blocks, and
    /// what is read is a **regular file** of at most `limitBytes`.
    ///
    /// `limitBytes` defaults to the runner's own retained-output cap, because both sides of a diff
    /// end up in the same panel and a working-tree side that cannot be reached through `git` must
    /// not be the one that exhausts the app's memory (D53/b). Injectable so a test can reach it
    /// without writing 64 MiB.
    public static func workingTreeFile(root: URL, path: String,
                                       limitBytes: Int = ToolRunner.defaultOutputLimitBytes)
        throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw ToolError.pathOutsideRepository(
                reason: "a working-tree path must be repository-relative and carry no parent "
                        + "component")
        }
        let url = root.appending(path: path)
        let fileSystemPath = url.path(percentEncoded: false)
        guard let anchor = resolved(root.path(percentEncoded: false)),
              let parent = resolved(url.deletingLastPathComponent().path(percentEncoded: false)),
              parent == anchor || parent.hasPrefix(anchor + "/") else {
            throw ToolError.pathOutsideRepository(
                reason: "a working-tree path's parent chain does not resolve inside the repository")
        }
        // `O_NOFOLLOW` so a symbolic link at the final component is refused by the call that would
        // otherwise have followed it — there is no window between a check and a read for a writer
        // to swap one in. `O_NONBLOCK` so a FIFO is opened rather than waited on: without it this
        // call parks until a writer appears, which for a panel is forever. `O_CLOEXEC` so the
        // descriptor is not inherited by any `git` this app spawns while the read runs.
        let descriptor = open(fileSystemPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            // `ELOOP` is the one refusal this function answers instead: the final component is a
            // symbolic link, and a link's *destination text* is what git stores as its blob, so
            // that text is the side of the diff to return (D42).
            if errno == ELOOP { return try symbolicLinkDestination(fileSystemPath) }
            throw ToolError.unreadableWorkingTreeEntry(
                reason: "a working-tree path could not be opened for reading")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ToolError.unreadableWorkingTreeEntry(
                reason: "an opened working-tree entry could not be described")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ToolError.unreadableWorkingTreeEntry(
                reason: "a working-tree path names \(kind(of: info.st_mode)) rather than a "
                        + "regular file")
        }
        guard info.st_size <= limitBytes else {
            throw ToolError.outputLimitExceeded(tool: .git, limitBytes: limitBytes)
        }
        return try readAll(descriptor, limitBytes: limitBytes)
    }

    /// The destination text of the symbolic link at `fileSystemPath`.
    ///
    /// `readlink` rather than `destinationOfSymbolicLink`, which returns a `String`: a link's
    /// destination is a path, and a path on macOS need not be valid UTF-8 (the same reason the
    /// listing parser splits over bytes). `st_size` is the destination's length for a link; the
    /// buffer is one byte longer so that a full read is distinguishable from a truncated one, and
    /// `readlink` never terminates what it writes.
    private static func symbolicLinkDestination(_ fileSystemPath: String) throws -> Data {
        var info = stat()
        guard lstat(fileSystemPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else {
            throw ToolError.unreadableWorkingTreeEntry(
                reason: "a working-tree entry stopped being a symbolic link while it was read")
        }
        var buffer = [UInt8](repeating: 0, count: max(Int(info.st_size), 1) + 1)
        let written = buffer.withUnsafeMutableBytes { raw in
            readlink(fileSystemPath, raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count)
        }
        guard written >= 0, written < buffer.count else {
            throw fail("a symbolic link's destination could not be read")
        }
        return Data(buffer[0..<written])
    }

    /// Everything the descriptor holds, refused the moment it passes `limitBytes`.
    ///
    /// The size `fstat` reported is checked first and this is checked again, because a file can
    /// grow between the two — the bound has to hold on what is actually read, not on what was
    /// promised.
    private static func readAll(_ descriptor: Int32, limitBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let taken = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if taken == 0 { return result }
            if taken < 0 {
                if errno == EINTR { continue }
                throw ToolError.unreadableWorkingTreeEntry(
                    reason: "a working-tree file could not be read to its end")
            }
            result.append(contentsOf: buffer[0..<taken])
            guard result.count <= limitBytes else {
                throw ToolError.outputLimitExceeded(tool: .git, limitBytes: limitBytes)
            }
        }
    }

    /// What an entry is, in this module's own words. Named rather than numbered because this
    /// string is rendered, and named without the path for the same reason (§6.3, §11).
    private static func kind(of mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: "a directory"
        case S_IFIFO: "a named pipe"
        case S_IFSOCK: "a socket"
        case S_IFCHR, S_IFBLK: "a device"
        case S_IFLNK: "a symbolic link"
        default: "something that is not a file"
        }
    }

    /// `realpath(3)`: every symbolic link and `.`/`..` component resolved, or nil when the path
    /// does not exist. A parent directory that is not there is outside the repository as far as
    /// this check is concerned, and the read below would fail for its own reason anyway.
    private static func resolved(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}
