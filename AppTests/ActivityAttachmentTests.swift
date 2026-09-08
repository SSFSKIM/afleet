import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The composition root's one ordering rule about Activity (spec §5): **nothing the user can act on
/// is on screen before Activity is following the fleet.**
///
/// Supervisor events do not replay. A request emitted while an action is in flight reaches whoever
/// is already subscribed and nobody else, so an adopt issued in the gap between the route being
/// published and Activity installing its hooks loses the payload of the very card it was going to
/// raise — the row survives as a bare decision with no answer control, and nothing else in the app
/// would notice.
@MainActor
final class ActivityAttachmentTests: XCTestCase {

    /// A launch whose fleet answers actions and hands out event streams, so an adopt driven through
    /// the composition root reaches something that behaves like C4's.
    private struct Rig {
        let temp: TempTree
        let configHome: URL
        let fleet: LifecycleDouble
        var sequence: LaunchSequence
    }

    private func makeRig() throws -> Rig {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let fleet = LifecycleDouble()
        let index = StubIndex(persisted: nil,
                              built: LaunchFixtures.snapshot(configHome: configHome, ids: [LaunchFixtures.sessionA]),
                              delta: IndexDelta(added: [LaunchFixtures.sessionA]))
        let watcher = StubWatcher()
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in index },
            fleetFactory: { _, _, _, _, _, _ in fleet },
            makeWatcher: { _ in watcher },
            readClaudeJSON: { _ in true })

        return Rig(temp: temp, configHome: configHome, fleet: fleet, sequence: sequence)
    }

    /// Runs `body` on the first turn of the main actor after the route carries a workspace — which
    /// is what a view that becomes actionable on the route does. Re-arms itself, because the launch
    /// republishes `.launching` before it reaches anything.
    private static func onWorkspaceRoute(_ model: AppModel, _ body: @escaping @MainActor () async -> Void) {
        withObservationTracking {
            _ = model.route
        } onChange: {
            Task { @MainActor in
                if model.route.workspace != nil { await body() } else { onWorkspaceRoute(model, body) }
            }
        }
    }

    /// An adopt issued as soon as the workspace route appears is observed by Activity: the request
    /// the engine emits inside `perform` lands on a subscription that already exists, and the row it
    /// produces carries its answer control.
    ///
    /// The assertion is the *answerable* card, not the row: a decision row comes from the state's
    /// `pendingDecisions` and appears either way, so a test asserting on the row alone would pass
    /// against a route published before Activity was attached.
    func testAnAdoptIssuedOnTheRouteIsObservedByActivity() async throws {
        let rig = try makeRig()
        let model = AppModel(sequence: rig.sequence)
        let key = ChannelKey(configHome: LaunchFixtures.directoryURL(rig.configHome),
                             session: LaunchFixtures.sessionB)
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        await rig.fleet.openEvents(of: key)
        await rig.fleet.stage(.success(ActivityFixtures.state(key, pending: [ActivityFixtures.pending(ask)])))
        // Like the supervisor: emitted to whoever is subscribed at that moment, never replayed.
        await rig.fleet.emitDuringPerform([.request(ask)])

        let adopted = expectation(description: "adopt issued on the route")
        Self.onWorkspaceRoute(model) {
            guard let browser = model.browser else { return XCTFail("the route carried a workspace with no browser") }
            await browser.adopt(JobEntry(short: JobShort(rawValue: "invented-job"), state: "running",
                                         kind: "session", sessionID: key.session, cwd: nil, name: nil))
            adopted.fulfill()
        }

        await model.launch()
        let issued = await XCTWaiter.fulfillment(of: [adopted], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(issued, .completed, "the adopt was never issued")

        let activity = try XCTUnwrap(model.activity, "the launch reached a workspace and built no Activity")
        let performed = await rig.fleet.performCount
        XCTAssertEqual(performed, 1, "the adopt never reached the fleet")
        XCTAssertEqual(activity.items.filter { $0.key == key }.compactMap(\.ask).count, 1,
                       "the request emitted during the adopt reached no subscription")
        activity.stop()
    }
}

/// `LifecycleDouble` as the composition root's fleet. It records nothing about registration — that
/// is `RegistrarDouble`'s job and this conformance deliberately keeps the two apart.
extension LifecycleDouble: AppFleet {
    func start() async {}
    func shutdown() async { finish() }
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async {}
}
