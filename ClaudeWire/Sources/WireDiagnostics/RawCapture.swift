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
        guard var redacted = Redactor.redact(line: line) else { return }
        redacted.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let file = directory.appendingPathComponent("\(session.description).ndjson")
        if handles[session] == nil {
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            handles[session] = try? FileHandle(forWritingTo: file)
            _ = try? handles[session]?.seekToEnd()
        }
        try? handles[session]?.write(contentsOf: redacted)
        enforceBudget(protecting: session)
    }
    public func prune(keeping: Set<SessionID>) {
        for (session, handle) in handles where !keeping.contains(session) { try? handle.close(); handles[session] = nil }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard name.hasSuffix(".ndjson"), let id = SessionID(String(name.dropLast(7))), !keeping.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
    private func enforceBudget(protecting current: SessionID) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        // A plain loop rather than `compactMap`: under language mode 6 the closure would capture the
        // non-Sendable `FileManager` out of actor isolation and the compiler rejects it.
        //
        // Only `.ndjson` files are counted or deleted, matching what `prune` owns. The two used to disagree,
        // and a budget loop that deletes a file the type does not own is a worse bug than an exceeded budget.
        var entries: [(URL, Date, Int)] = []
        for n in names where n.hasSuffix(".ndjson") {
            let u = directory.appendingPathComponent(n)
            guard let a = try? fm.attributesOfItem(atPath: u.path) else { continue }
            entries.append((u, (a[.modificationDate] as? Date) ?? .distantPast, (a[.size] as? Int) ?? 0))
        }
        entries.sort { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        // Oldest first, but *skipping* the session being written rather than stopping at it: stopping left
        // the budget exceeded for as long as that session stayed the oldest file, which is the normal case
        // for a long-lived session and would have made the budget a suggestion.
        let protected = "\(current.description).ndjson"
        var i = 0
        while total > budgetBytes, i < entries.count {
            let entry = entries[i]
            guard entry.0.lastPathComponent != protected else { i += 1; continue }
            if let id = SessionID(String(entry.0.lastPathComponent.dropLast(7))) { try? handles[id]?.close(); handles[id] = nil }
            try? fm.removeItem(at: entry.0)
            total -= entry.2
            entries.remove(at: i)
        }
    }
}
