import Foundation
import SwiftUI
import XCTest
import ClaudeWire
import FleetKit
@testable import Afleet

/// Spec §2's launch, one test per branch that can end it, plus the three orderings the sequence is
/// only correct because of: the write-root check before anything that writes, the coordinator
/// driven on the cold path as well as the warm one, and the index build not awaited on the way to
/// the first frame.
///
/// Every scratch tree is under the temporary directory and `TempTree` skips if that resolves inside
/// a config home. Nothing here names `~/.claude`, `$CLAUDE_CONFIG_DIR` or the fixture home, and the
/// two refusal tests point their demonstration at an invented home under the temporary directory
/// (tracker entry 52).
final class LaunchSequenceTests: XCTestCase {

    // MARK: - The rig

    private struct Rig {
        let temp: TempTree
        let configHome: URL
        let storeRoot: URL
        let diagnosticsRoot: URL
        let log: SeamLog
        let fleet: StubFleet
        let index: StubIndex
        let watcher: StubWatcher
        var sequence: LaunchSequence
    }

    /// A launch whose every seam is recorded and whose two write roots are nowhere near the config
    /// home. Each test overrides only the seam it is about.
    private func makeRig(signedIn: Bool = true,
                         persisted: IndexSnapshot? = nil,
                         blockingBuild: Bool = false,
                         loadDelay: Duration = .zero,
                         delta: IndexDelta = IndexDelta(added: [LaunchFixtures.sessionA])) throws -> Rig {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        // One real transcript, so the refusal test's before-and-after manifest is a comparison of
        // something rather than of two empty lists, and so its guard clauses have content to
        // match against.
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let storeRoot = temp.root.appending(path: "store", directoryHint: .isDirectory)
        let diagnosticsRoot = temp.root.appending(path: "logs", directoryHint: .isDirectory)
        let log = SeamLog()
        let fleet = StubFleet()
        let built = LaunchFixtures.snapshot(configHome: configHome, ids: [LaunchFixtures.sessionA])
        let index = StubIndex(persisted: persisted, built: built, blocks: blockingBuild,
                              loadDelay: loadDelay, delta: delta)
        let watcher = StubWatcher()
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let sequence = LaunchSequence(
            storeRoot: storeRoot,
            diagnosticsRoot: diagnosticsRoot,
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in log.note("locateBinary"); return binary },
            checkVersion: { _, _ in log.note("checkVersion"); return .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in
                log.note("makeStore")
                return try FileStateStore(baseDirectory: base, configHomes: homes)
            },
            makeDiagnostics: { directory in log.note("makeDiagnostics"); return DiagnosticsComposer(directory: directory) },
            makeIndex: { _, _, _ in log.note("makeIndex"); return index },
            fleetFactory: { _, _, _, _, _ in log.note("fleetFactory"); return fleet },
            makeWatcher: { _ in log.note("makeWatcher"); return watcher },
            readClaudeJSON: { _ in log.note("readClaudeJSON"); return signedIn })

        return Rig(temp: temp, configHome: configHome, storeRoot: storeRoot, diagnosticsRoot: diagnosticsRoot,
                   log: log, fleet: fleet, index: index, watcher: watcher, sequence: sequence)
    }

    /// R1: removing the shared in-flight task re-enters the resolver and builds two workspaces.
    /// Returning early instead of awaiting it fails the inverted completion wait. Both callers
    /// must observe a fully bound workspace, not merely a route changed by the other caller.
    @MainActor
    func testConcurrentLaunchesAwaitOneWorkspace() async throws {
        var rig = try makeRig()
        let entered = expectation(description: "first launch entered resolver")
        let reentered = expectation(description: "second launch entered resolver")
        reentered.isInverted = true
        let premature = expectation(description: "second caller returned before launch completed")
        premature.isInverted = true
        let (gate, release) = AsyncStream<Void>.makeStream()
        let log = rig.log
        let environment = LaunchFixtures.environment(home: rig.temp.root, configHome: rig.configHome)
        rig.sequence.resolveEnvironment = {
            log.note("resolveEnvironment")
            if log.count("resolveEnvironment") == 1 { entered.fulfill() }
            else { reentered.fulfill() }
            for await _ in gate { break }
            return environment
        }
        let app = AppModel(sequence: rig.sequence, coordinatorFactory: { _ in
            log.note("makeCoordinator")
            return RecordingCoordinator()
        })
        let first = Task { await app.launch() }
        let started = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(started, .completed, "first launch never reached the resolver")
        let secondEntered = expectation(description: "second caller started")
        var held = true
        let second = Task {
            secondEntered.fulfill()
            await app.launch()
            if held { premature.fulfill() }
            XCTAssertTrue(app.route.workspace != nil, "second caller returned without a workspace")
            XCTAssertTrue(app.settingsReadout != nil, "second caller returned before workspace binding")
        }
        let startedSecond = await XCTWaiter.fulfillment(of: [secondEntered], timeout: 3)
        XCTAssertEqual(startedSecond, .completed, "second caller never started")
        let blocked = await XCTWaiter.fulfillment(of: [reentered, premature], timeout: 0.2)
        XCTAssertEqual(blocked, .completed, "concurrent launch restarted or returned before completion")
        held = false
        release.finish()
        await first.value
        await second.value
        XCTAssertTrue(app.route.workspace != nil, "launch did not reach a workspace")
        for seam in ["resolveEnvironment", "makeStore", "fleetFactory", "makeWatcher", "makeCoordinator"] {
            XCTAssertEqual(log.count(seam), 1, "launch must construct each dependency exactly once")
        }
        rig.watcher.finish()
    }

    /// R3: a synthetic CLAUDE_CONFIG_DIR=/ must refuse before entering a write-producing seam.
    /// No process environment is changed and no filesystem write is performed: the store seam
    /// records then throws even if the guard is removed. That mutation fails BOTH the route
    /// and trace assertions, rather than reaching C4's identical (out-of-fence) guard.
    func testFilesystemRootConfigHomeRefusesBeforeAnyStoreConstruction() async {
        let log = SeamLog()
        let sequence = LaunchSequence(
            storeRoot: URL(filePath: "/invented/store"),
            diagnosticsRoot: URL(filePath: "/invented/logs"),
            resolveEnvironment: {
                log.note("resolveEnvironment")
                return LaunchFixtures.environment(home: URL(filePath: "/invented/home"),
                                                  configHome: URL(filePath: "/"))
            },
            makeStore: { _, _ in
                log.note("makeStore")
                throw CocoaError(.fileWriteUnknown)
            })

        let route = await sequence.run()

        if case .writeRootInsideConfigHome(root: .store, configHome: _) = route.setupState {
            // The case carries a path; assert its shape without printing that aggregate.
        } else {
            XCTFail("filesystem-root config home did not receive the write-root refusal")
        }
        XCTAssertEqual(log.count("resolveEnvironment"), 1, "launch never resolved its environment")
        XCTAssertEqual(log.count("makeStore"), 0, "launch entered a write-producing seam")
    }

    /// T1: reverse containment must refuse before the first writer is reached. The paths are
    /// invented and the seam throws without touching disk, even on the failing pre-fix run.
    func testConfigHomeInsideEitherWriteRootRefusesBeforeConstruction() async {
        for root in [WriteRoot.store, .diagnostics] {
            let store = URL(filePath: "/invented/store")
            let logs = URL(filePath: "/invented/logs")
            let home = (root == .store ? store : logs).appending(path: "nested-home")
            let log = SeamLog()
            let sequence = LaunchSequence(
                storeRoot: store, diagnosticsRoot: logs,
                resolveEnvironment: { LaunchFixtures.environment(home: URL(filePath: "/invented"), configHome: home) },
                makeStore: { _, _ in log.note("makeStore"); throw CocoaError(.fileWriteUnknown) })
            let route = await sequence.run()
            if case .writeRootInsideConfigHome(root: let refused, configHome: _) = route.setupState {
                XCTAssertEqual(refused, root)
            } else { XCTFail("reverse containment did not receive the write-root refusal") }
            XCTAssertEqual(log.count("makeStore"), 0, "launch entered a write-producing seam")
        }
        // Prefix siblings are not containment; canonical components, not string prefixes.
        XCTAssertNil(LaunchSequence.overlappingWriteRoot(
            configHome: URL(filePath: "/invented/logs-sibling/home"),
            storeRoot: URL(filePath: "/invented/store"), diagnosticsRoot: URL(filePath: "/invented/logs")))
    }

    /// T2: the shipped Settings body must expose recovery on both refusal routes. Pressing
    /// its button must clear the persisted override and retry with ordinary binary lookup.
    @MainActor
    func testSettingsCanResetAnOverrideWithoutAWorkspace() async throws {
        for unreadable in [false, true] {
            let rig = try makeRig()
            let store = try FileStateStore(baseDirectory: rig.storeRoot, configHomes: [rig.configHome])
            var settings = AfleetSettings()
            settings.developer.binaryPathOverride = "/invented/old-engine"
            settings.developer.rawFrameCapture = true
            try await AfleetSettingsStore.write(settings, to: store)
            var sequence = rig.sequence
            sequence.locateBinary = { _, override in override }
            sequence.checkVersion = { _, _ in
                unreadable ? .unparseable(output: "invented") : .tooOld(
                    installed: SemanticVersion(major: 2, minor: 1, patch: 200),
                    baseline: SemanticVersion(major: 2, minor: 1, patch: 259))
            }
            let model = AppModel(sequence: sequence)
            await model.launch()
            XCTAssertTrue(model.route.workspace == nil, "the refusal unexpectedly built a workspace")
            XCTAssertTrue(model.settingsReadout == nil, "the test must exercise pre-workspace settings")
            let body = AppSettingsView(model: model).body
            XCTAssertFalse(ViewTree.values(of: Text.self, in: body).isEmpty, "the Settings body contained no text")
            let reset = try XCTUnwrap(ViewTree.button("Reset binary override and check again", in: body),
                                     "Settings has no recovery control on a refused launch")
            let retried = expectation(description: "ordinary lookup after reset")
            model.sequence.locateBinary = { _, override in
                if override == nil { retried.fulfill() }
                return nil
            }
            XCTAssertTrue(ViewTree.press(reset), "the recovery button did not accept a press")
            await fulfillment(of: [retried], timeout: 5)
            let reopened = try FileStateStore(baseDirectory: rig.storeRoot, configHomes: [rig.configHome])
            let saved = await AfleetSettingsStore.read(from: reopened)
            XCTAssertTrue(saved.developer.binaryPathOverride == nil, "reset did not persist")
            XCTAssertTrue(saved.developer.rawFrameCapture, "reset discarded an unrelated preference")
            XCTAssertTrue(ViewTree.button("Reset binary override and check again", in: AppSettingsView(model: model).body) == nil,
                          "Settings still offered a reset after the override was cleared")
        }
    }

    // MARK: - The four refusals

    /// G3c. The route assertion alone would pass against code that builds a `Fleet` and then throws
    /// it away, so the discriminating clause is the second: the fleet factory was never called.
    /// That is the trace assertion the spec promises, because the dangerous act — constructing a
    /// `Fleet`, which eagerly opens two log files — cannot be observed after the fact.
    func testNoBinaryRoutesToSetupAndBuildsNoFleet() async throws {
        var rig = try makeRig()
        rig.sequence.locateBinary = { _, _ in nil }

        let route = await rig.sequence.run()

        XCTAssertEqual(route.setupState, .engineMissing)
        XCTAssertFalse(rig.log.reached("fleetFactory"), "a Fleet was constructed for a launch with no binary")
        XCTAssertFalse(rig.log.reached("checkVersion"), "the version gate ran with no binary to probe")
        // The floor: the seams before the refusal did run, so the assertions above are about the
        // sequence stopping and not about it never having started.
        XCTAssertTrue(rig.log.reached("makeStore"), "the launch did not reach the store")
    }

    /// G3a. Both versions travel to the screen, and nothing is constructed past the gate.
    func testOldBinaryRoutesToUpgradeNamingBothVersionsAndBuildsNoFleet() async throws {
        var rig = try makeRig()
        let installed = SemanticVersion(major: 2, minor: 1, patch: 200)
        let baseline = SemanticVersion(major: 2, minor: 1, patch: 259)
        rig.sequence.checkVersion = { _, _ in .tooOld(installed: installed, baseline: baseline) }

        let route = await rig.sequence.run()

        let versions = try XCTUnwrap(route.upgradeVersions)
        XCTAssertEqual(versions.installed, installed)
        XCTAssertEqual(versions.baseline, baseline)
        XCTAssertFalse(rig.log.reached("fleetFactory"), "a Fleet was constructed for a binary the gate refused")
        XCTAssertFalse(rig.log.reached("makeIndex"), "an index was built for a binary the gate refused")
    }

    /// The probe's own output is what the screen shows, so it has to survive the crossing verbatim.
    func testUnparseableVersionRoutesToSetupCarryingTheProbeOutput() async throws {
        var rig = try makeRig()
        let output = "invented probe output: not a version"
        rig.sequence.checkVersion = { _, _ in .unparseable(output: output) }

        let route = await rig.sequence.run()

        XCTAssertEqual(route.setupState, .engineUnreadable(output: output))
        XCTAssertFalse(rig.log.reached("fleetFactory"))
    }

    /// Both directions. Only checking the false branch would pass against a launch that always
    /// reports `.notSignedIn`.
    func testConfigHomeWithoutCompletedOnboardingRoutesToSetup() async throws {
        let refused = try makeRig()
        let refusedHome = refused.configHome
        var refusedSequence = refused.sequence
        refusedSequence.readClaudeJSON = { root in
            // Read the real file, so this exercises the reader and not a boolean.
            ClaudeJSONReader.hasCompletedOnboarding(in: root)
        }
        try refused.temp.file("home/.claude.json", #"{"hasCompletedOnboarding": false}"#)

        let refusedRoute = await refusedSequence.run()
        // Narrowed to the case and then to a boolean: `SetupState.notSignedIn` carries the scratch
        // config home, so an equality failure would print it.
        guard case let .notSignedIn(configHome: named) = refusedRoute.setupState else {
            return XCTFail("a home with no account did not route to .notSignedIn")
        }
        XCTAssertTrue(named.path == LaunchFixtures.directoryURL(refusedHome).path,
                      "the setup screen named a config home other than the one the launch resolved")
        XCTAssertFalse(refused.log.reached("fleetFactory"), "a Fleet was constructed for a home with no account")

        let accepted = try makeRig()
        var acceptedSequence = accepted.sequence
        acceptedSequence.readClaudeJSON = { ClaudeJSONReader.hasCompletedOnboarding(in: $0) }
        try accepted.temp.file("home/.claude.json", #"{"hasCompletedOnboarding": true}"#)

        let acceptedRoute = await acceptedSequence.run()
        XCTAssertNotNil(acceptedRoute.workspace, "a signed-in home did not reach the workspace")
    }

    // MARK: - The accepted launch

    /// Item 33's `fake-claude`, probed through the real `VersionGate` under the resolved
    /// environment, is what makes this a launch and not a stub returning `.accepted`.
    func testAcceptedBinaryBuildsTheWorkspace() async throws {
        var rig = try makeRig()
        let fake = Self.fakeClaude
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: fake.path),
                          "Tools/fake-claude is not executable in this checkout")
        let temp = rig.temp
        let configHome = rig.configHome
        rig.sequence.resolveEnvironment = {
            LaunchFixtures.environment(home: temp.root, configHome: configHome,
                                       extra: ["FAKE_CLAUDE_VERSION": "2.1.263"])
        }
        rig.sequence.locateBinary = { _, _ in fake }
        rig.sequence.checkVersion = { binary, environment in
            await VersionGate().check(binary: binary, environment: environment)
        }

        let route = await rig.sequence.run()

        let workspace = try XCTUnwrap(route.workspace, "the accepted binary did not reach a workspace")
        XCTAssertTrue(workspace.configHome.root.path == configHome.path,
                      "the workspace resolved a config home other than the one it was handed")
        XCTAssertEqual(workspace.configHome.source, .environment)
        XCTAssertEqual(workspace.installed, SemanticVersion(major: 2, minor: 1, patch: 263))
        XCTAssertEqual(workspace.binary, fake)
        let started = await rig.fleet.started
        XCTAssertTrue(started, "the fleet was constructed and never started")
    }

    // MARK: - X9's hardest rule

    /// All three directions, because a check that only ever refused would be as wrong as one that
    /// never did.
    ///
    /// This is the only path to breaking X9 that survives the store's own guard: `Fleet` builds
    /// `FileDiagnostics` and `FileFleetDiagnostics` from the directory it is handed, eagerly and
    /// with no guard at all, so a config home containing `~/Library/Logs/afleet` would have afleet
    /// creating a directory and two files inside it before a single channel existed.
    ///
    /// The demonstration is aimed at an invented home under the temporary directory. With the check
    /// removed, the run below creates `logs/` and its three files **inside** `home/` and the
    /// manifest comparison fails naming them — which is the forbidden write, performed against a
    /// scratch tree and never against a real config home (tracker entry 52).
    func testAWriteRootInsideTheConfigHomeRefusesToLaunch() async throws {
        // 1. The diagnostics root inside the config home.
        var diagnosticsRig = try makeRig()
        diagnosticsRig.sequence.diagnosticsRoot = diagnosticsRig.configHome.appending(path: "logs", directoryHint: .isDirectory)
        let beforeDiagnostics = try LaunchFixtures.manifest(of: diagnosticsRig.configHome)
        // Three floors on the manifest itself, because the two assertions below are only as good
        // as it is. It found something; its paths are relative to the home, so the `d /logs` guard
        // is a clause that can actually match; and the directory the refusal must prevent is not
        // already there.
        XCTAssertFalse(beforeDiagnostics.isEmpty, "the manifest of the scratch config home is empty")
        XCTAssertTrue(beforeDiagnostics.contains("d /projects"),
                      "the manifest did not strip the root, so no relative guard below can fire: \(beforeDiagnostics)")
        XCTAssertFalse(beforeDiagnostics.contains { $0.hasPrefix("d /logs") },
                       "the scratch home already holds the logs directory the refusal must prevent")

        let diagnosticsRoute = await diagnosticsRig.sequence.run()

        guard case let .writeRootInsideConfigHome(root: refusedRoot, configHome: refusedConfigHome)
                = diagnosticsRoute.setupState else {
            return XCTFail("a diagnostics root under the config home did not route to .writeRootInsideConfigHome")
        }
        XCTAssertEqual(refusedRoot, .diagnostics)
        XCTAssertTrue(refusedConfigHome.path == LaunchFixtures.directoryURL(diagnosticsRig.configHome).path,
                      "the refusal named a config home other than the rig's")
        XCTAssertFalse(diagnosticsRig.log.reached("makeStore"), "the store was constructed under a config home")
        XCTAssertFalse(diagnosticsRig.log.reached("makeDiagnostics"), "the diagnostics sinks were constructed under a config home")
        XCTAssertFalse(diagnosticsRig.log.reached("fleetFactory"), "a Fleet was constructed for a colliding write root")
        XCTAssertEqual(try LaunchFixtures.manifest(of: diagnosticsRig.configHome), beforeDiagnostics,
                       "the refused launch changed the config home")

        // 2. The store root inside the config home. `FileStateStore`'s own `configHomes:` guard
        //    would also refuse this one, but only after the initialiser has been reached; the
        //    assertion here is that it never is.
        var storeRig = try makeRig()
        storeRig.sequence.storeRoot = storeRig.configHome.appending(path: "state", directoryHint: .isDirectory)
        let beforeStore = try LaunchFixtures.manifest(of: storeRig.configHome)

        let storeRoute = await storeRig.sequence.run()

        guard case let .writeRootInsideConfigHome(root: storeRefusedRoot, configHome: storeRefusedHome)
                = storeRoute.setupState else {
            return XCTFail("a store root under the config home did not route to .writeRootInsideConfigHome")
        }
        XCTAssertEqual(storeRefusedRoot, .store)
        XCTAssertTrue(storeRefusedHome.path == LaunchFixtures.directoryURL(storeRig.configHome).path,
                      "the refusal named a config home other than the rig's")
        XCTAssertFalse(storeRig.log.reached("makeStore"), "FileStateStore was reached for a store root under a config home")
        XCTAssertFalse(storeRig.log.reached("makeDiagnostics"))
        XCTAssertFalse(storeRig.log.reached("fleetFactory"))
        XCTAssertEqual(try LaunchFixtures.manifest(of: storeRig.configHome), beforeStore,
                       "the refused launch changed the config home")

        // 3. Neither root inside it: the launch proceeds.
        let clearRig = try makeRig()
        let clearRoute = await clearRig.sequence.run()
        XCTAssertNotNil(clearRoute.workspace, "a launch whose write roots are outside the config home was refused")
        XCTAssertTrue(clearRig.log.reached("makeStore"))
        XCTAssertTrue(clearRig.log.reached("makeDiagnostics"))
        XCTAssertTrue(clearRig.log.reached("fleetFactory"))
    }

    // MARK: - The coordinator seam

    /// The warm path and the cold path, separately.
    ///
    /// The cold clause is the discriminating one: a composition root that drove the coordinator only
    /// from the restored snapshot would leave a first-ever launch with zero registered supervisors,
    /// and `Fleet.events(of:)` returns nil for a key it was never told about — so the symptom is a
    /// sidebar full of rows that never come alive, and a warm-path-only test would pass.
    @MainActor
    func testTheCoordinatorIsDrivenForTheRestoredSnapshotTheFreshBuildAndEveryDelta() async throws {
        // Warm.
        let restoredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let restored = LaunchFixtures.snapshot(configHome: URL(filePath: "/invented/home"),
                                               ids: [LaunchFixtures.sessionB], builtAt: restoredAt)
        var warm = try makeRig(persisted: restored)
        let warmHome = warm.configHome
        let warmCoordinator = RecordingCoordinator()
        warm.sequence.makeCoordinator = { _ in warmCoordinator }

        let bothSnapshots = warmCoordinator.expectSnapshots(2)
        let warmRoute = await warm.sequence.run()
        XCTAssertNotNil(warmRoute.workspace)

        await fulfillment(of: [bothSnapshots], timeout: LaunchFixtures.hangGuard)
        // Guarded rather than subscripted: below the count the second read would trap and take the
        // whole bundle down instead of reporting.
        guard warmCoordinator.snapshots.count >= 2 else {
            return XCTFail("the coordinator saw \(warmCoordinator.snapshots.count) snapshots, not the restored one and the fresh build")
        }
        XCTAssertEqual(warmCoordinator.snapshots[0].builtAt, restoredAt,
                       "the first snapshot handed over was not the persisted one")
        XCTAssertNotEqual(warmCoordinator.snapshots[1].builtAt, restoredAt,
                          "the second snapshot handed over was the persisted one again, not the fresh build")

        let bothDeltas = warmCoordinator.expectDeltas(2)
        warm.watcher.emit([warmHome.appending(path: "projects/invented/one.jsonl")])
        warm.watcher.emit([warmHome.appending(path: "projects/invented/two.jsonl")])
        await fulfillment(of: [bothDeltas], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(warmCoordinator.deltas.count, 2,
                       "the coordinator saw \(warmCoordinator.deltas.count) deltas for two watcher batches")
        warm.watcher.finish()

        // Cold: nothing persisted, and the coordinator must still hear about the build.
        var cold = try makeRig(persisted: nil)
        let coldCoordinator = RecordingCoordinator()
        cold.sequence.makeCoordinator = { _ in coldCoordinator }

        let coldSnapshot = coldCoordinator.expectSnapshots(1)
        let coldRoute = await cold.sequence.run()
        XCTAssertNotNil(coldRoute.workspace)
        await fulfillment(of: [coldSnapshot], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(coldCoordinator.snapshots.count, 1,
                       "a cold launch handed the coordinator \(coldCoordinator.snapshots.count) snapshots, not the one from the build")
        cold.watcher.finish()
    }

    // MARK: - The watcher's changes reach every consumer

    /// Spec §2 step 10 has two consumers of one stream: the index, which the composition root
    /// pumps, and `StreamIngestion.fileChanged(_:)` for the open channel, which is Task 7's.
    ///
    /// `TranscriptWatching.changes` is a single `AsyncStream`, and a second `for await` on one of
    /// those splits its elements between the loops rather than duplicating them — so a composition
    /// root that consumed the watcher directly would have taken the only subscription and left the
    /// second consumer with nothing it could do that did not rewrite `LaunchSequence`. Both counts
    /// below are asserted, because a split shows up as each consumer seeing *some* of the batches.
    @MainActor
    func testEveryWatcherChangeReachesEverySubscriber() async throws {
        var rig = try makeRig()
        let coordinator = RecordingCoordinator()
        rig.sequence.makeCoordinator = { _ in coordinator }

        let route = await rig.sequence.run()
        let workspace = try XCTUnwrap(route.workspace)
        let feed = try XCTUnwrap(workspace.changes,
                                 "the workspace carries no change feed for a second consumer to subscribe to")

        // Task 7's subscription, taken after the composition root has taken the index's.
        let second = await feed.subscribe()
        let collected = BatchCollector()
        let reader = Task { for await batch in second { await collected.append(batch.paths) } }

        let secondSawAll = await collected.expect(3)
        let indexSawAll = coordinator.expectDeltas(3)
        for number in 1...3 {
            rig.watcher.emit([workspace.configHome.root.appending(path: "projects/invented/\(number).jsonl")])
        }

        await fulfillment(of: [secondSawAll, indexSawAll], timeout: LaunchFixtures.hangGuard)
        let secondCount = await collected.count
        XCTAssertEqual(secondCount, 3, "the second subscriber saw \(secondCount) of three batches")
        XCTAssertEqual(coordinator.deltas.count, 3,
                       "the index pump saw \(coordinator.deltas.count) of three batches")

        reader.cancel()
        rig.watcher.finish()
    }

    /// A batch the watcher produced while the launch was still assembling itself reaches the index.
    ///
    /// This is the regression the first fan-out introduced. `TranscriptWatcher.changes` is
    /// `.unbounded`, so the `for await` it replaced buffered and lost nothing; a feed that starts
    /// pumping at construction and delivers only to the continuations existing at that instant
    /// throws away everything arriving before the index subscribes — several suspension points
    /// later, across a main-actor hop and `loadPersisted()`'s file I/O. Silent, and a lost batch is
    /// a transcript change the sidebar never learns about.
    ///
    /// Two batches are yielded **before** `run()` is called, so they are already in the watcher's
    /// own buffer when the feed is constructed, and the injected index sleeps twenty milliseconds
    /// inside `loadPersisted()` — the same suspension the production index takes there, reading the
    /// store — so a pump that started at construction has certainly drained them before any late
    /// subscription could be taken. Without that suspension the failure would be a race rather than
    /// a result.
    @MainActor
    func testAWatcherBatchFromBeforeTheLaunchFinishedStillReachesTheIndex() async throws {
        var rig = try makeRig(loadDelay: .milliseconds(20))
        let coordinator = RecordingCoordinator()
        rig.sequence.makeCoordinator = { _ in coordinator }

        let allThree = coordinator.expectDeltas(3)
        let home = rig.configHome
        rig.watcher.emit([home.appending(path: "projects/invented/early-one.jsonl")])
        rig.watcher.emit([home.appending(path: "projects/invented/early-two.jsonl")])

        let route = await rig.sequence.run()
        XCTAssertNotNil(route.workspace)

        rig.watcher.emit([home.appending(path: "projects/invented/late.jsonl")])

        await fulfillment(of: [allThree], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(coordinator.deltas.count, 3,
                       "the index saw \(coordinator.deltas.count) of three batches; two of them were produced before the launch finished")
        rig.watcher.finish()
    }

    // MARK: - The stall report

    /// The change pump's stall rule, both directions, and that a healthy launch stays quiet.
    ///
    /// The rule exists because the waits in this file are now fulfilled by the delivery itself
    /// rather than by a stopwatch — right for the tests, but it means a pump that stalls in
    /// production would be silent everywhere. Both directions are asserted because a rule that
    /// reported every delivery would be as useless as one that reported none: the log would be
    /// nothing but change notices and nobody would read it.
    @MainActor
    func testALateDeliveryIsReportedAndATimelyOneIsNot() async throws {
        let paths = [URL(filePath: "/invented/project/one.jsonl"), URL(filePath: "/invented/project/two.jsonl")]
        let received = ContinuousClock.now

        let late = TranscriptChangePump.notice(for: TranscriptChangeBatch(paths: paths, receivedAt: received),
                                               handledAt: received + .seconds(3))
        XCTAssertEqual(late, .transcriptChangeStalled(paths: 2, waitedMs: 3000))

        // Just inside the threshold, and just outside it: the boundary is where a rule with the
        // comparison backwards would show up.
        XCTAssertNil(TranscriptChangePump.notice(for: TranscriptChangeBatch(paths: paths, receivedAt: received),
                                                 handledAt: received + .milliseconds(1999)),
                     "a delivery inside the threshold was reported")
        XCTAssertNotNil(TranscriptChangePump.notice(for: TranscriptChangeBatch(paths: paths, receivedAt: received),
                                                    handledAt: received + .milliseconds(2000)),
                        "a delivery exactly at the threshold was not reported")
        XCTAssertNil(TranscriptChangePump.notice(for: TranscriptChangeBatch(paths: paths, receivedAt: received),
                                                 handledAt: received + .milliseconds(40)),
                     "an ordinary delivery was reported")

        // And end to end: a launch whose deliveries are prompt writes no stall line at all.
        var rig = try makeRig()
        let coordinator = RecordingCoordinator()
        rig.sequence.makeCoordinator = { _ in coordinator }
        let composerBox = DiagnosticsBox()
        rig.sequence.makeDiagnostics = { directory in
            let composer = DiagnosticsComposer(directory: directory)
            composerBox.set(composer)
            return composer
        }

        let delta = coordinator.expectDeltas(1)
        let route = await rig.sequence.run()
        let workspace = try XCTUnwrap(route.workspace)
        rig.watcher.emit([workspace.configHome.root.appending(path: "projects/invented/one.jsonl")])
        await fulfillment(of: [delta], timeout: LaunchFixtures.hangGuard)

        let composer = try XCTUnwrap(composerBox.value)
        composer.flush()
        let log = composer.directory.appending(path: "app.log")
        let written = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        XCTAssertTrue(written.isEmpty,
                      "a launch with prompt deliveries wrote a stall line: \(written)")
        // The floor: the file the emptiness is asserted over is the one the pump would have
        // written to, and it exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "app.log was never created")
        rig.watcher.finish()
    }

    // F3: an index mutation is forbidden during both the build and snapshot delivery.
    // The inverted wait detects the forbidden call; its result is asserted. The final
    // positive wait and ordered path comparison prove all buffered batches are replayed.
    @MainActor
    func testWatcherBatchesWaitForBuildAndSnapshotDelivery() async throws {
        for blockDelivery in [false, true] {
            let rig = try makeRig(blockingBuild: !blockDelivery)
            let coordinator = RecordingCoordinator()
            let (gate, release) = AsyncStream<Void>.makeStream()
            let delivering = XCTestExpectation(description: "snapshot delivery entered")
            if blockDelivery {
                coordinator.beforeSnapshotDelivery = {
                    delivering.fulfill()
                    for await _ in gate { break }
                }
            }
            var sequence = rig.sequence
            sequence.makeCoordinator = { _ in coordinator }
            let forbidden = expectation(description: "index updated before snapshot delivery completed")
            forbidden.isInverted = true
            await rig.index.observeUpdates { forbidden.fulfill() }
            let route = await sequence.run()
            guard case .workspace = route else { return XCTFail("launch did not reach workspace") }
            if blockDelivery {
                let result = await XCTWaiter.fulfillment(of: [delivering], timeout: 3)
                XCTAssertEqual(result, .completed, "snapshot delivery never entered")
            }
            let paths = [rig.configHome.appending(path: "projects/invented/early-one.jsonl"),
                         rig.configHome.appending(path: "projects/invented/early-two.jsonl")]
            for path in paths { rig.watcher.emit([path]) }
            let premature = await XCTWaiter.fulfillment(of: [forbidden], timeout: 0.2)
            XCTAssertEqual(premature, .completed, "watcher mutated the index before its snapshot landed")
            await rig.index.observeUpdates {}
            release.yield(())
            rig.index.releaseBuild()
            let delivered = await XCTWaiter.fulfillment(of: [coordinator.expectDeltas(2), coordinator.expectSnapshots(1)], timeout: 3)
            XCTAssertEqual(delivered, .completed, "buffered batches were lost")
            let updates = await rig.index.updated
            XCTAssertEqual(updates.count, 2, "expected both buffered batches exactly once")
            XCTAssertTrue(updates == paths.map { [$0] }, "buffered batches were reordered")
            XCTAssertEqual(coordinator.snapshots.count, 1, "the built snapshot was not delivered")
            rig.watcher.finish()
        }
    }

    // MARK: - The build is not awaited

    /// C3 measured that an index build awaited from a main-actor-bound caller runs at about a third
    /// of the machine's width, so the composition root issues it detached and returns. The assertion
    /// is on ordering: `run()` reaches `.workspace` while the injected `build()` is still blocked,
    /// and the coordinator hears about the snapshot only once the test lets the build go.
    ///
    /// Run inside a task with a deadline rather than awaited directly, so an implementation that
    /// awaited the build would fail this test rather than hang the suite.
    @MainActor
    func testIndexBuildIsNotAwaitedOnTheMainActor() async throws {
        let rig = try makeRig(blockingBuild: true)
        let coordinator = RecordingCoordinator()
        var sequence = rig.sequence
        sequence.makeCoordinator = { _ in coordinator }

        let outcome = RouteBox()
        let hasReturned = expectation(description: "run() returned while the injected build was blocked")
        let running = Task {
            await outcome.set(sequence.run())
            hasReturned.fulfill()
        }

        // The one wait in this file whose bound is doing real work, and the reason is the assertion
        // itself: against an implementation that awaited the build inline, `run()` never returns,
        // and there is no signal for something that does not happen. The bound turns that hang into
        // a reported failure. It is not a threshold this test approaches — it passes in hundredths
        // of a second — and the verdict on the passing path is the fulfilment, not the clock.
        await fulfillment(of: [hasReturned], timeout: LaunchFixtures.hangGuard)
        let returned = await outcome.isWorkspace
        XCTAssertTrue(returned,
                      "run() had not returned a workspace while the injected build() was still blocked")
        XCTAssertTrue(coordinator.snapshots.isEmpty,
                      "the coordinator was handed a snapshot before the build was released")

        let landed = coordinator.expectSnapshots(1)
        rig.index.releaseBuild()

        await fulfillment(of: [landed], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(coordinator.snapshots.count, 1, "the released build never reached the coordinator")
        let builds = await rig.index.buildCount
        XCTAssertEqual(builds, 1, "the build ran \(builds) times")
        rig.watcher.finish()
        _ = await running.value
    }

    // MARK: - Support

    /// `Tools/fake-claude/fake-claude`, from this file: AppTests/ → the repository root.
    private static var fakeClaude: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tools/fake-claude/fake-claude")
    }

    /// A route written from one task and read from another.
    private actor RouteBox {
        private var route: AppRoute?
        func set(_ value: AppRoute) { route = value }
        var isWorkspace: Bool { route?.workspace != nil }
    }
}
