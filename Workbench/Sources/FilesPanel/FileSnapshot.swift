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

    /// `nil` when the path does not exist or cannot be read, which is how a deletion reaches the
    /// policy as `observed: nil`.
    public static func read(_ url: URL) -> FileSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return nil }
        return FileSnapshot(size: data.count, modified: modified, digest: digest(of: data))
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
