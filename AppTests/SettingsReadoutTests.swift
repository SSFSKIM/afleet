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

    /// The three sinks write into the directory they were handed and nowhere else.
    ///
    /// The refusal this guards is X9's: `Fleet` builds two of these three itself, eagerly, from a
    /// directory it does not check, so "the sinks write only under their own directory" and "the
    /// directory is never inside a config home" are the two halves of one guarantee. The other half
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
        composer.flush()

        XCTAssertEqual(try LaunchFixtures.manifest(of: configHome), before,
                       "driving the three sinks changed the config home")

        let written = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        XCTAssertEqual(written, ["diagnostics.log", "fleet.log", "timeline.log"])
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
    func testDeletingDiagnosticsLeavesAllThreeSinksWriting() throws {
        let temp = try TempTree()
        let logs = temp.root.appending(path: "logs", directoryHint: .isDirectory)
        let composer = DiagnosticsComposer(directory: logs)

        composer.wire.record(.captureSkipped(reason: "invented-before"))
        composer.fleet.record(.verb(name: "invented-before", exitCode: 0, durationMs: 1))
        composer.timeline.record(.indexUpdated(changed: 1, durationMs: 1))
        composer.flush()
        // The floor: all three wrote before the deletion, so an empty file afterwards is the
        // deletion's doing and not a sink that never worked.
        for name in ["diagnostics.log", "fleet.log", "timeline.log"] {
            XCTAssertGreaterThan(try Data(contentsOf: logs.appending(path: name)).count, 0,
                                 "\(name) was empty before the deletion")
        }

        composer.deleteLogs()

        composer.wire.record(.captureSkipped(reason: "invented-after"))
        composer.fleet.record(.verb(name: "invented-after", exitCode: 0, durationMs: 2))
        composer.timeline.record(.indexUpdated(changed: 2, durationMs: 2))
        composer.flush()

        for name in ["diagnostics.log", "fleet.log", "timeline.log"] {
            let url = logs.appending(path: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(name) does not exist after the deletion, so the sink is writing into an unlinked inode")
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertTrue(text.contains("invented-after") || text.contains("index_updated"),
                          "\(name) does not carry the line written after the deletion")
            XCTAssertFalse(text.contains("invented-before"),
                           "\(name) still carries a line from before the deletion, so nothing was deleted")
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

        XCTAssertEqual(readout.configHomeRoot.path, configHome.path)
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

    // MARK: - Support

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
            fleetFactory: { _, _, _, _, _ in fleet },
            makeWatcher: { _ in watcher },
            readClaudeJSON: { _ in true })

        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the scratch launch did not reach a workspace")
        let composer = try XCTUnwrap(composerBox.value, "the diagnostics composer was never built")

        let reported = await LaunchFixtures.wait { composer.timeline.lastIndexBuild != nil }
        XCTAssertTrue(reported, "the index build never reported an indexBuilt notice")
        watcher.finish()
        return Built(workspace: workspace, diagnostics: composer)
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
