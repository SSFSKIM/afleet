import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Registration: what `Fleet.register(_:cwd:recent:)` is handed, and that a cold launch hands it
/// anything at all.
final class ChannelRegistrarTests: XCTestCase {

    /// Every registration carries the entry's **own** working directory and never the config home,
    /// and `recent` follows §8.2's thirty-day rule over the entry's mtime.
    ///
    /// The cwd clause is not decoration: C4 is explicit that a key with no seed runs in the config
    /// home and every precondition then refuses it, so a registrar that passed the home would produce
    /// a fleet where nothing can ever be opened. Both branches of `recent` are asserted, and each
    /// expected set is asserted non-empty first, so a listing that came back empty cannot pass by
    /// comparing nothing to nothing.
    func testRegistrationSeedsARealCWDAndRecency() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)

        let freshA = SidebarFixtures.session("1")
        let freshB = SidebarFixtures.session("2")
        let staleA = SidebarFixtures.session("3")
        let staleB = SidebarFixtures.session("4")
        let homeless = SidebarFixtures.session("5")

        let snapshot = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(freshA, configHome: home, cwd: "/invented/project-alpha",
                                  mtime: clock.addingTimeInterval(-3600)),
            // One hour inside the window: the boundary, on the recent side.
            SidebarFixtures.entry(freshB, configHome: home, cwd: "/invented/project-beta",
                                  mtime: clock.addingTimeInterval(-(ChannelRegistrar.recencyWindow - 3600))),
            // One hour outside it: the boundary, on the other side.
            SidebarFixtures.entry(staleA, configHome: home, cwd: "/invented/project-alpha",
                                  mtime: clock.addingTimeInterval(-(ChannelRegistrar.recencyWindow + 3600))),
            SidebarFixtures.entry(staleB, configHome: home, cwd: "/invented/project-gamma",
                                  mtime: clock.addingTimeInterval(-400 * 24 * 3600)),
            // No `cwd` at all: not registered, counted instead.
            SidebarFixtures.entry(homeless, configHome: home, cwd: nil,
                                  mtime: clock.addingTimeInterval(-60)),
        ])

        let listing = ChannelRegistrar.listed(snapshot, configHome: home, now: clock)
        XCTAssertEqual(listing.rows.count, 5, "every entry here is listed; the join lost one")

        let registrar = RegistrarDouble()
        let report = await ChannelRegistrar.register(listing, into: registrar, now: clock)

        let calls = await registrar.calls
        XCTAssertEqual(calls.count, 4, "four entries carry a cwd and exactly four may be registered")
        XCTAssertEqual(report.skippedWithoutCWD, 1)
        XCTAssertEqual(report.registered, 4)

        // The cwd clause, stated twice: the positive form (each call carries its own entry's
        // directory) and the negative one (no call carries the config home).
        let expectedCWD: [SessionID: String] = [
            freshA: "/invented/project-alpha",
            freshB: "/invented/project-beta",
            staleA: "/invented/project-alpha",
            staleB: "/invented/project-gamma",
        ]
        XCTAssertFalse(expectedCWD.isEmpty)
        for call in calls {
            guard let expected = expectedCWD[call.key.session] else {
                return XCTFail("a session was registered that no entry named")
            }
            XCTAssertEqual(call.cwd.path, expected)
            XCTAssertNotEqual(call.cwd.path, home.path, "a registration was seeded with the config home")
        }
        XCTAssertNil(calls.first { $0.key.session == homeless },
                     "an entry with no cwd was registered against something")

        // Both branches of `recent`, compared as sets in both directions.
        let expectedRecent = Set([freshA, freshB].map { ChannelKey(configHome: home, session: $0) })
        let expectedStale = Set([staleA, staleB].map { ChannelKey(configHome: home, session: $0) })
        XCTAssertFalse(expectedRecent.isEmpty)
        XCTAssertFalse(expectedStale.isEmpty)
        let recorded = await registrar.recentKeys
        let recordedStale = await registrar.staleKeys
        XCTAssertEqual(recorded, expectedRecent)
        XCTAssertEqual(recordedStale, expectedStale)
        XCTAssertEqual(report.recent, 2)
    }

    /// The end-to-end claim, over the real composition seam: a cold launch registers every listed
    /// channel, and a `ChannelState` pushed afterwards reaches the matching row.
    ///
    /// This is the assertion an isolated registrar test cannot make. A registrar nothing calls passes
    /// every unit test written about it, and the launch it is missing from ends with no supervisors —
    /// so `Fleet.events(of:)` returns nil for every key, and no row ever gets a live origin, an
    /// Activity event or an owned timeline. The launch is driven for real: `loadPersisted()` returns
    /// nil, `build()` blocks on a gate the test releases only **after** `run()` has already returned
    /// `.workspace`, and the registrations are counted after the release.
    func testAColdLaunchRegistersEveryEligibleChannel() async throws {
        let tree = try TempTree()
        let scratch = try ScratchConfigHome(tree: tree)
        try scratch.writeClaudeJSON(projects: ["/invented/project-alpha"])
        let home = LaunchFixtures.directoryURL(scratch.root)

        let listedA = SidebarFixtures.session("6")
        let listedB = SidebarFixtures.session("7")
        let excluded = SidebarFixtures.session("8")
        let built = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(listedA, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
            SidebarFixtures.entry(listedB, configHome: home, cwd: "/invented/project-beta", mtime: Date()),
            // A sidechain: listed by nothing, so registered by nothing either.
            SidebarFixtures.entry(excluded, configHome: home, cwd: "/invented/project-alpha",
                                  mtime: Date(), isSidechain: true),
        ])

        let index = StubIndex(persisted: nil, built: built, blocks: true)
        let fleet = FleetDouble()
        let registrar = RegistrarDouble()
        let coordinatorBox = CoordinatorBox()

        var sequence = try Self.sequence(tree: tree, configHome: scratch.root, fleet: fleet, index: index)
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(configHome: workspace.configHome.root,
                                               registrar: registrar,
                                               index: workspace.index,
                                               model: FleetBrowserModel(lifecycle: fleet,
                                                                        configHome: workspace.configHome.root))
            coordinatorBox.value = coordinator
            return coordinator
        }

        let route = await sequence.run()
        guard route.workspace != nil else {
            return XCTFail("the launch did not reach a workspace: \(route)")
        }
        // Nothing has been registered yet: the build is still blocked, and this launch had no
        // persisted snapshot to paint from.
        let beforeRelease = await registrar.count
        XCTAssertEqual(beforeRelease, 0, "registration ran before the index had built")

        let expected = Set([listedA, listedB].map { ChannelKey(configHome: home, session: $0) })
        XCTAssertFalse(expected.isEmpty)
        let bothRegistered = await registrar.expect(expected.count)
        index.releaseBuild()

        await fulfillment(of: [bothRegistered], timeout: LaunchFixtures.hangGuard)
        let keys = await registrar.keys
        // A boolean, not an equality: `ChannelKey` carries the config home, and this test's home is
        // the scratch tree's, so printing either set would print a runtime-derived path.
        XCTAssertTrue(keys == expected,
                      "the cold launch registered \(keys.count) of \(expected.count) listed channels")
        let calls = await registrar.count
        XCTAssertEqual(calls, expected.count, "each listed channel is registered exactly once")

        // And the live half arrives: a `ChannelState` pushed through `updates` reaches its row.
        let found = await MainActor.run { coordinatorBox.value }
        let coordinator = try XCTUnwrap(found)
        await Self.until(coordinator.model, "the model never painted the registered rows") {
            $0.row(listedA) != nil
        }
        let key = ChannelKey(configHome: home, session: listedA)
        let glyphBefore = await MainActor.run { coordinator.model.row(listedA)?.originGlyph }
        XCTAssertNil(glyphBefore, "a row carried an origin before any ChannelState arrived")
        fleet.emit(SidebarFixtures.state(key, origin: .owned(.ready)))
        await Self.until(coordinator.model, "the ChannelState never reached the row") {
            $0.row(listedA)?.originGlyph == .ready
        }
    }

    /// I1: a cold launch is painted as the **build** it is, not as a restored snapshot.
    ///
    /// The coordinator used to decide by "is this the first snapshot I have seen", which is right on
    /// a warm launch and wrong on a cold one — there is no persisted snapshot, so the fresh build is
    /// the first thing to arrive and every row was flagged provisional with nothing left to clear
    /// it. The two halves are asserted together: cold ends not provisional, warm is provisional
    /// after the restore and not provisional after the build, so a coordinator that hard-coded
    /// either answer fails one of them.
    @MainActor
    func testAColdLaunchIsPaintedAsABuildAndAWarmOneRestoresThenSwaps() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let session = SidebarFixtures.session("9")
        let snapshot = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(session, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
        ])

        let cold = Self.coordinator(configHome: home, snapshot: snapshot)
        await cold.snapshotAvailable(snapshot, origin: .built)
        XCTAssertEqual(cold.model.allRows.count, 1, "the cold launch painted no row to assert about")
        XCTAssertFalse(cold.model.isProvisional,
                       "a cold launch painted its own fresh build as a restored snapshot")
        XCTAssertFalse(try XCTUnwrap(cold.model.row(session)).isProvisional)

        let warm = Self.coordinator(configHome: home, snapshot: snapshot)
        await warm.snapshotAvailable(snapshot, origin: .restored)
        XCTAssertTrue(warm.model.isProvisional, "the restored paint was not marked provisional")
        XCTAssertTrue(try XCTUnwrap(warm.model.row(session)).isProvisional)
        await warm.snapshotAvailable(snapshot, origin: .built)
        XCTAssertFalse(warm.model.isProvisional, "the fresh build did not clear the provisional paint")
        XCTAssertFalse(try XCTUnwrap(warm.model.row(session)).isProvisional)
    }

    /// I2: the persisted `SidebarGrouping` is read from the store and reaches the sections.
    ///
    /// Pinning is the observable: the store names a session as pinned, and the section holding it
    /// sorts first even though the other project is the more recently active and would otherwise
    /// lead. Without the store read the grouping stays at its empty default and activity order wins.
    @MainActor
    func testThePersistedSidebarGroupingIsLoadedAndPinsASection() async throws {
        let tree = try TempTree()
        let older = try tree.directory("repo-older")
        let newer = try tree.directory("repo-newer")
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let now = Date()
        let pinned = SidebarFixtures.session("a")
        let busy = SidebarFixtures.session("b")
        let snapshot = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(pinned, configHome: home, cwd: older.path, mtime: now.addingTimeInterval(-9000)),
            SidebarFixtures.entry(busy, configHome: home, cwd: newer.path, mtime: now.addingTimeInterval(-10)),
        ])

        let store = try FileStateStore(baseDirectory: try tree.directory("store"),
                                       configHomes: [URL(fileURLWithPath: "/invented/config-home")])
        try await store.write(SidebarGrouping(pinned: [pinned]), namespace: .fleetKit,
                              key: FleetKitKeys.grouping)

        let coordinator = Self.coordinator(configHome: home, snapshot: snapshot, store: store)
        await coordinator.snapshotAvailable(snapshot, origin: .built)
        XCTAssertEqual(coordinator.model.sections.count, 2,
                       "the model built \(coordinator.model.sections.count) sections, not two")

        // The load is deliberately off the launch's critical path, so it lands after the paint. The
        // wait is on `hasGrouping` and the assertions that follow do not wait at all, which is what
        // makes the flag load-bearing in both directions: a flag that is never set leaves the wait
        // to the hang guard, and a flag that is always set lets these assertions run before the read
        // has landed. It was briefly production state that only the environment-gated spike read,
        // which is barely better than the fiction it was introduced to replace.
        await Self.until(coordinator.model, "the ordering inputs were never applied") { $0.hasGrouping }
        XCTAssertTrue(coordinator.model.sections.first?.isPinned == true,
                      "the persisted grouping never reached the sections")
        XCTAssertEqual(coordinator.model.sections.map(\.title), ["repo-older", "repo-newer"])
    }

    /// Minor 2: the count of channels registration declined is the count of *channels*, not of
    /// times it declined. A warm launch hands the coordinator the restored snapshot and then the
    /// fresh build, and the same cwd-less rows are in both.
    @MainActor
    func testTheSkippedWithoutCWDCountDoesNotDoubleOnAWarmLaunch() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let homeless = SidebarFixtures.session("c")
        let placed = SidebarFixtures.session("d")
        let snapshot = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(homeless, configHome: home, cwd: nil, mtime: Date()),
            SidebarFixtures.entry(placed, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
        ])
        let coordinator = Self.coordinator(configHome: home, snapshot: snapshot)

        await coordinator.snapshotAvailable(snapshot, origin: .restored)
        XCTAssertEqual(coordinator.skippedWithoutCWDCount, 1,
                       "the restored snapshot alone counted \(coordinator.skippedWithoutCWDCount)")
        await coordinator.snapshotAvailable(snapshot, origin: .built)
        XCTAssertEqual(coordinator.skippedWithoutCWDCount, 1,
                       "the fresh build counted the same row again: \(coordinator.skippedWithoutCWDCount)")
        // The floor: the model's own count agrees, so the two are not both wrong in the same way.
        XCTAssertEqual(coordinator.model.listedWithoutCWD, 1)
    }

    /// Minor 4: a second launch stops the coordinator the first one built before replacing it.
    @MainActor
    func testASecondLaunchStopsTheCoordinatorTheFirstOneBuilt() async throws {
        let tree = try TempTree()
        let scratch = try ScratchConfigHome(tree: tree)
        try scratch.writeClaudeJSON(projects: [])
        let built = SidebarFixtures.snapshot(configHome: LaunchFixtures.directoryURL(scratch.root), entries: [])

        let coordinators = CoordinatorLog()
        let sequence = try Self.sequence(tree: tree, configHome: scratch.root, fleet: FleetDouble(),
                                         index: StubIndex(persisted: nil, built: built))
        let model = AppModel(sequence: sequence, coordinatorFactory: { _ in
            let coordinator = StoppableCoordinatorDouble()
            coordinators.built.append(coordinator)
            return coordinator
        })

        await model.launch()
        XCTAssertEqual(coordinators.built.count, 1, "the first launch built \(coordinators.built.count) coordinators")
        XCTAssertEqual(coordinators.built[0].stops, 0, "the first coordinator was stopped before anything replaced it")

        await model.launch()
        XCTAssertEqual(coordinators.built.count, 2)
        XCTAssertEqual(coordinators.built[0].stops, 1,
                       "the second launch left the first coordinator's updates loop running")
        XCTAssertEqual(coordinators.built[1].stops, 0)
    }

    /// The coordinators one test's launches built, in order.
    @MainActor
    final class CoordinatorLog {
        var built: [StoppableCoordinatorDouble] = []
        init() {}
    }

    // MARK: - Support

    /// A single-owner box for the coordinator the launch built. `@unchecked Sendable` is sound
    /// because `value` is read and written only on the main actor, which serialises every access.
    final class CoordinatorBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }

    /// Waits for a condition on the model, fulfilled by the rebuild that makes it true.
    ///
    /// `FleetBrowserModel.whenChanged` is the signal; the expectation around it is only a hang
    /// guard, three orders of magnitude above what these waits take, so a genuine regression is
    /// reported as a failure rather than hanging the bundle. Nothing here consults a clock on the
    /// passing path — the earlier shape re-read the model on a five-millisecond loop, which makes
    /// the verdict depend on how much of the machine the polling task got.
    @MainActor
    static func until(_ model: FleetBrowserModel, _ message: String,
                      _ predicate: @escaping @MainActor (FleetBrowserModel) -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let reached = XCTestExpectation(description: message)
        let watcher = Task { @MainActor in
            await model.whenChanged(predicate)
            reached.fulfill()
        }
        let outcome = await XCTWaiter().fulfillment(of: [reached], timeout: LaunchFixtures.hangGuard)
        watcher.cancel()
        if outcome != .completed { XCTFail(message, file: file, line: line) }
    }

    /// A coordinator over an index that resolves from one snapshot, with no fleet behind it.
    @MainActor
    static func coordinator(configHome: URL, snapshot: IndexSnapshot,
                            store: (any StateStore)? = nil) -> FleetCoordinator {
        let fleet = LifecycleDouble()
        return FleetCoordinator(configHome: configHome,
                                registrar: RegistrarDouble(),
                                index: StubIndex(persisted: nil, built: snapshot),
                                model: FleetBrowserModel(lifecycle: fleet, configHome: configHome),
                                store: store)
    }

    /// A launch whose every external seam is a stub, reaching a workspace over the scratch home.
    static func sequence(tree: TempTree, configHome: URL, fleet: FleetDouble,
                         index: StubIndex) throws -> LaunchSequence {
        let storeRoot = try tree.directory("store")
        let logsRoot = try tree.directory("logs")
        let binary = tree.root.appending(path: "claude-that-never-runs")
        let environment = LaunchFixtures.environment(home: tree.root, configHome: configHome)
        return LaunchSequence(
            storeRoot: storeRoot,
            diagnosticsRoot: logsRoot,
            resolveEnvironment: { environment },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 257)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in index },
            fleetFactory: { _, _, _, _, _, _ in fleet },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })
    }
}
