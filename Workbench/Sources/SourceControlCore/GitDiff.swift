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

    /// What the diff did to the path, as `git diff --name-status --find-renames` reports it.
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

    public init(path: String, status: Status, additions: Int?, deletions: Int?, isBinary: Bool) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

/// The changed-file list for a `DiffRef.Base`, and access to either side's bytes.
///
/// **Two invocations, not one.** Measured on `git` 2.55.0: `--name-status` and `--numstat` given
/// to the same command do not both print — the last one wins and no section of the other appears
/// at all. So the status and rename information come from one `-z --name-status --find-renames`
/// call, the line counts from one `-z --numstat --find-renames` call, and the two are joined by
/// path. `GitDiffTests.testNameStatusAndNumstatGivenTogetherDoNotBothPrint` pins that fact
/// against the machine's own `git`, so a future git whose bytes differ fails a named test rather
/// than mis-joining here.
public enum GitDiff {

    /// A read of the object database and the working tree, so it is bounded by disk rather than
    /// by network; 30 s is the same budget the other readers take, for the same reason (D4).
    /// Per-call overridable.
    public static let readTimeout: Duration = .seconds(30)

    /// The subject every `.decodeFailed` from this parser carries.
    private static let subject = "git diff --name-status/--numstat"

    // MARK: - the command lines

    /// The exact invocation for one base and one listing.
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
    ///   default listing is unusable here in two different ways: for an ordinary merge
    ///   `--name-status` prints nothing at all while `--numstat` prints a record per path, so the
    ///   join below sees two listings that disagree completely; and for a merge whose tree
    ///   differs from both parents — a resolved conflict — the default is git's *combined* diff,
    ///   whose status field carries one letter per parent (`MM`), which the name-status parser
    ///   rejects. `--first-parent` produces the same shape in both listings, never a combined
    ///   status code, and answers the question a panel is asking: what the branch this merge
    ///   landed on gained by it.
    ///
    ///   `--root` is required for the same class of reason and is the R4 wave's pin (D45).
    ///   `log.showRoot=false` — a setting a user may hold for their own `git log -p` — makes this
    ///   `git show` print *nothing* for a root commit in **both** listings. The two agree, the join
    ///   succeeds, and `changes` returns "no changed files" for a non-empty initial tree: a silent
    ///   wrong answer rather than a failure. `--root` pins the default and changes nothing under it.
    ///
    /// `-z` because without it git C-quotes any path containing a space, a quote, a backslash or
    /// a non-ASCII byte, and this parser would have to reimplement git's quoting rules to be
    /// correct on an ordinary macOS path (D7). `--find-renames` explicitly, because the fixture
    /// environment disables the user's configuration and a repository that set `diff.renames`
    /// off would otherwise report every rename as a delete and an add.
    static func arguments(for base: DiffRef.Base, listing: String) -> [String] {
        let tail = [listing, "-z", "--find-renames"]
        switch base {
        case .workingTreeAgainstHEAD:
            return ["diff"] + tail + ["HEAD"]
        case .commit(let hash):
            return ["diff"] + tail + [hash]
        case .commitAgainstParent(let hash):
            return ["show", "--format=", "--first-parent", "--root"] + tail + [hash]
        }
    }

    // MARK: - the changed-file list

    /// Every path `base` changed, in the order git printed them.
    ///
    /// Only exit 0 is accepted; anything else becomes `.commandFailed`, a value the panel renders
    /// in its own area rather than an exception crossing into the conversation (§10, D3).
    public static func changes(root: URL, base: DiffRef.Base, environment: [String: String],
                               runner: any ToolRunning,
                               timeout: Duration = readTimeout) async throws -> [FileChange] {
        let statuses = try parseNameStatus(
            await read(root: root, base: base, listing: "--name-status",
                       environment: environment, runner: runner, timeout: timeout))
        let counts = try parseNumstat(
            await read(root: root, base: base, listing: "--numstat",
                       environment: environment, runner: runner, timeout: timeout))
        return try join(nameStatus: statuses, numstat: counts)
    }

    private static func read(root: URL, base: DiffRef.Base, listing: String,
                             environment: [String: String], runner: any ToolRunning,
                             timeout: Duration) async throws -> Data {
        let output = try await runner.run(.git, arguments: arguments(for: base, listing: listing),
                                          cwd: root, environment: environment, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return output.stdout
    }

    /// Joins the two listings by path.
    ///
    /// A path in one listing and not the other is an inconsistency between two reads of the same
    /// repository and is reported rather than papered over: a change carrying no counts is
    /// exactly how a *binary* file is represented, so inventing one for a path numstat did not
    /// mention would make every such defect look like a legitimate binary.
    static func join(nameStatus: [(String, FileChange.Status)],
                     numstat: [(String, Int?, Int?)]) throws -> [FileChange] {
        var counts: [String: (Int?, Int?)] = [:]
        for (path, additions, deletions) in numstat { counts[path] = (additions, deletions) }
        guard counts.count == numstat.count else {
            throw fail("the numstat listing named the same path twice")
        }
        let changes = try nameStatus.map { path, status -> FileChange in
            guard let entry = counts.removeValue(forKey: path) else {
                throw fail("a path in the name-status listing is absent from the numstat listing")
            }
            return FileChange(path: path, status: status,
                              additions: entry.0, deletions: entry.1,
                              isBinary: entry.0 == nil && entry.1 == nil)
        }
        guard counts.isEmpty else {
            throw fail("\(counts.count) path(s) in the numstat listing are absent from the "
                       + "name-status listing")
        }
        return changes
    }

    // MARK: - parsing

    /// Decodes `--name-status -z`.
    ///
    /// **Measured on `git` 2.55.0**, NULs shown as `^@`:
    ///
    ///     M^@a.txt^@R100^@r.txt^@moved.txt^@A^@n.txt^@
    ///
    /// A record is `<status>\0<path>\0`, and for a rename or a copy `R<score>\0<old>\0<new>\0` —
    /// **two** path fields, the original first. A status letter this switch does not name throws
    /// rather than being skipped: a parser that dropped the record a test exists to compare would
    /// make that test unfalsifiable (§17.7). `U` is not among them deliberately — measured on the
    /// same git, a tree with an unresolved merge conflict reports the conflicted path as an
    /// ordinary `M` under `git diff HEAD`, never as `U`.
    public static func parseNameStatus(_ bytes: Data) throws -> [(String, FileChange.Status)] {
        let fields = split(bytes)
        var result: [(String, FileChange.Status)] = []
        var index = 0
        while index < fields.count {
            let code = fields[index]
            index += 1
            guard let letter = code.first else {
                throw fail("a name-status record carried an empty status field")
            }
            func nextPath(_ what: String) throws -> String {
                guard index < fields.count, !fields[index].isEmpty else {
                    throw fail("a name-status record had no \(what) after its status field")
                }
                defer { index += 1 }
                return fields[index]
            }
            switch letter {
            case "A", "M", "D", "T":
                guard code.count == 1 else {
                    throw fail("a name-status record carried a score on a status that has none")
                }
                let status: FileChange.Status = switch letter {
                case "A": .added
                case "M": .modified
                case "D": .deleted
                default: .typeChanged
                }
                result.append((try nextPath("path"), status))
            case "R", "C":
                guard let score = Int(code.dropFirst()), score >= 0 else {
                    throw fail("a rename or copy record's similarity score is not a number")
                }
                let original = try nextPath("original path")
                let path = try nextPath("new path")
                result.append((path, letter == "R" ? .renamed(from: original, score: score)
                                                   : .copied(from: original, score: score)))
            default:
                throw fail("a name-status record carried a status letter this format does not define")
            }
        }
        return result
    }

    /// Decodes `--numstat -z` into `(path, additions, deletions)`.
    ///
    /// **Measured on `git` 2.55.0**, NULs shown as `^@`:
    ///
    ///     1	0	a.txt^@-	-	b.bin^@0	0	^@r.txt^@moved.txt^@
    ///
    /// A record is `<adds>\t<dels>\t<path>`, and for a rename or a copy the path field is
    /// **empty** and two path fields follow, the original first — the fact a parser reading one
    /// path per record silently mis-joins on. `-` for both counts is how a binary file is
    /// reported, and is where `FileChange.isBinary` comes from. A rename is returned under its
    /// **new** path, so that the join with the name-status listing has one key per change.
    public static func parseNumstat(_ bytes: Data) throws -> [(String, Int?, Int?)] {
        let fields = split(bytes)
        var result: [(String, Int?, Int?)] = []
        var index = 0
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
    private static func split(_ bytes: Data) -> [String] {
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

    /// The bytes of `path` as of `rev`.
    ///
    /// `cat-file blob` rather than `git show <rev>:<path>`, because the former is the stored
    /// object and the latter can be rewritten by a `textconv` filter the repository configured —
    /// and what Monaco is handed must be the file, not a rendering of it. A revision that does
    /// not carry the path exits non-zero and becomes `.commandFailed`, never empty `Data` that a
    /// panel would draw as an empty file.
    public static func blob(root: URL, rev: String, path: String, environment: [String: String],
                            runner: any ToolRunning,
                            timeout: Duration = readTimeout) async throws -> Data {
        let output = try await runner.run(.git, arguments: ["cat-file", "blob", "\(rev):\(path)"],
                                          cwd: root, environment: environment, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return output.stdout
    }

    /// The bytes of `path` as it stands in the working tree — the other side of every diff whose
    /// base is `.workingTreeAgainstHEAD` or `.commit`.
    ///
    /// Read directly rather than through `git`, because the working tree is a file and git has
    /// nothing to add to reading one — with one exception this function exists to handle. For a
    /// **symbolic link** git stores the link's *destination text* as the blob, so `blob` returns
    /// `"a.txt"` while an ordinary read follows the link and returns the bytes of `a.txt`. The
    /// two sides of the diff would then be different kinds of thing: retargeting a link would
    /// draw as a whole-file rewrite, and a dangling link — a change git tracks perfectly well —
    /// would throw. So a link is detected with `lstat` and its destination returned, which is the
    /// same git object type `blob` returns for the other side (D42).
    public static func workingTreeFile(root: URL, path: String) throws -> Data {
        let url = root.appending(path: path)
        let fileSystemPath = url.path(percentEncoded: false)
        var info = stat()
        guard lstat(fileSystemPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else {
            return try Data(contentsOf: url)
        }
        // `readlink` rather than `destinationOfSymbolicLink`, which returns a `String`: a link's
        // destination is a path, and a path on macOS need not be valid UTF-8 (the same reason the
        // listing parser splits over bytes). `st_size` is the destination's length for a link;
        // the buffer is one byte longer so that a full read is distinguishable from a truncated
        // one, and `readlink` never terminates what it writes.
        var buffer = [UInt8](repeating: 0, count: max(Int(info.st_size), 1) + 1)
        let written = buffer.withUnsafeMutableBytes { raw in
            readlink(fileSystemPath, raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count)
        }
        guard written >= 0, written < buffer.count else {
            throw fail("a symbolic link's destination could not be read")
        }
        return Data(buffer[0..<written])
    }
}
