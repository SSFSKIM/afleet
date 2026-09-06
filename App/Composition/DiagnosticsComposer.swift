import Foundation
import ClaudeWire
import FleetKit

/// One diagnostics directory, three sinks (parent §11, spec §2's *Diagnostics*).
///
/// `DiagnosticEvent`, `FleetDiagnosticEvent` and `TimelineNotice` are three closed enums in three
/// packages that cannot see each other, and C3 recorded that composing them is C5's work. The two
/// that already have file sinks get theirs on the same directory `Fleet` uses; the third — C3's
/// `TimelineNotice` — has none in FleetKit at all, so the app owns one, written in the same shape
/// as the other two so a reader learns one format.
///
/// Every path this type touches is under `directory` and nowhere else. That is the whole of its
/// filesystem contract, and it is what `testDiagnosticsComposerWritesOnlyUnderItsOwnDirectory`
/// asserts: the write-root overlap check in `LaunchSequence` runs first and refuses to construct
/// this at all when `directory` would sit inside a config home (X9).
final class DiagnosticsComposer: Sendable {
    let directory: URL
    /// C2's `diagnostics.log`.
    let wire: FileDiagnostics
    /// FleetKit's `fleet.log`.
    let fleet: FileFleetDiagnostics
    /// The app's own `timeline.log`.
    let timeline: FileTimelineDiagnostics

    init(directory: URL) {
        self.directory = directory
        wire = FileDiagnostics(directory: directory)
        fleet = FileFleetDiagnostics(directory: directory)
        timeline = FileTimelineDiagnostics(directory: directory)
    }

    /// Every line of all three files is on disk when this returns.
    func flush() {
        wire.flush()
        fleet.flush()
        timeline.flush()
    }
}

/// What the last completed index build reported, for Settings' ConfigHome section.
struct IndexBuildSummary: Hashable, Sendable {
    var files: Int
    var symlinkedProjectsSkipped: Int
    var durationMs: Int
}

/// C3's `TimelineNotice` as one JSON line each in `<directory>/timeline.log`, rotating once into
/// `timeline.log.1`, exactly as ClaudeWire's `FileDiagnostics` and FleetKit's `FileFleetDiagnostics`
/// do — one format for the three files beside each other.
///
/// It also remembers the last `indexBuilt`, which is the only notice a screen reads: spec §9 wants
/// the symlinked-project-directories-skipped count on the ConfigHome section, and the build reports
/// it nowhere else.
///
/// `@unchecked Sendable` is sound here because every mutable field is read and written only inside
/// `queue`, a serial `DispatchQueue` that is the single owner of the handle, the running size and
/// the remembered summary. That queue is the serialising mechanism.
final class FileTimelineDiagnostics: TimelineDiagnosticsSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "afleet.timeline-diagnostics")
    private let directory: URL
    private let rotateAt: Int
    private var handle: FileHandle?
    private var size = 0
    private var lastBuild: IndexBuildSummary?

    init(directory: URL, rotateAt: Int = 25 * 1024 * 1024) {
        self.directory = directory
        self.rotateAt = rotateAt
        queue.sync { open() }
    }

    private var logURL: URL { directory.appendingPathComponent("timeline.log") }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        size = (try? manager.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    }

    func record(_ notice: TimelineNotice) {
        queue.async { [self] in
            if case .indexBuilt(let files, let skipped, let durationMs) = notice {
                lastBuild = IndexBuildSummary(files: files, symlinkedProjectsSkipped: skipped,
                                              durationMs: durationMs)
            }
            guard var data = try? Self.line(notice).canonicalData() else { return }
            data.append(0x0A)
            if size + data.count > rotateAt { rotate() }
            try? handle?.write(contentsOf: data)
            size += data.count
        }
    }

    private func rotate() {
        try? handle?.close(); handle = nil
        let old = directory.appendingPathComponent("timeline.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
        open()
    }

    /// Every line written so far is on disk when this returns.
    func flush() { queue.sync { try? handle?.synchronize() } }

    /// The last completed build's report, or nil before the first one lands.
    var lastIndexBuild: IndexBuildSummary? { queue.sync { lastBuild } }

    /// Names, counts, identifiers and timings. `TimelineNotice` carries nothing else by
    /// construction — `LogicalStream` is deliberately absent from every payload because it holds
    /// the config home path — so this rendering is total without dropping a field.
    private static func line(_ notice: TimelineNotice) -> JSONValue {
        var object: [String: JSONValue] = ["at": .string(ISO8601DateFormatter().string(from: Date()))]
        func session(_ id: SessionID) { object["session"] = .string(id.description) }
        func stream(_ name: StreamName) { object["stream"] = .string(name.label) }
        func epoch(_ value: ProcessEpoch) { object["epoch"] = .integer(Int64(value.rawValue)) }

        switch notice {
        case .mirrorErrorSwitchedToFileOnly(let s, let n, let e):
            object["event"] = .string("mirror_error_switched_to_file_only"); session(s); stream(n); epoch(e)
        case .mirrorGap(let s, let n, let missing, let e):
            object["event"] = .string("mirror_gap"); session(s); stream(n)
            object["missing"] = .integer(Int64(missing)); epoch(e)
        case .mirrorRoutedElsewhere(let s, let e):
            object["event"] = .string("mirror_routed_elsewhere"); session(s); epoch(e)
        case .recordSkipped(let s, let n, let kind, let reason, let offset):
            object["event"] = .string("record_skipped"); session(s); stream(n)
            if let kind { object["kind"] = .string(kind) }
            object["reason"] = .string(reason.rawValue)
            object["byte_offset"] = .integer(Int64(offset))
        case .unknownRecordKind(let s, let kind):
            object["event"] = .string("unknown_record_kind"); session(s); object["kind"] = .string(kind)
        case .orphanHealed(let s, let n):
            object["event"] = .string("orphan_healed"); session(s); stream(n)
        case .relocationFollowed(let s):
            object["event"] = .string("relocation_followed"); session(s)
        case .tapAligned(let s, let n, let claimed, let unclaimed):
            object["event"] = .string("tap_aligned"); session(s); stream(n)
            object["claimed"] = .integer(Int64(claimed)); object["unclaimed"] = .integer(Int64(unclaimed))
        case .fileRewritten(let s, let n, let previous, let new):
            object["event"] = .string("file_rewritten"); session(s); stream(n)
            object["previous_length"] = .integer(Int64(previous)); object["new_length"] = .integer(Int64(new))
        case .windowClosureBudgetExhausted(let s, let n, let extensions, let records):
            object["event"] = .string("window_closure_budget_exhausted"); session(s); stream(n)
            object["extensions"] = .integer(Int64(extensions)); object["records"] = .integer(Int64(records))
        case .indexBuilt(let files, let skipped, let durationMs):
            object["event"] = .string("index_built")
            object["files"] = .integer(Int64(files))
            object["symlinked_projects_skipped"] = .integer(Int64(skipped))
            object["duration_ms"] = .integer(Int64(durationMs))
        case .indexUpdated(let changed, let durationMs):
            object["event"] = .string("index_updated")
            object["changed"] = .integer(Int64(changed))
            object["duration_ms"] = .integer(Int64(durationMs))
        }
        return .object(object)
    }
}
