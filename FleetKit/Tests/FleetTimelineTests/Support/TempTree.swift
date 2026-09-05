import Foundation
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// A config-home-shaped tree under `FileManager.default.temporaryDirectory`, assembled from fixture snapshots and
/// invented bytes. It is never a Claude Code config home: nothing here reads or writes `~/.claude` or
/// `$CLAUDE_CONFIG_DIR` (parent X9). The tree is removed when the instance goes away.
final class TempTree {
    /// The config-home root: `<tmp>/afleet-c3-<uuid>/`, with `projects/` already created.
    let root: URL
    var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-c3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: - Placing files

    /// Copy a fixture's whole `transcript/` tree under `projects/`, sidecars included, renaming the recorded slug
    /// placeholder `_slug_` to `slug`. Returns the main transcript's URL (the `<sessionId>.jsonl` directly under it).
    @discardableResult
    func add(_ fixture: FixtureCorpus.Fixture, slug: String) throws -> URL {
        let manager = FileManager.default
        for entry in try manager.contentsOfDirectory(at: fixture.transcriptRoot, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent == "_slug_" ? slug : entry.lastPathComponent
            let destination = projects.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: entry, to: destination)
        }
        let main = projects.appendingPathComponent(slug).appendingPathComponent("\(fixture.sessionID).jsonl")
        guard manager.fileExists(atPath: main.path) else {
            throw FixtureCorpus.Failure("fixture \(fixture.name): no main transcript at projects/<slug>/<sessionId>.jsonl")
        }
        return main
    }

    /// Place invented bytes as a main transcript: `projects/<slug>/<session>.jsonl`.
    @discardableResult
    func write(_ data: Data, session: SessionID, slug: String) throws -> URL {
        let directory = projects.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(session).jsonl")
        try data.write(to: url)
        return url
    }

    // MARK: - Mutating a placed file

    /// A *repeat*: the file's last line copied back with a fresh uuid, newline-terminated. Never new content, so a
    /// touched file carries no byte the recording did not already carry.
    @discardableResult
    func touch(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let last = LineScanner.scan(data).lines.last else {
            throw FixtureCorpus.Failure("touch: \(url.lastPathComponent) has no complete line to repeat")
        }
        var line = last.bytes
        if var object = (try? JSONDecoder().decode(JSONValue.self, from: line))?.objectValue {
            if object["uuid"] != nil { object["uuid"] = .string(UUID().uuidString.lowercased()) }
            line = (try? JSONValue.object(object).canonicalData()) ?? line
        }
        var appended = line
        appended.append(UInt8(ascii: "\n"))
        try appendRaw(appended, to: url)
        return appended
    }

    func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    func setModificationDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Move a session's main file and its `<sessionId>/` sidecar directory from one slug to another, the way the engine
    /// does when a session's cwd changes.
    func relocate(session: SessionID, from: String, to: String) throws {
        let manager = FileManager.default
        let destination = projects.appendingPathComponent(to, isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["\(session).jsonl", "\(session)"] {
            let source = projects.appendingPathComponent(from).appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: source, to: target)
        }
    }

    @discardableResult
    func symlink(_ link: URL, to target: URL) throws -> URL {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    /// The engine's `k(…)`: every non-alphanumeric byte of a path becomes `-`. (2.1.258 line 13843. The engine also
    /// truncates at 200 characters with a base-36 hash suffix, `KA`; no test needs a path that long yet.)
    static func slug(for path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
    func slug(for path: String) -> String { Self.slug(for: path) }
}
