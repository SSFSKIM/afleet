import Foundation
@testable import FleetSessions

/// A value behind a lock. `@unchecked Sendable` because every access to `stored` goes through `lock`.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { self.stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }; return body(&stored)
    }
}
extension LockedBox where T: RangeReplaceableCollection {
    func append(_ element: T.Element) { withLock { $0.append(element) } }
}

/// Passes every call through to Darwin until `arm()`, then makes the next call at `failAt`
/// throw `POSIXError(.EIO)` exactly once. At `.write` the fault lands only after the first
/// 4 KiB of the payload has really been written, so the staging file is partial when the
/// error surfaces. `@unchecked Sendable` because every mutable field is guarded by `lock`.
final class FaultingFileOperations: StoreFileOperations, @unchecked Sendable {
    enum Point: CaseIterable, Sendable { case create, write, fsync, close, rename, fsyncDirectory }

    private let inner = DarwinStoreFileOperations()
    private let lock = NSLock()
    private let failAt: Point
    private var armed = false
    private var removedFiles: [URL] = []

    init(failAt: Point) { self.failAt = failAt }

    func arm() { lock.lock(); armed = true; lock.unlock() }

    var removed: [URL] { lock.lock(); defer { lock.unlock() }; return removedFiles }

    /// True exactly once, for the armed point.
    private func fires(_ point: Point) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed, point == failAt else { return false }
        armed = false
        return true
    }

    func create(in directory: URL, named name: String) throws -> (fd: Int32, url: URL) {
        if fires(.create) { throw POSIXError(.EIO) }
        return try inner.create(in: directory, named: name)
    }
    func write(_ data: Data, to fd: Int32) throws {
        if fires(.write) {
            try inner.write(Data(data.prefix(4096)), to: fd)
            throw POSIXError(.EIO)
        }
        try inner.write(data, to: fd)
    }
    func fsync(_ fd: Int32) throws {
        if fires(.fsync) { throw POSIXError(.EIO) }
        try inner.fsync(fd)
    }
    func close(_ fd: Int32) throws {
        // Like close(2): the descriptor is released even when the call reports an error.
        if fires(.close) { try? inner.close(fd); throw POSIXError(.EIO) }
        try inner.close(fd)
    }
    func rename(_ from: URL, to: URL) throws {
        if fires(.rename) { throw POSIXError(.EIO) }
        try inner.rename(from, to: to)
    }
    func fsyncDirectory(_ directory: URL) throws {
        if fires(.fsyncDirectory) { throw POSIXError(.EIO) }
        try inner.fsyncDirectory(directory)
    }
    func remove(_ file: URL) throws {
        lock.lock(); removedFiles.append(file); lock.unlock()
        try inner.remove(file)
    }
}
