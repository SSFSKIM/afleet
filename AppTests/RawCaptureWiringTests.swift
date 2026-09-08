import Foundation
import XCTest
import ClaudeWire
import FleetKit
@testable import Afleet

/// The Developer setting *Capture raw frames* reaches the thing that spawns, or it records nothing at all.
///
/// The launch is the only place that reads the persisted setting, and `Fleet`'s default process factory is the only
/// place that decides whether a spawned process has a capture; between them is the provider this asserts on. Nothing
/// here spawns and nothing here opens a capture file: the provider's answer is the whole subject.
///
/// Every tree is a `TempTree` and every identifier is invented (§11). No assertion prints a path.
final class RawCaptureWiringTests: XCTestCase {

    /// Off is off: a launch that read a false setting hands the fleet a provider that answers nil, so the process
    /// factory builds processes with no capture and no byte is ever written under the diagnostics directory.
    func testTheProviderAnswersNilWhileTheSettingIsOff() async throws {
        let rig = try await Rig(rawFrameCapture: false)
        let provider = try XCTUnwrap(rig.provider, "the launch handed the fleet factory no capture provider")
        XCTAssertNil(provider(), "a launch with the setting off still gave the spawn path a capture")
    }

    /// On is on, and the capture is rooted where §11's owned-files table says: `<diagnostics root>/capture`, with
    /// the config-home hash below it.
    func testTheProviderAnswersACaptureUnderTheDiagnosticsTreeWhileTheSettingIsOn() async throws {
        let rig = try await Rig(rawFrameCapture: true)
        let provider = try XCTUnwrap(rig.provider, "the launch handed the fleet factory no capture provider")
        let capture = try XCTUnwrap(provider(), "the setting was on and the spawn path was given no capture")

        let root = await capture.root
        XCTAssertEqual(Array(root.pathComponents.suffix(2)), ["logs", "capture"],
                       "the capture is not rooted at <diagnostics root>/capture")
        let directory = await capture.directory
        XCTAssertEqual(directory.lastPathComponent, RawCapture.configHomeHash(rig.workspace.configHome),
                       "the capture directory is not this config home's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "constructing the capture created the tree before a single frame was captured")
    }

    /// The toggle is live: the provider is asked at every spawn, so a channel opened after the user moves it is
    /// built the new way without relaunching. Settings is what moves it, and this goes through Settings.
    @MainActor
    func testMovingTheSettingChangesWhatTheNextSpawnIsGiven() async throws {
        let rig = try await Rig(rawFrameCapture: false)
        let provider = try XCTUnwrap(rig.provider)
        XCTAssertNil(provider())

        let readout = SettingsReadout(workspace: rig.workspace)
        await readout.refresh()
        readout.settings.developer.rawFrameCapture = true
        await readout.save()
        XCTAssertNotNil(provider(), "a spawn after the toggle went on was still given no capture")

        readout.settings.developer.rawFrameCapture = false
        await readout.save()
        XCTAssertNil(provider(), "a spawn after the toggle went off was still given a capture")
    }

    /// *Delete diagnostics* clears §11's capture tree along with the four logs, and clears only what the capture
    /// owns: a foreign file in the same directory is somebody else's and stays.
    func testDeleteDiagnosticsClearsTheCaptureTreeAndLeavesAForeignFileAlone() throws {
        let temp = try TempTree()
        let directory = try temp.directory("logs")
        let composer = DiagnosticsComposer(directory: directory)
        let home = directory.appending(path: "capture/1a2b3c4d5e6f", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let captured = home.appending(path: "\(LaunchFixtures.sessionA).ndjson")
        try Data(#"{"type":"keep_alive"}"#.utf8).write(to: captured)
        let foreign = home.appending(path: "notes.txt")
        try Data("invented".utf8).write(to: foreign)

        composer.deleteLogs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.path),
                       "a captured session survived Delete diagnostics")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path),
                      "Delete diagnostics removed a file the capture does not own")
    }

    // MARK: - The rig

    /// One launch whose settings document was written before it ran, with the provider the fleet factory was handed
    /// held for the test. Everything below the launch is a stub: no engine is probed and no fleet is constructed.
    private struct Rig {
        let temp: TempTree
        let workspace: Workspace
        let provider: (@Sendable () -> RawCapture?)?

        init(rawFrameCapture: Bool) async throws {
            let tree = try TempTree()
            temp = tree
            let configHome = try tree.directory("home")
            let storeRoot = tree.root.appending(path: "store", directoryHint: .isDirectory)
            let diagnosticsRoot = tree.root.appending(path: "logs", directoryHint: .isDirectory)
            let binary = try tree.file("bin/claude", "#!/bin/sh\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

            // The setting as the user left it on a previous run: written through the same store the launch opens.
            let seed = try FileStateStore(baseDirectory: storeRoot, configHomes: [configHome])
            var settings = await AfleetSettingsStore.read(from: seed)
            settings.developer.rawFrameCapture = rawFrameCapture
            try await AfleetSettingsStore.write(settings, to: seed)

            let box = ProviderBox()
            let index = StubIndex(persisted: nil,
                                  built: LaunchFixtures.snapshot(configHome: configHome, ids: []))
            let sequence = LaunchSequence(
                storeRoot: storeRoot,
                diagnosticsRoot: diagnosticsRoot,
                resolveEnvironment: { LaunchFixtures.environment(home: tree.root, configHome: configHome) },
                locateBinary: { _, _ in binary },
                checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
                makeIndex: { _, _, _ in index },
                fleetFactory: { _, _, _, _, _, capture in
                    box.provider = capture
                    return StubFleet()
                },
                makeWatcher: { _ in StubWatcher() },
                readClaudeJSON: { _ in true })

            let route = await sequence.run()
            workspace = try XCTUnwrap(route.workspace, "the launch did not reach a workspace")
            provider = box.provider
        }
    }

    /// The provider the fleet factory was handed, kept where the test can ask it. A box because the factory is a
    /// sendable closure and writes from wherever the launch runs it.
    private final class ProviderBox: @unchecked Sendable {   // `lock` serialises the one field
        private let lock = NSLock()
        private var stored: (@Sendable () -> RawCapture?)?

        var provider: (@Sendable () -> RawCapture?)? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
