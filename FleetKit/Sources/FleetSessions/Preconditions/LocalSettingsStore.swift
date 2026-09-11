import Foundation
import Darwin

/// Whose ownership is being asked about. A path before the first open, a descriptor after it — the distinction is
/// the point: once the writer holds a descriptor it never asks a question about a name again.
public enum OwnershipSubject: Sendable {
    case path(URL)
    case descriptor(Int32)
}

/// The parent's §6.12 store resolution and write policy (SPEC 03 §4.4, §13.2–13.3). This is the only Claude
/// Code-owned file afleet writes, and it is written the way the CLI writes it. Every failure is a refusal with a
/// reason word; nothing is ever half-written.
///
/// The root is the one path opened by name. Its descriptor is verified with `F_GETPATH` before anything is checked
/// or created, the config-home containment check runs on *that* result rather than on any string computed before the
/// open, and every later open, create and rename is relative to a directory descriptor the writer holds — so a
/// component swapped for a symlink after resolution is refused (`ELOOP`/`ENOTDIR` → `symlink`), not followed.
public struct LocalSettingsStore: Sendable {
    public struct Resolution: Hashable, Sendable {
        /// `<root>/.claude`.
        public var storeDirectory: URL
        /// `<root>/.claude/settings.local.json`.
        public var storeFile: URL
        /// The cwd's own file, read as an overlay when the store moved up to the git root, as the CLI reads it.
        public var legacyOverlay: URL?
        public var atGitRoot: Bool
        public init(storeDirectory: URL, storeFile: URL, legacyOverlay: URL?, atGitRoot: Bool) {
            self.storeDirectory = storeDirectory; self.storeFile = storeFile
            self.legacyOverlay = legacyOverlay; self.atGitRoot = atGitRoot
        }
    }

    /// Test seams. `Hooks` lets a test act *between* two syscalls — swap a component, inspect the staging file — and
    /// is what makes the ancestor-swap refusals demonstrable rather than asserted. Production hooks do nothing.
    public struct Hooks: Sendable {
        public var afterResolve: @Sendable (Resolution) -> Void
        public var afterOpen: @Sendable (Int32) -> Void
        public var afterStagingCreated: @Sendable (Int32) -> Void
        public var afterStagingDirectory: @Sendable () -> Void
        public init(afterResolve: @escaping @Sendable (Resolution) -> Void = { _ in },
                    afterOpen: @escaping @Sendable (Int32) -> Void = { _ in },
                    afterStagingCreated: @escaping @Sendable (Int32) -> Void = { _ in },
                    afterStagingDirectory: @escaping @Sendable () -> Void = {}) {
            self.afterResolve = afterResolve; self.afterOpen = afterOpen
            self.afterStagingCreated = afterStagingCreated; self.afterStagingDirectory = afterStagingDirectory
        }
        public static let none = Hooks()
    }

    /// Consulted for every ownership check: paths before the first open, descriptors after it.
    public var ownerUID: @Sendable (OwnershipSubject) -> uid_t?
    public var hooks: Hooks

    public init(ownerUID: @escaping @Sendable (OwnershipSubject) -> uid_t? = LocalSettingsStore.statOwner,
                hooks: Hooks = .none) {
        self.ownerUID = ownerUID; self.hooks = hooks
    }

    public enum Refusal: String, Error, Sendable {
        case unparseable, symlink, foreignUID, insideConfigHome, processLive, writeFailed, notADirectory
    }

    /// The key the consent arrays live under, in the CLI's own spelling.
    static let disabledKey = "disabledMcpjsonServers"

    // MARK: - Resolution

    /// `<root>/.claude/settings.local.json` when `stat(root)`, `lstat(root/.git)` and `lstat(root/.claude)` are all
    /// owned by the effective uid and root is not the real home directory; otherwise `<cwd>/.claude/settings.local.json`,
    /// with the cwd file read as the legacy overlay when the store moved to the git root.
    ///
    /// **`.git` must be *there*, and `.claude` need not.** The engine's resolver `lstat`s
    /// `join(root, ".git")` **unguarded** (2.1.263 `chunk-aqbb35ee.js`); the may-be-absent licence in
    /// `SPEC/03` §4.4 step 4 is granted to `.claude` alone. The difference is not academic: a
    /// worktree of a **bare** repository canonicalises to the bare directory, which has no `.git`
    /// inside it, so the engine keeps its store at the checkout — and afleet, treating an absent
    /// entry as "not foreign", moved the store to the bare directory. A decline written there is a
    /// file afleet then reads back as authoritative while the engine reads the checkout's, so the
    /// declined server loads and §6.12's one write has been made in a place nobody honours.
    public func resolve(gitRoot: URL?, cwd: URL) -> Resolution {
        let me = geteuid()
        let cwdReal = RealPath.url(cwd)
        var directory = cwdReal
        var atGitRoot = false
        if let gitRoot {
            let root = RealPath.url(gitRoot)
            let home = RealPath.string(FileManager.default.homeDirectoryForCurrentUser)
            if RealPath.string(root) != home,
               ownerUID(.path(root)) == me,
               presentAndOwned(root.appending(path: ".git"), by: me),
               owned(root.appending(path: ".claude"), by: me) {
                directory = root
                atGitRoot = true
            }
        }
        let storeDirectory = directory.appending(path: ".claude")
        let overlay = (atGitRoot && RealPath.string(directory) != RealPath.string(cwdReal))
            ? cwdReal.appending(path: ".claude/settings.local.json") : nil
        let resolution = Resolution(storeDirectory: storeDirectory,
                                    storeFile: storeDirectory.appending(path: "settings.local.json"),
                                    legacyOverlay: overlay, atGitRoot: atGitRoot)
        hooks.afterResolve(resolution)
        return resolution
    }

    /// An entry that is not there is not a foreign one. `.claude`'s rule, and `.claude`'s alone.
    private func owned(_ url: URL, by me: uid_t) -> Bool {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return true }
        return ownerUID(.path(url)) == me
    }

    /// The entry must exist **and** be ours. `.git`'s rule, because the engine's `lstat` of it is
    /// unguarded: a root with no `.git` is a root the engine does not move its store to.
    private func presentAndOwned(_ url: URL, by me: uid_t) -> Bool {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return false }
        return ownerUID(.path(url)) == me
    }

    // MARK: - The one write

    /// Steps, in order; any failure throws a `Refusal` before or without touching the target, and every descriptor
    /// is closed on every path out.
    ///
    /// 1. `resolve`; `realpath(3)` the project root → `resolved` (the store and staging directories are
    ///    `resolved/.claude` and `resolved/.claude/.cc-writes` by construction). `hooks.afterResolve`.
    /// 2. `rootFD = open(resolved, O_DIRECTORY|O_NOFOLLOW)`; `fcntl(rootFD, F_GETPATH)` must equal `resolved` byte
    ///    for byte (else `symlink`: an ancestor was swapped between the two calls); the `insideConfigHome` check
    ///    runs on that `F_GETPATH` result; `fstat(rootFD)` → directory, owned by the effective uid, and `.git`
    ///    beside it owned too. `hooks.afterOpen(rootFD)`. `mkdirat(rootFD, ".claude", 0o755)` if absent;
    ///    `dirFD = openat(rootFD, ".claude", O_DIRECTORY|O_NOFOLLOW)`; `fstat(dirFD)` → directory, same uid.
    /// 3. When the file exists: `openat(dirFD, "settings.local.json", O_RDONLY|O_NOFOLLOW)`, `fstat` → regular file,
    ///    its mode is the mode to preserve (0o644 for a new file), and the raw text is read through the descriptor.
    ///    `JSONSerialization` validates it; a scanner over the raw text finds the top-level key's bracketed value and
    ///    the merged array's JSON is spliced into that range, so every other byte of the file is untouched.
    /// 4. `mkdirat(dirFD, ".cc-writes", 0o700)`; `hooks.afterStagingDirectory`; `openat` it the same way.
    /// 5. `openat(stagingFD, "settings.local.json.<uuid>", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0o600)`;
    ///    `hooks.afterStagingCreated`; write whole; `fchmod` to the preserved mode; `fsync`; close.
    /// 6. `renameat` within the two descriptors; `fsync(dirFD)`; remove the staging directory. Any error in 5–6
    ///    unlinks the staging file and refuses `writeFailed`.
    @discardableResult
    public func decline(names: [String], gitRoot: URL?, cwd: URL, configHome: URL) throws -> Resolution {
        // `resolve` realpaths the root and *then* fires `afterResolve`, so this string is the one taken before any
        // swap a hook could make: realpathing again here would resolve through the swapped link and agree with the
        // descriptor that is about to be opened, which is precisely the comparison that has to disagree.
        let resolution = resolve(gitRoot: gitRoot, cwd: cwd)
        let resolved = RealPath.trimmed(resolution.storeDirectory.deletingLastPathComponent()
            .path(percentEncoded: false))
        let me = geteuid()

        // 2. The one path opened by name.
        let rootFD = resolved.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard rootFD >= 0 else { throw Self.refusal(forErrno: errno) }
        defer { Darwin.close(rootFD) }
        guard let opened = Self.descriptorPath(rootFD), opened == resolved else { throw Refusal.symlink }
        // The config home goes through the *same* normaliser as the descriptors it is compared against. A path
        // spelled through the data volume's firmlink (`/System/Volumes/Data/...`) survives `realpath(3)` — a
        // firmlink is not a symlink, so there is nothing to resolve — while `F_GETPATH` answers the same directory
        // without the prefix, and a containment check between the two spellings never fires.
        let home = Self.canonicalDirectory(configHome)
        guard !RealPath.contains(home, opened) else { throw Refusal.insideConfigHome }
        guard Self.isDirectory(rootFD) else { throw Refusal.notADirectory }
        guard ownerUID(.descriptor(rootFD)) == me else { throw Refusal.foreignUID }
        // `.git` beside the root: an `lstat` is not an open, and the descriptor above has just proved that this name
        // names the directory the writer resolved.
        let gitPath = resolved + "/.git"
        var gitStat = stat()
        if lstat(gitPath, &gitStat) == 0, ownerUID(.path(URL(filePath: gitPath))) != me {
            throw Refusal.foreignUID
        }
        hooks.afterOpen(rootFD)

        if mkdirat(rootFD, ".claude", 0o755) != 0, errno != EEXIST { throw Refusal.writeFailed }
        let dirFD = openat(rootFD, ".claude", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw Self.directoryRefusal(forErrno: errno, in: rootFD, named: ".claude") }
        defer { Darwin.close(dirFD) }
        guard Self.isDirectory(dirFD) else { throw Refusal.notADirectory }
        guard ownerUID(.descriptor(dirFD)) == me else { throw Refusal.foreignUID }
        // Where the store directory *itself* lands, not only its root. `CLAUDE_CONFIG_DIR` may name
        // `<root>/.claude`, in which case the root is nowhere near the config home and the check above passes
        // while the write goes straight into it — the arrangement parent §6.12 names in as many words. Asked of
        // the descriptor, so this too is never a string computed before the open.
        guard let storePath = Self.descriptorPath(dirFD), !RealPath.contains(home, storePath) else {
            throw Refusal.insideConfigHome
        }

        // 3. The existing document, read through a descriptor.
        var preservedMode: mode_t = 0o644
        var rawText = "{}"
        let fileFD = openat(dirFD, "settings.local.json", O_RDONLY | O_NOFOLLOW)
        if fileFD >= 0 {
            defer { Darwin.close(fileFD) }
            var st = stat()
            guard fstat(fileFD, &st) == 0 else { throw Refusal.writeFailed }
            guard st.st_mode & S_IFMT == S_IFREG else { throw Refusal.notADirectory }
            preservedMode = st.st_mode & 0o7777
            guard let text = Self.readAll(fileFD) else { throw Refusal.writeFailed }
            rawText = text
        } else if errno != ENOENT {
            throw Self.refusal(forErrno: errno)
        }

        guard let document = (try? JSONSerialization.jsonObject(with: Data(rawText.utf8))) as? [String: Any] else {
            throw Refusal.unparseable
        }
        // A value of another shape would slip past the scanner's bracket check and the insert path would append a
        // *second* key: both parsers take the last occurrence, so afleet's value would win, but the document would
        // be left with two. This build does not know what such a file means, and fail-closed is the rule.
        var merged: [String] = []
        if let existing = document[Self.disabledKey] {
            guard let names = existing as? [String] else { throw Refusal.unparseable }
            merged = names
        }
        for name in names where !merged.contains(name) { merged.append(name) }
        guard let arrayData = try? JSONSerialization.data(withJSONObject: merged,
                                                          options: [.withoutEscapingSlashes]),
              let newText = Self.splice(rawText, array: String(decoding: arrayData, as: UTF8.self)) else {
            throw Refusal.writeFailed
        }

        // 4. The staging directory, never opened by path.
        var createdStaging = false
        if mkdirat(dirFD, ".cc-writes", 0o700) == 0 {
            createdStaging = true
        } else if errno != EEXIST {
            throw Refusal.writeFailed
        }
        // Declared before the descriptor's own `defer` so it runs after it: the directory goes away whether this
        // call succeeds or refuses, and `ENOTEMPTY` from a concurrent writer's staging file is not our business.
        // Only when *this* call created it. A `.cc-writes` that was already there belongs to somebody else — an
        // interrupted write of ours or a concurrent one — and removing it would pull the directory out from under
        // a writer that is still using it. The cost is that an interrupted write leaves the directory behind.
        defer { if createdStaging { _ = unlinkat(dirFD, ".cc-writes", AT_REMOVEDIR) } }
        hooks.afterStagingDirectory()
        let stagingFD = openat(dirFD, ".cc-writes", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stagingFD >= 0 else { throw Self.directoryRefusal(forErrno: errno, in: dirFD, named: ".cc-writes") }
        defer { Darwin.close(stagingFD) }
        guard Self.isDirectory(stagingFD) else { throw Refusal.notADirectory }
        guard ownerUID(.descriptor(stagingFD)) == me else { throw Refusal.foreignUID }
        guard let stagingPath = Self.descriptorPath(stagingFD), !RealPath.contains(home, stagingPath) else {
            throw Refusal.insideConfigHome
        }

        // 5. The staging file: private on creation, the target's own mode before the rename.
        let temporary = "settings.local.json.\(UUID().uuidString)"
        let tmpFD = openat(stagingFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard tmpFD >= 0 else { throw Self.refusal(forErrno: errno) }
        hooks.afterStagingCreated(tmpFD)
        let wrote = Self.writeAll(tmpFD, Data(newText.utf8))
            && fchmod(tmpFD, preservedMode) == 0
            && Darwin.fsync(tmpFD) == 0
        Darwin.close(tmpFD)
        guard wrote else {
            _ = unlinkat(stagingFD, temporary, 0)
            throw Refusal.writeFailed
        }

        // 6. The rename, within the two descriptors the writer holds.
        guard renameat(stagingFD, temporary, dirFD, "settings.local.json") == 0 else {
            _ = unlinkat(stagingFD, temporary, 0)
            throw Refusal.writeFailed
        }
        _ = Darwin.fsync(dirFD)
        return resolution
    }

    // MARK: - Syscall helpers

    public static func statOwner(_ subject: OwnershipSubject) -> uid_t? {
        var st = stat()
        switch subject {
        case .path(let url):
            guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        case .descriptor(let fd):
            guard fstat(fd, &st) == 0 else { return nil }
        }
        return st.st_uid
    }

    /// Why an open without `O_DIRECTORY` failed. There `O_NOFOLLOW` does answer `ELOOP` for a symlink, so the errno
    /// is the whole story.
    private static func refusal(forErrno code: Int32) -> Refusal {
        switch code {
        case ELOOP: .symlink
        case ENOTDIR: .notADirectory
        default: .writeFailed
        }
    }

    /// Why a *directory* open relative to `parent` failed, and this one cannot be read off the errno.
    ///
    /// Measured on Darwin: `openat(fd, name, O_DIRECTORY|O_NOFOLLOW)` answers `ENOTDIR` for a symlink, for a plain
    /// file and for a dangling link alike; `ELOOP` appears only when `O_DIRECTORY` is absent. So the entry itself
    /// has to be asked, through the descriptor already held — `fstatat`, not a path. The word matters because it
    /// reaches the user in `ChannelBanner.mcpDeclineRefused`, and telling someone "symlink" when their `.claude` is
    /// a regular file sends them hunting the wrong thing.
    ///
    /// The refusal is already decided by the time this runs; all that is being chosen is what to call it. So the
    /// window between the failed open and this `fstatat` costs nothing: an entry that changed in it, or vanished,
    /// answers `symlink`, which is the conservative word for "something moved under us".
    private static func directoryRefusal(forErrno code: Int32, in parent: Int32, named name: String) -> Refusal {
        guard code == ELOOP || code == ENOTDIR else { return .writeFailed }
        guard code == ENOTDIR else { return .symlink }
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return .symlink }
        return st.st_mode & S_IFMT == S_IFLNK ? .symlink : .notADirectory
    }

    private static func isDirectory(_ fd: Int32) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// A directory's path in the spelling `F_GETPATH` answers in, so it compares against a descriptor's own path.
    /// Falls back to `realpath(3)` when the directory cannot be opened — a home that is not there contains nothing,
    /// and the string check is what the writer had before.
    private static func canonicalDirectory(_ url: URL) -> String {
        let given = RealPath.trimmed(url.path(percentEncoded: false))
        let fd = given.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard fd >= 0 else { return RealPath.string(url) }
        defer { Darwin.close(fd) }
        return descriptorPath(fd).map(RealPath.trimmed) ?? RealPath.string(url)
    }

    /// Where the kernel says this descriptor actually is, which is the only trustworthy answer once a name may have
    /// been swapped underneath.
    private static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let ok = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return fcntl(fd, F_GETPATH, base) != -1
        }
        return ok ? RealPath.string(fromCString: buffer) : nil
    }

    private static func readAll(_ fd: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    // MARK: - Splicing one array into a document nobody else may reformat

    /// Replaces the top-level `disabledMcpjsonServers` array's own text with `array`, or inserts the key before the
    /// document's closing brace when it is absent. Every other byte — key order, whitespace, number spelling, keys
    /// this build does not recognise — survives, which re-serialising through `JSONSerialization` would not manage.
    static func splice(_ raw: String, array: String) -> String? {
        var bytes = Array(raw.utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d }
        /// The end of the string literal starting at `start` (the index of its opening quote).
        func endOfString(_ start: Int) -> Int {
            var i = start + 1
            while i < bytes.count {
                if bytes[i] == backslash { i += 2; continue }
                if bytes[i] == quote { return i }
                i += 1
            }
            return bytes.count
        }

        guard let open = bytes.firstIndex(of: openBrace) else { return nil }
        var i = open + 1
        var depth = 0            // 0 == directly inside the top-level object
        var topLevelClose = -1
        var previousSignificant: UInt8 = openBrace
        while i < bytes.count {
            let c = bytes[i]
            if c == quote {
                let end = endOfString(i)
                // A key sits directly after the opening brace or after a comma; a string *value* does not, and this
                // is what keeps a value that happens to spell the key from being mistaken for one.
                let isKey = depth == 0 && (previousSignificant == openBrace || previousSignificant == UInt8(ascii: ","))
                if isKey, String(decoding: bytes[(i + 1)..<end], as: UTF8.self) == disabledKey {
                    var j = end + 1
                    while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                    if j < bytes.count, bytes[j] == UInt8(ascii: ":") {
                        j += 1
                        while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                        if j < bytes.count, bytes[j] == openBracket {
                            var k = j, brackets = 0
                            while k < bytes.count {
                                let ch = bytes[k]
                                if ch == quote { k = endOfString(k) }
                                else if ch == openBracket { brackets += 1 }
                                else if ch == closeBracket {
                                    brackets -= 1
                                    if brackets == 0 { break }
                                }
                                k += 1
                            }
                            guard brackets == 0, k < bytes.count else { return nil }
                            bytes.replaceSubrange(j...k, with: Array(array.utf8))
                            return String(decoding: bytes, as: UTF8.self)
                        }
                    }
                }
                previousSignificant = quote
                i = end + 1
                continue
            }
            if c == openBrace || c == openBracket { depth += 1 }
            else if c == closeBracket { depth -= 1 }
            else if c == closeBrace {
                if depth == 0 { topLevelClose = i; break }
                depth -= 1
            }
            if !isSpace(c) { previousSignificant = c }
            i += 1
        }

        guard topLevelClose >= 0 else { return nil }
        let inner = String(decoding: bytes[(open + 1)..<topLevelClose], as: UTF8.self)
        let separator = inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ", "
        bytes.insert(contentsOf: Array("\(separator)\"\(disabledKey)\": \(array)".utf8), at: topLevelClose)
        return String(decoding: bytes, as: UTF8.self)
    }
}
