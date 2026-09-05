import Foundation
import CryptoKit
import AfleetCore
import WireFrames

/// Opt-in raw frame capture: redacted before any write, 0700 directory, 0600 files, byte budget oldest-first.
public actor RawCapture {
    public let root: URL
    public let directory: URL
    public let budgetBytes: Int
    private var handles: [SessionID: FileHandle] = [:]
    /// One per session: a `control_response` is gated on the subtype of the request it answers, and that is
    /// the only place the subtype is written down. Per session rather than shared, because request ids are
    /// only unique within the stream that issued them.
    private var correlations: [SessionID: Redactor.Correlation] = [:]

    public init(root: URL, configHome: ConfigHome, budgetBytes: Int = 200 * 1024 * 1024) {
        self.root = root
        self.budgetBytes = budgetBytes
        self.directory = root.appendingPathComponent(Self.configHomeHash(configHome))
    }
    public static func configHomeHash(_ home: ConfigHome) -> String {
        String(SHA256.hash(data: Data(home.root.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
    /// Redaction happens before the file is even opened, so no unredacted byte ever reaches disk.
    /// A line that does not parse is dropped, not written through.
    public func write(line: Data, session: SessionID) {
        var correlation = correlations[session] ?? .init()
        defer { correlations[session] = correlation }
        guard var redacted = Redactor.redact(line: line, correlation: &correlation) else { return }
        redacted.append(0x0A)
        guard let dirFD = openDirectory() else { return }
        defer { close(dirFD) }
        // Before the append, not after it. Appending first left the directory over budget for the whole
        // window between the two, and the budget is a statement about what is on disk.
        guard admit(redacted.count, for: session) else { return }
        let name = "\(session.description).ndjson"
        if handles[session] == nil { handles[session] = openSessionFile(name, in: dirFD) }
        try? handles[session]?.write(contentsOf: redacted)
    }
    /// Renames a capture opened before its session was named — a fork, whose id arrives a few frames in.
    ///
    /// A file, not a copy: the frames already written belong to this session and there is exactly one file
    /// for it. The provisional key is itself a fresh `SessionID`, so the file is a well-formed one this
    /// capture owns while it waits, and stays inside the budget and the prune sweep rather than sitting
    /// outside both under a name neither recognises.
    public func rename(from provisional: SessionID, to real: SessionID) {
        guard provisional != real else { return }
        try? handles[provisional]?.close(); handles[provisional] = nil
        correlations[real] = correlations.removeValue(forKey: provisional)
        guard let dirFD = openDirectory() else { return }
        defer { close(dirFD) }
        // Relative to the verified descriptor, like every other access here. A provisional file that was
        // never opened — nothing written yet — simply is not there, and `renameat` failing is the answer.
        _ = renameat(dirFD, "\(provisional).ndjson", dirFD, "\(real).ndjson")
    }
    public func prune(keeping: Set<SessionID>) {
        for (session, handle) in handles where !keeping.contains(session) { try? handle.close(); handles[session] = nil }
        for session in correlations.keys where !keeping.contains(session) { correlations[session] = nil }
        for entry in ownedEntries() where !keeping.contains(entry.session) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    // MARK: opening

    /// Opens the capture directory, creating it if needed, **without following a symlink**, and forces 0700
    /// on what it opened whether it created it or found it there.
    ///
    /// The path-based `fileExists` / `createDirectory` pair this replaces was wrong twice over. It applied
    /// the mode only on creation, so a directory that already existed kept whatever mode it had — including
    /// a world-readable one. And a check on a path followed by an open of that path are two different
    /// objects the moment anything else can write the parent: a symlink planted in between redirected every
    /// captured frame to wherever it pointed. `O_NOFOLLOW` plus `fstat` on the descriptor actually opened
    /// is what closes both.
    private func openDirectory() -> Int32? {
        let fm = FileManager.default
        // The root holds no capture data of its own; only the hashed directory below it does.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = mkdir(directory.path, 0o700)      // EEXIST is expected; the descriptor below is what decides.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { close(fd); return nil }
        if info.st_mode & 0o777 != 0o700 { _ = fchmod(fd, 0o700) }
        return fd
    }
    /// Opens one session file relative to the directory descriptor, refusing a symlink and anything that is
    /// not a regular file, and forcing 0600 on an entry that was already there with a looser mode.
    ///
    /// `openat` rather than a path: the directory written into is the one just verified, not whatever the
    /// path resolves to by the time a second syscall runs. A planted symlink is refused rather than
    /// replaced — deleting something this type does not own is not a repair.
    private func openSessionFile(_ name: String, in dirFD: Int32) -> FileHandle? {
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { close(fd); return nil }
        if info.st_mode & 0o777 != 0o600 { _ = fchmod(fd, 0o600) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: budget

    private struct Entry { let url: URL; let session: SessionID; let modified: Date; let size: Int }

    /// The files this capture owns: a **regular file** whose name is `<session uuid>.ndjson`.
    ///
    /// Counting by suffix alone was a data-loss hazard, not merely an accounting one: a directory — or
    /// anything else — named `x.ndjson` was counted against the budget and then handed to `removeItem`,
    /// which deletes a whole tree. Losing something this type does not own is a far worse outcome than
    /// exceeding a byte budget, so ownership is proven, and `prune` proves it the same way.
    private func ownedEntries() -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard name.hasSuffix(".ndjson"), let session = SessionID(String(name.dropLast(7))) else { continue }
            let url = directory.appendingPathComponent(name)
            // `attributesOfItem` does not follow a symlink, so a symlinked `<uuid>.ndjson` reports
            // `.typeSymbolicLink` here and is neither counted nor deleted.
            guard let a = try? fm.attributesOfItem(atPath: url.path), (a[.type] as? FileAttributeType) == .typeRegular else { continue }
            out.append(Entry(url: url, session: session,
                             modified: (a[.modificationDate] as? Date) ?? .distantPast,
                             size: (a[.size] as? Int) ?? 0))
        }
        return out
    }

    /// Whether `incoming` bytes may be appended, having first made room for them.
    ///
    /// Oldest first, *skipping* the session being written rather than stopping at it: stopping left the
    /// budget exceeded for as long as that session stayed the oldest file, which is the normal case for a
    /// long-lived session. But being skipped must not mean being unbounded — one long-lived session, or a
    /// single line larger than the whole budget, used to sit over the limit forever with neither rotation
    /// nor shutdown. So there are three steps, and the last two are what makes the budget real: evict what
    /// can be evicted, rotate the active file away if it is what breaks the budget, and if even that is not
    /// enough, drop the line. A gap in a capture is recoverable; a capture that quietly ignores its own
    /// budget is not.
    private func admit(_ incoming: Int, for current: SessionID) -> Bool {
        let fm = FileManager.default
        var entries = ownedEntries().sorted { $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.size }
        var i = 0
        while total + incoming > budgetBytes, i < entries.count {
            let entry = entries[i]
            guard entry.session != current else { i += 1; continue }
            guard (try? fm.removeItem(at: entry.url)) != nil else {
                // Accounted only when it actually happened. Decrementing on a failed removal made
                // enforcement conclude the budget held while every one of those bytes was still on disk.
                i += 1
                continue
            }
            try? handles[entry.session]?.close(); handles[entry.session] = nil
            total -= entry.size
            entries.remove(at: i)
        }
        if total + incoming > budgetBytes, let active = entries.first(where: { $0.session == current }),
           (try? fm.removeItem(at: active.url)) != nil {
            try? handles[current]?.close(); handles[current] = nil
            total -= active.size
        }
        return total + incoming <= budgetBytes
    }
}
