import Foundation
import WireFrames

/// Appends one JSON line per event to <directory>/diagnostics.log; rotates once into diagnostics.log.1 at rotateAt bytes.
///
/// `@unchecked Sendable` is sound here because every mutable field is touched only inside `queue`,
/// a serial queue that is the single owner of the handle and the running size.
public final class FileDiagnostics: DiagnosticsSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "afleet.diagnostics")
    private let directory: URL
    private let rotateAt: Int
    private var handle: FileHandle?
    private var size = 0

    public init(directory: URL, rotateAt: Int = 25 * 1024 * 1024) {
        self.directory = directory
        self.rotateAt = rotateAt
        queue.sync { open() }
    }
    private var logURL: URL { directory.appendingPathComponent("diagnostics.log") }
    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    }
    public func record(_ event: DiagnosticEvent) {
        queue.async { [self] in
            guard var data = try? event.jsonValue.canonicalData() else { return }
            data.append(0x0A)
            if size + data.count > rotateAt { rotate() }
            try? handle?.write(contentsOf: data)
            size += data.count
        }
    }
    private func rotate() {
        try? handle?.close(); handle = nil
        let old = directory.appendingPathComponent("diagnostics.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
        open()
    }
    public func flush() { queue.sync { try? handle?.synchronize() } }
}
