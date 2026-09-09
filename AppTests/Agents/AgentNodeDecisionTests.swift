import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.4 Task 6, contract Y2 and item 52's headless half: a subagent's permission card, mirrored on
/// the run's node.
///
/// **One component, one mapping, two hosts.** The node hosts C6.3's `DecisionCardView` with a
/// `DecisionAnswering` whose reservations are the app's one set and whose raise is the channel
/// fold's `signal(_:)`. Both are ways for the mount to be silently wrong and neither shows in a test
/// that only checks a card appeared: a private reservation set disables this surface's buttons and
/// leaves the same request answerable in Activity, and a raise that went nowhere leaves the card
/// reading `.pending` for ever with every other assertion green.
///
/// Every identifier here is invented (§11) and nothing is written anywhere (X9).
@MainActor
final class AgentNodeDecisionTests: XCTestCase {

    private static let runID: AgentRunID = "task_invented_agent_01"
    private static let siblingID: AgentRunID = "task_invented_agent_02"
    private static let requestID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab7"

    // MARK: - The card is the shared component (Y2)

    /// The card the node draws **is** `DecisionCardView`, in the compact presentation Activity's row
    /// uses, over the request the engine is waiting on for this run — and it is labelled with the
    /// run's own type and errand (item 52).
    func testTheNodeHostsTheComponentLabelledWithTheRun() throws {
        let rig = try Rig()
        rig.wait(on: Self.runID)

        let drawn = try XCTUnwrap(Self.decisions(of: Self.runID, in: rig), "the node drew no cards")
        XCTAssertEqual(drawn.cards.count, 1, "the node drew \(drawn.cards.count) card(s) for one waiting request")
        let card = try XCTUnwrap(drawn.cards.first)
        XCTAssertTrue(card.presentation == .compact, "the node drew the timeline's full card in a list row")
        XCTAssertTrue(card.card.requestID == RequestID(rawValue: Self.requestID),
                      "the node drew a card for another request")
        XCTAssertTrue(drawn.label.contains(Rig.agentType), "the card is not labelled with the run's type")
        XCTAssertTrue(drawn.label.contains(Rig.description), "the card is not labelled with the run's errand")
    }

    /// **A sibling's card is not on this node.**
    ///
    /// `DecisionItem.agentID` is what the reducer set from the request payload, and it is the whole
    /// of the filter. A panel that drew the channel's pending requests on every node would put one
    /// subagent's permission under another's name.
    func testACardForASiblingRunIsNotOnThisNode() throws {
        let rig = try Rig()
        rig.wait(on: Self.siblingID)

        XCTAssertTrue(try Self.decisions(of: Self.runID, in: rig) == nil,
                      "a sibling's card was drawn on this node")
        XCTAssertNotNil(try Self.decisions(of: Self.siblingID, in: rig),
                        "the sibling drew no card either, so the assertion above proves nothing")
        XCTAssertEqual(rig.model.read.content(of: Self.runID)?.waitingCount, 0,
                       "this node's waiting badge counted a sibling's request")
        XCTAssertEqual(rig.model.read.content(of: Self.siblingID)?.waitingCount, 1,
                       "the sibling's waiting badge did not count its own request")
    }

    /// A settled request is a reading and not a card to answer, and the badge counts the same set.
    func testAnAnsweredRequestLeavesNoCardOnTheNode() throws {
        let rig = try Rig()
        rig.wait(on: Self.runID)
        rig.settle(Self.requestID)

        XCTAssertTrue(try Self.decisions(of: Self.runID, in: rig) == nil,
                      "a settled request is still drawn as a card")
        XCTAssertEqual(rig.model.read.content(of: Self.runID)?.waitingCount, 0,
                       "the waiting badge still counts a request that has been answered")
    }

    // MARK: - The app's one reservation set (Y7)

    /// **One request answered from this host and from Activity reaches `perform(.answer)` once.**
    ///
    /// Discriminating, and the reason the set is app-scoped: two reservation sets would each succeed
    /// locally and both reach the wire, and the second answer comes back `decisionGone` — an error
    /// about afleet's own bookkeeping dressed as an error about the engine. The second press happens
    /// **while the first answer is genuinely on the wire**, inside the double's `perform`, because
    /// that is the only window in which the reservation is held.
    func testTheReservationSetIsTheApps() async throws {
        let rig = try Rig()
        rig.wait(on: Self.runID)
        await rig.lifecycle.always(.success(Rig.state(rig.key)))

        let node = try XCTUnwrap(Self.decisions(of: Self.runID, in: rig)?.cards.first, "the node drew no card")
        // Activity's host over the **same** app-scoped set, which is the whole subject here.
        let activity = DecisionAnswering(lifecycle: rig.lifecycle, reservations: rig.reservations)
        let elsewhere = DecisionCardView(card: node.card, presentation: .compact, in: rig.key,
                                         answering: activity)

        await rig.lifecycle.duringPerform {
            await MainActor.run { try? Self.press("Allow once", in: elsewhere) }
        }
        try Self.press("Allow once", in: node)
        await rig.settle(actions: 1)

        let actions = await rig.lifecycle.actions
        let answers = actions.filter { if case .answer = $0 { true } else { false } }
        XCTAssertEqual(answers.count, 1,
                       "one request answered from two hosts reached the wire \(answers.count) time(s)")
    }

    // MARK: - Leaving `pending` (Y7)

    /// **A card leaves `pending` because `HostSignal.decisionAnswered` was raised on the fold.**
    ///
    /// Asserted as the signal handed to the fold and never as the card disappearing: the engine sends
    /// no frame back for an answer, so a host that dropped the card locally would look right on
    /// screen and leave the item `.pending` in C3's overlay for every other surface — and a card that
    /// vanished for any other reason would satisfy the weaker assertion.
    func testAnsweringLeavesPendingThroughTheFoldsSignal() async throws {
        let rig = try Rig()
        rig.wait(on: Self.runID)
        await rig.lifecycle.always(.success(Rig.state(rig.key)))

        let card = try XCTUnwrap(Self.decisions(of: Self.runID, in: rig)?.cards.first, "the node drew no card")
        try Self.press("Allow once", in: card)
        await rig.settle(actions: 1)
        _ = await AgentNodeActionTests.settle { rig.raised.signals.isEmpty == false }

        XCTAssertEqual(rig.raised.signals.count, 1, "the answer raised \(rig.raised.signals.count) signal(s)")
        guard case .decisionAnswered(let id, let outcome)? = rig.raised.signals.first else {
            return XCTFail("the fold was handed a signal that is not a decision answer")
        }
        XCTAssertTrue(id == RequestID(rawValue: Self.requestID), "the signal names another request")
        XCTAssertTrue(outcome == .allowed, "the signal carries an outcome other than the one the button sent")
        XCTAssertTrue(rig.raised.channels.allSatisfy { $0 == rig.key },
                      "the signal was raised on a channel other than the card's")
    }

    /// A refused answer raises nothing: the engine was never told, so the item is still `.pending`
    /// and a signal would mark a request nobody answered as answered.
    func testARefusedAnswerRaisesNothing() async throws {
        let rig = try Rig()
        rig.wait(on: Self.runID)
        await rig.lifecycle.always(.failure(.notOwned))

        let card = try XCTUnwrap(Self.decisions(of: Self.runID, in: rig)?.cards.first, "the node drew no card")
        try Self.press("Allow once", in: card)
        await rig.settle(actions: 1)
        _ = await AgentNodeActionTests.settle { rig.model.answering?.banner != nil }

        XCTAssertEqual(rig.raised.signals.count, 0,
                       "a refused answer raised \(rig.raised.signals.count) signal(s) on the fold")
    }

    // MARK: - Driving the surface

    /// The cards the outline draws for one run, through the outline's own expression.
    static func decisions(of run: AgentRunID, in rig: Rig) throws -> AgentNodeDecisions? {
        let outline = try XCTUnwrap(ViewTree.values(of: AgentOutline.self,
                                                    in: AgentTreeView(model: rig.model).body).first,
                                    "the tree drew no outline")
        let row = try XCTUnwrap(outline.rows.first { $0.id == run }, "the outline drew no row for the run")
        return AgentOutline.decisions(of: row, in: rig.model)
    }

    static func press(_ label: String, in card: DecisionCardView) throws {
        let body = try XCTUnwrap(CardTree.permissionBody(in: card.body), "the card drew no permission body")
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the card offers no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    // MARK: - The rig

    /// One channel with two sibling runs, the app's one reservation set, and a fold that records the
    /// signals raised on it. The tab is built the way `performLaunch` builds it.
    @MainActor
    struct Rig {

        static let agentType = "an-invented-agent"
        static let description = "an invented errand"

        let lifecycle: ActionDouble
        let reservations = DecisionReservations()
        let raised = RaisedSignals()
        let published: Published
        let model: AgentsModel
        let key: ChannelKey

        init() throws {
            lifecycle = ActionDouble()
            key = PanelFixtures.key(31)
            published = Published(ChannelTimeline(agents: Self.twoSiblings()))
            let host = PanelHostModel()
            let recorder = raised
            try host.register(AgentsTab(timelines: { [published] _ in published.timeline },
                                        selection: AgentSelectionStore(),
                                        lifecycle: lifecycle,
                                        fold: ChannelFold(raise: { key, signal in recorder.note(key, signal) },
                                                          decision: { _, _ in nil }),
                                        reservations: reservations))
            model = try XCTUnwrap(host.session(for: .agents, context: PanelFixtures.context(key)) as? AgentsModel,
                                  "the tab made something other than its own session")
        }

        /// Puts one real `can_use_tool` request into C3's overlay, attributed to a run.
        ///
        /// The request is decoded from a committed recording through `FixtureRunner`, because a card
        /// with an invented payload renders as `.unmodelled` and answers nothing — which would make
        /// every assertion below vacuous. `agentID` is set here because a test tree has no reducer to
        /// set it from the payload.
        func wait(on run: AgentRunID) {
            guard let request = try? FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                            id: AgentNodeDecisionTests.requestID),
                  var item = DecisionItem(surfacing: request, in: key) else { return }
            item.agentID = run
            published.timeline.overlay.decisions[item.requestID] = item
        }

        /// The same request, answered — as C3's reducer leaves it after a `decisionAnswered` signal.
        func settle(_ request: String) {
            let id = RequestID(rawValue: request)
            published.timeline.overlay.decisions[id]?.state = .answered(outcome: DecisionOutcome.allowed.label)
        }

        func settle(actions count: Int) async {
            _ = await AgentNodeActionTests.settle { await self.lifecycle.actions.count >= count }
        }

        /// Two runs at the top level, so "this node and not its sibling" is a thing the tree can be
        /// asked about.
        static func twoSiblings() -> AgentRunTree {
            var tree = InventedAgents.tree()
            for (index, id) in [AgentNodeDecisionTests.runID, AgentNodeDecisionTests.siblingID].enumerated() {
                tree.apply(taskStarted: InventedAgents.taskStarted(taskID: id,
                                                                   toolUseID: "toolu_invented000\(index)",
                                                                   agentType: agentType,
                                                                   description: description, depth: 1),
                           at: InventedAgents.epoch)
            }
            return tree
        }

        static func state(_ key: ChannelKey) -> ChannelState { AgentNodeActionTests.state(key) }

        @MainActor
        final class Published {
            var timeline: ChannelTimeline
            init(_ timeline: ChannelTimeline) { self.timeline = timeline }
        }
    }

    /// What the channel's fold was told. The signal and the channel, and nothing derived from either:
    /// an assertion over an aggregate holding a `ChannelKey` would print one on failure (§11).
    @MainActor
    final class RaisedSignals {
        private(set) var signals: [HostSignal] = []
        private(set) var channels: [ChannelKey] = []
        func note(_ key: ChannelKey, _ signal: HostSignal) {
            channels.append(key)
            signals.append(signal)
        }
    }
}
