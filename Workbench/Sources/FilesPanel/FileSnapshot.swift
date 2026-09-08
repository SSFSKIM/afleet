// C7.5 spec Design §8: what the watcher observes and what the policy compares.
import Foundation
import CryptoKit

/// What one look at a file on disk saw: its size, its modification time, and a digest of its
/// contents. The digest is what the policy compares — size and time describe the observation and
/// are carried for the session's own bookkeeping, not for the decision.
public struct FileSnapshot: Sendable, Equatable, Hashable {

    public let size: Int
    public let modified: Date
    public let digest: String

    public init(size: Int, modified: Date, digest: String) {
        self.size = size
        self.modified = modified
        self.digest = digest
    }

    /// `nil` when the path does not exist, is not a regular file, cannot be read, or is **above
    /// the cap** — which is how a deletion reaches the policy as `observed: nil`, and how a file
    /// the panel already refuses to open (`FileKind.of`) stays unread here too.
    ///
    /// `unchangedFrom` is the observation this one is being compared against. `stat(2)` comes
    /// first, and the contents are read only when the size or the modification time moved: a poll
    /// tick over an open file is otherwise a whole-file read and a SHA-256 for every file, every
    /// interval. When they did not move, `previous` is returned unchanged, so the caller's own
    /// equality answers "nothing happened" without the bytes ever being touched. The shortcut's
    /// cost is the write that keeps both — a swap of the same number of bytes with the
    /// modification time put back — which no watcher on this file system observes for free.
    public static func read(_ url: URL,
                            unchangedFrom previous: FileSnapshot? = nil,
                            maximumBytes: Int = FileKind.maximumReadableBytes) -> FileSnapshot? {
        guard let seen = observe(url) else { return nil }
        if let previous, previous.size == seen.size, previous.modified == seen.modified {
            return previous
        }
        guard seen.size <= maximumBytes, let data = contents(of: url, upTo: maximumBytes) else {
            return nil
        }
        return FileSnapshot(size: data.count, modified: seen.modified, digest: digest(of: data))
    }

    /// A regular file's size and modification time, or `nil` for anything else — the same
    /// `stat(2)` question `FileKind` asks, so the two agree about what a path names.
    private static func observe(_ url: URL) -> (size: Int, modified: Date)? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (Int(info.st_size), modified)
    }

    /// The file's bytes, or `nil` when it grew past the cap between the `stat` and the read.
    private static func contents(of url: URL, upTo maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1) else { return nil }
        return data.count > maximumBytes ? nil : data
    }

    /// The snapshot a save *will* produce, from the bytes it is about to write. Spec §8 records
    /// `lastWritten` before the rename lands, so the echo cannot arrive before the record of it;
    /// that record cannot come from the file system, only from the bytes.
    public static func predicted(contents: Data, at moment: Date = Date()) -> FileSnapshot {
        FileSnapshot(size: contents.count, modified: moment, digest: digest(of: contents))
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Contents only: two snapshots of the same bytes at different times are the same contents.
    public func hasSameContents(as other: FileSnapshot) -> Bool { digest == other.digest }
}
