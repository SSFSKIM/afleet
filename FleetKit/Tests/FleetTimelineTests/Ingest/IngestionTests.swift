import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

// MARK: - Test doubles

/// The channel's tap as a test drives it: an unbounded `AsyncStream<WireEvent>` plus the three shapes this actor cares
/// about. `terminated` is set from the continuation's `onTermination`, which fires when the consuming task stops
/// iterating — the signal `testAFailedOpenEndsTheConsumingTaskAndFinishesEffects` waits on.
private final class SyntheticTap: @unchecked Sendable {
    let events: AsyncStream<WireEvent>
    private let continuation: AsyncStream<WireEvent>.Continuation
    private let flag = Flag()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    init() {
        (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        let flag = self.flag
        continuation.onTermination = { _ in flag.set() }
    }

    var terminated: Bool { flag.isSet }
    func send(_ frame: Frame, epoch: ProcessEpoch = .first) { continuation.yield(.frame(frame, epoch)) }
    func send(event: WireEvent) { continuation.yield(event) }
    func exited(epoch: ProcessEpoch = .first) { continuation.yield(.exited(.code(0, stderrTail: ""), epoch)) }
    func finish() { continuation.finish() }
}

/// Everything `StreamIngestion.effects` yielded, consumed by one task so a test never has to hold an iterator across
/// an await. `next(within:)` polls under a bound and returns nil rather than hanging: a test that hangs is worse than
/// one that fails.
private final class EffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StreamIngestion.Effect] = []
    private var consumed = 0
    private var done = false
    private var task: Task<Void, Never>?

    init(_ ingestion: StreamIngestion) {
        let effects = ingestion.effects
        task = Task { [self] in
            for await effect in effects { lock.withLock { items.append(effect) } }
            lock.withLock { done = true }
        }
    }
    deinit { task?.cancel() }

    var all: [StreamIngestion.Effect] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
    var finished: Bool { lock.withLock { done } }

    private func pop() -> StreamIngestion.Effect? {
        lock.withLock {
            guard consumed < items.count else { return nil }
            defer { consumed += 1 }
            return items[consumed]
        }
    }

    func next(within bound: TimeInterval) async -> StreamIngestion.Effect? {
        let deadline = Date().addingTimeInterval(bound)
        while true {
            if let effect = pop() { return effect }
            if Date() >= deadline { return pop() }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct Bail: Error { let what: String }

// MARK: - The tests

final class IngestionTests: XCTestCase {

    // MARK: Fixtures and framing

    /// The recorded config home rewritten onto a `TempTree`, slug for slug. Only the envelope's `filePath` changes; the
    /// entries are the recording's own bytes.
    private func rehome(_ frame: TranscriptMirrorFrame, to root: URL) -> Frame {
        var rewritten = frame
        rewritten.filePath = frame.filePath.replacingOccurrences(
            of: FixtureCorpus.recordedConfigHome.standardizedFileURL.path,
            with: root.standardizedFileURL.path)
        return .transcriptMirror(rewritten)
    }

    /// A recording's `transcript_mirror` frames in `t` order.
    private func mirrorFrames(_ fx: FixtureCorpus.Fixture) throws -> [TranscriptMirrorFrame] {
        try fx.frames().sorted { $0.t == $1.t ? $0.index < $1.index : $0.t < $1.t }
            .compactMap { if case .transcriptMirror(let m) = $0.frame { return m } else { return nil } }
    }

    /// A frame the test builds: the real decoder over a real envelope, so nothing here bypasses `FrameDecoder`.
    private func mirrorFrame(path: URL, entries: [JSONValue]) throws -> Frame {
        let value = JSONValue.object(["type": .string("transcript_mirror"),
                                      "filePath": .string(path.standardizedFileURL.path),
                                      "entries": .array(entries)])
        return FrameDecoder.decode(line: try value.canonicalData())
    }

    private func entry(_ line: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: line)
    }

    private func lines(of url: URL) throws -> [Data] {
        try Data(contentsOf: url)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    /// Where the fixture's mirror says its main transcript lives, rewritten onto the tree. The recorded slug is kept:
    /// the mirror's own `filePath` is what the actor resolves, so the file has to sit where the mirror says it does.
    private func mirroredMainPath(_ fx: FixtureCorpus.Fixture, in tree: TempTree) throws -> URL {
        for frame in try mirrorFrames(fx) {
            let path = URL(fileURLWithPath: frame.filePath)
            guard let (stream, kind) = TranscriptPath.resolve(path, under: FixtureCorpus.recordedConfigHome),
                  stream.sessionID == fx.sessionID, case .mainTranscript = kind else { continue }
            return URL(fileURLWithPath: frame.filePath.replacingOccurrences(
                of: FixtureCorpus.recordedConfigHome.standardizedFileURL.path,
                with: tree.root.standardizedFileURL.path))
        }
        throw Bail(what: "fixture \(fx.name): no mirror frame names a main transcript")
    }

    private func stream(_ tree: TempTree, _ session: SessionID, _ name: StreamName = .main) -> LogicalStream {
        LogicalStream(configHome: tree.root, sessionID: session, name: name)
    }

    private func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: Assertion helpers

    // XCTest's assertions take non-async autoclosures, and every query on this actor is `await`. These wrappers are
    // the same assertions with the awaits evaluated first; nothing else about them differs.

    private func expectEqual<T: Equatable>(_ a: @autoclosure () async throws -> T,
                                           _ b: @autoclosure () async throws -> T,
                                           _ message: @autoclosure () -> String = "",
                                           file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b()
        XCTAssertEqual(x, y, message(), file: file, line: line)
    }
    private func expectNotEqual<T: Equatable>(_ a: @autoclosure () async throws -> T,
                                              _ b: @autoclosure () async throws -> T,
                                              _ message: @autoclosure () -> String = "",
                                              file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b()
        XCTAssertNotEqual(x, y, message(), file: file, line: line)
    }
    private func expectNil<T>(_ a: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                              file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a()
        XCTAssertNil(x, message(), file: file, line: line)
    }
    private func expectNotNil<T>(_ a: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                                 file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a()
        XCTAssertNotNil(x, message(), file: file, line: line)
    }
    private func expectTrue(_ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a()
        XCTAssertTrue(x, message(), file: file, line: line)
    }
    private func expectFalse(_ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a()
        XCTAssertFalse(x, message(), file: file, line: line)
    }
    private func expectGreaterThan<T: Comparable>(_ a: @autoclosure () async throws -> T,
                                                  _ b: @autoclosure () async throws -> T,
                                                  _ message: @autoclosure () -> String = "",
                                                  file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b()
        XCTAssertGreaterThan(x, y, message(), file: file, line: line)
    }
    private func expectLessThan<T: Comparable>(_ a: @autoclosure () async throws -> T,
                                               _ b: @autoclosure () async throws -> T,
                                               _ message: @autoclosure () -> String = "",
                                               file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b()
        XCTAssertLessThan(x, y, message(), file: file, line: line)
    }
    private func expectUnwrap<T>(_ a: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let x = try await a()
        return try XCTUnwrap(x, message(), file: file, line: line)
    }

    /// A key printed without its `LogicalStream`, which carries the config home path (C3 constraint 12).
    private func labels(_ keys: [RecordKey]) -> [String] {
        keys.map { key in
            switch key.identity {
            case .uuid(let uuid): return "uuid:\(uuid)"
            case .hash(let hash, let ordinal): return "hash:\(hash.prefix(12))#\(ordinal)"
            }
        }
    }

    private func next(_ log: EffectLog, _ what: String, within bound: TimeInterval = 2,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> StreamIngestion.Effect {
        guard let effect = await log.next(within: bound) else {
            XCTFail("no effect within \(bound)s: \(what)", file: file, line: line)
            throw Bail(what: what)
        }
        return effect
    }

    @discardableResult
    private func send(_ tap: SyntheticTap, _ frame: Frame, epoch: ProcessEpoch = .first, _ log: EffectLog,
                      _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws
        -> StreamIngestion.Effect {
        tap.send(frame, epoch: epoch)
        return try await next(log, what, file: file, line: line)
    }

    /// The record reducer's merged projection over a fixture's `transcript/` files, restated under a tree's config
    /// home so the two sides' `ItemID`s are comparable.
    private func fileProjection(_ fx: FixtureCorpus.Fixture, in tree: TempTree) throws -> DurableProjection {
        var projections: [StreamProjection] = []
        var metadata: [StreamName: AgentMetadataRecord] = [:]
        for (stream, url) in try fx.metaFiles() {
            // The sidecar carries no `type` key; the mirror's own entry is the same body with `agent_metadata` added.
            guard var object = (try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))).objectValue
            else { continue }
            if object["type"] == nil { object["type"] = .string("agent_metadata") }
            guard case .agentMetadata(let record, _) = RecordDecoder.decode(entry: .object(object)) else { continue }
            metadata[stream.name] = record
        }
        for (stream, _, url) in try fx.transcriptFiles() {
            let local = self.stream(tree, fx.sessionID, stream.name)
            let records = try TranscriptReader(url: url).readAll().records
            var projection = RecordReducer.reduce(records, stream: local, sourceFile: url)
            projection.metadata = metadata[stream.name]
            projections.append(projection)
        }
        return RecordReducer.merge(projections, main: stream(tree, fx.sessionID))
    }

    // MARK: - G3: relocation

    func testRelocationReplaysWithNoDuplicateAndNoMissingRecord() async throws {
        let fx = try FixtureCorpus.named("session-mirror-relocation")
        let frames = try mirrorFrames(fx)
        XCTAssertEqual(frames.count, 15, "the relocation recording's mirror frame count")
        XCTAssertEqual(frames.reduce(0) { $0 + $1.entries.count }, 53, "the relocation recording's mirrored entries")
        XCTAssertEqual(fx.offset(for: try XCTUnwrap(try fx.transcriptFiles().first?.2)), 0,
                       "streams.json is empty, so the mirror began with the file")

        let source = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let complete = try Data(contentsOf: source)
        let fileKeys = try RecordKey.keys(for: TranscriptReader(url: source).readAll().records,
                                          in: LogicalStream(configHome: FixtureCorpus.recordedConfigHome,
                                                            sessionID: fx.sessionID, name: .main))

        // The two paths the recording mirrors one stream under.
        var paths: [String] = []
        for frame in frames where !paths.contains(frame.filePath) { paths.append(frame.filePath) }
        XCTAssertEqual(paths.count, 2, "the recording mirrors one stream under two filePath values")
        let oldSlug = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().lastPathComponent
        let newSlug = URL(fileURLWithPath: paths[1]).deletingLastPathComponent().lastPathComponent

        // Half one: the file starts empty at the original slug and every mirrored entry arrives before it is written.
        do {
            let tree = try TempTree()
            let oldPath = tree.projects.appendingPathComponent(oldSlug).appendingPathComponent("\(fx.sessionID).jsonl")
            let newPath = tree.projects.appendingPathComponent(newSlug).appendingPathComponent("\(fx.sessionID).jsonl")
            try place(Data(), at: oldPath)
            let main = stream(tree, fx.sessionID)

            let notices = RecordingTimelineDiagnostics()
            let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary,
                                            diagnostics: notices)
            let log = EffectLog(ingestion)
            let tap = SyntheticTap()
            try await ingestion.open(file: oldPath, events: tap.events)

            var relocated = false
            var applied = 0
            for frame in frames {
                if frame.filePath == paths[1], !relocated {
                    try FileManager.default.createDirectory(at: newPath.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try tree.relocate(session: fx.sessionID, from: oldSlug, to: newSlug)
                    await ingestion.relocated(mainPath: newPath)
                    relocated = true
                }
                let effect = try await send(tap, rehome(frame, to: tree.root), log, "relocation mirror frame")
                applied += effect.applied.count
                XCTAssertEqual(effect.duplicates, 0, "nothing is on disk yet, so no mirrored entry is a duplicate")
            }
            XCTAssertTrue(relocated, "the recording never named the second path")
            XCTAssertEqual(applied, 53, "every mirrored entry is applied once")

            try append(complete, to: newPath)
            let confirm = await ingestion.fileChanged(newPath)
            _ = try await next(log, "the file catching up after the relocation")
            XCTAssertEqual(confirm.duplicates, 53,
                           "the file confirms all 53: 28 uuid records by uuid, 25 uuid-less by occurrence")
            XCTAssertEqual(labels(confirm.applied), [], "the file introduces no record the mirror had not delivered")

            let held = await ingestion.applied(main)
            XCTAssertEqual(labels(held.map(\.key)), labels(fileKeys),
                           "the stream's keys equal a whole-file read's, repeats included")
            XCTAssertEqual(held.filter { $0.locator == nil }.count, 0, "every applied key has a locator")
            XCTAssertEqual(Set(held.compactMap(\.locator)).count, held.count, "the locators are distinct")

            // The last `relocated` line, read back through the new path.
            let lastRelocated = try await expectUnwrap(await lastRelocatedKey(ingestion), "no `relocated` record applied")
            let raw = try await ingestion.rawRecord(for: lastRelocated)
            XCTAssertEqual(raw["type"]?.stringValue, "relocated")
            await expectEqual(await ingestion.paths[main], newPath, "the path follows the relocation")
            await ingestion.close()
        }

        // Half two: the file first, under `mirrorPrimary`, then the same mirror frames.
        do {
            let tree = try TempTree()
            let oldPath = tree.projects.appendingPathComponent(oldSlug).appendingPathComponent("\(fx.sessionID).jsonl")
            let newPath = tree.projects.appendingPathComponent(newSlug).appendingPathComponent("\(fx.sessionID).jsonl")
            try place(Data(), at: oldPath)
            let main = stream(tree, fx.sessionID)

            let notices = RecordingTimelineDiagnostics()
            let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                            diagnostics: notices)
            let log = EffectLog(ingestion)
            let tap = SyntheticTap()
            try await ingestion.open(file: oldPath, events: tap.events)

            try FileManager.default.createDirectory(at: newPath.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try tree.relocate(session: fx.sessionID, from: oldSlug, to: newSlug)
            await ingestion.relocated(mainPath: newPath)
            try append(complete, to: newPath)
            let read = await ingestion.fileChanged(newPath)
            _ = try await next(log, "the whole file arriving before any mirror frame")
            XCTAssertEqual(read.applied.count, 53, "the file delivered every record first")

            var duplicates = 0
            for frame in frames {
                duplicates += try await send(tap, rehome(frame, to: tree.root), log, "mirror after the file").duplicates
            }
            XCTAssertEqual(duplicates, 53, "every mirrored entry is a counted duplicate of a line already applied")
            await expectEqual(labels(await ingestion.applied(main).map(\.key)), labels(fileKeys),
                           "the same keys whichever source arrived first")
            XCTAssertFalse(notices.notices.contains { if case .mirrorGap = $0 { return true } else { return false } },
                           "the mirror confirmed every record, so no gap")
            await ingestion.close()
        }
    }

    private func lastRelocatedKey(_ ingestion: StreamIngestion) async -> RecordKey? {
        for hidden in await ingestion.projection.hidden.reversed() where hidden.kind == "relocated" {
            return hidden.key
        }
        return nil
    }

    // MARK: - G3: resume

    func testResumeCarriesTheOffsetAndTheFileClosesTheUnmirroredRecord() async throws {
        let fx = try FixtureCorpus.named("session-mirror-resume")
        XCTAssertEqual(fx.unmirroredPrefix, 1, "the resume recording declares one unmirrored record")
        let frames = try mirrorFrames(fx)
        XCTAssertEqual(frames.count, 3)
        let mirrored = frames.reduce(0) { $0 + $1.entries.count }
        XCTAssertEqual(mirrored, 8, "the resume recording's mirrored entries")

        let initialURL = try XCTUnwrap(try fx.initialFiles().first?.2)
        let finalURL = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let initial = try Data(contentsOf: initialURL)
        let complete = try Data(contentsOf: finalURL)
        XCTAssertEqual(fx.offset(for: finalURL), initial.count,
                       "streams.json records the length the mirror resumed at")

        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try place(initial, at: mainPath)
        let main = stream(tree, fx.sessionID)

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)
        await expectEqual(await ingestion.offsets[main], initial.count, "the open read carried the resume offset")

        for frame in frames {
            _ = try await send(tap, rehome(frame, to: tree.root), log, "resume mirror frame")
        }
        let fileKeys = try RecordKey.keys(for: TranscriptReader(url: finalURL).readAll().records, in: main)
        let beforeFile = await ingestion.applied(main).map(\.key)
        XCTAssertEqual(beforeFile.count, fileKeys.count - 1,
                       "one record — the unmirrored `atis-latch` — is still missing versus transcript/")

        try append(complete.suffix(from: initial.count), to: mainPath)
        let effect = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file closing the unmirrored record")
        XCTAssertEqual(effect.duplicates, 8,
                       "matching is per hash and per unclaimed occurrence, so the unmirrored line displaces none")
        XCTAssertEqual(effect.applied.count, 1, "the file introduces exactly the record the mirror never carried")
        await expectEqual(labels(await ingestion.applied(main).map(\.key)), labels(fileKeys))
        await ingestion.close()
    }

    // MARK: - G4: the mirror alone

    func testMirrorAloneDrivesTheReducer() async throws {
        let names = FixtureCorpus.mirrored.subtracting(["session-mirror-resume", "resume-no-replay"]).sorted()
        XCTAssertEqual(names.count, 13, "the fully mirrored fixtures")
        for name in names {
            let fx = try FixtureCorpus.named(name)
            let tree = try TempTree()
            let mainPath = try mirroredMainPath(fx, in: tree)
            try place(Data(), at: mainPath)
            let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
            let log = EffectLog(ingestion)
            let tap = SyntheticTap()
            try await ingestion.open(file: mainPath, events: tap.events)
            for frame in try mirrorFrames(fx) {
                _ = try await send(tap, rehome(frame, to: tree.root), log, "\(name): mirror frame")
            }

            let expected = try fileProjection(fx, in: tree)
            let produced = await ingestion.projection
            XCTAssertEqual(ProjectionComparison.compare(wire: produced, file: expected), [],
                           "\(name): the mirror alone reduces to what the files reduce to")
            for (stream, _, url) in try fx.transcriptFiles() {
                let local = self.stream(tree, fx.sessionID, stream.name)
                let keys = try RecordKey.keys(for: TranscriptReader(url: url).readAll().records, in: local)
                await expectEqual(labels(await ingestion.applied(local).map(\.key)), labels(keys),
                               "\(name)/\(stream.name.label): the mirror delivered every record once")
            }
            await ingestion.close()
        }

        // The counter-case: a resume mirrors only what follows its offset, so one record is only ever on disk.
        let fx = try FixtureCorpus.named("session-mirror-resume")
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        let initialURL = try XCTUnwrap(try fx.initialFiles().first?.2)
        try place(try Data(contentsOf: initialURL), at: mainPath)
        let main = stream(tree, fx.sessionID)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)
        for frame in try mirrorFrames(fx) {
            _ = try await send(tap, rehome(frame, to: tree.root), log, "resume mirror frame")
        }
        let finalURL = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let fileKeys = try RecordKey.keys(for: TranscriptReader(url: finalURL).readAll().records, in: main)
        let produced = await ingestion.applied(main).map(\.key)
        XCTAssertNotEqual(labels(produced), labels(fileKeys), "the resume's mirror cannot reconstruct the whole file")
        XCTAssertEqual(produced.count, fileKeys.count - 1, "exactly one record short")
        await ingestion.close()
    }

    // MARK: - G4: mirror errors

    func testMirrorErrorSwitchesToFileOnlyForTheEpoch() async throws {
        // Shape-verified, not engine-verified: no committed fixture carries a `mirror_error`, so the frame is C2's own
        // sample at ClaudeWire/Tests/Support/Samples/system_mirror_error.json, decoded through `FrameDecoder`.
        let sample = FixtureCorpus.root.deletingLastPathComponent()
            .appendingPathComponent("ClaudeWire/Tests/Support/Samples/system_mirror_error.json")
        let frame = FrameDecoder.decode(line: try Data(contentsOf: sample))
        guard case .system(.mirrorError) = frame else {
            return XCTFail("C2's sample no longer decodes to system/mirror_error")
        }

        let turn = SyntheticTranscript.queuedTurnLines(turn: 1)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let mainPath = try tree.write(Data(), session: session, slug: "synthetic")
        let main = stream(tree, session)

        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary,
                                        diagnostics: notices)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        let switched = try await send(tap, frame, log, "the mirror error")
        XCTAssertEqual(switched.stateChange, .fileOnly(since: .first))
        await expectEqual(await ingestion.state, .fileOnly(since: .first))
        XCTAssertEqual(notices.notices.filter {
            if case .mirrorErrorSwitchedToFileOnly = $0 { return true } else { return false }
        }.count, 1, "one notice, once")

        let ignored = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(turn[0])]), log,
                                     "a mirror frame under the failed epoch")
        XCTAssertEqual(labels(ignored.applied), [], "the mirror is not a source under this epoch")
        await expectEqual(await ingestion.applied(main).count, 0)

        try append(turn[0], to: mainPath)
        let fromFile = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file under fileOnly")
        XCTAssertEqual(fromFile.applied.count, 1, "the file still applies")

        let nextEpoch = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(turn[1])]),
                                       epoch: ProcessEpoch.first.next(), log, "a mirror frame under the next epoch")
        XCTAssertEqual(nextEpoch.stateChange, .both, "a greater epoch is a replaced process")
        XCTAssertEqual(nextEpoch.applied.count, 1)
        await expectEqual(await ingestion.state, .both)
        await ingestion.close()
    }

    // MARK: - The mirror gap

    func testMirrorGapUnderMirrorPrimarySwitchesToFileOnly() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(50))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        try tree.touch(mainPath)
        let watched = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the watcher's own effect")
        XCTAssertEqual(watched.applied.count, 1, "one appended record, applied from the file")
        XCTAssertNil(watched.stateChange, "the deadline has not passed yet")

        let swept = try await next(log, "the mirror-gap deadline's own effect")
        XCTAssertEqual(labels(swept.applied), [], "the sweep applies nothing")
        XCTAssertEqual(swept.stateChange, .fileOnly(since: .first))
        await expectEqual(await ingestion.state, .fileOnly(since: .first))
        let gaps = notices.notices.compactMap { notice -> Int? in
            if case .mirrorGap(_, _, let missing, _) = notice { return missing } else { return nil }
        }
        XCTAssertEqual(gaps, [1], "exactly one gap, for the one record the mirror never delivered")
        await ingestion.close()
    }

    func testATimelyMirrorClearsThePendingGap() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(50))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // Two invented `queue-operation` lines, each with its own timestamp. A repeat of a line the file already holds
        // would be a second occurrence of one hash, and the occurrence rule lets a mirror entry claim the earlier one.
        let first = SyntheticTranscript.queuedTurnLines(turn: 7)[1]
        try append(first, to: mainPath)
        _ = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the first watcher change")
        let confirmed = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(first)]), log,
                                       "the mirror inside the window")
        XCTAssertEqual(confirmed.duplicates, 1, "the mirror confirmed the record the watcher applied")

        try await Task.sleep(for: .milliseconds(100))       // past the window: the armed sweep runs and finds nothing

        let second = SyntheticTranscript.queuedTurnLines(turn: 8)[1]
        try append(second, to: mainPath)
        _ = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the second watcher change")
        let confirmedAgain = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(second)]), log,
                                            "the second mirror inside the window")
        XCTAssertEqual(confirmedAgain.duplicates, 1)

        await expectEqual(await ingestion.state, .both, "nothing was ever pending past the window")
        XCTAssertFalse(notices.notices.contains { if case .mirrorGap = $0 { return true } else { return false } })
        XCTAssertEqual(log.all.count, 4, "two calls and two frames, and the sweep found nothing to report")
        XCTAssertTrue(log.all.allSatisfy { $0.stateChange == nil })
        await ingestion.close()
    }

    // MARK: - Routing, lazy streams, exit

    func testARoutedElsewhereMirrorIsCountedNotApplied() async throws {
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let other = try XCTUnwrap(SessionID("44444444-4444-4444-8444-444444444444"))
        let tree = try TempTree()
        let mainPath = try tree.write(Data(), session: session, slug: "synthetic")
        let elsewhere = tree.projects.appendingPathComponent("synthetic").appendingPathComponent("\(other).jsonl")

        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary,
                                        diagnostics: notices)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        let turn = SyntheticTranscript.queuedTurnLines(turn: 1)
        let effect = try await send(tap, try mirrorFrame(path: elsewhere, entries: [try entry(turn[0])]), log,
                                    "a mirror frame for another session")
        XCTAssertEqual(effect.routedElsewhere, 1)
        XCTAssertEqual(labels(effect.applied), [])
        await expectEqual(await ingestion.applied(stream(tree, session)).count, 0)
        XCTAssertEqual(notices.notices.filter {
            if case .mirrorRoutedElsewhere = $0 { return true } else { return false }
        }.count, 1)
        await ingestion.close()
    }

    func testLazyAgentStreamsOpenFromTheMirror() async throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try place(Data(), at: mainPath)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)
        for frame in try mirrorFrames(fx) {
            _ = try await send(tap, rehome(frame, to: tree.root), log, "nested-depth-2 mirror frame")
        }

        let streams = await ingestion.openStreams
        XCTAssertEqual(streams.count, 3, "the main stream and the two agents the mirror named")
        let agents = streams.filter { if case .agent = $0.name { return true } else { return false } }
        XCTAssertEqual(agents.count, 2)
        for agent in agents {
            await expectNotNil(await ingestion.metadata(of: agent), "\(agent.name.label): the mirror's agent_metadata")
        }
        await ingestion.close()
    }

    func testProcessExitedReconcilesFromTheFile() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let frames = try mirrorFrames(fx)
        XCTAssertEqual(frames.count, 8)
        let source = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let complete = try Data(contentsOf: source)

        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try place(Data(), at: mainPath)
        let main = stream(tree, fx.sessionID)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        let sent = frames.dropLast(2)
        for frame in sent { _ = try await send(tap, rehome(frame, to: tree.root), log, "mirror before the exit") }
        let delivered = sent.reduce(0) { $0 + $1.entries.count }
        await expectEqual(await ingestion.applied(main).count, delivered)

        try append(complete, to: mainPath)
        tap.exited(epoch: .first)
        let effect = try await next(log, "the exit's reconciliation")
        let fileKeys = try RecordKey.keys(for: TranscriptReader(url: source).readAll().records, in: main)
        XCTAssertEqual(effect.applied.count, fileKeys.count - delivered,
                       "the exit applies exactly what the mirror never delivered")
        XCTAssertEqual(effect.duplicates, delivered, "and confirms everything it did")
        await expectEqual(labels(await ingestion.applied(main).map(\.key)), labels(fileKeys))
        await ingestion.close()
    }

    /// Under `mirrorPrimary`, the exit reconciliation must leave nothing pending: the process it closes out will never
    /// mirror anything again, so a record it applies is not a mirror gap. Without that, the entries sit until the next
    /// `fileChanged` arms the sweep and then expire together, switching the state for a gap that is not one.
    func testProcessExitedLeavesNothingPendingForTheMirrorGap() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let source = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let complete = try Data(contentsOf: source)

        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try place(Data(), at: mainPath)
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(50))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // The whole file arrives with no mirror frame at all, and the exit reconciles it.
        try append(complete, to: mainPath)
        tap.exited(epoch: .first)
        let reconciled = try await next(log, "the exit's reconciliation")
        XCTAssertGreaterThan(reconciled.applied.count, 0, "the exit applied what the mirror never delivered")

        // A later watcher change is what arms the sweep. Its own record is confirmed inside the window, so the only
        // thing a sweep could find is what the exit left behind.
        let line = SyntheticTranscript.queuedTurnLines(turn: 9)[1]
        try append(line, to: mainPath)
        _ = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the watcher change after the exit")
        let confirmed = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(line)]), log,
                                       "the mirror confirming that one record")
        XCTAssertEqual(confirmed.duplicates, 1)

        try await Task.sleep(for: .milliseconds(120))       // well past the window
        await expectEqual(await ingestion.state, .both, "the exited process's records are not a mirror gap")
        XCTAssertFalse(notices.notices.contains { if case .mirrorGap = $0 { return true } else { return false } },
                       "no gap notice for a process that has already exited")
        await ingestion.close()
    }

    /// The other half of the same rule, for what was already pending. `trackPending: false` keeps the exit's *own*
    /// read out of the map; a record the watcher applied a moment earlier is already in it, with the sweep armed, and
    /// the process that would have confirmed it has now exited. Left alone it expires into a `mirrorGap` and switches
    /// a healthy channel to `fileOnly`.
    func testTheExitClearsAPendingMirrorGapFromBeforeIt() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(400))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // One unmirrored watcher append, remembered and swept for in 400 ms.
        try tree.touch(mainPath)
        let watched = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the watcher's own effect")
        XCTAssertEqual(watched.applied.count, 1, "one appended record, applied from the file")
        XCTAssertNil(watched.stateChange, "the deadline has not passed yet")

        // The process exits well inside the window: the mirror that would have confirmed that record is gone.
        tap.exited(epoch: .first)
        _ = try await next(log, "the exit's reconciliation")

        try await Task.sleep(for: .milliseconds(700))       // well past the window the append armed
        await expectEqual(await ingestion.state, .both, "an exited process's unconfirmed record is not a gap")
        XCTAssertFalse(notices.notices.contains { if case .mirrorGap = $0 { return true } else { return false } },
                       "no gap notice for a record the exit already accounted for")
        XCTAssertTrue(log.all.allSatisfy { $0.stateChange == nil }, "no effect carried a state change")
        await ingestion.close()
    }

    /// After a `mirror_error` the mirror is refused as a source for the epoch (`applyMirror` returns at once), so a
    /// record the watcher applies afterwards can never be confirmed. Remembering it anyway means every file append
    /// under `fileOnly` eventually reports a `mirrorGap` for a mirror everybody already knows is gone.
    func testFileOnlyStopsRememberingFileAppendsForTheGapSweep() async throws {
        let sample = FixtureCorpus.root.deletingLastPathComponent()
            .appendingPathComponent("ClaudeWire/Tests/Support/Samples/system_mirror_error.json")
        let errorFrame = FrameDecoder.decode(line: try Data(contentsOf: sample))
        guard case .system(.mirrorError) = errorFrame else {
            return XCTFail("C2's sample no longer decodes to system/mirror_error")
        }

        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(400))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // One append before the error — remembered, sweep armed — and the error inside that window.
        try tree.touch(mainPath)
        _ = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the watcher change before the error")
        let switched = try await send(tap, errorFrame, log, "the mirror error")
        XCTAssertEqual(switched.stateChange, .fileOnly(since: .first))

        // And one append after it, which the mirror can no longer confirm either.
        try tree.touch(mainPath)
        let after = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the watcher change after the error")
        XCTAssertEqual(after.applied.count, 1, "the file is still a source under fileOnly")

        try await Task.sleep(for: .milliseconds(700))       // well past the window either append would have armed
        let gaps = notices.notices.filter { if case .mirrorGap = $0 { return true } else { return false } }
        XCTAssertEqual(gaps.count, 0, "file-only reports the switch once, not a gap per append after it")
        await expectEqual(await ingestion.state, .fileOnly(since: .first), "and the state is the one it already was")
        await ingestion.close()
    }

    /// The bounded window belongs to the main stream: `loadEarlier()` and the published `WindowMarker` name
    /// `mainStream` and nothing else. An agent transcript read to a tail would therefore have a beginning no caller
    /// could ever ask for, so agent transcripts are read whole whatever the policy says.
    ///
    /// The corpus's agent transcripts do not close a tail window by themselves — their `user` records are tool
    /// results, so the closure rule walks back to offset 0 and reads them whole by accident. To make the window
    /// actually close mid-file, the fixture's own first line is appended again with an invented uuid and no
    /// `parentUuid`: a turn start that is its own chain root, which is exactly what the rule closes on. No byte here
    /// is new — it is the recording's line with one field replaced, the same mutation `TempTree.touch` makes.
    func testAnAgentTranscriptIsReadWholeUnderATightWindowPolicy() async throws {
        let fx = try FixtureCorpus.named("explore-depth-1")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "explore")

        let subagents = tree.projects.appendingPathComponent("explore").appendingPathComponent("\(fx.sessionID)")
            .appendingPathComponent("subagents")
        let agentPaths = try FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(agentPaths.count, 1, "explore-depth-1 has one agent transcript beside its main file")
        let agentPath = try XCTUnwrap(agentPaths.first)

        let firstLine = try XCTUnwrap(LineScanner.scan(try Data(contentsOf: agentPath)).lines.first).bytes
        var object = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: firstLine).objectValue)
        XCTAssertEqual(object["type"]?.stringValue, "user", "the agent transcript opens on its prompt")
        object["uuid"] = .string("00000000-0000-4000-8000-00000000a9e0")
        object["parentUuid"] = .null
        var closingLine = try JSONValue.object(object).canonicalData()
        closingLine.append(UInt8(ascii: "\n"))
        try tree.appendRaw(closingLine, to: agentPath)

        // Small enough that this policy's tail is a fraction of the file, and the appended turn start closes it.
        let tight = WindowPolicy(wholeFileUpTo: 0, initialTail: 2048, earlierStep: 2048)
        let windowed = try WindowedTranscript.read(TranscriptReader(url: agentPath), policy: tight)
        let onDisk = try TranscriptReader(url: agentPath).readAll().records
        XCTAssertLessThan(windowed.records.count, onDisk.count,
                          "the tight policy really does cut this agent transcript short")

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        _ = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events, policy: tight)

        let agentStreams = await ingestion.openStreams.filter { if case .agent = $0.name { true } else { false } }
        let agent = try XCTUnwrap(agentStreams.first)
        await expectEqual(await ingestion.applied(agent).count, onDisk.count,
                          "every record of the agent transcript was read, not just its tail")
        await expectEqual(labels(await ingestion.applied(agent).map(\.key)),
                          labels(RecordKey.keys(for: onDisk, in: agent)))

        // The main stream is still windowed: this is a per-stream policy, not a policy the actor ignores.
        let main = stream(tree, fx.sessionID)
        let mainOnDisk = try TranscriptReader(url: mainPath).readAll().records
        await expectTrue(await ingestion.applied(main).count < mainOnDisk.count,
                         "the main stream still honours the tight window")
        await ingestion.close()
    }

    /// A stream whose file this actor has never seen learned every record it holds from a mirror entry. Labelling it
    /// `.file`, and naming a file that does not exist, is what `Provenance.origin` exists to prevent — and it left
    /// `.mirror` unreachable.
    func testAMirrorOnlyStreamCarriesMirrorProvenance() async throws {
        let turn = SyntheticTranscript.queuedTurnLines(turn: 1)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let directory = tree.projects.appendingPathComponent("synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mainPath = directory.appendingPathComponent("\(session).jsonl")

        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)
        await expectEqual(await ingestion.state, .mirrorOnly)

        _ = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(turn[0]), try entry(turn[1])]),
                           log, "the mirror before the file exists")
        let fromMirror = await ingestion.projection
        XCTAssertFalse(fromMirror.items.isEmpty, "the mirror alone produced items")
        XCTAssertEqual(Set(fromMirror.items.map(\.provenance.origin)), [.mirror],
                       "every item of a stream with no file on disk came by the mirror")
        XCTAssertEqual(fromMirror.items.compactMap(\.provenance.sourceFile), [],
                       "and none of them names a file that does not exist")

        var data = Data()
        for line in turn.prefix(3) { data.append(line) }
        try data.write(to: mainPath)
        _ = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file appearing")
        let onDisk = await ingestion.projection
        XCTAssertEqual(Set(onDisk.items.map(\.provenance.origin)), [.file],
                       "once the file exists the same records are the file's")
        XCTAssertEqual(Set(onDisk.items.compactMap(\.provenance.sourceFile)), [mainPath.standardizedFileURL])
        await ingestion.close()
    }

    /// `open` awaits the tap falling quiet, and C6 awaits `open`. An engine emitting mirror frames faster than
    /// `tapSettle` must therefore not stall the channel: the settle wait is capped and the alignment runs on whatever
    /// is buffered.
    func testOpenReturnsWhileTheTapKeepsGrowing() async throws {
        let turn = SyntheticTranscript.queuedTurnLines(turn: 1)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let mainPath = try tree.write(Data(), session: session, slug: "synthetic")

        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary,
                                        tapSettle: .milliseconds(5))
        _ = EffectLog(ingestion)
        let tap = SyntheticTap()
        let frame = try mirrorFrame(path: mainPath, entries: [try entry(turn[0])])

        let stop = SyntheticTap.Flag()
        let feeder = Task {
            // Five times faster than `tapSettle`, so the tap never falls quiet for a whole round and the cap is the
            // only thing that can let `open` go — but not so fast that the buffer grows to a size no engine produces.
            while !stop.isSet {
                tap.send(frame)
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let returned = SyntheticTap.Flag()
        let opener = Task {
            _ = try? await ingestion.open(file: mainPath, events: tap.events)
            returned.set()
        }
        let deadline = Date().addingTimeInterval(10)
        while !returned.isSet, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        stop.set()
        feeder.cancel()
        opener.cancel()
        XCTAssertTrue(returned.isSet, "open returned rather than waiting for a tap that never falls quiet")
        await ingestion.close()
    }

    // MARK: - Notices

    func testNoticesCarryNoPathsOrPayload() async throws {
        let notices = RecordingTimelineDiagnostics()
        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let main = stream(tree, fx.sessionID)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .mirrorPrimary,
                                        diagnostics: notices, mirrorGapWindow: .milliseconds(50))
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()

        // A buffered frame (tapAligned), a relocation, a routed-elsewhere frame, a gap and a rewrite: five kinds.
        let firstLine = try XCTUnwrap(try lines(of: mainPath).first)
        tap.send(try mirrorFrame(path: mainPath, entries: [try entry(firstLine)]))
        try await ingestion.open(file: mainPath, events: tap.events)
        _ = try await next(log, "the buffered frame")

        let other = try XCTUnwrap(SessionID("44444444-4444-4444-8444-444444444444"))
        _ = try await send(tap, try mirrorFrame(
            path: tree.projects.appendingPathComponent("plain").appendingPathComponent("\(other).jsonl"),
            entries: [try entry(firstLine)]), log, "a routed-elsewhere frame")

        try tree.relocate(session: fx.sessionID, from: "plain", to: "moved")
        let moved = tree.projects.appendingPathComponent("moved").appendingPathComponent("\(fx.sessionID).jsonl")
        await ingestion.relocated(mainPath: moved)
        try tree.touch(moved)
        _ = await ingestion.fileChanged(moved)
        _ = try await next(log, "the watcher change after the relocation")
        _ = try await next(log, "the gap sweep")

        // A rewrite: the same inode, shorter.
        let kept = try lines(of: moved).dropFirst(4)
        var rewritten = Data()
        for line in kept { rewritten.append(line); rewritten.append(UInt8(ascii: "\n")) }
        let handle = try FileHandle(forWritingTo: moved)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: rewritten)
        try handle.close()
        _ = await ingestion.fileChanged(moved)
        _ = try await next(log, "the rewrite")
        _ = main

        let kinds = Set(notices.notices.map { String(describing: $0).prefix(while: { $0 != "(" }) })
        XCTAssertTrue(kinds.count >= 5, "the scenario produced \(kinds.count) notice kinds: \(kinds.sorted())")

        let uuid = try Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        for notice in notices.notices {
            let described = String(describing: notice)
            XCTAssertFalse(described.contains("/"), "a notice carries a path component: \(kindName(notice))")
            for match in described.matches(of: uuid) {
                XCTAssertEqual(String(described[match.range]).lowercased(), fx.sessionID.description,
                               "a notice carries a uuid that is not the session id: \(kindName(notice))")
            }
        }
        await ingestion.close()
    }

    private func kindName(_ notice: TimelineNotice) -> String {
        String(String(describing: notice).prefix(while: { $0 != "(" }))
    }

    // MARK: - The raw view

    func testRawRecordReadsAnAttachmentByLocatorAndAMirrorOnlyMetaRecordFromMemory() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "plain")
        let main = stream(tree, fx.sessionID)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        let raw = try lines(of: mainPath)
        let attachmentIndex = try XCTUnwrap(raw.firstIndex { RecordDecoder.decode(line: $0).kind == "attachment" })
        let attachment = RecordDecoder.decode(line: raw[attachmentIndex])
        let attachmentKey = RecordKey(stream: main, identity: .uuid(try XCTUnwrap(attachment.uuid)))
        try await expectEqual(try await ingestion.rawRecord(for: attachmentKey), try entry(raw[attachmentIndex]),
                       "the attachment's own line, read through its locator")
        await expectNotNil(await ingestion.projection.hidden(attachmentKey)?.locator)

        // A `user` record the mirror delivers and the file does not hold yet. Invented uuid, invented text.
        let parent = try XCTUnwrap(raw.reversed().compactMap { RecordDecoder.decode(line: $0).uuid }.first)
        let inventedUUID = "00000000-0000-4000-8000-0000000009f1"
        let metaLine = Data(#"{"type":"user","uuid":"\#(inventedUUID)","parentUuid":"\#(parent)","isSidechain":false,"isMeta":true,"sessionId":"\#(fx.sessionID)","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"invented meta record"}}"#.utf8)
        let metaKey = RecordKey(stream: main, identity: .uuid(inventedUUID))
        let applied = try await send(tap, try mirrorFrame(path: mainPath, entries: [try entry(metaLine)]), log,
                                     "a mirror-only meta record")
        XCTAssertEqual(labels(applied.applied), labels([metaKey]))
        let served = try await ingestion.rawRecord(for: metaKey)
        XCTAssertEqual(served["uuid"]?.stringValue, inventedUUID)
        await expectNil(await ingestion.projection.hidden(metaKey)?.locator, "the file has not shown it yet")

        var appended = metaLine
        appended.append(UInt8(ascii: "\n"))
        try append(appended, to: mainPath)
        let confirm = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file catching up with the mirror-only record")
        XCTAssertEqual(confirm.duplicates, 1)
        await expectNotNil(await ingestion.projection.hidden(metaKey)?.locator, "the locator is bound now")
        try await expectEqual(try await ingestion.rawRecord(for: metaKey), served, "the raw record is unchanged")

        let unknown = RecordKey(stream: main, identity: .uuid("00000000-0000-4000-8000-00000000ffff"))
        do {
            _ = try await ingestion.rawRecord(for: unknown)
            XCTFail("an unknown key must throw")
        } catch let error as StreamIngestion.RawRecordError {
            XCTAssertEqual(error, .unknownKey)
        }
        await ingestion.close()
    }

    // MARK: - G3: multiplicity

    func testRepeatedUUIDLessLinesAreAppliedOnceEach() async throws {
        let fx = try FixtureCorpus.named("session-mirror-resume")
        let source = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let complete = try Data(contentsOf: source)
        let fileLines = try lines(of: source)
        let records = try TranscriptReader(url: source).readAll().records
        let uuidless = records.filter { $0.uuid == nil }
        XCTAssertEqual(uuidless.count, 36, "the resume fixture's uuid-less lines")
        XCTAssertLessThan(Set(uuidless.compactMap(\.contentHash)).count, 36, "some of them repeat byte for byte")

        // Opened whole.
        do {
            let tree = try TempTree()
            let mainPath = try mirroredMainPath(fx, in: tree)
            try place(complete, at: mainPath)
            let main = stream(tree, fx.sessionID)
            let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
            _ = EffectLog(ingestion)
            let tap = SyntheticTap()
            try await ingestion.open(file: mainPath, events: tap.events)
            let held = await ingestion.applied(main)
            let hashKeys = held.filter { if case .hash = $0.key.identity { return true } else { return false } }
            XCTAssertEqual(hashKeys.count, 36, "each repeat is its own key")
            XCTAssertEqual(Set(hashKeys.map(\.key)).count, 36)
            XCTAssertEqual(Set(held.compactMap(\.locator)).count, held.count, "the locators are distinct")
            let expected = RecordReducer.reduce(records, stream: main, sourceFile: mainPath)
            await expectEqual(ProjectionComparison.compare(wire: await ingestion.projection,
                                                        file: RecordReducer.merge([expected], main: main)), [])
            await ingestion.close()
        }

        // Mirror-only from an empty file, then the file written in place.
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try place(Data(), at: mainPath)
        let main = stream(tree, fx.sessionID)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        var duplicates = 0
        for chunk in stride(from: 0, to: fileLines.count, by: 8) {
            let slice = fileLines[chunk..<min(chunk + 8, fileLines.count)]
            let effect = try await send(tap, try mirrorFrame(path: mainPath, entries: try slice.map(entry)), log,
                                        "a frame of the file's own lines")
            duplicates += effect.duplicates
        }
        XCTAssertEqual(duplicates, 0, "nothing was on disk, so nothing is a duplicate")
        let fileKeys = RecordKey.keys(for: records, in: main)
        let mirrored = await ingestion.applied(main).map(\.key)
        XCTAssertEqual(labels(mirrored), labels(fileKeys), "the mirror alone numbers every repeat as the file does")

        try append(complete, to: mainPath)
        let confirm = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file confirming every line")
        XCTAssertEqual(confirm.duplicates, fileLines.count, "every line binds its locator to the mirror's key")
        XCTAssertEqual(labels(confirm.applied), [], "no new key appears")
        await expectEqual(labels(await ingestion.applied(main).map(\.key)), labels(fileKeys))
        await ingestion.close()
    }

    // MARK: - G3: straddles

    /// `[u1, q1, q2, s1, a1, p1]`: a `user`, two `queue-operation`s, a `file-history-snapshot`, an `assistant` and a
    /// `last-prompt`. Turn 2 is `[u2, q3, q4, s2, a2, p2]`.
    private func straddleSetup(fileLines: Int, turn: Int = 1) throws -> (tree: TempTree, path: URL, lines: [Data],
                                                                        session: SessionID) {
        let lines = SyntheticTranscript.queuedTurnLines(turn: turn)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        var data = Data()
        for line in lines.prefix(fileLines) { data.append(line) }
        let path = try tree.write(data, session: session, slug: "synthetic")
        return (tree, path, lines, session)
    }

    func testAStraddleWithAUUIDAnchorClaimsTheLinesTheOpenRead() async throws {
        let setup = try straddleSetup(fileLines: 5)
        let main = stream(setup.tree, setup.session)
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: setup.session, configHome: setup.tree.root, mode: .filePrimary,
                                        diagnostics: notices)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()

        // The write-then-emit straddle: the read holds the frame's first four entries, and the frame's uuid anchor
        // `a1` follows its three uuid-less ones.
        tap.send(try mirrorFrame(path: setup.path, entries: try setup.lines[1...5].map(entry)))
        try await ingestion.open(file: setup.path, events: tap.events)

        let first = try await next(log, "the buffered frame's own effect")
        XCTAssertEqual(first.duplicates, 4, "q1, q2 and s1 between the read's start and the anchor, plus a1 by uuid")
        XCTAssertEqual(first.applied.count, 1, "only p1 lies past the read")
        XCTAssertEqual(alignments(notices), [.init(claimed: 4, unclaimed: 1)])

        try append(setup.lines[5], to: setup.path)
        let caught = await ingestion.fileChanged(setup.path)
        _ = try await next(log, "the watcher showing p1")
        XCTAssertEqual(caught.duplicates, 1)
        XCTAssertEqual(labels(caught.applied), [])
        try await assertStraddleFinished(ingestion, main: main, path: setup.path, queueOperations: 2, snapshots: 1)
        await ingestion.close()
    }

    func testAStraddleWithoutAnAnchorClaimsTheLongestMatchingPrefix() async throws {
        let setup = try straddleSetup(fileLines: 4)
        let main = stream(setup.tree, setup.session)
        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: setup.session, configHome: setup.tree.root, mode: .filePrimary,
                                        diagnostics: notices)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()

        tap.send(try mirrorFrame(path: setup.path, entries: try setup.lines[1...5].map(entry)))
        try await ingestion.open(file: setup.path, events: tap.events)

        let first = try await next(log, "the buffered frame's own effect")
        XCTAssertEqual(first.duplicates, 3, "no buffered uuid is in the file, so the longest matching prefix decides")
        XCTAssertEqual(first.applied.count, 2, "a1 and p1, in that order")
        XCTAssertEqual(alignments(notices), [.init(claimed: 3, unclaimed: 2)])

        try append(setup.lines[4], to: setup.path)
        try append(setup.lines[5], to: setup.path)
        let caught = await ingestion.fileChanged(setup.path)
        _ = try await next(log, "the watcher showing a1 and p1")
        XCTAssertEqual(caught.duplicates, 2, "a1 by uuid, p1 by the earliest unclaimed mirror record of its hash")
        XCTAssertEqual(labels(caught.applied), [])
        try await assertStraddleFinished(ingestion, main: main, path: setup.path, queueOperations: 2, snapshots: 1)
        await ingestion.close()
    }

    func testAReopenMidEpochAlignsWhileFramesKeepArriving() async throws {
        let turn1 = SyntheticTranscript.queuedTurnLines(turn: 1)
        let turn2 = SyntheticTranscript.queuedTurnLines(turn: 2)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        var data = Data()
        for line in turn1 { data.append(line) }
        data.append(turn2[0]); data.append(turn2[1])                    // the file holds turn 1 plus u2 and q3
        let path = try tree.write(data, session: session, slug: "synthetic")
        let main = stream(tree, session)

        let notices = RecordingTimelineDiagnostics()
        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary,
                                        diagnostics: notices)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        tap.send(try mirrorFrame(path: path, entries: try turn2[0...2].map(entry)))
        try await ingestion.open(file: path, events: tap.events)

        let first = try await next(log, "the buffered frame at the re-open")
        XCTAssertEqual(first.duplicates, 2, "u2 is the anchor and q3 follows it")
        XCTAssertEqual(first.applied.count, 1, "q4 alone lies past the read")
        XCTAssertEqual(alignments(notices), [.init(claimed: 2, unclaimed: 1)])

        let more = try await send(tap, try mirrorFrame(path: path, entries: try turn2[3...4].map(entry)), log,
                                  "s2 and a2 arriving after the open")
        XCTAssertEqual(more.applied.count, 2)
        XCTAssertEqual(more.duplicates, 0)

        try append(turn2[2], to: path); try append(turn2[3], to: path)
        let caughtUp = await ingestion.fileChanged(path)
        _ = try await next(log, "the watcher showing q4 and s2")
        XCTAssertEqual(caughtUp.duplicates, 2)
        XCTAssertEqual(labels(caughtUp.applied), [])

        let last = try await send(tap, try mirrorFrame(path: path, entries: [try entry(turn2[5])]), log, "p2")
        XCTAssertEqual(last.applied.count, 1)

        try append(turn2[4], to: path); try append(turn2[5], to: path)
        let finished = await ingestion.fileChanged(path)
        _ = try await next(log, "the watcher showing a2 and p2")
        XCTAssertEqual(finished.duplicates, 2)

        try await assertStraddleFinished(ingestion, main: main, path: path, queueOperations: 4, snapshots: 2)
        let expected = RecordReducer.reduce(try TranscriptReader(url: path).readAll().records, stream: main,
                                            sourceFile: path)
        await expectEqual(ProjectionComparison.compare(wire: await ingestion.projection,
                                                    file: RecordReducer.merge([expected], main: main)), [])
        await ingestion.close()
    }

    private struct AlignmentCounts: Hashable { var claimed: Int; var unclaimed: Int }

    private func alignments(_ notices: RecordingTimelineDiagnostics) -> [AlignmentCounts] {
        notices.notices.compactMap { notice in
            if case .tapAligned(_, _, let claimed, let unclaimed) = notice {
                return AlignmentCounts(claimed: claimed, unclaimed: unclaimed)
            }
            return nil
        }
    }

    /// The three assertions every straddle ends on: the keys a whole-file read would assign, one locator per key, and
    /// the hidden records the file actually holds — a phantom `queue-operation` would show up here and nowhere else.
    private func assertStraddleFinished(_ ingestion: StreamIngestion, main: LogicalStream, path: URL,
                                        queueOperations: Int, snapshots: Int,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let records = try TranscriptReader(url: path).readAll().records
        let held = await ingestion.applied(main)
        XCTAssertEqual(labels(held.map(\.key)), labels(RecordKey.keys(for: records, in: main)),
                       "the stream's keys equal a whole-file read's", file: file, line: line)
        XCTAssertEqual(Set(held.compactMap(\.locator)).count, held.count,
                       "every key is located exactly once", file: file, line: line)
        let hidden = await ingestion.projection.hidden
        XCTAssertEqual(hidden.filter { $0.kind == "queue-operation" }.count, queueOperations,
                       "hidden queue-operation records", file: file, line: line)
        XCTAssertEqual(hidden.filter { $0.kind == "file-history-snapshot" }.count, snapshots,
                       "hidden file-history-snapshot records", file: file, line: line)
    }

    // MARK: - The rewrite arm

    func testAFileRewriteRebuildsTheStreamAndInvalidatesStaleLocators() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")

        // Each variant is its own run: its own tree, its own ingestion, its own rewrite shape.
        for variant in ["rename-over", "truncate-in-place", "engine-remove-by-uuid", "same-bytes-new-inode",
                        "no-fileChanged"] {
            let tree = try TempTree()
            let mainPath = try tree.add(fx, slug: "plain")
            let main = stream(tree, fx.sessionID)
            let original = try lines(of: mainPath)
            let attachmentIndices = original.indices.filter { RecordDecoder.decode(line: original[$0]).kind == "attachment" }
            let earlyIndex = try XCTUnwrap(attachmentIndices.first { $0 < original.count / 3 })
            let lateIndex = try XCTUnwrap(attachmentIndices.last { $0 > 2 * original.count / 3 })
            let earlyKey = RecordKey(stream: main,
                                     identity: .uuid(try XCTUnwrap(RecordDecoder.decode(line: original[earlyIndex]).uuid)))
            let lateKey = RecordKey(stream: main,
                                    identity: .uuid(try XCTUnwrap(RecordDecoder.decode(line: original[lateIndex]).uuid)))

            let notices = RecordingTimelineDiagnostics()
            let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary,
                                            diagnostics: notices)
            let log = EffectLog(ingestion)
            let tap = SyntheticTap()
            try await ingestion.open(file: mainPath, events: tap.events)
            let earlyBefore = try await expectUnwrap(await ingestion.projection.hidden(earlyKey)?.locator)
            let lateBefore = try await expectUnwrap(await ingestion.projection.hidden(lateKey)?.locator)
            let previousLength = try await expectUnwrap(await ingestion.offsets[main])
            _ = earlyBefore

            var survivor = lateKey
            var dropped: RecordKey? = earlyKey
            switch variant {
            case "rename-over", "no-fileChanged":
                // Without the first `earlyIndex + 1` lines. A rename brings a new inode; the in-place truncate keeps it.
                var rewritten = Data()
                for line in original.dropFirst(earlyIndex + 1) { rewritten.append(line); rewritten.append(UInt8(ascii: "\n")) }
                if variant == "rename-over" {
                    let staging = mainPath.deletingLastPathComponent().appendingPathComponent("staging.jsonl")
                    try rewritten.write(to: staging)
                    _ = try FileManager.default.replaceItemAt(mainPath, withItemAt: staging)
                } else {
                    let handle = try FileHandle(forWritingTo: mainPath)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: rewritten)
                    try handle.close()
                }
            case "same-bytes-new-inode":
                // The one shape the tail anchor cannot see: identical bytes at a new inode, so the length is the same
                // and the anchor's range reads back its own digest. Only the `st_ino` half of the `fstat` check can
                // catch it, which is what makes that half of the predicate discriminating.
                dropped = nil
                let staging = mainPath.deletingLastPathComponent().appendingPathComponent("staging.jsonl")
                try Data(contentsOf: mainPath).write(to: staging)
                _ = try FileManager.default.replaceItemAt(mainPath, withItemAt: staging)
            case "truncate-in-place":
                var rewritten = Data()
                for line in original.dropFirst(earlyIndex + 1) { rewritten.append(line); rewritten.append(UInt8(ascii: "\n")) }
                let handle = try FileHandle(forWritingTo: mainPath)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: rewritten)
                try handle.close()
            default:
                // The engine's own shape: one `r+` descriptor, truncated at the removed line, the suffix written back
                // in place, then enough further records that the length exceeds the old offset.
                survivor = earlyKey
                dropped = lateKey
                var rewritten = Data()
                for (index, line) in original.enumerated() where index != lateIndex {
                    rewritten.append(line); rewritten.append(UInt8(ascii: "\n"))
                }
                for turn in 3...6 { for line in SyntheticTranscript.queuedTurnLines(turn: turn) { rewritten.append(line) } }
                let handle = try FileHandle(forWritingTo: mainPath)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: rewritten)
                try handle.close()
                XCTAssertGreaterThan(rewritten.count, previousLength,
                                     "the engine's in-place rewrite can leave the file longer than the old offset")
            }

            if variant == "no-fileChanged" {
                // The one case with no `fileChanged`: the locator is stale and must never serve other bytes.
                do {
                    _ = try await ingestion.rawRecord(for: lateKey)
                    XCTFail("a locator from before an unseen rewrite must not return a record")
                } catch let error as StreamIngestion.RawRecordError {
                    XCTAssertEqual(error, .staleLocator)
                }
                XCTAssertEqual(lateBefore.range.offset, lateBefore.range.offset)
                await ingestion.close()
                continue
            }

            _ = await ingestion.fileChanged(mainPath)
            _ = try await next(log, "\(variant): the rewrite")
            let rewrites = notices.notices.compactMap { notice -> (Int, Int)? in
                if case .fileRewritten(_, _, let old, let new) = notice { return (old, new) } else { return nil }
            }
            XCTAssertEqual(rewrites.count, 1, "\(variant): exactly one fileRewritten notice")
            XCTAssertEqual(rewrites.first?.0, previousLength, "\(variant): the old length")
            XCTAssertEqual(rewrites.first?.1, try Data(contentsOf: mainPath).count, "\(variant): the new length")
            if variant == "same-bytes-new-inode" {
                XCTAssertEqual(rewrites.first?.0, rewrites.first?.1,
                               "same-bytes-new-inode: nothing but the inode changed, so the two lengths are equal")
            }
            await expectEqual(await ingestion.state, .both, "\(variant): a rewrite says nothing about the sources")

            let expected = RecordReducer.reduce(try TranscriptReader(url: mainPath).readAll().records, stream: main,
                                                sourceFile: mainPath)
            await expectEqual(ProjectionComparison.compare(wire: await ingestion.projection,
                                                        file: RecordReducer.merge([expected], main: main)), [],
                           "\(variant): the projection is the rebuilt file's")
            let served = try await ingestion.rawRecord(for: survivor)
            XCTAssertEqual(served["type"]?.stringValue, "attachment", "\(variant): the survivor reads back")
            guard let dropped else {
                // Nothing was dropped: both attachments survive the rebuild and both read back through fresh locators.
                let early = try await ingestion.rawRecord(for: earlyKey)
                XCTAssertEqual(early["type"]?.stringValue, "attachment", "\(variant): the early attachment reads back")
                await ingestion.close()
                continue
            }
            do {
                _ = try await ingestion.rawRecord(for: dropped)
                XCTFail("\(variant): the dropped record's key must be unknown")
            } catch let error as StreamIngestion.RawRecordError {
                XCTAssertEqual(error, .unknownKey, "\(variant)")
            }
            await ingestion.close()
        }
    }

    // MARK: - Load earlier

    func testLoadEarlierPaginatesToTheRootAndMatchesReadAll() async throws {
        let file = SyntheticTranscript.rewound(turns: 30, paddingBytes: 300_000, rewindAfterTurn: 12, thenTurns: 10)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let path = try tree.write(file.data, session: session, slug: "synthetic")
        let main = stream(tree, session)

        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary)
        _ = EffectLog(ingestion)
        let tap = SyntheticTap()
        let opened = try await ingestion.open(file: path, events: tap.events)
        XCTAssertEqual(opened.window?.earlierAvailable, true, "the default policy leaves earlier bytes unread")
        let suffix = await ingestion.applied(main).map(\.key)

        var pages = 0
        while true {
            let effect = try await ingestion.loadEarlier()
            if effect.applied.isEmpty { break }
            pages += 1
            XCTAssertLessThan(pages, 20, "the pagination must terminate")
            for key in effect.applied {
                await expectNotNil(await ingestion.locator(of: key), "a prepended key carries its locator")
            }
        }
        XCTAssertGreaterThan(pages, 0, "the file is larger than one window")
        await expectEqual(await ingestion.projection.window?.earlierAvailable, false, "the walk reached offset 0")
        try await expectEqual(labels(try await ingestion.loadEarlier().applied), [], "one more call is empty")

        let held = await ingestion.applied(main)
        let keys = held.map(\.key)
        XCTAssertEqual(labels(Array(keys.suffix(suffix.count))), labels(suffix),
                       "the suffix keys are unchanged, as a sequence, across every prepend")

        // The repeated `atis-latch`: one per turn, byte-identical, so its hash straddles every page boundary.
        let all = try TranscriptReader(url: path).readAll().records
        XCTAssertEqual(keys.count, all.count)
        let latchHash = try XCTUnwrap(all.first { $0.kind == "atis-latch" }?.contentHash)
        let latchCount = all.filter { $0.contentHash == latchHash }.count
        XCTAssertEqual(latchCount, 40, "one per turn")
        var ordinals: Set<Int> = []
        for key in keys { if case .hash(latchHash, let ordinal) = key.identity { ordinals.insert(ordinal) } }
        XCTAssertEqual(ordinals, Set(0..<latchCount), "the ordinals for the hash are 0..<n, in application order")

        let prepended = try XCTUnwrap(keys.first { if case .hash(latchHash, _) = $0.identity { return true }
                                                   else { return false } })
        try await expectEqual(try await ingestion.rawRecord(for: prepended)["type"]?.stringValue, "atis-latch")
        XCTAssertEqual(Set(held.compactMap(\.locator)).count, held.count, "every record's locator, exactly once")

        let expected = RecordReducer.merge([RecordReducer.reduce(all, stream: main, sourceFile: path)], main: main)
        let produced = await ingestion.projection
        XCTAssertEqual(ProjectionComparison.compare(wire: produced, file: expected), [],
                       "the projection equals a whole-file read's in content")
        XCTAssertEqual(produced.session, expected.session)
        XCTAssertEqual(hiddenHashes(produced), hiddenHashes(expected),
                       "and the same multiset of hidden records, though not the same key numbering")
        await ingestion.close()
    }

    private func hiddenHashes(_ projection: DurableProjection) -> [String: Int] {
        var out: [String: Int] = [:]
        for hidden in projection.hidden {
            let label: String
            switch hidden.key.identity {
            case .uuid(let uuid): label = "uuid:\(uuid)"
            case .hash(let hash, _): label = "hash:\(hash)"
            }
            out[label, default: 0] += 1
        }
        return out
    }

    // MARK: - The whole wire stream

    func testTheWholeWireStreamThroughTheTapYieldsOnlyMirrorEffects() async throws {
        let fx = try FixtureCorpus.named("session-mirror-relocation")
        let source = try XCTUnwrap(try fx.transcriptFiles().first?.2)
        let complete = try Data(contentsOf: source)

        // The new slug: where the transcript lives after the relocation.
        let frames = try mirrorFrames(fx)
        var paths: [String] = []
        for frame in frames where !paths.contains(frame.filePath) { paths.append(frame.filePath) }
        let tree = try TempTree()
        let mainPath = URL(fileURLWithPath: paths[1].replacingOccurrences(
            of: FixtureCorpus.recordedConfigHome.standardizedFileURL.path,
            with: tree.root.standardizedFileURL.path))
        try place(complete, at: mainPath)
        let main = stream(tree, fx.sessionID)

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // Every event of the recording, in `t` order — the tap carrying what the fan-out carries.
        var expectedEffects = 0
        for step in try FixtureWireReplay.steps(for: fx) {
            for event in step.events {
                if case .frame(.transcriptMirror(let mirror), let epoch) = event {
                    expectedEffects += 1
                    tap.send(rehome(mirror, to: tree.root), epoch: epoch)
                } else {
                    tap.send(event: event)
                }
            }
        }
        tap.finish()
        XCTAssertEqual(expectedEffects, 15, "the recording's transcript_mirror frames, counted from its own frames")

        var duplicates = 0, routed = 0, applied = 0
        for index in 0..<expectedEffects {
            let effect = try await next(log, "mirror effect \(index + 1) of \(expectedEffects)")
            duplicates += effect.duplicates
            routed += effect.routedElsewhere
            applied += effect.applied.count
        }
        XCTAssertEqual(duplicates, 53, "every mirrored entry was claimed against the read")
        XCTAssertEqual(routed, 0, "the new-slug path resolves to the same session")
        XCTAssertEqual(applied, 0, "the file already held every record")

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(log.count, expectedEffects,
                       "a `receive` that reacted to any other event would yield more, one that dropped mirror frames fewer")

        let expected = RecordReducer.merge(
            [RecordReducer.reduce(try TranscriptReader(url: mainPath).readAll().records, stream: main,
                                  sourceFile: mainPath)], main: main)
        await expectEqual(ProjectionComparison.compare(wire: await ingestion.projection, file: expected), [])

        await ingestion.close()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(log.finished, "close() finishes effects")
        XCTAssertEqual(log.count, expectedEffects, "and nothing arrives after it")
    }

    // MARK: - A main path that does not exist yet

    func testOpenOnAMissingMainFileIsMirrorOnlyUntilTheFileAppears() async throws {
        let turn = SyntheticTranscript.queuedTurnLines(turn: 1)
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let directory = tree.projects.appendingPathComponent("synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mainPath = directory.appendingPathComponent("\(session).jsonl")
        let main = stream(tree, session)

        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        let opened = try await ingestion.open(file: mainPath, events: tap.events)
        await expectEqual(await ingestion.state, .mirrorOnly)
        XCTAssertEqual(opened.items, [])
        await expectEqual(await ingestion.offsets[main], 0)

        let fromMirror = try await send(tap, try mirrorFrame(path: mainPath,
                                                             entries: [try entry(turn[0]), try entry(turn[1])]),
                                        log, "the mirror before the file exists")
        XCTAssertEqual(fromMirror.applied.count, 2)
        let held = await ingestion.applied(main)
        XCTAssertEqual(held.compactMap(\.locator).count, 0, "no line is on disk yet")
        let userKey = held[0].key
        try await expectEqual(try await ingestion.rawRecord(for: userKey)["type"]?.stringValue, "user")

        var data = Data()
        for line in turn.prefix(3) { data.append(line) }
        try data.write(to: mainPath)
        let appeared = await ingestion.fileChanged(mainPath)
        _ = try await next(log, "the file appearing")
        XCTAssertEqual(appeared.duplicates, 2)
        XCTAssertEqual(appeared.applied.count, 1, "s1 alone is new")
        XCTAssertEqual(appeared.stateChange, .both)
        await expectEqual(await ingestion.state, .both)
        let after = await ingestion.applied(main)
        XCTAssertEqual(after.compactMap(\.locator).count, after.count, "every key is located")
        try await expectEqual(try await ingestion.rawRecord(for: userKey), try entry(turn[0]),
                       "the raw view now reads the file's own line")
        await ingestion.close()
    }

    // MARK: - A failed open

    func testAFailedOpenEndsTheConsumingTaskAndFinishesEffects() async throws {
        let session = try XCTUnwrap(SessionID(SyntheticTranscript.sessionID))
        let tree = try TempTree()
        let mainPath = tree.projects.appendingPathComponent("synthetic").appendingPathComponent("\(session).jsonl")
        try FileManager.default.createDirectory(at: mainPath, withIntermediateDirectories: true)

        let ingestion = StreamIngestion(session: session, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = SyntheticTap()
        do {
            _ = try await ingestion.open(file: mainPath, events: tap.events)
            XCTFail("a directory at the main path is not a transcript")
        } catch let error as ReaderError {
            XCTAssertEqual(error, .notARegularFile)
        }

        let deadline = Date().addingTimeInterval(2)
        while !tap.terminated, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(tap.terminated, "the consuming task stopped iterating the tap")

        // The wait for `effects` to finish is bounded too. `EffectLog` is already iterating the stream on its own
        // task, so the test polls that task rather than iterating here, where a stream that never finished would hang.
        let finished = Date().addingTimeInterval(2)
        while !log.finished, Date() < finished { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(log.finished, "effects finished")
        XCTAssertEqual(log.count, 0, "and yielded no element")

        tap.send(try mirrorFrame(path: mainPath, entries: []))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.count, 0, "a frame sent after a failed open produces nothing")
    }
}
