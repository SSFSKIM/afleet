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

    // MARK: - G2's gate arm, on `nested-depth-2`

    /// **G2, from the run's own frames**: replaying the recording through the app's ingestion, the
    /// nested run's transcript is that run's items, authored by the type the wire named for it and
    /// badged with the model its own assistant frames carried.
    ///
    /// The corpus is the fixture and not invented items, which is what item 38's "(fixture)" asks
    /// for and what makes this an arm of the gate rather than a test of a corpus this file wrote.
    /// Attribution and model propagation both run the whole way here — `WireReducer` stamping
    /// `Provenance.agentID` from the forwarding block, `observe(assistantModel:agentID:)` setting
    /// the run's badge, the read sanitising the type, the pane framing it — so a break anywhere on
    /// that path fails this rather than passing on values a test assigned.
    ///
    /// §11 throughout: nothing here writes an agent type, an id or a model down. Every expected
    /// value is read back out of the tree or the items and compared as a boolean with a written
    /// message, so a failure states counts and never the recording's bytes.
    func testTheRunsTranscriptAndAuthorshipComeFromTheRunsOwnFrames() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2")
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let reached = await rig.settleOnBarrier()
        XCTAssertTrue(reached, "the replay never reached the model")
        let armed = await rig.settleOnRuns(2)
        XCTAssertTrue(armed, "the replay armed a tree with 2 runs in it")

        let read = rig.read()
        let root = try XCTUnwrap(read.roots.first, "the tree offered no root")
        let run = try XCTUnwrap(read.children(of: root).first, "the root has no child to open")
        let pane = rig.pane()
        pane.select(run)
        let content = try XCTUnwrap(pane.read.content(of: run), "the read holds no content for the nested run")

        // The filter, on the recording: the run's items and only the run's, with the parent's — the
        // sibling of this pane's subject — absent.
        let input = pane.input(of: run, retainedBy: nil)
        XCTAssertGreaterThan(input.rows.count, 0, "the nested run drew no rows at all on a recording it spoke in")
        // **The expectation is derived from the channel's items, not from the filter under test.**
        // `input.rows` is `AgentRunRead.items(of:in:)`' own output; an expectation taken from the
        // same expression shrinks with it, so a filter that returned nothing — or that dropped the
        // run's messages and kept its tool calls — satisfies both operands at once.
        let items = rig.model.timeline.items
        let mine = items.filter { $0.provenance.agentID == run }
        XCTAssertGreaterThan(mine.count, 0, "the recording carries no item of the nested run's, so this compares nothing")
        XCTAssertTrue(input.rows.map(\.id) == mine.map(\.id),
                      "the pane's \(input.rows.count) row(s) are not the run's \(mine.count) item(s), in order")
        let parents = items.filter { $0.provenance.agentID == root }
        XCTAssertGreaterThan(parents.count, 0, "the parent run produced nothing, so its absence proves nothing")
        let drawnIDs = Set(input.rows.map(\.id.key))
        XCTAssertEqual(parents.filter { drawnIDs.contains($0.id.key) }.count, 0,
                       "the parent run's items are drawn inside the nested run's transcript")

        // The authorship the wire named, not one this file wrote.
        let type = try XCTUnwrap(content.agentType, "the recording named no type for the nested run")
        XCTAssertFalse(type.isEmpty, "the run's type is empty, so the clauses below compare nothing")
        XCTAssertFalse(type.localizedCaseInsensitiveContains("claude"),
                       "the recording's own type for this run is the assistant's name, so this proves nothing")
        let badge = try XCTUnwrap(content.model, "no assistant frame set the nested run's model")
        let spoken = Set(mine.compactMap { item -> String? in
            if case .assistantMessage(let message) = item { return message.model }
            return nil
        })
        XCTAssertEqual(spoken.count, 1, "the run's items carry \(spoken.count) model(s), not the 1 it spoke on")
        XCTAssertTrue(spoken.first == badge, "the run's badge is not the model its own assistant frames carried")

        // And the **drawn message**, through the pane's own context expression (item 38).
        let app = AppModel(registry: RowRegistry())
        let context = AgentTranscriptPane.context(for: content, in: app, channel: rig.model, model: pane)
        let message = try XCTUnwrap(mine.compactMap { item -> AssistantMessageItem? in
            if case .assistantMessage(let message) = item { return message }
            return nil
        }.first, "the nested run produced no assistant message to draw")
        let drawn = ViewTree.values(of: String.self, in: AssistantMessageBody(item: message, context: context).body)
        XCTAssertEqual(drawn.filter { $0 == type }.count, 1,
                       "the drawn message states the run's type \(drawn.filter { $0 == type }.count) time(s), not once")
        // The author is checked as the author and not as "no string here says claude": this
        // recording's model name does, and a sweep over every drawn string would fail on the badge.
        XCTAssertTrue(AssistantMessageBody.author(in: context) == type,
                      "the drawn message is authored by something other than the run's own type")
        XCTAssertFalse(AssistantMessageBody.author(in: context).localizedCaseInsensitiveContains("claude"),
                       "a message in the run's transcript is authored by the assistant rather than by the run")
        XCTAssertEqual(drawn.filter { $0 == badge }.count, 1,
                       "the drawn message badges the run's model \(drawn.filter { $0 == badge }.count) time(s), not once")
    }

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
        // Derived from the channel's items rather than from the filter the pane used, for the
        // reason the gate arm above states: two operands out of one expression move together.
        let mine = rig.timeline.items.filter { $0.provenance.agentID == InventedAgents.run(0) }
        XCTAssertTrue(input.rows.map(\.id) == mine.map(\.id),
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

        // A boolean and not `XCTAssertNil` (§11): a `StreamingPreview` carries the message being
        // streamed and the tool-use ids inside it, and a failing `XCTAssertNil` prints its operand.
        XCTAssertTrue(input.preview == nil,
                      "the channel's streaming tail is drawn inside a subagent's transcript")
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

        // **The message row itself**, which is what item 38 is about. A pane that set a header and
        // left the rows alone draws the run's name once at the top and "Claude" over every message,
        // and passes every clause above.
        let row = ViewTree.values(of: String.self, in: rig.assistantRow(model: TranscriptRig.runModel))
        XCTAssertEqual(row.filter { $0 == TranscriptRig.agentType }.count, 1,
                       "the drawn message states the agent type \(row.filter { $0 == TranscriptRig.agentType }.count) "
                       + "time(s), not once")
        XCTAssertEqual(row.filter { $0.localizedCaseInsensitiveContains("claude") }.count, 0,
                       "a message inside the subagent's transcript is authored by the assistant")
        // And the channel column is untouched: the same row with no authorship in its context is the
        // row it has always been.
        let column = ViewTree.values(of: String.self, in: TranscriptRig.assistantRow(context: nil))
        XCTAssertEqual(column.filter { $0 == "Claude" }.count, 1,
                       "the channel's own thread stopped authoring its messages the way it did")
    }

    /// The badge is the **run's own** model, and not the channel's.
    ///
    /// **The premise is the channel's own readout, not two constants.** The two are usually the
    /// same, so a corpus with one model passes whichever value the pane picked up; here the
    /// channel's header model is supplied the way production supplies it — one `get_settings`
    /// answer, read back through the poller into `ChannelTimelineModel.readout` — and it is the
    /// model the run's items carry too. Only the run's own may be drawn.
    ///
    /// Discriminating twice over: a pane that preferred the channel's header model draws it here,
    /// and a row that fell back to the message's own model draws it as well, because the item this
    /// row is built from carries exactly that value.
    func testTheBadgeIsTheRunsOwnModelAndNotTheChannelsHeaderReadout() async throws {
        let rig = try TranscriptRig(selecting: InventedAgents.run(0))
        let content = try XCTUnwrap(rig.model.read.content(of: InventedAgents.run(0)),
                                    "the read holds no content for the run the pane is open on")

        // The channel the pane is drawn over, with an engine answer behind its header.
        let app = AppModel(registry: RowRegistry())
        let double = ComposerLifecycleDouble()
        await double.openEvents(of: rig.key)
        let channel = ChannelTimelineModel(key: rig.key, workspace: nil, lifecycle: double)
        channel.adopt(ChannelHeader(row: HeaderReadoutTests.Rig.row(
            rig.key,
            entry: HeaderReadoutTests.Rig.entry(rig.key, branch: "an-invented-branch"),
            origin: .owned(.ready))))
        await double.stageSend("get_settings",
                               .success(.object(["applied": .object(["model": .string(TranscriptRig.channelModel)])])))
        await channel.refreshReadbacks()

        let header = try XCTUnwrap(channel.readout.model,
                                   "the settings readback never reached the channel's readout, so there is no "
                                   + "channel model to tell the run's from")
        XCTAssertFalse(header == content.model,
                       "the channel's header and the run report the same model, so this test cannot tell them apart")

        XCTAssertEqual(AgentTranscriptHeader.badge(of: content), TranscriptRig.runModel,
                       "the badge is not the model the run's own assistant frames carried")

        let drawn = ViewTree.values(of: String.self, in: AgentTranscriptHeader(content: content).body)
        XCTAssertEqual(drawn.filter { $0 == TranscriptRig.runModel }.count, 1,
                       "the framing draws the run's model \(drawn.filter { $0 == TranscriptRig.runModel }.count) "
                       + "time(s), not once")
        XCTAssertEqual(drawn.filter { $0 == header }.count, 0,
                       "the framing draws the channel's header model on a subagent's transcript")

        // The badge on the message, for the reason above: the header is not where item 38's badge
        // is. The item this row is built from carries the **channel's** model, and the context is
        // built over the channel whose readout reports it — so a pane that preferred either draws
        // the wrong one, and only this clause would see it.
        let context = AgentTranscriptPane.context(for: content, in: app, channel: channel, model: rig.model)
        let row = ViewTree.values(of: String.self, in: TranscriptRig.assistantRow(context: context, model: header))
        XCTAssertEqual(row.filter { $0 == TranscriptRig.runModel }.count, 1,
                       "the drawn message badges \(row.filter { $0 == TranscriptRig.runModel }.count) run model(s), "
                       + "not 1")
        XCTAssertEqual(row.filter { $0 == header }.count, 0,
                       "a message inside the run's transcript is badged with the channel's model rather than the run's")
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
    let key = PanelFixtures.key(52)

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
        store.select(run, in: key)
        model = AgentsModel(channel: key, timelines: { [timeline] _ in timeline }, store: store)
    }

    /// One assistant message of the open run, drawn through **the pane's own context expression**.
    ///
    /// The row is C6.1's, unmodified; what this walks is the frame it draws around the message,
    /// which is where the author and the badge are. Reflection does not enter the frame's content
    /// closure, so the strings found here are exactly the frame's own.
    func assistantRow(model itemModel: String?) -> Any {
        let app = AppModel(registry: RowRegistry())
        guard let content = model.read.content(of: model.selectedRun ?? "") else { return [] }
        let context = AgentTranscriptPane.context(for: content, in: app,
                                                  channel: app.timelines.model(for: key), model: model)
        return Self.assistantRow(context: context, model: itemModel)
    }

    /// The same row, for a caller that supplies the context — nil being the channel column's, which
    /// is the half that says this leaf changed nothing there.
    static func assistantRow(context: TimelineRenderContext?, model: String? = channelModel) -> Any {
        AssistantMessageBody(item: InventedItems.assistant([InventedItems.text("an invented sentence")],
                                                           model: model),
                             context: context).body
    }
}
