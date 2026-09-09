import Foundation
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7's Parent-Level Acceptance item 3, the `.command` clause: a `WorkspaceLink.command` reaches the
/// composer of the channel it was raised in, through a target the **app** registers.
///
/// The distinction this file exists for: `LinkRouterTests.testCommandLinkReachesTheTarget` installs a
/// catch-all target of its own and asserts the registry delivers to it, which it did while no
/// production target claimed a command link at all — every command link the app raised reached the
/// router's diagnostic. So the first test below registers nothing itself: it drives `AppModel`'s own
/// registration, the one line the launch runs.
///
/// Every identifier is invented and no assertion prints a channel, a session or a path (§11).
@MainActor
final class CommandLinkTargetTests: XCTestCase {

    /// The app's registration alone carries a command link to the routed channel's composer, which
    /// opens the surface the command names — the same member a typed `/agents` reaches.
    func testTheAppsOwnRegistrationCarriesACommandLinkToTheChannelsComposer() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        // The window is on the second channel; the link is raised there and belongs there.
        app.panels.focusChannel(rig.keys[1])
        await app.registerCommandLinkTarget()

        await app.panels.links.open(.command("agents"), from: .currentPanel)

        XCTAssertEqual(app.composers.openChannels.count, 1,
                       "\(app.composers.openChannels.count) channel(s) received the command link")
        XCTAssertEqual(app.composers.model(for: rig.keys[1])?.openSurface, "agents",
                       "the routed channel's composer opened "
                        + "\(app.composers.model(for: rig.keys[1])?.openSurface ?? "no surface")")
    }

    /// The floor under it: the target claims command links and nothing else, so the assertion above
    /// cannot be passing on a target that swallows every link the registry has.
    func testTheTargetClaimsCommandLinksAlone() throws {
        let target = CommandLinkTarget.target(composers: ComposerRegistry(), diagnostic: { _ in })

        XCTAssertTrue(target.handles(.command("agents")), "the target does not claim a command link")
        XCTAssertFalse(target.handles(.url(URL(string: "https://invented.example/one")!)),
                       "the target claims URL links, which belong to the Browser")
        XCTAssertFalse(target.handles(.file(URL(filePath: "/invented/project/a.swift"), line: nil)),
                       "the target claims file links, which belong to Files")
        XCTAssertEqual(target.tab, .thread, "the target is registered against \(target.tab)")
    }

    /// A channel with no composer — before a launch has reached a workspace there is no lifecycle to
    /// build one over — is still *reported*. The diagnostic is what stood here when nothing claimed
    /// the link, and it stays for the one case that has nowhere to run the command.
    func testAChannelWithNoComposerIsReportedRatherThanSilent() async throws {
        let sink = DiagnosticSink()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { sink.said($0) })
        // A registry no launch has bound: `model(for:)` answers nil, because there is no X5 to send
        // through and a composer built over none could dispatch nothing.
        await router.register(CommandLinkTarget.target(composers: ComposerRegistry(),
                                                       diagnostic: { sink.said($0) }))
        let key = ChannelKey(configHome: URL(filePath: "/invented/config-home"),
                             session: PanelRig.session(3))

        await LinkOrigin.$channel.withValue(key) {
            await router.open(.command("agents"), from: .currentPanel)
        }

        XCTAssertEqual(sink.messages.count, 1, "the delivery produced \(sink.messages.count) diagnostics")
        XCTAssertFalse(sink.messages.first?.contains(key.session.description) ?? true,
                       "the diagnostic named the channel it was about (§11)")
    }

    /// And a delivery with no origin at all — the window is on Activity, or the channel left the
    /// index while the link was in flight — runs the command nowhere rather than in whichever
    /// channel is selected by the time it lands.
    func testADeliveryWithNoOriginRunsNothing() async throws {
        let rig = try await PanelRig(channels: 1)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        app.panels.focusChannel(nil)
        await app.registerCommandLinkTarget()

        await app.panels.links.open(.command("agents"), from: .currentPanel)

        XCTAssertEqual(app.composers.openChannels.count, 0,
                       "a command link with no origin built a composer in \(app.composers.openChannels.count) channel(s)")
    }
}

/// Where a target's diagnostics go under test. A class with a lock rather than an actor, because the
/// handler that writes is `@MainActor` and the assertion reads on the same actor.
private final class DiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func said(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
