import Foundation
import Darwin

/// What a config home held, at every depth, and what changed about it — X9's instrument.
///
/// C4's G5 carried a witness of the same name that read a flat map of relative paths to
/// `(size, mtime)` and classified a change by its **first path component** against an allowlist.
/// That is not enough for C5's live gate, and the gap is not theoretical: a defect that truncates
/// `.claude.json`, rewrites an existing transcript under `projects/<slug>/`, or drops a file three
/// levels down inside a directory the allowlist already names leaves the top-level name set
/// unchanged and passes. This witness therefore records **every regular file at any depth** and
/// classifies **every changed path in full**.
///
/// Three fields per file, and each earns its place. `size` catches a truncation and an append.
/// `modified` is nanosecond-resolution, because a same-size rewrite inside one second is invisible
/// to a whole-second timestamp and that is exactly the shape a corrupting write has. `inode` catches
/// an atomic replace, where a staging file is renamed over the original: same name, same size, and a
/// different file entirely.
///
/// It **never writes**. `lstat(2)` is the only call it makes against the tree — no `open`, no read,
/// and a symlink is recorded as itself rather than followed, so a link pointing out of the home
/// cannot make the witness report on a file that is not in it.
struct ConfigHomeWitness: Sendable {

    let root: URL

    init(root: URL) { self.root = root }

    // MARK: - A reading

    struct Stamp: Hashable, Sendable {
        var size: Int
        /// Whole nanoseconds since the epoch, from `st_mtimespec`.
        var modifiedNanoseconds: Int64
        var inode: UInt64
    }

    /// Every regular file and symlink under `root`, keyed by its path relative to `root`.
    ///
    /// Hidden files are included and an unreadable subtree is skipped rather than aborting the walk,
    /// so any two readings of the same tree are comparable. Directories are not entries of their
    /// own: a directory that appears carries the files that made it interesting, and a directory
    /// that appears empty changes nothing anybody can read.
    func read() -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        Self.walk(root, prefix: "", into: &out)
        return out
    }

    private static func walk(_ directory: URL, prefix: String, into out: inout [String: Stamp]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let child = directory.appending(path: name)
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            var status = stat()
            guard lstat(child.path, &status) == 0 else { continue }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                walk(child, prefix: relative, into: &out)
            case S_IFREG, S_IFLNK:
                out[relative] = Stamp(size: Int(status.st_size),
                                      modifiedNanoseconds: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
                                          + Int64(status.st_mtimespec.tv_nsec),
                                      inode: UInt64(status.st_ino))
            default:
                continue
            }
        }
    }

    // MARK: - The difference between two readings

    struct Difference: Hashable, Sendable {
        var created: Set<String> = []
        var modified: Set<String> = []
        var deleted: Set<String> = []

        var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
        var changed: Set<String> { created.union(modified).union(deleted) }
        /// Counts only. A failure names the relative paths it could not attribute; a routine line
        /// says how many moved (parent §11).
        var summary: String { "created \(created.count), modified \(modified.count), deleted \(deleted.count)" }
    }

    static func difference(from before: [String: Stamp], to after: [String: Stamp]) -> Difference {
        var difference = Difference()
        difference.created = Set(after.keys).subtracting(before.keys)
        difference.deleted = Set(before.keys).subtracting(after.keys)
        difference.modified = Set(before.keys).intersection(after.keys).filter { before[$0] != after[$0] }
        return difference
    }

    // MARK: - Attribution

    /// A relative path a spawned `claude` is known to write, as a pattern.
    ///
    /// A trailing `/` matches that directory and everything beneath it at any depth; a trailing `*`
    /// matches any path with that prefix; anything else matches exactly. The set is C4's widened
    /// allowlist (`FleetKit/Tests/FleetSessionsTests/Support/LiveGate.swift`) plus the two entries
    /// this child's own probing found in the scratch home: `chrome/`, and the `.claude.json` staging
    /// file the engine renames into place. It is pinned by
    /// `testTheAllowlistPinMatchesTheScratchHome`, so a drift fails naming the pattern instead of
    /// widening the claim quietly.
    static let childWrittenPaths: Set<String> = [
        "sessions/", "projects/", "tasks/", "jobs/", "daemon/", "daemon.log", "daemon.lock", "daemon.status.json",
        "history.jsonl", ".claude.json", ".claude.json.tmp.*",
        "shell-snapshots/", "session-env/", "file-history/", "statsig/", "cache/", "todos/", "debug/", "plugins/",
        "backups/", "plans/", "ide/", "logs/", "history/", "chrome/", ".credentials.json", ".last-cleanup",
        ".last-update-result.json", "settings.json",
    ]

    /// Which child a change is expected to have come from.
    ///
    /// The allowlist alone says a path is one an engine writes; it does not say *this* engine wrote
    /// it. For the two families that carry an identity in the name — the registry record and the
    /// messaging key under `sessions/`, and the transcript under `projects/` — the identity is
    /// checked, so a second `claude` that happened to be running during the scenario is reported
    /// rather than absorbed.
    struct Attribution: Sendable {
        var childPID: pid_t
        var session: String

        init(childPID: pid_t, session: String) {
            self.childPID = childPID
            self.session = session
        }
    }

    static func matches(_ path: String, pattern: String) -> Bool {
        if pattern.hasSuffix("/") { return path == String(pattern.dropLast()) || path.hasPrefix(pattern) }
        if pattern.hasSuffix("*") { return path.hasPrefix(String(pattern.dropLast())) }
        return path == pattern
    }

    /// Every changed path that no pattern explains, or that a pattern explains but the named child
    /// cannot account for, sorted.
    ///
    /// `allowlist` and `attribution` are parameters so a test can hold one reading up against a
    /// deliberately narrowed set and prove the comparison discriminates, rather than taking that on
    /// faith or paying for a second live run to watch it fail.
    static func unattributed(_ difference: Difference,
                             against allowlist: Set<String> = childWrittenPaths,
                             attribution: Attribution? = nil) -> [String] {
        difference.changed.filter { path in
            guard allowlist.contains(where: { matches(path, pattern: $0) }) else { return true }
            guard let attribution else { return false }
            let components = path.split(separator: "/").map(String.init)
            if components.first == "sessions", let name = components.last {
                return !name.hasPrefix("\(attribution.childPID).")
            }
            if components.first == "projects", let name = components.last {
                return !name.hasPrefix(attribution.session)
            }
            return false
        }.sorted()
    }
}
