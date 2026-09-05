import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The committed golden recordings under `<repo>/Fixtures`, read the way C1 redacted them.
/// Nothing here writes: every path is opened for reading, and no fixture byte is ever asserted
/// against a literal — only names, kinds, counts and shapes are (parent §11, C3 constraints).
enum FixtureCorpus {
    /// `<repo>/Fixtures`, from this file: FleetKit/Tests/FleetTimelineTests/Support/FixtureCorpus.swift → up five.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    /// The config home every recording used; mirror `filePath` values resolve under it.
    static let recordedConfigHome = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
    static let committedCount = 18
    static let committedRecordedCount = 16
    /// Fixtures with at least one mirrored stream, pinned as names so a silent loss fails (spec G1).
    static let mirrored: Set<String> = [
        "ask-user-question", "background-shell", "control-shapes", "exit-plan-mode", "explore-depth-1", "nested-depth-2",
        "notification-hook", "permission-allow", "permission-deny", "plain-two-turn", "rate-limited-turn", "resume-no-replay",
        "send-user-file", "session-mirror-relocation", "session-mirror-resume",
    ]

    struct Fixture {
        let name: String
        let dir: URL
        let synthetic: Bool
        let sessionID: SessionID
        let unmirroredPrefix: Int
        /// scope → field paths (`mirror_identity_only`); the scope key is a path substring.
        let identityOnly: [String: [String]]
        /// `streams.json`: "<slug>/<file>" → byte offset the recording started the stream at.
        let streamOffsets: [String: Int]

        var framesURL: URL { dir.appendingPathComponent("frames.ndjson") }
        var transcriptRoot: URL { dir.appendingPathComponent("transcript") }
        var initialRoot: URL { dir.appendingPathComponent("initial") }
        /// Throwing on purpose: `initialFiles()` throws when the layout drifts, and swallowing that into a
        /// silent `false` would hide the very drift the loader exists to make loud.
        var hasInitial: Bool { get throws { !(try initialFiles()).isEmpty } }

        /// Every JSONL under transcript/, resolved to its stream; `_slug_` is a slug like any other.
        func transcriptFiles() throws -> [(LogicalStream, TranscriptPath, URL)] {
            try FixtureCorpus.resolvedFiles(under: transcriptRoot, suffix: ".jsonl", fixture: name)
        }
        /// Every JSONL under `initial/` — the file as it stood before a resume recording — resolved the same way; empty without the directory.
        func initialFiles() throws -> [(LogicalStream, TranscriptPath, URL)] {
            try FixtureCorpus.resolvedFiles(under: initialRoot, suffix: ".jsonl", fixture: name)
        }
        /// Every `.meta.json` sidecar under transcript/, with the agent stream it belongs to.
        func metaFiles() throws -> [(LogicalStream, URL)] {
            try FixtureCorpus.resolvedFiles(under: transcriptRoot, suffix: ".meta.json", fixture: name).map { ($0.0, $0.2) }
        }
        /// Offset for a stream: streams.json keys are `<slug>/<relative path>`; match on the path's suffix; 0 when no key
        /// matches — a mirror that began with the file, as `session-mirror-relocation`'s empty `streams.json` records.
        func offset(for path: URL) -> Int {
            let p = path.standardizedFileURL.path
            for (key, offset) in streamOffsets where p.hasSuffix("/" + key) || p == key { return offset }
            return 0
        }
        /// The recording's frames in order. `index` is the envelope's position among the file's non-empty lines,
        /// and every non-empty line yields exactly one `RecordedFrame`: a line whose `frame` is missing or is not an
        /// object throws rather than being skipped, so `index` stays a position later tasks can index by.
        func frames() throws -> [RecordedFrame] {
            let text = try String(contentsOf: framesURL, encoding: .utf8)
            var out: [RecordedFrame] = []
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let index = out.count
                let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
                guard let frameValue = envelope["frame"], frameValue.objectValue != nil else {
                    throw Failure("fixture \(name): frames.ndjson line \(index) carries no frame object")
                }
                let raw = try frameValue.canonicalData()
                out.append(RecordedFrame(index: index,
                                         t: Int(envelope["t"]?.intValue ?? 0),
                                         direction: envelope["dir"]?.stringValue ?? "?",
                                         value: frameValue,
                                         frame: FrameDecoder.decode(line: raw)))
            }
            return out
        }
    }

    /// The envelope's `dir` is "in" (host→engine) or "out" (engine→host, the direction the transport receives).
    struct RecordedFrame { let index: Int; let t: Int; let direction: String; let value: JSONValue; let frame: Frame }

    // MARK: - Loading

    /// Every committed fixture, sorted by name. Asserts the pinned count and fails a directory that is missing
    /// `frames.ndjson` or `fixture.json`, so a lost or half-written fixture cannot pass silently.
    static func all() throws -> [Fixture] {
        let names = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
        let fixtures = try names.map { try load($0) }
        XCTAssertEqual(fixtures.count, committedCount, "fixture directory count changed: \(names)")
        XCTAssertEqual(fixtures.filter { !$0.synthetic }.count, committedRecordedCount,
                       "recorded-fixture count changed: \(fixtures.filter(\.synthetic).map(\.name))")
        return fixtures
    }

    static func named(_ name: String) throws -> Fixture { try load(name) }

    private static func load(_ name: String) throws -> Fixture {
        let dir = root.appendingPathComponent(name)
        let metaURL = dir.appendingPathComponent("fixture.json")
        let framesURL = dir.appendingPathComponent("frames.ndjson")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw Failure("fixture \(name) has no fixture.json")
        }
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw Failure("fixture \(name) has no frames.ndjson")
        }
        let meta = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: metaURL))
        guard let idString = meta["session_id"]?.stringValue, let sessionID = SessionID(idString) else {
            throw Failure("fixture \(name) has no usable session_id")
        }
        var offsets: [String: Int] = [:]
        let streamsURL = dir.appendingPathComponent("streams.json")
        if let data = try? Data(contentsOf: streamsURL) {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            for (key, offset) in value.objectValue ?? [:] { offsets[key] = offset.intValue.map(Int.init) ?? 0 }
        }
        var identityOnly: [String: [String]] = [:]
        for (scope, paths) in meta["mirror_identity_only"]?.objectValue ?? [:] {
            identityOnly[scope] = paths.arrayValue?.compactMap(\.stringValue) ?? []
        }
        return Fixture(name: name,
                       dir: dir,
                       synthetic: meta["synthetic"]?.boolValue ?? false,
                       sessionID: sessionID,
                       unmirroredPrefix: meta["unmirrored_prefix"]?.intValue.map(Int.init) ?? 0,
                       identityOnly: identityOnly,
                       streamOffsets: offsets)
    }

    /// A fixture's `transcript/<slug>/…` layout IS the config home's `projects/<slug>/…` layout, so a file is resolved
    /// by rewriting its fixture-relative path onto `recordedConfigHome/projects/` and asking `TranscriptPath.resolve`.
    private static func resolvedFiles(under base: URL, suffix: String, fixture: String) throws -> [(LogicalStream, TranscriptPath, URL)] {
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let basePath = base.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(LogicalStream, TranscriptPath, URL)] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasSuffix(suffix) else { continue }
            // `.meta.json` also ends in `.json`, and `.jsonl` never ends in `.meta.json`, so the suffixes are disjoint.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(path.dropFirst(basePath.count + 1))
            let aliased = recordedConfigHome.appendingPathComponent("projects").appendingPathComponent(relative)
            guard let (stream, kind) = TranscriptPath.resolve(aliased, under: recordedConfigHome) else {
                throw Failure("fixture \(fixture): \(relative) does not resolve to a stream")
            }
            out.append((stream, kind, url))
        }
        return out.sorted { $0.2.path < $1.2.path }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
