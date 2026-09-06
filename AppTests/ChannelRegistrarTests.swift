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

        index.releaseBuild()

        let expected = Set([listedA, listedB].map { ChannelKey(configHome: home, session: $0) })
        XCTAssertFalse(expected.isEmpty)
        let arrived = await LaunchFixtures.waitAsync { await registrar.keys == expected }
        let keys = await registrar.keys
        XCTAssertTrue(arrived, "the cold launch registered \(keys.count) of \(expected.count) listed channels")
        XCTAssertEqual(keys, expected)
        let calls = await registrar.count
        XCTAssertEqual(calls, expected.count, "each listed channel is registered exactly once")

        // And the live half arrives: a `ChannelState` pushed through `updates` reaches its row.
        let found = await MainActor.run { coordinatorBox.value }
        let coordinator = try XCTUnwrap(found)
        let painted = await LaunchFixtures.wait { coordinator.model.row(listedA) != nil }
        XCTAssertTrue(painted, "the model never painted the registered rows")
        let key = ChannelKey(configHome: home, session: listedA)
        let glyphBefore = await MainActor.run { coordinator.model.row(listedA)?.originGlyph }
        XCTAssertNil(glyphBefore, "a row carried an origin before any ChannelState arrived")
        fleet.emit(SidebarFixtures.state(key, origin: .owned(.ready)))
        let joined = await LaunchFixtures.wait { coordinator.model.row(listedA)?.originGlyph == .ready }
        XCTAssertTrue(joined, "the ChannelState never reached the row")
    }

    // MARK: - Support

    /// A single-owner box for the coordinator the launch built. `@unchecked Sendable` is sound
    /// because `value` is read and written only on the main actor, which serialises every access.
    final class CoordinatorBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
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
            fleetFactory: { _, _, _, _, _ in fleet },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })
    }
}
