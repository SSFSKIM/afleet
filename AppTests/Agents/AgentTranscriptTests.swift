import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Gate **G2**: one run's transcript, with the run's own authorship and badge.
///
/// The pane is C6.1's renderer over a **filtered** row set (child spec D4): the channel's own items
/// whose `Provenance.agentID` names the run, in the timeline's order, with the run's authorship and
/// model supplied once by the pane rather than written into a row this leaf does not own.
///
/// §11: every assertion over a value that reaches a task id, a channel key or a path is spelled as a
/// boolean with a written message. A task id is drawable and never printable.
///
/// X9: nothing here opens a file or a config home — the corpus is invented items and an invented
/// tree over an invented config home, and the one `AppModel` is built with no workspace.
@MainActor
final class AgentTranscriptTests: XCTestCase {

    // MARK: - The filter (G2)

    /// The pane draws the run's items and only the run's: a main-thread item and a **sibling** run's
    /// item are both absent.
    ///
    /// The sibling is the discriminating half. A pane that merely excluded the main thread — the
    /// obvious reading of "a subagent's transcript" — draws every subagent's messages under whichever
    /// run happens to be open, and passes any assertion that only checks the main thread is gone.
    func testThePaneDrawsOnlyTheSelectedRunsItems() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(0))

        let input = rig.model.input(of: InventedAgents.run(0), retainedBy: nil)

        XCTAssertEqual(input.rows.count, 2, "the pane drew \(input.rows.count) row(s) for a run with 2 items")
        XCTAssertTrue(input.rows.map(\.id) == AgentRunRead.items(of: InventedAgents.run(0), in: rig.timeline).map(\.id),
                      "the pane's rows are not the run's items, in the timeline's own order")
        let keys = Set(input.rows.map(\.id.key))
        XCTAssertFalse(keys.contains(TranscriptRig.mainThreadKey),
                       "the main thread's item is drawn inside a subagent's transcript")
        XCTAssertFalse(keys.contains(TranscriptRig.siblingKey),
                       "a sibling run's item is drawn inside this run's transcript")

        // The other run's transcript is the other run's: the same expression over the sibling draws
        // the sibling's one item and none of this run's.
        let sibling = rig.model.input(of: InventedAgents.run(1), retainedBy: nil)
        XCTAssertEqual(sibling.rows.count, 1,
                       "the sibling run drew \(sibling.rows.count) row(s) for the 1 item it produced")
        XCTAssertTrue(sibling.rows.map(\.id.key) == [TranscriptRig.siblingKey],
                      "the sibling run's transcript drew an item that is not the sibling's")
    }

    /// **No streaming tail is passed through.** `StreamingPreview` carries no agent attribution — the
    /// fold keeps one preview per channel — so a tail drawn under a subagent would be the parent's
    /// words in the child's mouth.
    ///
    /// Asserted against a channel that **has** a preview open, which is the only state in which the
    /// clause can fail: a pane that passed the channel's preview through would draw it here.
    func testTheChannelsStreamingTailIsNotDrawnUnderARun() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(0), streaming: true)
        XCTAssertNotNil(rig.timeline.preview, "the channel has no open preview, so this proves nothing")

        let input = rig.model.input(of: InventedAgents.run(0), retainedBy: nil)

        XCTAssertNil(input.preview, "the channel's streaming tail is drawn inside a subagent's transcript")
    }

    // MARK: - Authorship and the badge (G2, item 38)

    /// The messages are authored by the run's **agent type**, and never by "Claude".
    ///
    /// Discriminating against a pane that inherited the channel's authorship: the drawn author is the
    /// node's own type, and the assistant's name appears nowhere in the framing. The type is the
    /// sanitised one the node content carries, so the framing inherits the strip rather than
    /// re-doing it.
    func testAuthorshipIsTheAgentTypeAndNeverClaude() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(0))
        let content = try XCTUnwrap(rig.model.read.content(of: InventedAgents.run(0)),
                                    "the read holds no content for the run the pane is open on")

        XCTAssertEqual(AgentTranscriptHeader.author(of: content), TranscriptRig.agentType,
                       "the transcript is not authored by the run's own agent type")

        let drawn = ViewTree.values(of: String.self, in: AgentTranscriptHeader(content: content).body)
        XCTAssertEqual(drawn.filter { $0 == TranscriptRig.agentType }.count, 1,
                       "the framing states the agent type \(drawn.filter { $0 == TranscriptRig.agentType }.count) "
                       + "time(s), not once")
        XCTAssertEqual(drawn.filter { $0.localizedCaseInsensitiveContains("claude") }.count, 0,
                       "the subagent's transcript is authored by the assistant rather than by the run")
    }

    /// The badge is the **run's own** model, and not the channel's.
    ///
    /// The two are stated differently on purpose. They are usually the same, so a corpus with one
    /// model passes whichever value the pane picked up; here the run's assistant frames carried one
    /// model and the channel's streaming tail another, and only the run's may be drawn.
    func testTheBadgeIsTheRunsOwnModel() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(0), streaming: true)
        let content = try XCTUnwrap(rig.model.read.content(of: InventedAgents.run(0)),
                                    "the read holds no content for the run the pane is open on")
        XCTAssertNotEqual(TranscriptRig.runModel, TranscriptRig.channelModel,
                          "the run and the channel are on one model, so this test cannot tell them apart")

        XCTAssertEqual(AgentTranscriptHeader.badge(of: content), TranscriptRig.runModel,
                       "the badge is not the model the run's own assistant frames carried")

        let drawn = ViewTree.values(of: String.self, in: AgentTranscriptHeader(content: content).body)
        XCTAssertEqual(drawn.filter { $0 == TranscriptRig.runModel }.count, 1,
                       "the framing draws the run's model \(drawn.filter { $0 == TranscriptRig.runModel }.count) "
                       + "time(s), not once")
        XCTAssertEqual(drawn.filter { $0 == TranscriptRig.channelModel }.count, 0,
                       "the framing draws the channel's model on a subagent's transcript")
    }

    /// A run no assistant frame has arrived for **says so** rather than borrowing the channel's.
    ///
    /// The delegated unknown, answered: neither the task frames nor the `.meta.json` sidecar carries
    /// a model, so a run that has not spoken has none, and drawing the channel's would state the
    /// wrong model with exactly the confidence of the right one.
    func testARunWithNoModelSaysSoRatherThanBorrowingOne() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(1), streaming: true)
        let content = try XCTUnwrap(rig.model.read.content(of: InventedAgents.run(1)),
                                    "the read holds no content for the silent run")
        XCTAssertTrue(content.model == nil, "the silent run carries a model, so this proves nothing")

        XCTAssertEqual(AgentTranscriptHeader.badge(of: content), AgentTranscriptHeader.unknownModel,
                       "a run with no model of its own does not say so")
        let drawn = ViewTree.values(of: String.self, in: AgentTranscriptHeader(content: content).body)
        XCTAssertEqual(drawn.filter { $0 == TranscriptRig.channelModel }.count, 0,
                       "a run with no model of its own borrowed the channel's")
        XCTAssertEqual(drawn.filter { $0 == AgentTranscriptHeader.unknownModel }.count, 1,
                       "the framing does not state that the run has reported no model")
    }

    // MARK: - The two stated states (G2)

    /// A run with nothing in it, and a run this channel's tree does not know, are two different
    /// sentences — and neither is an ordinary empty transcript, which reads as a bug.
    func testARunWithNothingInItAndARunTheTreeDoesNotKnowSayDifferentThings() throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(2))

        let empty = rig.model.input(of: InventedAgents.run(2), retainedBy: nil)
        XCTAssertEqual(empty.rows.count, 0,
                       "the run the corpus gave no items drew \(empty.rows.count) row(s)")
        XCTAssertTrue(rig.model.read.knows(InventedAgents.run(2)),
                      "the empty run is not in the tree, so this is the unknown-run arm and not the empty one")
        XCTAssertEqual(AgentTranscriptPane.sentence(for: .run(InventedAgents.run(2)), rows: 0),
                       AgentTranscriptEmptyState.noItems,
                       "a run with nothing in it does not state that it has produced nothing")

        XCTAssertEqual(AgentTranscriptPane.sentence(for: .unknownRun, rows: 0),
                       AgentTranscriptEmptyState.unknownRun,
                       "a run this channel does not hold is drawn as a run that produced nothing")
        XCTAssertEqual(AgentTranscriptPane.sentence(for: AgentsModel.Selection.none, rows: 0),
                       AgentTranscriptEmptyState.noSelection,
                       "a pane with nothing open is drawn as a run that produced nothing")

        XCTAssertNil(AgentTranscriptPane.sentence(for: .run(InventedAgents.run(0)), rows: 2),
                     "a run with items in it is drawn as an empty state")

        // The three sentences are three sentences: a pane that worded any two the same tells the
        // user the wrong one of two facts, which is what the tree's two states exist to prevent.
        let sentences = Set([AgentTranscriptEmptyState.noItems, AgentTranscriptEmptyState.unknownRun,
                             AgentTranscriptEmptyState.noSelection])
        XCTAssertEqual(sentences.count, 3, "the pane has \(sentences.count) distinct sentence(s) for 3 states")
    }

    // MARK: - No composer site (G2, contract Y6)

    /// **The transcript offers no composer**, and every other capability is the app's running object.
    ///
    /// A subagent transcript is not a place to type, and Y6's *Edit* on a message inside a run would
    /// rewind the **main** conversation — the composer belongs to the channel, and a rewind fired
    /// from here would take back turns the user is reading somewhere else.
    ///
    /// The pair is the discrimination. `composer == nil` alone is satisfied by a context built out of
    /// nothing at all, which is the failure contract Y7 exists to prevent; so the same assertion
    /// states that the link router, the reservation set, the retraction registry and the navigation
    /// seam are the **same objects** the channel column passes, and only the composer is absent.
    func testThePaneOffersNoComposerSite() throws {
        let app = AppModel(registry: RowRegistry())
        let key = PanelFixtures.key(52)
        let channel = app.timelines.model(for: key)
        // The installed navigator, so the seam's clause below compares two objects and not two
        // copies of the pre-launch default, which is a value type.
        let navigation = AgentNavigator(selection: AgentSelectionStore(), focusChannel: { _ in }, selectTab: {})
        app.agentNavigation = navigation

        let context = AgentRenderContext.context(in: app, channel: channel,
                                                 collapse: TimelineCollapseState(),
                                                 editing: TimelineEditState())

        XCTAssertTrue(context.composer == nil, "a subagent's transcript offers a composer site")
        XCTAssertTrue(context.links as AnyObject === app.panels.links as AnyObject,
                      "the transcript's link router is not the app's own")
        XCTAssertTrue(context.decisions === app.decisions,
                      "the transcript's reservation set is not the app's one set")
        XCTAssertTrue(context.retraction === channel.retraction,
                      "the transcript's retraction registry is not the channel's own")
        XCTAssertTrue(context.agents as AnyObject === navigation,
                      "the transcript's agent navigation is not the app's own")
        XCTAssertTrue(context.key == key, "the context names a channel other than the pane's")
    }
}

// MARK: - The corpus

/// One channel's tree and items, invented: two runs, one of which produced two items and one of
/// which produced one, a main-thread item that belongs to neither, and a third run that produced
/// nothing at all.
///
/// Every identifier is this file's own (§11), and nothing here is opened: the tree's config home is
/// an invented path the tree only computes URLs from.
@MainActor
private struct TranscriptRig {

    static let agentType = "an-invented-nested-agent"
    static let runModel = "an-invented-model-the-run-spoke-on"
    static let channelModel = "an-invented-model-the-channel-is-on"
    static let mainThreadKey = "toolu_invented_main0"
    static let siblingKey = "toolu_invented_sib00"

    let timeline: ChannelTimeline
    let model: AgentsModel

    /// `streaming` opens a preview on the channel — the state in which "the tail is not passed
    /// through" is a clause that can fail.
    init(selecting run: AgentRunID, streaming: Bool = false) throws {
        var tree = InventedAgents.treeOfRoots(3)
        tree.observe(assistantModel: Self.runModel, agentID: InventedAgents.run(0))
        tree.apply(taskStarted: InventedAgents.taskStarted(taskID: InventedAgents.run(0),
                                                           toolUseID: "toolu_invented0000",
                                                           agentType: Self.agentType, depth: 1),
                   at: InventedAgents.epoch)

        let items: [TimelineItem] = [
            InventedAgents.call(Self.mainThreadKey, agent: nil),
            InventedAgents.call("toolu_invented_mine0", agent: InventedAgents.run(0)),
            InventedAgents.call("toolu_invented_mine1", agent: InventedAgents.run(0)),
            InventedAgents.call(Self.siblingKey, agent: InventedAgents.run(1))
        ]
        timeline = ChannelTimeline(durable: DurableProjection(items: items),
                                   preview: streaming ? StreamingPreview(model: Self.channelModel,
                                                                         blocks: []) : nil,
                                   agents: tree)
        let store = AgentSelectionStore()
        let key = PanelFixtures.key(52)
        store.select(run, in: key)
        model = AgentsModel(channel: key, timelines: { [timeline] _ in timeline }, store: store)
    }
}
