import Foundation

/// What the working tree currently differs by, as `git status --porcelain=v2 --branch -z`
/// reports it.
///
/// One value, parsed from one invocation: the branch headers and the per-path entries arrive
/// together, so reading them apart would be two invocations that could disagree with each other
/// about the same instant.
public struct WorkingTreeStatus: Hashable, Sendable {

    /// One path the status has something to say about.
    ///
    /// Porcelain v2 reports two independent statuses per path — `X`, what the index differs from
    /// `HEAD` by, and `Y`, what the working tree differs from the index by — and `.` for
    /// "unchanged" on either side. That is carried here as two optionals rather than one status,
    /// because a file can be staged as added *and* modified again since, and a panel that showed
    /// only one of the two would be lying about what a commit would capture.
    public struct Entry: Hashable, Sendable {

        /// One side's change. `renamed` and `copied` carry the path git found the content at
        /// before, which arrives as its own field and is the reason this enum has payloads at all.
        public enum Change: Hashable, Sendable {
            case added
            case modified
            case deleted
            case renamed(from: String)
            case copied(from: String)
            case typeChanged
            /// Untracked and ignored are working-tree-only conditions: they have no index side,
            /// so they never appear in `staged`.
            case untracked
            case ignored
            /// A path with an unresolved merge conflict. Porcelain v2 gives it a record of its
            /// own whose `XY` are the two sides of the conflict rather than an index/worktree
            /// pair, so both sides of the entry carry this and neither claims more than it knows.
            case unmerged
        }

        /// Repository-relative, and raw bytes decoded as UTF-8 — never git's C-quoted form, which
        /// is what `-z` buys (ledger D7).
        public var path: String
        /// The index side (`X`), nil when the index matches `HEAD`.
        public var staged: Change?
        /// The working-tree side (`Y`), nil when the working tree matches the index.
        public var worktree: Change?

        public init(path: String, staged: Change? = nil, worktree: Change? = nil) {
            self.path = path
            self.staged = staged
            self.worktree = worktree
        }
    }

    /// The checked-out branch, nil when `HEAD` is detached.
    public var branch: String?
    /// `HEAD`'s object name, nil in a repository with no commit yet.
    public var headOID: String?
    /// The upstream's name as git prints it (`origin/main`), nil when the branch tracks nothing.
    public var upstream: String?
    /// Commits the branch has that its upstream does not, nil when there is no upstream.
    public var ahead: Int?
    /// Commits the upstream has that the branch does not, nil when there is no upstream.
    public var behind: Int?
    /// Every path the status reported, in the order git printed them.
    public var entries: [Entry]

    /// True when git reported nothing to say about any path.
    ///
    /// Ignored files are only ever present when a caller asked for them (`includeIgnored`), so a
    /// tree carrying nothing but ignored files is clean under the default read — which is what the
    /// working-tree row of the commit graph means by dirty (ledger D6).
    public var isClean: Bool { entries.isEmpty }

    public init(branch: String? = nil, headOID: String? = nil, upstream: String? = nil,
                ahead: Int? = nil, behind: Int? = nil, entries: [Entry] = []) {
        self.branch = branch
        self.headOID = headOID
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
    }
}

// MARK: - running the command

extension WorkingTreeStatus {

    /// A read of the index and the working tree, so it is bounded by disk rather than by network;
    /// 30 s is long enough for a cold, very large repository and short enough that a panel does
    /// not sit on a hung `git` forever (ledger D4). Per-call overridable.
    public static let readTimeout: Duration = .seconds(30)

    /// The exact invocation.
    ///
    /// `--porcelain=v2` for the documented machine format, `--branch` for the four headers, and
    /// `-z` because without it git C-quotes any path containing a space, a quote, a backslash or
    /// a non-ASCII byte and this parser would have to reimplement git's quoting rules to be
    /// correct on an ordinary macOS path (ledger D7).
    ///
    /// **The two configuration pins (D45).** Production runs the user's own configuration (X11)
    /// while the fixtures disable it (D14), so a setting that changes these bytes is invisible to
    /// the suite unless it is pinned here. Measured on `git` 2.55.0:
    ///
    /// - `status.showUntrackedFiles=no` removes every untracked path from the porcelain, so a
    ///   dirty tree reports itself clean and the commit graph loses its working-tree row (D6).
    ///   `--untracked-files=normal` pins the default, and also normalises the `all` value, which
    ///   would otherwise expand an untracked directory into one entry per file.
    /// - `status.renames=false` (and `diff.renames=false`, which porcelain v2 also reads) reports a
    ///   staged rename as a delete and an add, so `Entry.Change.renamed(from:)` never occurs and a
    ///   panel draws two rows for one change. `--find-renames` pins detection at git's own default
    ///   threshold and changes nothing under the default configuration.
    public static func arguments(includeIgnored: Bool = false) -> [String] {
        var arguments = ["status", "--porcelain=v2", "--branch", "-z",
                         "--untracked-files=normal", "--find-renames"]
        if includeIgnored { arguments.append("--ignored") }
        return arguments
    }

    /// Runs `git status` at `root` and parses it.
    ///
    /// Only exit 0 is accepted; anything else becomes `.commandFailed`, a value the panel renders
    /// in its own area rather than an exception crossing into the conversation (§10, D3).
    public static func read(root: URL, environment: [String: String], runner: any ToolRunning,
                            includeIgnored: Bool = false,
                            timeout: Duration = readTimeout) async throws -> WorkingTreeStatus {
        let output = try await runner.run(.git, arguments: arguments(includeIgnored: includeIgnored),
                                          cwd: root, environment: environment, timeout: timeout)
        guard output.exitCode == 0 else {
            throw ToolError.commandFailed(tool: .git, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return try parse(output.stdout)
    }
}

// MARK: - parsing

extension WorkingTreeStatus {

    /// The subject name every `.decodeFailed` from this parser carries.
    private static let subject = "git status --porcelain=v2"

    /// Parses the raw bytes of `git status --porcelain=v2 --branch -z`.
    ///
    /// **The measured format**, `git` 2.55.0, 2026-09-07 and re-measured 2026-09-08. Records are
    /// NUL-terminated; a record's kind is its first token:
    ///
    /// - `# branch.oid <oid>` — the literal `(initial)` before the first commit.
    /// - `# branch.head <name>` — the literal `(detached)` when `HEAD` is detached.
    /// - `# branch.upstream <name>`, `# branch.ab +<n> -<n>`.
    /// - `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — an ordinary change.
    /// - `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` — a rename or a copy, whose
    ///   **original path follows as its own NUL-terminated field**. New path first, original
    ///   second: that order is the measured fact, and reading it the other way round produces a
    ///   plausible wrong answer on every rename.
    /// - `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` — unmerged, three fields wider
    ///   than an ordinary entry.
    /// - `? <path>` untracked, `! <path>` ignored.
    ///
    /// A path may contain spaces, so each record is split with a fixed maximum number of splits
    /// and everything after the last fixed field is the path.
    ///
    /// Anything that does not have one of those shapes throws `.decodeFailed` and is never
    /// skipped: a parser that dropped the record a test exists to compare would make that test
    /// unfalsifiable, which is the failure mode §17.7 names.
    public static func parse(_ bytes: Data) throws -> WorkingTreeStatus {
        let records = split(bytes).map { String(decoding: $0, as: UTF8.self) }
        var status = WorkingTreeStatus()
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            // The output ends with a terminator, so the final split yields an empty tail. No
            // record git prints is empty, and a rename's second field is consumed below rather
            // than dispatched here, so an empty one is never meaningful.
            if record.isEmpty { continue }

            switch record.first {
            case "#":
                try readHeader(record, into: &status)
            case "1":
                status.entries.append(try ordinaryEntry(record))
            case "2":
                guard index < records.count else {
                    throw fail("a rename or copy record had no original-path field after it")
                }
                let original = records[index]
                index += 1
                guard !original.isEmpty else {
                    throw fail("a rename or copy record's original-path field was empty")
                }
                status.entries.append(try renameEntry(record, originalPath: original))
            case "u":
                status.entries.append(try unmergedEntry(record))
            case "?":
                status.entries.append(.init(path: try path(after: "? ", in: record),
                                            worktree: .untracked))
            case "!":
                status.entries.append(.init(path: try path(after: "! ", in: record),
                                            worktree: .ignored))
            default:
                throw fail("a record began with a token this format does not define")
            }
        }
        return status
    }

    private static func fail(_ message: String) -> ToolError {
        // The message names the shape that was violated and never quotes the record: a path is a
        // published byte the moment it reaches a rendered error (§6.3, §11).
        .decodeFailed(subject: subject, message: message)
    }

    /// Splits on NUL. Bytes rather than a `String` split, because a path on macOS need not be
    /// valid UTF-8 and slicing after a lossy decode would slice the replacement characters.
    private static func split(_ bytes: Data) -> [Data] {
        var records: [Data] = []
        var start = bytes.startIndex
        for position in bytes.indices where bytes[position] == 0 {
            records.append(bytes[start..<position])
            start = bytes.index(after: position)
        }
        if start < bytes.endIndex { records.append(bytes[start..<bytes.endIndex]) }
        return records
    }

    private static func path(after prefix: String, in record: String) throws -> String {
        guard record.hasPrefix(prefix) else {
            throw fail("a record's kind token was not followed by a single space")
        }
        let path = String(record.dropFirst(prefix.count))
        guard !path.isEmpty else { throw fail("a record carried an empty path") }
        return path
    }

    /// Splits the body of a record into exactly `count` space-separated fields, the last of which
    /// absorbs any space the path contains.
    private static func fields(_ record: String, kind: String, count: Int) throws -> [Substring] {
        let body = record.dropFirst(2)
        let parts = body.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false)
        guard parts.count == count, parts.allSatisfy({ !$0.isEmpty }) else {
            throw fail("a \(kind) record did not carry its \(count) fields")
        }
        return parts
    }

    /// `XY`: the index status and the working-tree status, `.` for unchanged.
    private static func change(_ code: Character, renamedFrom: String?) throws -> Entry.Change? {
        switch code {
        case ".": return nil
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "T": return .typeChanged
        case "R", "C":
            guard let renamedFrom else {
                throw fail("a rename or copy status appeared on a record that carries no "
                           + "original path")
            }
            return code == "R" ? .renamed(from: renamedFrom) : .copied(from: renamedFrom)
        default:
            throw fail("a record carried a change code this format does not define")
        }
    }

    private static func statusPair(_ field: Substring) throws -> (Character, Character) {
        guard field.count == 2 else { throw fail("a record's XY field was not two characters") }
        return (field[field.startIndex], field[field.index(after: field.startIndex)])
    }

    private static func ordinaryEntry(_ record: String) throws -> Entry {
        // <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        let parts = try fields(record, kind: "changed-entry", count: 8)
        let (x, y) = try statusPair(parts[0])
        return Entry(path: String(parts[7]),
                     staged: try change(x, renamedFrom: nil),
                     worktree: try change(y, renamedFrom: nil))
    }

    private static func renameEntry(_ record: String, originalPath: String) throws -> Entry {
        // <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>
        let parts = try fields(record, kind: "rename-or-copy", count: 9)
        let (x, y) = try statusPair(parts[0])
        guard let detection = parts[7].first, detection == "R" || detection == "C" else {
            throw fail("a rename or copy record's detection field named neither R nor C")
        }
        return Entry(path: String(parts[8]),
                     staged: try change(x, renamedFrom: originalPath),
                     worktree: try change(y, renamedFrom: originalPath))
    }

    private static func unmergedEntry(_ record: String) throws -> Entry {
        // <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path> — three fields wider than an
        // ordinary entry, which is why it cannot share the split above.
        let parts = try fields(record, kind: "unmerged", count: 10)
        _ = try statusPair(parts[0])
        // `XY` here are the two *sides* of the conflict (`UU`, `AA`, `DU`), not an index and a
        // working-tree status, so neither side is translated through `change`: both simply say
        // the path is unresolved.
        return Entry(path: String(parts[9]), staged: .unmerged, worktree: .unmerged)
    }

    private static func readHeader(_ record: String, into status: inout WorkingTreeStatus) throws {
        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "#" else {
            throw fail("a header line did not have the shape # <key> <value>")
        }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            // The literal git prints before the first commit; there is no object to name.
            status.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            // The literal git prints for a detached HEAD; there is no branch to name.
            status.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // `+<n> -<n>`, always both and always in that order.
            let counts = value.split(separator: " ", omittingEmptySubsequences: false)
            guard counts.count == 2, counts[0].hasPrefix("+"), counts[1].hasPrefix("-"),
                  let ahead = Int(counts[0].dropFirst()), let behind = Int(counts[1].dropFirst()) else {
                throw fail("the branch.ab header did not carry +<n> -<n>")
            }
            status.ahead = ahead
            status.behind = behind
        default:
            // An unfamiliar header is not a malformed one: git adds them (`# stash <n>`), and a
            // parser that refused would break on a git newer than the one it was written against.
            // Unfamiliar *entries* still throw, because those are what the panel renders.
            break
        }
    }
}
