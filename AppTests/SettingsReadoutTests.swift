import Foundation
import XCTest
import ClaudeWire
import FleetKit
@testable import Afleet

/// G3b (item 48) and the diagnostics directory's own contract.
///
/// Every config home here is a scratch tree under the temporary directory holding invented
/// transcripts; nothing reads or writes `~/.claude`, `$CLAUDE_CONFIG_DIR` or the fixture home.
final class SettingsReadoutTests: XCTestCase {

    // MARK: - The diagnostics directory

    /// The four sinks write into the directory they were handed and nowhere else.
    ///
    /// The refusal this guards is X9's: `Fleet` builds two of these three itself, eagerly, from a
    /// directory it does not check, so "the sinks write only under their own directory" and "the
    /// directory never overlaps a config home in either direction" are the two halves of one guarantee. The other half
    /// is `LaunchSequence`'s overlap check; this half is that the sinks are not creating anything
    /// outside what they were pointed at.
    func testDiagnosticsComposerWritesOnlyUnderItsOwnDirectory() throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let logs = temp.root.appending(path: "logs", directoryHint: .isDirectory)
        let before = try LaunchFixtures.manifest(of: configHome)
        XCTAssertFalse(before.isEmpty, "the scratch config home is empty, so an unchanged manifest would prove nothing")

        let composer = DiagnosticsComposer(directory: logs)
        composer.wire.record(.captureSkipped(reason: "invented"))
        composer.fleet.record(.verb(name: "invented", exitCode: 0, durationMs: 1))
        composer.timeline.record(.indexBuilt(files: 1, symlinkedProjectsSkipped: 0, durationMs: 1))
        composer.app.record(.transcriptChangeStalled(paths: 1, waitedMs: 2100))
        composer.flush()

        XCTAssertEqual(try LaunchFixtures.manifest(of: configHome), before,
                       "driving the three sinks changed the config home")

        let written = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        XCTAssertEqual(written, ["app.log", "diagnostics.log", "fleet.log", "timeline.log"])
        for name in written {
            let size = try Data(contentsOf: logs.appending(path: name)).count
            XCTAssertGreaterThan(size, 0, "\(name) was created and never written to")
        }
        // The floor: the whole scratch tree holds the config home and the log directory and nothing
        // else, so "only under its own directory" is a claim about a tree that was actually walked.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.root.path).sorted(),
                       ["home", "logs"])
    }

    /// *Delete diagnostics* clears the logs; it does not turn logging off.
    ///
    /// Deleting a file out from under an open `FileHandle` leaves the sink writing into an unlinked
    /// inode, and nothing anywhere says so — the user asked to clear the logs and silently got no
    /// logging for the rest of the session. The assertion is on the write *after* the deletion, in
    /// all three files, which is the one that fails when the sinks are not renewed.
    func testDeletingDiagnosticsLeavesAllFourSinksWriting() throws {
        let temp = try TempTree()
        let logs = temp.root.appending(path: "logs", directoryHint: .isDirectory)
        let composer = DiagnosticsComposer(directory: logs)

        composer.wire.record(.captureSkipped(reason: "invented-before"))
        composer.fleet.record(.verb(name: "invented-before", exitCode: 0, durationMs: 1))
        composer.timeline.record(.indexUpdated(changed: 1, durationMs: 1))
        composer.app.record(.transcriptChangeStalled(paths: 1, waitedMs: 2100))
        composer.flush()
        // The floor: all three wrote before the deletion, so an empty file afterwards is the
        // deletion's doing and not a sink that never worked.
        for name in ["app.log", "diagnostics.log", "fleet.log", "timeline.log"] {
            XCTAssertGreaterThan(try Data(contentsOf: logs.appending(path: name)).count, 0,
                                 "\(name) was empty before the deletion")
        }

        composer.deleteLogs()

        composer.wire.record(.captureSkipped(reason: "invented-after"))
        composer.fleet.record(.verb(name: "invented-after", exitCode: 0, durationMs: 2))
        composer.timeline.record(.indexUpdated(changed: 2, durationMs: 2))
        composer.app.record(.transcriptChangeStalled(paths: 2, waitedMs: 2200))
        composer.flush()

        for name in ["app.log", "diagnostics.log", "fleet.log", "timeline.log"] {
            let url = logs.appending(path: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(name) does not exist after the deletion, so the sink is writing into an unlinked inode")
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertTrue(text.contains("invented-after") || text.contains("\"changed\":2") || text.contains("\"waited_ms\":2200"),
                          "\(name) does not carry the line written after the deletion")
            XCTAssertFalse(text.contains("invented-before") || text.contains("\"waited_ms\":2100"),
                           "\(name) still carries a line from before the deletion, so nothing was deleted")
        }
    }

    /// T1: deletion is an allowlist of files, not a recursive directory purge. All artefacts
    /// here are ordinary invented scratch data, NOT a config home. The opposite direction
    /// asserts that known rotated logs really are removed, so a no-op cannot pass.
    func testDeletingDiagnosticsPreservesUnrelatedFilesAndDirectories() throws {
        let temp = try TempTree()
        let logs = try temp.directory("logs")
        let composer = DiagnosticsComposer(directory: logs)
        let preserved = ["notes.txt", "nested/keep.txt", "app.log.1/keep.txt", "fleet.log.2"]
        for name in preserved { try temp.file("logs/" + name, "invented survivor") }
        let rotations = ["diagnostics.log.1", "fleet.log.1", "timeline.log.1"]
        for name in rotations { try temp.file("logs/" + name, "invented old log") }
        XCTAssertEqual(preserved.count, 4)
        XCTAssertEqual(rotations.count, 3)

        composer.deleteLogs()

        for name in preserved {
            let data = try? Data(contentsOf: logs.appending(path: name))
            XCTAssertTrue(data == Data("invented survivor".utf8), "deletion changed an unrelated artefact")
        }
        for name in rotations {
            XCTAssertFalse(FileManager.default.fileExists(atPath: logs.appending(path: name).path),
                           "deletion retained a known rotated log")
        }
    }

    // MARK: - G3b

    /// The resolved root, its source, the baseline, the installed version and the count of
    /// symlinked project directories the build skipped.
    ///
    /// The skipped count is asserted against a home holding one symlinked slug and one ordinary
    /// one, so the expected value is 1 and not 0: a readout wired to a constant zero would pass a
    /// home with no symlink in it.
    @MainActor
    func testSettingsShowsTheResolvedConfigHomeAndItsSource() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "ordinary-project", session: LaunchFixtures.sessionA)

        // A real slug directory outside `projects/`, reachable only through a symlink. The build
        // skips it, exactly as the engine's own lookup does, and counts it.
        let outside = try temp.directory("outside-project")
        try LaunchFixtures.transcript(in: temp.root.appending(path: "staging"), slug: "staged",
                                      session: LaunchFixtures.sessionB)
        try FileManager.default.moveItem(
            at: temp.root.appending(path: "staging/projects/staged/\(LaunchFixtures.sessionB).jsonl"),
            to: outside.appending(path: "\(LaunchFixtures.sessionB).jsonl"))
        try FileManager.default.createSymbolicLink(
            at: configHome.appending(path: "projects/symlinked-project"), withDestinationURL: outside)

        let built = try await Self.workspace(temp: temp, configHome: configHome)
        let readout = SettingsReadout(workspace: built.workspace)
        await readout.refresh()

        XCTAssertTrue(readout.configHomeRoot.path == configHome.path,
                      "the readout reported a config home other than the workspace's")
        XCTAssertEqual(readout.configHomeSource, .environment)
        XCTAssertEqual(readout.protocolBaseline, "2.1.259")
        XCTAssertEqual(readout.installedVersion, SemanticVersion(major: 2, minor: 1, patch: 263))
        XCTAssertEqual(readout.symlinkedProjectsSkipped, 1,
                       "the build skipped a symlinked slug and the readout reported \(readout.symlinkedProjectsSkipped)")
        XCTAssertEqual(readout.transcriptCount, 1, "the ordinary slug's transcript was not indexed")
        XCTAssertEqual(readout.projectCount, 1)
    }

    /// Item 48's second half. Two homes are the point: a single-home test passes against an
    /// implementation that reads whichever home it likes.
    @MainActor
    func testTheListedSessionsComeOnlyFromTheResolvedConfigHome() async throws {
        let temp = try TempTree()
        let homeA = try temp.directory("home-a")
        let homeB = try temp.directory("home-b")
        try LaunchFixtures.transcript(in: homeA, slug: "project-a", session: LaunchFixtures.sessionA)
        try LaunchFixtures.transcript(in: homeB, slug: "project-b", session: LaunchFixtures.sessionB)

        let built = try await Self.workspace(temp: temp, configHome: homeA)
        let readout = SettingsReadout(workspace: built.workspace)
        await readout.refresh()

        let listed = Set(readout.sessions.map(\.sessionID))
        XCTAssertEqual(listed, [LaunchFixtures.sessionA],
                       "the listing is not exactly the resolved home's one session")
        XCTAssertFalse(listed.contains(LaunchFixtures.sessionB),
                       "a session from the home CLAUDE_CONFIG_DIR does not name reached the listing")
        // The floor: both transcripts are real and readable, so B's absence is a decision and not a
        // missing file.
        XCTAssertNotNil(try? Data(contentsOf: homeB.appending(path: "projects/project-b/\(LaunchFixtures.sessionB).jsonl")))
    }

    /// §6.5's two readouts that nothing else asserts: the unknown-frame count since install and the
    /// last census. A Settings screen missing both entirely would otherwise have passed G3b.
    @MainActor
    func testSettingsShowsTheUnknownFrameCountAndTheLastCensus() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)

        let built = try await Self.workspace(temp: temp, configHome: configHome)

        let counter = UnknownFrameCounter(store: built.workspace.store)
        await counter.record("invented_frame_kind_one")
        await counter.record("invented_frame_kind_two")

        let census = CensusSummary(cliVersion: "2.1.263",
                                   takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   newInboundSubtypes: ["invented_subtype"])
        try await built.workspace.store.write(census, namespace: .fleetKit, key: FleetKitKeys.lastCensus)

        let readout = SettingsReadout(workspace: built.workspace)
        await readout.refresh()

        XCTAssertEqual(readout.unknownFrames.total, 2,
                       "two frames the corpus does not type were counted as \(readout.unknownFrames.total)")
        XCTAssertEqual(readout.unknownFrames.counts["invented_frame_kind_one"], 1)
        XCTAssertEqual(readout.lastCensus, census, "the readout did not report the stored census")
    }

    /// The count moves. Settings' `.task` runs `refresh()` every time the window is opened, so a
    /// readout that answered from a cached tally would show the first open's number forever — and
    /// the test above cannot see that, because it builds a fresh readout after the frames are
    /// already recorded and refreshes exactly once. This one reuses the readout across two reads.
    @MainActor
    func testTheUnknownFrameCountMovesWhenMoreFramesArrive() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let built = try await Self.workspace(temp: temp, configHome: configHome)

        let counter = UnknownFrameCounter(store: built.workspace.store)
        await counter.record("invented_frame_kind_one")
        await counter.record("invented_frame_kind_two")

        let readout = SettingsReadout(workspace: built.workspace)
        await readout.refresh()
        XCTAssertEqual(readout.unknownFrames.total, 2, "the first read did not see the two frames")

        await counter.record("invented_frame_kind_three")
        await counter.record("invented_frame_kind_one")

        await readout.refresh()
        XCTAssertEqual(readout.unknownFrames.total, 4,
                       "the count froze at \(readout.unknownFrames.total) after the first read")
        XCTAssertEqual(readout.unknownFrames.counts["invented_frame_kind_one"], 2,
                       "a repeated type did not accumulate")
    }

    /// Concurrent increments do not lose each other.
    ///
    /// `record` reads the tally, adds one and writes it back, and both halves suspend. Actor
    /// isolation excludes concurrent execution but not interleaving across a suspension point, so
    /// without the chain inside `record` two calls read the same pre-increment value and one
    /// increment vanishes. Forty calls, one instance, and the total has to be forty.
    func testConcurrentIncrementsDoNotLoseEachOther() async throws {
        let temp = try TempTree()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store"),
                                       configHomes: [temp.root.appending(path: "home")])
        let counter = UnknownFrameCounter(store: store)
        let calls = 40

        await withTaskGroup(of: Void.self) { group in
            for number in 0..<calls {
                group.addTask { await counter.record("invented_kind_\(number % 4)") }
            }
        }

        let tally = await counter.snapshot()
        XCTAssertEqual(tally.total, calls,
                       "\(calls) concurrent increments left a total of \(tally.total)")
        // The floor: the tally really is spread over the four types, so a single type absorbing
        // everything could not pass on the total alone.
        XCTAssertEqual(tally.counts.count, 4, "the four invented types are not all present: \(tally.counts)")
    }

    // MARK: - Support

    // F7: the production Activity ingestion path, not a test's call to record, must
    // feed Settings. Two subscribers see both frames, but only one owns the tally.
    @MainActor
    func testReceivedUnknownFramesReachSettingsExactlyOnce() async throws {
        let temp = try TempTree()
        let home = try temp.directory("home")
        let built = try await Self.workspace(temp: temp, configHome: home)
        let persisted = expectation(description: "two unknown-frame increments persisted")
        let store = TallyWriteWitness(store: built.workspace.store, completed: persisted)
        let source = built.workspace
        let workspace = Workspace(configHome: source.configHome, environment: source.environment,
                                  binary: source.binary, installed: source.installed, store: store,
                                  index: source.index, fleet: source.fleet, watcher: nil, changes: nil,
                                  diagnostics: source.diagnostics)
        let lifecycle = LifecycleDouble()
        let key = ActivityFixtures.key("1", configHome: home)
        await lifecycle.setStates([ActivityFixtures.state(key)])
        await lifecycle.openEvents(of: key)
        let shell = ShellModel()
        let router = NotificationRouter(poster: RecordingPoster(), lifecycle: lifecycle,
                                        isInView: { shell.isInView($0) }, preferences: { NotificationPreferences() })
        let activity = ActivityModel(lifecycle: lifecycle, configHome: home, shell: shell, router: router, store: store)
        await activity.start()
        let secondaryReceived = expectation(description: "secondary subscription received both frames")
        let secondary = ChannelEventPump(key: key) { pump, _ in
            if pump.recent.count == 2 { secondaryReceived.fulfill() }
        }
        let stream = await lifecycle.events(of: key)
        secondary.start(try XCTUnwrap(stream))
        let subscribers = await lifecycle.fanOutCount(of: key)
        XCTAssertEqual(subscribers, 2, "the test did not establish two subscribers")
        // Invented protocol input, never captured from an engine.
        let frame = FrameDecoder.decode(line: Data(#"{"type":"invented_unknown_frame"}"#.utf8))
        await lifecycle.push(.frame(frame, .first), to: key)
        await lifecycle.push(.frame(frame, .first), to: key)
        let received = await XCTWaiter.fulfillment(of: [secondaryReceived, persisted], timeout: 3)
        XCTAssertEqual(received, .completed, "received frames never reached the persisted tally")
        let readout = SettingsReadout(workspace: workspace)
        await readout.refresh()
        XCTAssertEqual(readout.unknownFrames.total, 2, "unknown frames were missed or counted per subscriber")
        XCTAssertEqual(readout.unknownFrames.counts["invented_unknown_frame"], 2, "the received type was not counted")
        let reopened = UnknownFrameCounter(store: source.store)
        let tally = await reopened.snapshot()
        XCTAssertEqual(tally.total, 2, "a fresh reader lost the cumulative tally")
        activity.stop()
        secondary.stop()
    }

    /// Forwards every operation to the real store. The signal follows successful persistence,
    /// so a dead ingestion owner fails the asserted wait rather than passing on a later read.
    private actor TallyWriteWitness: StateStore {
        let store: any StateStore
        let completed: XCTestExpectation
        private var writes = 0
        init(store: any StateStore, completed: XCTestExpectation) {
            self.store = store; self.completed = completed
        }
        func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T? {
            try await store.read(type, namespace: namespace, key: key)
        }
        func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws {
            try await store.write(value, namespace: namespace, key: key)
            if namespace == .afleet && key == AfleetStoreKeys.unknownFrames {
                writes += 1
                if writes == 2 { completed.fulfill() }
            }
        }
        func remove(namespace: StoreNamespace, key: String) async throws { try await store.remove(namespace: namespace, key: key) }
        func keys(in namespace: StoreNamespace) async throws -> [String] { try await store.keys(in: namespace) }
        func appendUnique(_ element: String, namespace: StoreNamespace, key: String) async throws {
            try await store.appendUnique(element, namespace: namespace, key: key)
        }
    }

    private struct Built {
        let workspace: Workspace
        let diagnostics: DiagnosticsComposer
    }

    /// A real launch over a scratch config home: the real store, the real `TranscriptIndex` and the
    /// real diagnostics composer, with only the binary, the version gate and the fleet stubbed.
    /// Returns once the detached index build has reported, which is what makes the readout's
    /// numbers deterministic.
    @MainActor
    private static func workspace(temp: TempTree, configHome: URL) async throws -> Built {
        let composerBox = ComposerBox()
        let fleet = StubFleet()
        let watcher = StubWatcher()
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")

        let signalBox = SignalBox()

        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeDiagnostics: { directory in
                let composer = DiagnosticsComposer(directory: directory)
                composerBox.set(composer)
                return composer
            },
            // The real `TranscriptIndex`, over the real composer's sink, with a signal spliced in
            // so the detached build's completion is something to wait *on* rather than to poll for.
            makeIndex: { home, store, diagnostics in
                let signal = IndexBuildSignal(forwardingTo: diagnostics.timeline)
                signalBox.set(signal)
                return TranscriptIndex(configHome: home,
                                       storage: StoreIndexStorage(store: store),
                                       diagnostics: signal)
            },
            fleetFactory: { _, _, _, _, _ in fleet },
            makeWatcher: { _ in watcher },
            readClaudeJSON: { _ in true })

        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the scratch launch did not reach a workspace")
        let composer = try XCTUnwrap(composerBox.value, "the diagnostics composer was never built")
        let signal = try XCTUnwrap(signalBox.value, "the index was never built through the seam")

        // The outcome is asserted, not just awaited: this helper builds the fixture every readout
        // test then measures, so a wait that timed out silently would hand each of them a workspace
        // whose index had never been built.
        let built = await XCTWaiter().fulfillment(of: [signal.built], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(built, .completed, "the index was never built through the seam")
        XCTAssertNotNil(composer.timeline.lastIndexBuild, "the index build never reported an indexBuilt notice")
        watcher.finish()
        return Built(workspace: workspace, diagnostics: composer)
    }

    /// The build signal the sequence spliced in, carried back out of the seam. Same locking
    /// argument as `ComposerBox`.
    private final class SignalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: IndexBuildSignal?
        func set(_ signal: IndexBuildSignal) {
            lock.lock(); defer { lock.unlock() }
            storage = signal
        }
        var value: IndexBuildSignal? {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// The composer the sequence built, carried back out of the seam.
    ///
    /// `@unchecked Sendable` is sound here because the one mutable field is written and read only
    /// inside `lock`, this instance's private `NSLock`.
    private final class ComposerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: DiagnosticsComposer?
        func set(_ composer: DiagnosticsComposer) {
            lock.lock(); defer { lock.unlock() }
            storage = composer
        }
        var value: DiagnosticsComposer? {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
