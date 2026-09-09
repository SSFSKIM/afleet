import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.4 Task 2: the Agents tab, its per-channel session and its `/agents` command target.
///
/// The tab is built here the way `performLaunch` builds it — the app's one registry reached through
/// a closure, the app's one selection store handed in — which is the shape `ThreadTabTests` takes
/// for the same reason: what is under test is the tab, and a full launch adds a binary probe, a
/// version gate and a sign-in gate, none of which says anything about §8.8.
///
/// Every identifier is invented (§11) and nothing here writes anything (X9).
@MainActor
final class AgentsTabTests: XCTestCase {

    // MARK: - Registration and availability (child spec D10)

    /// `.agents` is a tab the host offers, and it offers it for a channel with a live fold **and**
    /// for one with none.
    ///
    /// Both halves matter and neither implies the other: `isRegistered` says an id is taken, and
    /// `available(for:)` is what the panel column draws, which additionally asks the tab whether it
    /// can render this channel. A tab that hid itself for a channel with no tree would leave the
    /// user with no way to ask — and no way to be told which of the two empty states is true.
    func testTheTabIsRegisteredAndAvailableForEveryChannel() async throws {
        let rig = try await PanelRig(channels: 1)
        let store = AgentSelectionStore()
        try rig.host.register(AgentsTab(timelines: { [rig] key in rig.timelines.model(for: key).timeline },
                                        selection: store))

        XCTAssertTrue(rig.host.isRegistered(.agents), "no tab holds .agents after the registration")
        XCTAssertEqual(rig.host.title(for: .agents), PanelTabID.agents.defaultTitle,
                       "the registered tab is not the Agents tab's own")

        let owned = try XCTUnwrap(rig.host.context(for: rig.keys[0], cwd: PanelFixtures.cwd),
                                  "the host built no context for the channel it owns")
        XCTAssertTrue(rig.host.available(for: owned).contains(.agents),
                      "the host does not offer .agents to a channel with a fold")

        // A channel the host has no fold for at all — every archived and every foreign session,
        // which is most of what this app lists.
        let foreign = PanelFixtures.context(PanelFixtures.key(41))
        XCTAssertTrue(rig.host.available(for: foreign).contains(.agents),
                      "the host does not offer .agents to a channel with no fold")

        // And the pane it makes for that channel states the *no-wire* fact rather than "no runs".
        let session = rig.host.session(for: .agents, context: foreign)
        let model = try XCTUnwrap(session as? AgentsModel, "the tab made something other than its own session")
        XCTAssertEqual(model.read.state, .noWire,
                       "a channel with no fold reads as a channel that simply has no runs")
    }

    // MARK: - The session the host retains (X7)

    /// The host answers the same `AgentsModel` for one channel after another channel's session was
    /// built, and two channels never share one.
    ///
    /// Discriminating: this is X7's whole reason for sessions. A tab keeping the open run and the
    /// disclosure set in SwiftUI `@State` passes every other assertion in this file and loses both
    /// on every channel switch, because SwiftUI discards `@State` when the subtree unmounts.
    func testTheSessionIsRetainedAcrossAChannelSwitch() throws {
        let host = PanelHostModel()
        let store = AgentSelectionStore()
        try host.register(AgentsTab(timelines: { _ in nil }, selection: store))
        let a = PanelFixtures.context(PanelFixtures.key(0))
        let b = PanelFixtures.context(PanelFixtures.key(1))

        let first = host.session(for: .agents, context: a)
        let other = host.session(for: .agents, context: b)
        let again = host.session(for: .agents, context: a)

        XCTAssertTrue(first === again, "the host rebuilt the channel's Agents session on the way back")
        XCTAssertFalse(first === other, "two channels were handed one Agents session")
        XCTAssertTrue(first is AgentsModel, "the tab's session is not an AgentsModel")
    }

    /// The disclosure set is the session's, so one channel's closed branch does not close the same
    /// branch in another channel's tree.
    func testTheDisclosureSetIsPerChannel() throws {
        let host = PanelHostModel()
        try host.register(AgentsTab(timelines: { _ in nil }, selection: AgentSelectionStore()))
        let a = try XCTUnwrap(host.session(for: .agents, context: PanelFixtures.context(PanelFixtures.key(0)))
                                as? AgentsModel, "the tab made something other than its own session")
        let b = try XCTUnwrap(host.session(for: .agents, context: PanelFixtures.context(PanelFixtures.key(1)))
                                as? AgentsModel, "the tab made something other than its own session")

        a.toggle("task_invented0001")

        XCTAssertEqual(a.collapsed.count, 1, "the channel's own disclosure set holds \(a.collapsed.count) node(s), not 1")
        XCTAssertEqual(b.collapsed.count, 0,
                       "another channel's disclosure set gained \(b.collapsed.count) node(s) from this one")
    }

    // MARK: - What the tab is allowed to hold (X7)

    /// The tab's stored properties contain no `PanelHostModel` and no `ChannelTimelineRegistry`.
    ///
    /// A panel holding its host is a retain path and X7 hands panels capabilities, not the host;
    /// a panel holding the registry is a second route to a channel's fold, which is what the C6 cut
    /// exists to prevent. Both are reached through closures instead, and `Mirror` does not descend
    /// into a capture — which is why this assertion is possible at all, and why a stored reference
    /// would be visible here.
    func testTheTabHoldsNoRegistryAndNoHost() async throws {
        let rig = try await PanelRig(channels: 1)
        let tab = AgentsTab(timelines: { [rig] key in rig.timelines.model(for: key).timeline },
                            selection: AgentSelectionStore())

        XCTAssertEqual(ViewTree.values(of: PanelHostModel.self, in: tab).count, 0,
                       "the tab stores \(ViewTree.values(of: PanelHostModel.self, in: tab).count) panel host(s)")
        XCTAssertEqual(ViewTree.values(of: ChannelTimelineRegistry.self, in: tab).count, 0,
                       "the tab stores \(ViewTree.values(of: ChannelTimelineRegistry.self, in: tab).count) registry(s)")
        // And the store it *is* allowed to hold is there, so the walk above is not vacuous.
        XCTAssertEqual(ViewTree.values(of: AgentSelectionStore.self, in: tab).count, 1,
                       "the walk found no selection store either, so it proves nothing about the two above")
    }

    /// The un-erased view seam (C7.6's pattern): `makeView` answers an `AnyView`, which is not a
    /// thing a test can ask which surface it was built for.
    func testThePanelViewIsBuiltForTheSurfaceItWasAskedFor() throws {
        let host = PanelHostModel()
        let tab = AgentsTab(timelines: { _ in nil }, selection: AgentSelectionStore())
        try host.register(tab)
        let context = PanelFixtures.context(PanelFixtures.key(0))
        let session = host.session(for: .agents, context: context)
        let popped = PanelSurface.poppedOutWindow(tab: .agents, channel: PanelFixtures.key(0))

        let panel = try XCTUnwrap(tab.panelView(session: session, surface: .panel),
                                  "the tab built no view for the main panel")
        let window = try XCTUnwrap(tab.panelView(session: session, surface: popped),
                                   "the tab built no view for a popped-out window")

        XCTAssertEqual(panel.surface, .panel, "the main panel's view was built for another surface")
        XCTAssertEqual(window.surface, popped, "the popped-out window's view was built for another surface")
        XCTAssertNil(tab.panelView(session: OtherSession(), surface: .panel),
                     "the tab built a view over a session that is not its own")
    }

    // MARK: - The `/agents` command link (child spec D15, tracker 207)

    /// A `WorkspaceLink.command("agents")` reaches this target and selects the tab, and nothing else
    /// claims it: the router's fallback — which is what answers `/agents` with a diagnostic today —
    /// never runs.
    func testTheCommandLinkSelectsTheTab() async throws {
        let fallbacks = FallbackRecorder()
        let router = HostLinkRouter(externalOpener: { _ in fallbacks.note() },
                                    diagnostic: { _ in fallbacks.note() })
        let selections = SelectionRecorder()
        let tab = AgentsTab(timelines: { _ in nil }, selection: AgentSelectionStore())
        for target in tab.linkTargets(through: { selections.selected() }) {
            await router.register(target)
        }

        await router.open(.command("agents"), from: .currentPanel)

        XCTAssertEqual(selections.count, 1, "the command selected the tab \(selections.count) time(s), not 1")
        XCTAssertEqual(fallbacks.count, 0,
                       "the router fell back \(fallbacks.count) time(s), so nothing claimed the command")

        // The claim is on this one command string and not on commands in general: `tasks` and
        // `switcher` stay open and stay other owners' (tracker 207).
        await router.open(.command("tasks"), from: .currentPanel)
        XCTAssertEqual(selections.count, 1,
                       "another command reached the Agents target, which claims \(selections.count) of 2")
        XCTAssertEqual(fallbacks.count, 1, "an unclaimed command did not reach the router's fallback")
    }

    // MARK: - Doubles

    /// A session of another tab's kind, so the guard in `panelView` has something to refuse.
    private final class OtherSession: PanelTabSession {}

    /// Counts, never links: what the router did with a link that nothing claimed (§11).
    ///
    /// The router's two fallbacks are non-isolated `@Sendable` closures — they are taken at its
    /// construction and can run anywhere — so the counter is a locked box, the shape `URLBox` takes
    /// beside it and for the same reason.
    private final class FallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
        func note() { lock.lock(); stored += 1; lock.unlock() }
    }

    /// The tab's own selection request, which is `@MainActor` and needs no lock.
    @MainActor
    private final class SelectionRecorder {
        private(set) var count = 0
        func selected() { count += 1 }
    }
}
