import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.4 Task 2, contract Y4: what an `Agent` chip's click does once `NoAgentNavigation` is replaced.
///
/// C6.1's own gate proved the chip *calls* the seam against a counting double. This is the other
/// end: the run lands on the session the host retains, in the channel the run belongs to.
///
/// Every identifier is invented (§11); nothing here writes anything (X9).
@MainActor
final class AgentNavigatorTests: XCTestCase {

    /// The three things `show(run:in:)` does, and the one a chip clicked before the tab was ever
    /// opened depends on: the run is written into the app-scoped store, and the session the host
    /// builds *afterwards* reads it.
    ///
    /// The discriminating half is the last clause. A navigation that kept the run to itself — or
    /// wrote it onto a session it built for the occasion — passes every assertion about the tab's
    /// selection and lands the user on an Agents pane with nothing open.
    func testNavigationSelectsTheTabAndTheRun() throws {
        let rig = try NavigationRig(tree: InventedAgents.treeOfRoots(2))
        let run = InventedAgents.run(1)

        rig.navigator.show(run: run, in: rig.key)

        XCTAssertEqual(rig.host.selected, .agents, "the navigation did not bring the Agents tab forward")
        XCTAssertTrue(rig.store.selection(in: rig.key) == run, "the store does not hold the run the chip named")

        // The session is built only now, which is the case the store exists for.
        let model = try rig.session()
        XCTAssertTrue(model.selectedRun == run, "the session the host built afterwards did not read the selection")
        XCTAssertTrue(model.selection == .run(run),
                      "the pane reports a selection state other than the open run")
    }

    /// A run in a channel that is **not** the one on screen focuses that channel **before** the tab.
    ///
    /// Failing-first against a navigator that selected only the tab: that one leaves the user
    /// looking at another channel's Agents pane, with the run they clicked nowhere on it. The order
    /// is asserted as well as the outcome, because selecting the tab first and the channel second
    /// draws one frame of the wrong pane.
    func testNavigationFocusesTheChannelFirst() throws {
        let rig = try NavigationRig(tree: InventedAgents.treeOfRoots(1))
        XCTAssertTrue(rig.shell.focus.isActivity, "the window must start off the run's channel for this to discriminate")

        rig.navigator.show(run: InventedAgents.run(0), in: rig.key)

        XCTAssertEqual(rig.order, ["channel", "tab"],
                       "the navigation performed \(rig.order.count) step(s) in the wrong order")
        XCTAssertTrue(rig.shell.focus.session == rig.key.session,
                      "the window is not on the channel the run belongs to")
        XCTAssertEqual(rig.host.selected, .agents, "the navigation did not bring the Agents tab forward")
    }

    /// A run id this channel's tree does not hold selects **nothing**, and the pane says so
    /// (child spec D5).
    ///
    /// Discriminating: the alternative is a fabricated selection, which is exactly what a channel
    /// with no wire would otherwise produce — a chip on an archived channel resolves nil today, and
    /// a pane that invented a node for it would be worse than one that stated the fact.
    func testAnUnknownRunSelectsNothingAndSaysSo() throws {
        let rig = try NavigationRig(tree: InventedAgents.treeOfRoots(1))

        rig.navigator.show(run: "task_invented9999", in: rig.key)

        let model = try rig.session()
        XCTAssertTrue(model.selection == .unknownRun,
                      "a run the tree does not hold did not read as an unknown run")
        XCTAssertTrue(model.selectedRun == nil, "a run the tree does not hold was selected anyway")
        XCTAssertEqual(rig.host.selected, .agents,
                       "the tab was not brought forward, so the user is not where the message is")

        // The "and says so" half, drawn: the pane states the fact rather than showing an ordinary
        // tree with nothing open, which reads as a bug rather than as an answer.
        let drawn = ViewTree.values(of: String.self, in: AgentTreeView(model: model).body)
        XCTAssertEqual(drawn.filter { $0 == AgentUnknownRunNotice.sentence }.count, 1,
                       "the pane drew the unknown-run sentence \(drawn.filter { $0 == AgentUnknownRunNotice.sentence }.count) time(s), not once")
        // And the tree the channel does hold is still drawn beneath it: the other runs stay openable.
        let beneath = ViewTree.values(of: AgentOutline.self, in: AgentTreeView(model: model).body).first
        XCTAssertEqual(beneath?.rows.count, 1,
                       "the notice replaced the channel's own runs instead of sitting above them")
        XCTAssertEqual(drawn.filter { $0 == AgentTreeEmptyState.noRuns || $0 == AgentTreeEmptyState.notOpened }.count, 0,
                       "a channel with a run in it drew one of the empty-state sentences")
    }

    /// The notice is the unknown-run state's and not a permanent fixture: a run the tree **does**
    /// hold draws no sentence at all.
    ///
    /// Without this half the clause above passes against a pane that says "that run is not in this
    /// channel's tree" over every run it opens.
    func testAKnownRunDrawsNoUnknownRunNotice() throws {
        let rig = try NavigationRig(tree: InventedAgents.treeOfRoots(1))

        rig.navigator.show(run: InventedAgents.run(0), in: rig.key)
        let model = try rig.session()

        XCTAssertTrue(model.selection == .run(InventedAgents.run(0)),
                      "the run the tree holds did not read as the open run, so this proves nothing")
        let drawn = ViewTree.values(of: String.self, in: AgentTreeView(model: model).body)
        XCTAssertEqual(drawn.filter { $0 == AgentUnknownRunNotice.sentence }.count, 0,
                       "an open run drew the unknown-run sentence \(drawn.filter { $0 == AgentUnknownRunNotice.sentence }.count) time(s)")
    }

    /// A chip click on a run whose branch the user closed **lands on the run**: the branch above it
    /// is disclosed and the row is drawn.
    ///
    /// Failing-first against the panel before this: the selection landed, the session reported the
    /// run open, and the outline kept it hidden under a closed parent — a pane that disagrees with
    /// itself about what is open. Y4's sentence is that the click lands on the run, and a row that
    /// is not on screen is not landed on.
    func testAChipClickRevealsARunUnderAClosedBranch() throws {
        let rig = try NavigationRig(tree: InventedAgents.nestedPair())
        let parent = InventedAgents.run(0)
        let nested = InventedAgents.run(1)
        let model = try rig.session()
        model.toggle(parent)
        XCTAssertEqual(AgentTreeView.visibleRows(read: model.read, collapsed: model.collapsed).count, 1,
                       "the closed branch still draws its child, so nothing below is about revealing it")

        rig.navigator.show(run: nested, in: rig.key)

        // The rows the *view* is about to draw, read off the outline it built — not a second call to
        // the helper, which would prove only that the helper can reveal.
        // The outline the body built, and not an `[AgentTreeView.Row]` found by type: an **empty**
        // array of any element type casts to an empty array of any other, so a walk for the row
        // array matches the first empty array in the view — which, since the read is cached on the
        // session, can be one belonging to the tree the cache holds.
        let outline = try XCTUnwrap(ViewTree.values(of: AgentOutline.self,
                                                    in: AgentTreeView(model: model).body).first,
                                    "the panel drew no outline at all")
        let drawn = outline.rows
        XCTAssertEqual(drawn.count, 2,
                       "the panel drew \(drawn.count) row(s), so the run the chip named is not on it")
        XCTAssertTrue(drawn.last?.id == nested, "the row the chip's run needs is not the one drawn")
        XCTAssertTrue(drawn.first?.disclosure == .expanded,
                      "the branch above the open run is still closed, so the run is drawn under a shut parent")
        // The user's own closed branch is remembered: the reveal is what the selection needs, not a
        // rewrite of what they chose.
        XCTAssertEqual(model.collapsed.count, 1,
                       "revealing the run left \(model.collapsed.count) closed branch(es), so the user's own was discarded")
    }

    // MARK: - The rig

    /// The shell, the host, the store and the navigator, wired the way `performLaunch` wires them —
    /// the shell and the host reached through closures, never references — plus an order log, which
    /// is what makes "before" assertable at all.
    @MainActor
    private struct NavigationRig {

        let key = PanelFixtures.key(3)
        let host = PanelHostModel()
        let shell: ShellModel
        let store = AgentSelectionStore()
        let navigator: AgentNavigator
        private let log = OrderLog()

        var order: [String] { log.steps }

        init(tree: AgentRunTree) throws {
            let host = self.host
            let shell = ShellModel(panels: host)
            self.shell = shell
            let store = self.store
            let log = self.log
            let timeline = ChannelTimeline(agents: tree)
            try host.register(AgentsTab(timelines: { _ in timeline }, selection: store))
            navigator = AgentNavigator(selection: store,
                                       focusChannel: { key in log.note("channel"); shell.select(key.session) },
                                       selectTab: { log.note("tab"); host.select(.agents) })
        }

        /// The session the host builds for this channel — built on demand, which is the point.
        func session() throws -> AgentsModel {
            let session = host.session(for: .agents, context: PanelFixtures.context(key))
            return try XCTUnwrap(session as? AgentsModel, "the tab made something other than its own session")
        }
    }

    /// What the navigation did, in order. Steps are the two words this file wrote — never a key,
    /// a session id or a run id (§11).
    @MainActor
    private final class OrderLog {
        private(set) var steps: [String] = []
        func note(_ step: String) { steps.append(step) }
    }
}
