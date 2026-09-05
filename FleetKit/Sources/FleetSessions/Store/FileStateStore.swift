import Foundation
import Darwin

/// One JSON document per namespace under `baseDirectory`, `state.<namespace>.json`, with the
/// envelope `{"schemaVersion": N, "values": {"<key>": <json>}}`. Every write re-serialises the
/// whole namespace document into a staging file in the same directory and renames it into
/// place through `StoreFileOperations`, so a reader never sees a partial document (X6).
public actor FileStateStore: StateStore {
    public static let schemaVersion = 1

    private let baseDirectory: URL
    private let fileOperations: any StoreFileOperations
    private let onDiagnostic: @Sendable (StoreDiagnostic) -> Void

    /// The loaded values of each namespace touched so far. Absent means "not loaded yet"; a
    /// failed write clears the entry so the actor never believes a write that did not land.
    private var documents: [StoreNamespace: [String: Any]] = [:]
    private var statuses: [StoreNamespace: SchemaStatus] = [:]
    /// Each namespace announces its schema situation once, on the first touch.
    private var announced: Set<StoreNamespace> = []

    /// The only construction. Resolves every path through `realpath(3)` and refuses a base
    /// directory that equals or lies under any of `configHomes`, however it is spelled (X9).
    public init(baseDirectory: URL,
                configHomes: [URL],
                fileOperations: any StoreFileOperations = DarwinStoreFileOperations(),
                onDiagnostic: @escaping @Sendable (StoreDiagnostic) -> Void = { _ in }) throws {
        let basePath = Self.resolve(baseDirectory)
        for home in configHomes {
            let homePath = Self.resolve(home)
            if basePath == homePath || basePath.hasPrefix(homePath + "/") {
                throw StoreError.insideConfigHome
            }
        }
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: basePath) {
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw StoreError.io(Self.message(error, step: "createDirectory"))
            }
        }
        self.baseDirectory = base
        self.fileOperations = fileOperations
        self.onDiagnostic = onDiagnostic
    }

    // MARK: - StateStore

    public func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) throws -> T? {
        guard !key.isEmpty else { throw StoreError.emptyKey }
        try load(namespace)
        guard let raw = documents[namespace]?[key] else { return nil }
        return try Self.decode(T.self, from: raw)
    }

    public func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) throws {
        guard !key.isEmpty else { throw StoreError.emptyKey }
        try load(namespace)
        try refuseIfNewer(namespace)
        var values = documents[namespace] ?? [:]
        values[key] = try Self.encode(value)
        try persist(namespace, values: values)
        documents[namespace] = values
        statuses[namespace] = .current
    }

    public func remove(namespace: StoreNamespace, key: String) throws {
        guard !key.isEmpty else { throw StoreError.emptyKey }
        try load(namespace)
        try refuseIfNewer(namespace)
        var values = documents[namespace] ?? [:]
        guard values.removeValue(forKey: key) != nil else { return }
        try persist(namespace, values: values)
        documents[namespace] = values
        statuses[namespace] = .current
    }

    public func keys(in namespace: StoreNamespace) throws -> [String] {
        try load(namespace)
        return (documents[namespace] ?? [:]).keys.sorted()
    }

    /// What this build made of the namespace's document. The app turns `.newer` into the banner.
    public func schemaStatus(of namespace: StoreNamespace) -> SchemaStatus {
        if statuses[namespace] == nil { try? load(namespace) }
        return statuses[namespace] ?? .absent
    }

    // MARK: - The document

    private func documentURL(_ namespace: StoreNamespace) -> URL {
        baseDirectory.appendingPathComponent("state.\(namespace.rawValue).json")
    }

    private func refuseIfNewer(_ namespace: StoreNamespace) throws {
        if case .newer(let found) = statuses[namespace] ?? .absent {
            throw StoreError.schemaTooNew(found: found, supported: Self.schemaVersion)
        }
    }

    /// Decides the namespace's schema situation on the first touch and caches its values.
    private func load(_ namespace: StoreNamespace) throws {
        guard documents[namespace] == nil else { return }
        let url = documentURL(namespace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            documents[namespace] = [:]
            note(namespace, .absent)
            return
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw StoreError.io(Self.message(error, step: "read \(namespace.rawValue)")) }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let found = envelope["schemaVersion"] as? Int,
              let values = envelope["values"] as? [String: Any]
        else {
            try moveAside(namespace, at: url)
            documents[namespace] = [:]
            note(namespace, .absent)
            return
        }

        if found == Self.schemaVersion {
            documents[namespace] = values
            note(namespace, .current)
        } else if found > Self.schemaVersion {
            documents[namespace] = values     // the keys this build understands stay readable
            note(namespace, .newer(found: found))
        } else {
            var migrated = values
            var version = found
            while version < Self.schemaVersion {
                guard let step = Migrations.step(for: namespace, from: version) else {
                    throw StoreError.io("no migration for \(namespace.rawValue) schema \(version)")
                }
                migrated = step(migrated)
                version += 1
            }
            documents[namespace] = migrated
            note(namespace, .migrated(from: found))
        }
    }

    /// A document that does not parse, or parses without the envelope, is kept for the user and
    /// the namespace starts empty. The move goes through the seam like every other mutation.
    private func moveAside(_ namespace: StoreNamespace, at url: URL) throws {
        let stamp = DateFormatter.malformedStamp.string(from: Date())
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".malformed-\(stamp)")
        do { try fileOperations.rename(url, to: aside) }
        catch { throw StoreError.io(Self.message(error, step: "moveAside \(namespace.rawValue)")) }
        if announced.insert(namespace).inserted {
            onDiagnostic(.malformedMovedAside(namespace: namespace))
        }
    }

    private func note(_ namespace: StoreNamespace, _ status: SchemaStatus) {
        statuses[namespace] = status
        guard announced.insert(namespace).inserted else { return }
        switch status {
        case .newer(let found): onDiagnostic(.newerSchema(namespace: namespace, found: found))
        case .migrated(let from): onDiagnostic(.migrated(namespace: namespace, from: from))
        case .current, .absent: break
        }
    }

    /// create -> write -> fsync -> close -> rename -> fsync(directory), every step through the
    /// seam. Any failure closes a still-open descriptor, removes the staging file best-effort
    /// and drops the cached document, so the next operation re-reads what actually landed.
    private func persist(_ namespace: StoreNamespace, values: [String: Any]) throws {
        let envelope: [String: Any] = ["schemaVersion": Self.schemaVersion, "values": values]
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) }
        catch { throw StoreError.io(Self.message(error, step: "serialise \(namespace.rawValue)")) }

        let name = ".state.\(namespace.rawValue).json.tmp-\(UUID().uuidString)"
        var staging = baseDirectory.appendingPathComponent(name)
        var unclosed: Int32?
        var renamed = false
        do {
            let created = try fileOperations.create(in: baseDirectory, named: name)
            unclosed = created.fd
            staging = created.url
            try fileOperations.write(data, to: created.fd)
            try fileOperations.fsync(created.fd)
            // close(2) invalidates the descriptor whether or not it reports an error, so it is
            // never retried: a second close would name whatever the kernel handed out next.
            unclosed = nil
            try fileOperations.close(created.fd)
            try fileOperations.rename(staging, to: documentURL(namespace))
            renamed = true
            try fileOperations.fsyncDirectory(baseDirectory)
        } catch {
            if let fd = unclosed { try? fileOperations.close(fd) }
            if !renamed { try? fileOperations.remove(staging) }
            documents[namespace] = nil
            throw StoreError.io(Self.message(error, step: "persist \(namespace.rawValue)"))
        }
    }

    // MARK: - Values

    /// Values ride in the namespace document as raw JSON. The one-element array keeps every
    /// value, including a scalar, inside a container both coders accept.
    private static func encode<T: Encodable>(_ value: T) throws -> Any {
        let data: Data
        do { data = try JSONEncoder().encode([value]) }
        catch { throw StoreError.io(Self.message(error, step: "encode")) }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = array.first else {
            throw StoreError.io("encode: unexpected shape")
        }
        return first
    }

    private static func decode<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: [raw]) }
        catch { throw StoreError.io(Self.message(error, step: "decode")) }
        do { return try JSONDecoder().decode([T].self, from: data)[0] }
        catch { throw StoreError.io(Self.message(error, step: "decode")) }
    }

    // MARK: - Containment

    /// Resolves the longest existing prefix of `path` with `realpath(3)` and re-appends the rest,
    /// so a path through a symlinked ancestor is compared as what it really names. Strings, not
    /// URLs: `URL.standardizedFileURL` rewrites `/private/var` back to `/var` and would undo the
    /// resolution on exactly the temporary directories the tests use.
    private static func resolve(_ url: URL) -> String {
        var trailing: [String] = []
        var probe = url.standardizedFileURL.path
        while true {
            if let resolved = realpath(probe, nil) {
                var out = String(cString: resolved)
                free(resolved)
                for component in trailing.reversed() {
                    out = (out as NSString).appendingPathComponent(component)
                }
                return out
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { return url.standardizedFileURL.path }
            trailing.append((probe as NSString).lastPathComponent)
            probe = parent
        }
    }

    /// Shapes only: an error's kind and the step it failed at, never a path or a record's contents.
    private static func message(_ error: any Error, step: String) -> String {
        if let posix = error as? POSIXError { return "\(step): \(posix.code)" }
        if let store = error as? StoreError { return "\(step): \(store)" }
        return "\(step): \(type(of: error))"
    }
}

/// One step per (namespace, from-version), each taking a namespace's values one version forward.
/// Version 0 is the reserved pre-release version and its step to 1 is the identity; it exists so
/// the chain is real before the first migration that changes anything.
enum Migrations {
    static func step(for namespace: StoreNamespace, from version: Int) -> (([String: Any]) -> [String: Any])? {
        switch version {
        case 0: return { $0 }
        default: return nil
        }
    }
}

extension DateFormatter {
    static let malformedStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
