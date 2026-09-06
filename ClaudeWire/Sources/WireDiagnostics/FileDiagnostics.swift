import Foundation
import WireFrames

/// Appends one JSON line per event to <directory>/diagnostics.log; rotates once into diagnostics.log.1 at rotateAt bytes.
///
/// The file is opened `O_APPEND` for each write and closed again rather than held open for the sink's life. The
/// app's *Delete diagnostics* unlinks the log while the sink lives on, and `Fleet` builds its sink internally, so
/// nothing can reach in to reopen a stale handle: a held handle would go on writing into an unlinked inode and the
/// user's next diagnostics would be lost to a file with no name. Under `O_APPEND` the kernel places every write at
/// the current end and a deleted log is simply recreated. Diagnostics are low-volume metadata, so the open and
/// close per line cost nothing worth engineering around.
///
/// `@unchecked Sendable` is sound here because every write happens inside `queue`, a serial queue that is the
/// single owner of the file.
public final class FileDiagnostics: DiagnosticsSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "afleet.diagnostics")
    private let directory: URL
    private let rotateAt: Int

    public init(directory: URL, rotateAt: Int = 25 * 1024 * 1024) {
        self.directory = directory
        self.rotateAt = rotateAt
        queue.sync { createDirectory() }
    }
    private var logURL: URL { directory.appendingPathComponent("diagnostics.log") }
    private func createDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
    /// The log's size on disk right now. There is no tracked offset to consult: the file may have been unlinked and
    /// recreated since the last write, in which case the answer is zero.
    private var currentSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    }
    public func record(_ event: DiagnosticEvent) {
        queue.async { [self] in
            guard var data = try? event.jsonValue.canonicalData() else { return }
            data.append(0x0A)
            if currentSize + data.count > rotateAt { rotate() }
            append(data)
        }
    }
    /// One line, appended to whatever `diagnostics.log` names at this moment, creating it if it is gone.
    private func append(_ data: Data) {
        var fd = Darwin.open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        if fd < 0 {   // the directory went with the log
            createDirectory()
            fd = Darwin.open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    private func rotate() {
        let old = directory.appendingPathComponent("diagnostics.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }
    /// Every line recorded before this call is on disk when it returns: the `sync` drains the queue and the
    /// `synchronize` flushes the file those lines went to.
    public func flush() {
        queue.sync {
            let fd = Darwin.open(logURL.path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
