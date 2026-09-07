import Foundation
import FleetKit

/// The one seam every byte afleet itself puts on disk goes through (X9).
///
/// The recursive `ConfigHomeWitness` says *what changed* under a config home. It cannot say *who*
/// changed it: a legitimate `claude` child is writing into the same tree at the same moment, and no
/// filesystem diff distinguishes its write from ours. This is the other half — the app's own write
/// surface, narrow enough to be named and injectable enough to be recorded, so
/// `testNoAppCodePathWritesUnderAConfigHome` can assert that nothing afleet runs ever aimed a write
/// at a config home in the first place.
///
/// Two kinds of report, because the app makes two kinds of write:
///
/// - `willWrite` is a concrete file the app is about to create, write to, rename onto or remove.
/// - `willDelegate` is a directory the app hands to a component in a package below it that will
///   write underneath it — the state store's base directory and the diagnostics directory. Those
///   bytes are written by `FileStateStore` and by the three package sinks, not by app code; choosing
///   the root is the whole of the app's part in them, so the root is what gets reported.
///
/// Production installs `.none`. This is a seam for the test that proves the invariant, in the same
/// way every other seam on `LaunchSequence` exists so a test can assert a call that must *not*
/// happen; a guard that refused a config-home path here would be a second answer to a question
/// `LaunchSequence.overlappingWriteRoot` and `FileStateStore`'s `configHomes:` already answer at the
/// only two places a root is chosen.
struct AppFileWrites: Sendable {
    var willWrite: @Sendable (URL) -> Void
    var willDelegate: @Sendable (URL) -> Void

    init(willWrite: @escaping @Sendable (URL) -> Void, willDelegate: @escaping @Sendable (URL) -> Void) {
        self.willWrite = willWrite
        self.willDelegate = willDelegate
    }

    static let none = AppFileWrites(willWrite: { _ in }, willDelegate: { _ in })
}

/// C4's `StoreFileOperations` with every path it is given reported to `writes` first.
///
/// `write(_:to:)` takes a descriptor and no path, so it reports nothing: the file that descriptor
/// belongs to was reported by the `create` that opened it, which is the only way one is made. The
/// same reasoning covers `fsync`, `close` and `fsyncDirectory`, none of which puts a byte anywhere
/// the `create` did not already name.
struct SeamedStoreFileOperations: StoreFileOperations {
    let inner: any StoreFileOperations
    let writes: AppFileWrites

    init(inner: any StoreFileOperations = DarwinStoreFileOperations(), writes: AppFileWrites) {
        self.inner = inner
        self.writes = writes
    }

    func create(in directory: URL, named name: String) throws -> (fd: Int32, url: URL) {
        writes.willWrite(directory.appendingPathComponent(name))
        return try inner.create(in: directory, named: name)
    }

    func write(_ data: Data, to fd: Int32) throws { try inner.write(data, to: fd) }
    func fsync(_ fd: Int32) throws { try inner.fsync(fd) }
    func close(_ fd: Int32) throws { try inner.close(fd) }

    func rename(_ from: URL, to: URL) throws {
        writes.willWrite(to)
        try inner.rename(from, to: to)
    }

    func fsyncDirectory(_ directory: URL) throws { try inner.fsyncDirectory(directory) }

    func remove(_ file: URL) throws {
        writes.willWrite(file)
        try inner.remove(file)
    }
}
