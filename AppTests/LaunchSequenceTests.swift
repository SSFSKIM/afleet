import Foundation
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
        let index = StubIndex(persisted: persisted, built: built, blocks: blockingBuild, delta: delta)
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
            ClaudeJSONReader.hasCompletedOnboarding(configHome: root)
        }
        try refused.temp.file("home/.claude.json", #"{"hasCompletedOnboarding": false}"#)

        let refusedRoute = await refusedSequence.run()
        XCTAssertEqual(refusedRoute.setupState, .notSignedIn(configHome: LaunchFixtures.directoryURL(refusedHome)))
        XCTAssertFalse(refused.log.reached("fleetFactory"), "a Fleet was constructed for a home with no account")

        let accepted = try makeRig()
        var acceptedSequence = accepted.sequence
        acceptedSequence.readClaudeJSON = { ClaudeJSONReader.hasCompletedOnboarding(configHome: $0) }
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
        XCTAssertEqual(workspace.configHome.root.path, configHome.path)
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

        XCTAssertEqual(diagnosticsRoute.setupState,
                       .writeRootInsideConfigHome(root: .diagnostics,
                                                  configHome: LaunchFixtures.directoryURL(diagnosticsRig.configHome)))
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

        XCTAssertEqual(storeRoute.setupState,
                       .writeRootInsideConfigHome(root: .store,
                                                  configHome: LaunchFixtures.directoryURL(storeRig.configHome)))
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

        let warmRoute = await warm.sequence.run()
        XCTAssertNotNil(warmRoute.workspace)

        let sawBoth = await LaunchFixtures.wait { warmCoordinator.snapshots.count >= 2 }
        XCTAssertTrue(sawBoth,
                      "the coordinator saw \(warmCoordinator.snapshots.count) snapshots, not the restored one and the fresh build")
        XCTAssertEqual(warmCoordinator.snapshots.first?.builtAt, restoredAt,
                       "the first snapshot handed over was not the persisted one")
        XCTAssertNotEqual(warmCoordinator.snapshots[1].builtAt, restoredAt,
                          "the second snapshot handed over was the persisted one again, not the fresh build")

        warm.watcher.emit([warmHome.appending(path: "projects/invented/one.jsonl")])
        warm.watcher.emit([warmHome.appending(path: "projects/invented/two.jsonl")])
        let sawDeltas = await LaunchFixtures.wait { warmCoordinator.deltas.count == 2 }
        XCTAssertTrue(sawDeltas,
                      "the coordinator saw \(warmCoordinator.deltas.count) deltas for two watcher batches")
        warm.watcher.finish()

        // Cold: nothing persisted, and the coordinator must still hear about the build.
        var cold = try makeRig(persisted: nil)
        let coldCoordinator = RecordingCoordinator()
        cold.sequence.makeCoordinator = { _ in coldCoordinator }

        let coldRoute = await cold.sequence.run()
        XCTAssertNotNil(coldRoute.workspace)
        let sawCold = await LaunchFixtures.wait { coldCoordinator.snapshots.count == 1 }
        XCTAssertTrue(sawCold,
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
        let reader = Task { for await batch in second { await collected.append(batch) } }

        for number in 1...3 {
            rig.watcher.emit([workspace.configHome.root.appending(path: "projects/invented/\(number).jsonl")])
        }

        let secondSawAll = await LaunchFixtures.waitAsync { await collected.count == 3 }
        let secondCount = await collected.count
        XCTAssertTrue(secondSawAll, "the second subscriber saw \(secondCount) of three batches")

        let indexSawAll = await LaunchFixtures.wait { coordinator.deltas.count == 3 }
        XCTAssertTrue(indexSawAll, "the index pump saw \(coordinator.deltas.count) of three batches")

        reader.cancel()
        rig.watcher.finish()
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
        let running = Task { await outcome.set(sequence.run()) }

        let returned = await LaunchFixtures.waitAsync(upTo: .seconds(3), for: { await outcome.isWorkspace })
        XCTAssertTrue(returned,
                      "run() had not returned a workspace while the injected build() was still blocked")
        XCTAssertTrue(coordinator.snapshots.isEmpty,
                      "the coordinator was handed a snapshot before the build was released")

        rig.index.releaseBuild()

        let landed = await LaunchFixtures.wait { coordinator.snapshots.count == 1 }
        XCTAssertTrue(landed, "the released build never reached the coordinator")
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
