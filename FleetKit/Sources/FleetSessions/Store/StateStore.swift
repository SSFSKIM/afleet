import Foundation
import Darwin

/// Closed: a namespace is a package, and there are three (X6). A fourth is a spec change, not a call site.
public enum StoreNamespace: String, CaseIterable, Hashable, Codable, Sendable { case fleetKit, workbench, afleet }

public enum StoreError: Error, Equatable, Sendable {
    case schemaTooNew(found: Int, supported: Int)
    case insideConfigHome
    case emptyKey
    case io(String)                      // the underlying error's description; never a path
}

/// What the store reports about a namespace's document; the app turns `.newer` into the banner.
public enum SchemaStatus: Hashable, Sendable { case current, migrated(from: Int), newer(found: Int), absent }

public enum StoreDiagnostic: Hashable, Sendable {
    case malformedMovedAside(namespace: StoreNamespace)
    case migrated(namespace: StoreNamespace, from: Int)
    case newerSchema(namespace: StoreNamespace, found: Int)
}

/// The seam every byte the store writes goes through. Production is Darwin's calls; the atomicity test injects faults.
public protocol StoreFileOperations: Sendable {
    /// Creates `directory/name` with `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`, mode 0o600, and returns the open descriptor and the URL.
    func create(in directory: URL, named name: String) throws -> (fd: Int32, url: URL)
    func write(_ data: Data, to fd: Int32) throws            // the whole payload, looping on short writes
    func fsync(_ fd: Int32) throws
    func close(_ fd: Int32) throws
    func rename(_ from: URL, to: URL) throws
    func fsyncDirectory(_ directory: URL) throws
    func remove(_ file: URL) throws
}

public struct DarwinStoreFileOperations: StoreFileOperations {
    public init() {}

    public func create(in directory: URL, named name: String) throws -> (fd: Int32, url: URL) {
        let url = directory.appendingPathComponent(name)
        let fd = url.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw Self.posix() }
        return (fd, url)
    }

    public func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.posix()
                }
                offset += n
            }
        }
    }

    public func fsync(_ fd: Int32) throws {
        guard Darwin.fsync(fd) == 0 else { throw Self.posix() }
    }

    public func close(_ fd: Int32) throws {
        guard Darwin.close(fd) == 0 else { throw Self.posix() }
    }

    public func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw Self.posix() }
    }

    public func fsyncDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else { throw Self.posix() }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw Self.posix() }
    }

    public func remove(_ file: URL) throws {
        guard Darwin.unlink(file.path) == 0 else { throw Self.posix() }
    }

    private static func posix() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// X6. Keys are non-empty strings; a dot is an ordinary character and implies no hierarchy.
/// One schema version per namespace; nothing else is versioned.
public protocol StateStore: Sendable {
    func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T?
    func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws
    func remove(namespace: StoreNamespace, key: String) async throws
    func keys(in namespace: StoreNamespace) async throws -> [String]
    /// Adds one string to the array at `key`, keeping it a set, in a single step on the store.
    ///
    /// A protocol member rather than a read and a write at the call site: those are two hops onto the store, and a
    /// second appender that lands between them writes a list that never saw the first one's element. The shorts of
    /// afleet's own background jobs are appended from one supervisor per handoff, and two handoffs at once is an
    /// ordinary thing for this app.
    func appendUnique(_ element: String, namespace: StoreNamespace, key: String) async throws
}
