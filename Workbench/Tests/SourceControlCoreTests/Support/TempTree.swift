import Foundation
import XCTest

/// A scratch directory tree under the process's temporary directory, for tests that need real
/// files on disk.
///
/// X9 and tracker entry 24 (ledger Q15/D15): nothing this child writes may land inside a Claude
/// Code config home. A temporary directory is normally nowhere near one, but `TMPDIR` is
/// settable, so the resolved root is canonicalised and compared against every config home before
/// a single directory is created. When it does resolve inside one the initialiser throws
/// `XCTSkip` rather than writing.
///
/// This is C5's `AppTests/Support/TempTree.swift` re-created rather than imported: a test target
/// cannot import another target's test bundle, and W1 fences each leaf to its own region.
struct TempTree {

    /// The three config homes a scratch tree may never resolve inside, canonicalised.
    static func configHomes(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var homes = [URL(filePath: NSHomeDirectory()).appending(path: ".claude"),
                     URL(filePath: "/tmp/afleet-fixtures/config-home")]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            homes.append(URL(filePath: configured))
        }
        return homes.map(canonical)
    }

    /// The canonical form of `url`, resolved through its nearest **existing** ancestor and with
    /// the components below it re-appended.
    ///
    /// `resolvingSymlinksInPath()` alone is not enough, and the difference is the whole of this
    /// guard (R6/F3). It resolves nothing in a path that does not exist: measured on this machine,
    /// `/tmp` comes back as `/tmp` rather than `/private/tmp`, and a path under a directory that
    /// has not been created yet comes back spelled exactly as it was written. So a `TMPDIR` naming
    /// a directory that does not exist yet — which is precisely the case this type then *creates*,
    /// intermediates and all — keeps whatever spelling it was given, while the config home it is
    /// really inside resolves to its own. The two spell one directory two ways, no prefix matches,
    /// and the tree is created inside the config home the guard exists to refuse.
    ///
    /// `realpath(3)` rather than `resolvingSymlinksInPath()` on the ancestor, because Foundation
    /// leaves `/tmp` — the ancestor of one of the three forbidden homes — unresolved.
    ///
    /// `standardized`, never `standardizedFileURL`, and that is not a detail either. The file-URL
    /// form consults the filesystem and *removes* a `/private` prefix from a path that exists
    /// while leaving it on one that does not, so canonicalising both sides with it makes the same
    /// directory come back as `/var/…` for the config home and `/private/var/…` for the base — the
    /// two-spellings failure this function exists to end, reintroduced one line below the fix.
    /// Measured here before it was written down.
    static func canonical(_ url: URL) -> URL {
        let manager = FileManager.default
        var missing: [String] = []
        var existing = url.standardized
        while !manager.fileExists(atPath: existing.path(percentEncoded: false)) {
            let parent = existing.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < existing.pathComponents.count else { break }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
        var resolved = URL(filePath: realpath(existing.path(percentEncoded: false))
                           ?? existing.resolvingSymlinksInPath().path(percentEncoded: false))
        for component in missing.reversed() { resolved = resolved.appending(path: component) }
        return resolved
    }

    /// `path` with every symbolic link resolved, or nil when the kernel cannot answer.
    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `base` is `home` or lies inside it.
    ///
    /// Two questions, asked in that order, because neither answers the other.
    ///
    /// **Identity first.** A path is not a name for a directory; it is one of the names. macOS
    /// mounts the data volume twice, so `/System/Volumes/Data/private/var/…` and `/private/var/…`
    /// are one directory with identical `(st_dev, st_ino)` — and `realpath(3)` *preserves* the
    /// firmlink prefix rather than removing it, so canonicalising both sides leaves two spellings
    /// that share no components at all. A comparison made over names is then satisfied by nothing
    /// and the guard fails open, which is the one direction X9 does not allow. Measured on this
    /// host (R7/1a). So each of `base`'s existing ancestors is compared with `home` by the identity
    /// the kernel gives them, which no spelling can disagree about.
    ///
    /// **Components second**, for what identity cannot reach: a `base` — or a home — that does not
    /// exist yet has no inode to compare, and this guard runs precisely to stop such a path from
    /// being created. That comparison is **case- and normalisation-insensitive**, deliberately: a
    /// macOS volume is case-insensitive by default, so `.CLAUDE` and `.claude` are one directory,
    /// and a guard correct only on a case-sensitive volume is not correct on the machines this
    /// runs on. Erring towards refusal costs a skipped test and never a write under a config home.
    static func contains(_ home: URL, _ base: URL) -> Bool {
        if sharesIdentity(home, base) { return true }
        let inside = base.pathComponents, outside = home.pathComponents
        guard inside.count >= outside.count else { return false }
        for (mine, theirs) in zip(inside, outside) where !sameComponent(mine, theirs) { return false }
        return true
    }

    /// True when `home` exists and is `base` or one of `base`'s existing ancestors, by
    /// `(st_dev, st_ino)`.
    ///
    /// The walk goes upward from `base` because `base` itself need not exist — the caller is about
    /// to create it — while some ancestor of it always does, and it is the *first existing* one
    /// that a spelling can disguise. `lstat` rather than `stat`: a symbolic link is compared as
    /// itself, and the directory it points at is reached anyway through `canonical`'s resolution
    /// of the existing prefix.
    private static func sharesIdentity(_ home: URL, _ base: URL) -> Bool {
        guard let target = identity(home) else { return false }
        var candidate = base.standardized
        while true {
            if let found = identity(candidate), found == target { return true }
            let parent = candidate.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < candidate.pathComponents.count else { return false }
            candidate = parent
        }
    }

    /// The filesystem identity of `url`, or nil when nothing is there.
    private static func identity(_ url: URL) -> (dev_t, ino_t)? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    private static func sameComponent(_ one: String, _ other: String) -> Bool {
        one.precomposedStringWithCanonicalMapping
            .compare(other.precomposedStringWithCanonicalMapping, options: [.caseInsensitive])
            == .orderedSame
    }

    /// The root of this tree. Created by `init`, and unique to it.
    let root: URL

    init() throws {
        try self.init(temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    /// The injectable form. `temporaryDirectory` is the directory the tree is created under;
    /// `configHomes` is the forbidden set. Both default to the real ones.
    ///
    /// Both sides are canonicalised here, not just the temporary directory. Comparing a resolved
    /// path against an unresolved one is a guard that fails open: the two spell one directory two
    /// ways, no prefix matches, and the tree is created inside the config home it was meant to
    /// refuse. `canonical` and `contains` carry the two ways that happens — a base that does not
    /// exist yet, and a volume that does not distinguish case.
    init(temporaryDirectory: URL, configHomes: [URL] = TempTree.configHomes()) throws {
        let base = TempTree.canonical(temporaryDirectory)
        for home in configHomes.map(TempTree.canonical) where TempTree.contains(home, base) {
            throw XCTSkip("temporary directory resolves inside a config home")
        }
        root = base.appending(path: "afleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Writes `contents` at `relativePath`, creating every intermediate directory.
    @discardableResult
    func file(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates `relativePath` as a directory, with every intermediate directory.
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the whole tree. Called from a test's teardown; a failure to remove is not a test
    /// failure, because the tree is unique per initialiser and the system reclaims it.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
