import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.4 Task 5, gate G3: what a user can do to one agent run from its node, and the two actions at
/// the top of the tree that go through a confirm.
///
/// **Every assertion is the exact request or action handed to the double**, never a surface that
/// changed: a menu item appearing is not a request sent, and a dialog appearing is not an action
/// withheld until it is answered. The double records `send` and `perform` separately, because Y5
/// splits these seven affordances across both and a surface that took the other route would
/// otherwise pass.
///
/// Every identifier here is invented (§11) and nothing is written anywhere (X9). A task id is
/// drawable and never printable, so an assertion over a value that carries one is a boolean with a
/// written message.
@MainActor
final class AgentNodeActionTests: XCTestCase {

    // MARK: - Stop

    /// **G3: *Stop* is `stop_task` naming the node's own id, on the node's channel.**
    ///
    /// Driven through the outline's own row rather than through a model member, so what is asserted
    /// is that the tree *offers* the action and that pressing it sends that request — a model with
    /// the right method and no button reaching it would pass the second half alone.
    func testStopSendsStopTaskWithTheNodesID() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        rig.model.select(Rig.runID)

        try press("Stop", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let sent = await rig.lifecycle.sent
        XCTAssertEqual(sent.count, 1, "one press sent \(sent.count) control request(s)")
        XCTAssertTrue(sent.first == AnyControlRequest(StopTask(taskID: Rig.runID)),
                      "Stop sent a request that is not stop_task naming this node")
        let performed = await rig.lifecycle.actions.count
        XCTAssertEqual(performed, 0, "Stop took the lifecycle-action route \(performed) time(s) instead of X5's send")
        let onTheNodesChannel = await rig.lifecycle.channels.allSatisfy { $0 == rig.key }
        XCTAssertTrue(onTheNodesChannel, "the request went out on a channel other than the node's")
    }

    /// A run that is not running offers no *Stop*: the engine would refuse it, and an offer the
    /// engine refuses is worse than no offer.
    func testAFinishedRunOffersNoStop() throws {
        let rig = try Rig(mirror: Rig.runningAgent(), tree: Rig.completedTree())
        rig.model.select(Rig.runID)

        XCTAssertNil(ViewTree.button("Stop", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "a completed run was offered Stop")
    }

    // MARK: - Move to background

    /// **G3: *Move to background* is `background_tasks` naming the run's tool-use id.**
    ///
    /// The eligibility half is the discriminating one. The mirror is what §8.8 gates the offer on,
    /// and it is published on `ChannelTimeline` only since C3's corrective — so the pair is asserted:
    /// the run the mirror holds is offered the action, and a run it never saw is not. A panel that
    /// offered it on every node passes the first assertion alone.
    func testMoveToBackgroundSendsBackgroundTasksWithTheToolUseID() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        rig.model.select(Rig.runID)

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let sent = await rig.lifecycle.sent
        XCTAssertEqual(sent.count, 1, "one press sent \(sent.count) control request(s)")
        XCTAssertTrue(sent.first == AnyControlRequest(BackgroundTasks(toolUseID: Rig.toolUseID)),
                      "Move to Background sent a request that is not background_tasks naming this run's tool use")
        let onTheNodesChannel = await rig.lifecycle.channels.allSatisfy { $0 == rig.key }
        XCTAssertTrue(onTheNodesChannel, "the request went out on a channel other than the node's")
    }

    /// The offer follows the mirror and nothing else: a run the mirror never saw is not offered the
    /// action, on the same tree and through the same row.
    func testARunTheMirrorDoesNotHoldIsNotOfferedBackgrounding() throws {
        let rig = try Rig(mirror: RegistryMirror())
        rig.model.select(Rig.runID)

        XCTAssertNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "a run the registry mirror never saw was offered backgrounding")
        XCTAssertNotNil(ViewTree.button("Stop", in: try Self.actionBody(of: Rig.runID, in: rig)),
                        "the row drew no actions at all, so the assertion above proves nothing")
    }

    /// **G3: `{backgrounded: false}` is a success body and not a success.**
    ///
    /// It is the engine saying the registry row the panel read is stale or ineligible (§8.4, item
    /// 61's first arm). Three clauses, and a handler that read any non-throwing reply as success
    /// fails all three: nothing reports the run moved, the derived read is dropped so the next body
    /// takes whatever the timeline now says, and the affordance goes for that run.
    func testAStaleBackgroundedFalseRefreshesRatherThanReportingSuccess() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.stageReply(.success(.object(["backgrounded": .bool(false)])))
        rig.model.select(Rig.runID)
        _ = rig.model.read
        let cache = try XCTUnwrap(ViewTree.values(of: AgentRunReadCache.self, in: rig.model).first,
                                  "the session holds no read cache")
        let before = cache.builds

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let actions = try XCTUnwrap(rig.model.actions)
        XCTAssertTrue(actions.lastBackgrounding == .stale,
                      "a {backgrounded: false} reply was concluded as something other than a stale row")
        // A boolean and not `XCTAssertNil` (§11): a `RowBanner` carries the engine's own sentence,
        // and a failing `XCTAssertNil` prints its operand.
        XCTAssertTrue(actions.banner == nil,
                      "a success body raised a banner, which belongs to the refusal arm alone")
        XCTAssertFalse(actions.backgroundingDisabled,
                       "a stale row disabled backgrounding for the whole session, which is §6.4's arm")
        _ = rig.model.read
        XCTAssertEqual(cache.builds, before + 1,
                       "the read was rebuilt \(cache.builds - before) time(s) after the engine contradicted it")
        XCTAssertNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "the action stayed on a run the engine has said its row is stale for")
    }

    /// A reply that says the run **did** move is the other arm, and it is not the stale one: the
    /// action stays offered and nothing is dropped.
    func testABackgroundedTrueReplyIsNotReadAsStale() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.stageReply(.success(.object(["backgrounded": .bool(true)])))
        rig.model.select(Rig.runID)

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let actions = try XCTUnwrap(rig.model.actions)
        XCTAssertTrue(actions.lastBackgrounding == .moved,
                      "a {backgrounded: true} reply was concluded as a stale row")
        XCTAssertEqual(actions.staleBackgrounding.count, 0,
                       "\(actions.staleBackgrounding.count) run(s) were marked stale by a reply that moved one")
    }

    /// **A stale row is a reading about one row of the registry, and it expires when the engine
    /// moves on from that row.**
    ///
    /// `{backgrounded: false}` says the registry row the panel read is stale, and the affordance goes
    /// for that run. Held against the run alone it never came back: a re-engaged run — a new
    /// `tool_use` block, a fresh mirror row the engine is currently willing to move — was refused the
    /// action for the life of the panel, and nothing on screen said why.
    ///
    /// The discriminating clause is the first: the action is gone straight after the reply, so what
    /// the clauses below measure is the reading expiring rather than a panel that never held one.
    func testAStaleRowExpiresWhenTheEngineReEngagesTheRun() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.stageReply(.success(.object(["backgrounded": .bool(false)])))
        rig.model.select(Rig.runID)

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)
        XCTAssertNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "the action stayed on the very row the engine called stale")

        // The engine re-engages the run: the mirror names it again, under a new block.
        // The engine re-engages the run: a second `task_started` for the same id, which is the
        // re-engagement `nested-depth-2`'s README says a host must expect. **The same `tool_use`
        // block**, because that is the case tracker 178 records as the one the corpus produces — an
        // expiry that needed a new id would never fire on the runs this actually happens to.
        rig.published.timeline.agents = Rig.reEngagedTree()

        XCTAssertNotNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                        "a re-engaged run the mirror is offering is still refused backgrounding")
        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 2)
        let sent = await rig.lifecycle.sent
        XCTAssertEqual(sent.count, 2, "the second press sent \(sent.count) control request(s) in total, not 2")
        XCTAssertTrue(sent.last == AnyControlRequest(BackgroundTasks(toolUseID: Rig.toolUseID)),
                      "the second press named a block other than the one the mirror holds")
    }

    // MARK: - The two confirms (child spec D9 and D14)

    /// **G3, and the clause the whole confirm exists for: declining performs nothing.**
    ///
    /// A dialog wired straight to the action passes every other assertion in this file — the button
    /// is there, the dialog comes up, the affirmative works — and ends a user's turn because they
    /// pressed *Cancel*. So the first thing asserted is the double's action list at zero.
    func testDecliningTheConfirmPerformsNothing() async throws {
        for opening in [AgentTreeConfirm.stopEverythingTitle, AgentTreeConfirm.backgroundAllTitle] {
            let rig = try Rig(mirror: Rig.runningAgent())
            // The double **can** answer a `perform`, so a decline that performed anyway would be
            // recorded rather than trapping: what is asserted is an empty action list, not a crash.
            await rig.lifecycle.always(.success(Self.state(rig.key)))
            await rig.lifecycle.setLive(["task_invented_live_01", "task_invented_live_02"])

            try pressTop(opening, in: rig)
            await rig.settleConfirm()
            XCTAssertNotNil(rig.model.actions?.pending, "\(opening) raised no confirm at all")
            let beforeDecline = await rig.lifecycle.actions.count
            XCTAssertEqual(beforeDecline, 0, "\(opening) performed \(beforeDecline) action(s) before it was answered")

            // The dialog's *Cancel*, which is the member its button calls. A
            // `confirmationDialog`'s content is a closure and `Mirror` does not enter one, so the
            // affirmative and the decline are driven through the members the bar wires them to —
            // and the wiring itself is asserted from the source below.
            rig.model.actions?.cancelPending()
            await Task.yield()

            let performed = await rig.lifecycle.actions.count
            XCTAssertEqual(performed, 0, "declining \(opening) performed \(performed) action(s)")
            XCTAssertNil(rig.model.actions?.pending, "declining \(opening) left the confirm waiting")
        }
    }

    /// **G3: *Stop everything* performs `.stopEverything`, and only after the affirmative.**
    func testStopEverythingPerformsTheActionOnlyAfterTheConfirm() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.always(.success(Self.state(rig.key)))
        await rig.lifecycle.setLive(["task_invented_live_01"])

        try pressTop(AgentTreeConfirm.stopEverythingTitle, in: rig)
        await rig.settleConfirm()
        let beforeAnswer = await rig.lifecycle.actions.count
        XCTAssertEqual(beforeAnswer, 0, "the action ran \(beforeAnswer) time(s) before the user answered")

        rig.model.actions?.answerPending()
        await rig.settle(actions: 1)

        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the affirmative performed \(actions.count) action(s)")
        if case .stopEverything = actions.first { } else { XCTFail("the affirmative performed something else") }
        let sent = await rig.lifecycle.sent.count
        XCTAssertEqual(sent, 0, "Stop everything took X5's send route \(sent) time(s) instead of perform")
        // G3's "on the node's channel", which the action route needs as much as the send route does:
        // ending every task in **another** session is the same button with the same recording and a
        // different victim.
        let onTheTreesChannel = await rig.lifecycle.channels.allSatisfy { $0 == rig.key }
        XCTAssertTrue(onTheTreesChannel, "the action was performed on a channel other than the tree's")
    }

    /// The same shape for *Background all* — and its copy must not imply that anything stops, which
    /// is C6.2's sentence and is reused rather than rewritten (D14).
    func testBackgroundAllPerformsTheActionOnlyAfterTheConfirm() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.always(.success(Self.state(rig.key)))

        try pressTop(AgentTreeConfirm.backgroundAllTitle, in: rig)
        await rig.settleConfirm()
        let beforeAnswer = await rig.lifecycle.actions.count
        XCTAssertEqual(beforeAnswer, 0, "the action ran \(beforeAnswer) time(s) before the user answered")

        rig.model.actions?.answerPending()
        await rig.settle(actions: 1)

        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the affirmative performed \(actions.count) action(s)")
        if case .backgroundAll = actions.first { } else { XCTFail("the affirmative performed something else") }
        let onTheTreesChannel = await rig.lifecycle.channels.allSatisfy { $0 == rig.key }
        XCTAssertTrue(onTheTreesChannel, "the action was performed on a channel other than the tree's")
        let message = AgentTreeConfirm.backgroundAll.message
        XCTAssertTrue(message == ComposerConfirmation.backgroundAll.message,
                      "the panel writes its own Background all copy instead of reusing C6.2's")
        XCTAssertTrue(message.contains("Nothing stops"),
                      "the Background all confirm no longer says that nothing stops")
    }

    /// **§11: the *Stop everything* confirm names a count and no ids.**
    ///
    /// The census is X5's own — `liveTaskIDs(of:)`, the fleet's fact rather than the fold's, because
    /// the action ends work in a channel this window may never have drawn. The discriminating half
    /// is the second: two invented ids are staged and neither appears in the sentence.
    func testTheStopEverythingConfirmNamesACountAndNoIDs() async throws {
        let ids = ["task_invented_live_01", "task_invented_live_02", "task_invented_live_03"]
        let rig = try Rig(mirror: Rig.runningAgent())
        // Answerable, so a panel that performed the action instead of asking is recorded rather
        // than trapping — a crashed bundle reports "Executed 0" and says nothing.
        await rig.lifecycle.always(.success(Self.state(rig.key)))
        await rig.lifecycle.setLive(ids)

        try pressTop(AgentTreeConfirm.stopEverythingTitle, in: rig)
        await rig.settleConfirm()

        let census = await rig.lifecycle.censusCalls
        XCTAssertEqual(census, 1, "the confirm took the fleet's census \(census) time(s)")
        let pending = try XCTUnwrap(rig.model.actions?.pending, "no confirm is waiting")
        XCTAssertTrue(pending == .stopEverything(liveTaskCount: ids.count),
                      "the confirm carries a count other than the fleet's own")
        let message = pending.message
        XCTAssertTrue(message.contains("\(ids.count) running task(s)"),
                      "the confirm's sentence does not state the count of what it ends")
        for id in ids {
            XCTAssertFalse(message.contains(id), "the confirm's sentence names a task id")
        }
        XCTAssertTrue(message.hasPrefix(ComposerConfirmation.stopEverything.message),
                      "the panel writes its own Stop everything copy instead of reusing C6.2's")
    }

    /// The dialog's own wiring, checked against the source because `Mirror` cannot reach it.
    ///
    /// A `confirmationDialog`'s content is a `@ViewBuilder` closure, and reflection does not enter a
    /// closure — so the two buttons above are driven through the members the bar wires them to, and
    /// this is what says those are the members. The synchronous claim is the load-bearing half: the
    /// affirmative must take the answer whole in the button's own call, because SwiftUI runs the
    /// dismissal — the cancel path — before the button's `Task` body begins (C6.2's rule, D14).
    func testTheDialogsAffirmativeClaimsSynchronously() throws {
        let bar = try XCTUnwrap(try Self.agentSources().first { $0.name == "AgentTreeConfirm.swift" },
                                "the tree's confirm no longer lives where the check looks")
        XCTAssertTrue(bar.code.contains("confirmationDialog"), "the panel presents no dialog of its own")
        XCTAssertTrue(bar.code.contains("{ actions.answerPending() }"),
                      "the affirmative does not claim the answer synchronously")
        XCTAssertTrue(bar.code.contains("{ actions.cancelPending() }"), "the decline is wired to something else")
        // And it does not route through the composer, which a popped-out window and a read-only
        // channel both lack (D14).
        for (name, code) in try Self.agentSources() {
            XCTAssertFalse(code.contains("ComposerModel"), "\(name) reaches the composer for its confirm")
        }
    }

    /// **A census that comes back late does not replace the confirm the user raised after it.**
    ///
    /// The scenario, and the reason this is the file's most serious clause: press *Stop everything*,
    /// then press *Background all* while the fleet's census is still in the air. The census returns,
    /// writes its own dialog into the slot, and the user — who is looking at a dialog they believe
    /// says "nothing stops" — confirms `.stopEverything` and loses every running task, which is work
    /// `--resume` cannot restore.
    ///
    /// Three clauses: the race actually ran, the waiting confirm is the one the user raised last,
    /// and the affirmative performs **that** action. The third is the one that matters — a panel
    /// that kept the right dialog and performed the other would pass the first two.
    func testALateCensusDoesNotReplaceTheConfirmRaisedAfterIt() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.always(.success(Self.state(rig.key)))
        await rig.lifecycle.setLive(["task_invented_live_01", "task_invented_live_02"])
        let raced = Pressed()
        await rig.lifecycle.duringCensus {
            await MainActor.run {
                rig.model.actions?.requestBackgroundAll()
                raced.note()
            }
        }

        try pressTop(AgentTreeConfirm.stopEverythingTitle, in: rig)
        let returned = await Self.settle { await rig.lifecycle.censusesReturned >= 1 }
        XCTAssertTrue(returned, "the census never came back, so nothing here is about a late one")
        XCTAssertTrue(raced.did, "the second press never happened, so the census raced nothing")

        let pending = try XCTUnwrap(rig.model.actions?.pending, "no confirm is waiting")
        XCTAssertTrue(pending == .backgroundAll,
                      "the census's late completion replaced the confirm the user raised after it")

        rig.model.actions?.answerPending()
        await rig.settle(actions: 1)
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the affirmative performed \(actions.count) action(s)")
        if case .backgroundAll = actions.first { } else {
            XCTFail("a click that said background stopped every running task in the channel")
        }
    }

    /// Whether the competing press happened at all. A flag rather than a count: the press has to
    /// land **inside** the census's window, and a test that assumed it did would be asserting about
    /// a race that never ran.
    @MainActor
    final class Pressed {
        private(set) var did = false
        func note() { did = true }
    }

    // MARK: - A session that does no background work at all (§6.4)

    /// **G3: the refusal renders as a banner and hides *both* backgrounding affordances.**
    ///
    /// The sentence arrives as a control **error**, before the engine consults its task registry, so
    /// it cannot be read out of a `{backgrounded: false}` body — the two arms are two paths and a
    /// handler that drove both off one would never raise this banner.
    ///
    /// Four clauses. The outcome is a refusal, the banner carries the engine's own words, the node's
    /// *Move to background* is gone and the tree's *Background all* is gone with it. *Stop
    /// everything* stays, which is what makes this about backgrounding rather than about hiding
    /// everything after any failure.
    func testBackgroundingDisabledHidesBothAffordances() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.stageReply(.failure(.controlError(AgentNodeActions.backgroundingRefusal)))
        rig.model.select(Rig.runID)
        XCTAssertNotNil(ViewTree.button(AgentTreeConfirm.backgroundAllTitle, in: try Self.topBarBody(in: rig)),
                        "the tree offered no Background All before the refusal, so nothing was hidden by it")

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let actions = try XCTUnwrap(rig.model.actions)
        XCTAssertTrue(actions.lastBackgrounding == .refused, "the refusal was concluded as something else")
        XCTAssertTrue(actions.backgroundingDisabled, "the session's refusal left backgrounding available")
        XCTAssertTrue(actions.banner?.text == AgentNodeActions.backgroundingRefusal,
                      "the banner says something other than the engine's own sentence")
        // **And the tree draws it.** The clause above reads the model; a body that raised the
        // banner and never rendered it takes both affordances away with nothing on screen to say
        // why, which is the state this arm exists to make legible. Asserted through the drawn
        // value and its own body, because a sweep of the tree's strings finds the sentence on the
        // action object the body holds whether or not anything renders it.
        let banner = try XCTUnwrap(ViewTree.values(of: AgentTreeBanner.self,
                                                   in: AgentTreeView(model: rig.model).body).first,
                                   "the tree drew no banner at all for a refusal it is holding")
        XCTAssertTrue(banner.sentence == AgentNodeActions.backgroundingRefusal,
                      "the drawn banner says something other than the engine's own sentence")
        let drawn = ViewTree.values(of: String.self, in: banner.body)
            .filter { $0 == AgentNodeActions.backgroundingRefusal }
        XCTAssertEqual(drawn.count, 1, "the banner's own body draws the refusal \(drawn.count) time(s), not once")
        XCTAssertNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "the node still offers backgrounding in a session that refuses it")
        XCTAssertNil(ViewTree.button(AgentTreeConfirm.backgroundAllTitle, in: try Self.topBarBody(in: rig)),
                     "the tree still offers Background All in a session that refuses it")
        XCTAssertNotNil(ViewTree.button(AgentTreeConfirm.stopEverythingTitle, in: try Self.topBarBody(in: rig)),
                        "Stop Everything went with it, so the refusal hid more than backgrounding")
    }

    /// *Background all* meets the same refusal — it is one `background_tasks` with no tool-use id —
    /// and hides the same two affordances, through the action route rather than the send route.
    func testTheRefusalReachesTheSameReadingThroughBackgroundAll() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.failPerform(with: WireError.controlError(AgentNodeActions.backgroundingRefusal))
        rig.model.select(Rig.runID)

        try pressTop(AgentTreeConfirm.backgroundAllTitle, in: rig)
        await rig.settleConfirm()
        rig.model.actions?.answerPending()
        await rig.settle(actions: 1)
        let noted = await Self.settle { rig.model.actions?.banner != nil }
        XCTAssertTrue(noted, "the refused action left no banner before the budget ran out")

        XCTAssertTrue(rig.model.actions?.backgroundingDisabled == true,
                      "a refusal that arrived through Background all left backgrounding available")
        XCTAssertNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                     "the node still offers backgrounding after the channel-wide action was refused")
    }

    /// **A failure that is not the refusal hides nothing.**
    ///
    /// Discriminating, and the reason the reading is taken from the sentence rather than from "a
    /// control error on a backgrounding request": §6.4 hides the affordances for the process and
    /// nothing puts them back, so a transient error that hid them would take backgrounding away from
    /// a channel that can still do it, for as long as the panel lives.
    func testATransientFailureRaisesTheBannerAndHidesNothing() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        await rig.lifecycle.stageReply(.failure(.controlError("The request could not be completed.")))
        rig.model.select(Rig.runID)

        try press("Move to Background", on: Rig.runID, in: rig)
        await rig.settle(sends: 1)

        let actions = try XCTUnwrap(rig.model.actions)
        XCTAssertNotNil(actions.banner, "a failed request left no banner at all")
        XCTAssertFalse(actions.backgroundingDisabled,
                       "a failure that is not the session's refusal disabled backgrounding for the session")
        XCTAssertNotNil(ViewTree.button("Move to Background", in: try Self.actionBody(of: Rig.runID, in: rig)),
                        "a transient failure took the affordance away for good")
    }

    // MARK: - The two that send nothing

    /// **G3: *Open transcript file* is one `WorkspaceLink.file`, and no descriptor is opened.**
    ///
    /// Three clauses. The link goes to the **channel's** router — X7's `ChannelContext.links`, which
    /// is the one route a panel has. It carries the url `AgentRunTree.transcriptURL(of:)` composes,
    /// so a panel that guessed a path would name a different file. And nothing under `App/Agents/`
    /// opens a descriptor on it: C5's TCC fact binds and the `.file` target is the Files panel's, so
    /// a panel that read the transcript itself would be a second reader spending a grant that is not
    /// its own.
    func testOpenTranscriptFileEmitsOneFileLinkAndOpensNoDescriptor() async throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        rig.model.select(Rig.runID)
        let expected = try XCTUnwrap(rig.model.transcriptURL(of: Rig.runID), "the tree composed no transcript path")

        try press("Open Transcript File", on: Rig.runID, in: rig)
        let raised = await Self.settle { await rig.links.opened.isEmpty == false }
        XCTAssertTrue(raised, "the press raised no link before the budget ran out")

        let opened = await rig.links.opened
        XCTAssertEqual(opened.count, 1, "one press raised \(opened.count) link(s)")
        XCTAssertTrue(opened.first == .file(expected, line: nil),
                      "the link raised is not a .file at the path the tree composes")
        let sent = await rig.lifecycle.sent.count
        XCTAssertEqual(sent, 0, "opening a transcript sent \(sent) control request(s)")

        // The static half: no source under `App/Agents/` reaches a file at all.
        for (name, code) in try Self.agentSources() {
            for opener in ["FileHandle", "contentsOf:", "contentsOfFile", "FileManager.default",
                           "InputStream", "String(contentsOf"] {
                XCTAssertFalse(code.contains(opener),
                               "\(name) reaches a file directly instead of raising a link")
            }
        }
    }

    /// A run whose tree composes no path is offered nothing, rather than a button pointing at a path
    /// nobody answered for.
    func testARunWithNoTranscriptPathIsOfferedNoOpen() throws {
        let rig = try Rig(mirror: Rig.runningAgent())
        rig.model.select(Rig.runID)
        // The row the outline built while the tree was there, kept: what is being asked is what the
        // outline's own row expression offers for a run whose path the tree no longer composes, and
        // a row rebuilt afterwards would not exist to ask.
        let row = try XCTUnwrap(AgentTreeView.visibleRows(read: rig.model.read, collapsed: [])
                                    .first { $0.id == Rig.runID },
                                "the outline drew no row for the run")
        rig.published.timeline.agents = nil

        // A boolean and not `XCTAssertNil` (§11): the url is composed from the config home, the
        // session id and the project slug, and a failing `XCTAssertNil` prints its operand.
        XCTAssertTrue(rig.model.transcriptURL(of: Rig.runID) == nil,
                      "a channel with no tree composed a path anyway")

        // **And the affordance is what is asserted**, not only the model behind it: a bar that drew
        // *Open transcript file* whatever the path was would leave the user pressing a button that
        // raises a link to nothing, and the clause above would not see it.
        let drawn = AgentOutline.view(of: row, in: rig.model, selected: Rig.runID)
        let bar = try XCTUnwrap(ViewTree.values(of: AgentNodeActionBar.self, in: drawn.body).first,
                                "the open node drew no action bar at all")
        XCTAssertNil(ViewTree.button("Open Transcript File", in: bar.body),
                     "a run whose tree composes no path was offered the transcript file anyway")
        XCTAssertNotNil(ViewTree.button("Copy Agent ID", in: bar.body),
                        "the bar drew no actions at all, so the assertion above proves nothing")
    }

    /// **G3: *Copy agent id* puts the node id on the pasteboard, and logs nothing.**
    ///
    /// It writes to a **named** board, never the general one: a suite that took the user's clipboard
    /// while it ran would be a side effect nobody asked for. The second clause is the §11 one — the
    /// id leaves the app here and nowhere else, and no diagnostic in this leaf states one.
    func testCopyAgentIDWritesTheIDAndLogsNothing() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("afleet.invented.agents-copy-id"))
        board.clearContents()
        let rig = try Rig(mirror: Rig.runningAgent(), pasteboard: board)
        rig.model.select(Rig.runID)

        try press("Copy Agent ID", on: Rig.runID, in: rig)

        XCTAssertTrue(board.string(forType: .string) == Rig.runID,
                      "the pasteboard holds something other than the node's own id")
        // Nothing under `App/Agents/` prints, logs or traces at all, which is what makes "logs
        // nothing" a property of the source rather than of this one press.
        for (name, code) in try Self.agentSources() {
            for spelling in ["print(", "NSLog", "Logger(", "os_log", "debugPrint"] {
                XCTAssertFalse(code.contains(spelling), "\(name) writes a diagnostic of its own")
            }
        }
    }

    /// Every Swift source under `App/Agents/`, comments dropped so a sentence about a file is not
    /// read as a call to one. C6.3's G3 shape, for its reason: a rule about the source is checked
    /// against the source.
    static func agentSources() throws -> [(name: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "App").appending(path: "Agents")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 0, "no source was found under the Agents panel")
        return try names.map { name in
            let text = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (name, code)
        }
    }

    // MARK: - The rig

    /// One channel, one published timeline holding C3's tree and C3's registry mirror, and the tab
    /// built the way `performLaunch` builds it — the app's one selection store handed in, the fold
    /// reached by a closure, the fleet as X5.
    ///
    /// It goes through `PanelHostModel.session(for:context:)` rather than constructing the model,
    /// because the session the host retains is the object the panel draws and a test that made its
    /// own would be asserting about something the app never builds.
    @MainActor
    struct Rig {

        static let runID: AgentRunID = "task_invented_agent_01"
        static let toolUseID = "toolu_invented0001"
        /// The block a re-engagement of the same run is named by. A second `tool_use`, because that
        /// is what a re-engaged run gets, and the id is what the engine matches the request against.
        static let secondToolUseID = "toolu_invented0002"

        let lifecycle: ActionDouble
        let links: RecordingLinkRouter
        let host: PanelHostModel
        let published: Published
        let model: AgentsModel
        let key: ChannelKey

        init(mirror: RegistryMirror, tree: AgentRunTree? = nil,
             pasteboard: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("afleet.invented.agents-actions"))) throws {
            lifecycle = ActionDouble()
            links = RecordingLinkRouter()
            key = PanelFixtures.key(21)
            published = Published(ChannelTimeline(agents: tree ?? Self.runningTree(), registry: mirror))
            host = PanelHostModel()
            try host.register(AgentsTab(timelines: { [published] _ in published.timeline },
                                        selection: AgentSelectionStore(),
                                        lifecycle: { [lifecycle] in lifecycle },
                                        pasteboard: pasteboard))
            // The channel's own capabilities, which is where a panel's link goes (X7).
            let context = ComposerContextFixtures.context(key, links: links)
            model = try XCTUnwrap(host.session(for: .agents, context: context) as? AgentsModel,
                                  "the tab made something other than its own session")
        }

        /// Waits for the round trip a button press started. Counted rather than timed: the press
        /// starts a `Task`, and a test that waited a duration would be asserting about the scheduler.
        func settle(sends: Int, file: StaticString = #filePath, line: UInt = #line) async {
            let arrived = await AgentNodeActionTests.settle { await self.lifecycle.sent.count >= sends }
            XCTAssertTrue(arrived, "the press sent fewer than \(sends) control request(s) before the budget ran out",
                          file: file, line: line)
            let finished = await AgentNodeActionTests.settle { self.model.actions?.inFlight != true }
            XCTAssertTrue(finished, "the request never left the wire, so the round trip did not settle",
                          file: file, line: line)
        }

        /// The same, for the half of Y5 that goes out as a `LifecycleAction`.
        func settle(actions count: Int, file: StaticString = #filePath, line: UInt = #line) async {
            let performed = await AgentNodeActionTests.settle { await self.lifecycle.actions.count >= count }
            XCTAssertTrue(performed, "fewer than \(count) action(s) were performed before the budget ran out",
                          file: file, line: line)
        }

        /// Waits for the confirm to be raised. *Stop everything* takes the fleet's census first, so
        /// the dialog appears one suspension after the button was pressed.
        func settleConfirm(file: StaticString = #filePath, line: UInt = #line) async {
            let raised = await AgentNodeActionTests.settle { self.model.actions?.pending != nil }
            XCTAssertTrue(raised, "no confirm was waiting before the budget ran out", file: file, line: line)
        }

        /// One running, foreground agent run — the shape §8.4 makes *Move to background* available
        /// for — folded from a `task_started` rather than assembled, so what the panel reads is what
        /// the fold would have produced.
        static func runningAgent(toolUseID: String = Rig.toolUseID,
                                 at instant: Date = InventedAgents.epoch) -> RegistryMirror {
            var mirror = RegistryMirror()
            let started = InventedAgents.taskStarted(taskID: runID, toolUseID: toolUseID,
                                                     agentType: "an-invented-agent", depth: 1)
            mirror.apply(.taskStarted(started), at: instant, epoch: .first)
            return mirror
        }

        static func runningTree() -> AgentRunTree {
            var tree = InventedAgents.tree()
            tree.apply(taskStarted: InventedAgents.taskStarted(taskID: runID, toolUseID: toolUseID,
                                                               agentType: "an-invented-agent", depth: 1),
                       at: InventedAgents.epoch)
            return tree
        }

        /// The same run, finished: `task_notification` is what C3 folds a run's end from.
        /// The same run, started a second time — one node whose `startedCount` moved, which is what
        /// C3 folds a re-engagement into.
        static func reEngagedTree() -> AgentRunTree {
            var tree = runningTree()
            tree.apply(taskStarted: InventedAgents.taskStarted(taskID: runID, toolUseID: toolUseID,
                                                               agentType: "an-invented-agent", depth: 1),
                       at: InventedAgents.epoch.addingTimeInterval(60))
            return tree
        }

        static func completedTree() -> AgentRunTree {
            var tree = runningTree()
            tree.apply(taskNotification: InventedAgents.taskNotification(taskID: runID, status: "completed"),
                       at: InventedAgents.epoch)
            return tree
        }

        /// The channel's timeline as the fold publishes it: one value, replaced in place, which is
        /// what the pane's closure reaches for on every access.
        @MainActor
        final class Published {
            var timeline: ChannelTimeline
            init(_ timeline: ChannelTimeline) { self.timeline = timeline }
        }
    }

    /// What the outline's row offers for one run, reached through the outline's **own** expression
    /// and never through a view this test assembled.
    ///
    /// Two descents, both forced by reflection rather than chosen: `Mirror` does not enter a
    /// `ForEach` closure, which is why the outline names the row-building expression, and it does not
    /// evaluate a nested view's `body`, which is why the action bar's own body is taken here. The
    /// path is otherwise exactly the app's.
    static func actionBody(of run: AgentRunID, in rig: Rig) throws -> Any {
        let outline = try XCTUnwrap(ViewTree.values(of: AgentOutline.self, in: AgentTreeView(model: rig.model).body).first,
                                    "the tree drew no outline")
        let row = try XCTUnwrap(outline.rows.first { $0.id == run }, "the outline drew no row for the run")
        let drawn = AgentOutline.view(of: row, in: rig.model, selected: rig.model.selectedRun)
        let bar = try XCTUnwrap(ViewTree.values(of: AgentNodeActionBar.self, in: drawn.body).first,
                                "the open node drew no action bar at all")
        return bar.body
    }

    /// The tree's own top bar, through the panel's real body. The second descent is the action bar's
    /// `body`, which reflection does not evaluate for a nested view.
    static func topBarBody(in rig: Rig) throws -> Any {
        let bar = try XCTUnwrap(ViewTree.values(of: AgentTreeActionBar.self, in: AgentTreeView(model: rig.model).body).first,
                                "the tree drew no channel-wide actions")
        return bar.body
    }

    /// Presses one of the tree's channel-wide buttons.
    func pressTop(_ label: String, in rig: Rig,
                  file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: try Self.topBarBody(in: rig)),
                                   "the tree offers no \(label) button", file: file, line: line)
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action", file: file, line: line)
    }

    /// Yields until the condition holds or the budget runs out, and answers whether it held.
    ///
    /// **Bounded on purpose.** Every wait in this tree is fulfilled by the event it waits for and
    /// none of them has a deadline — but a *broken* implementation leaves one unfulfilled for ever,
    /// and a spin that never ends turns a failing assertion into a suite that never reports. The
    /// budget is a count of scheduler turns rather than a duration, so it decides nothing about
    /// speed; what it bounds is the failure.
    ///
    /// **Every caller asserts the answer.** A wait whose outcome is discarded turns a handler that
    /// sends the right request and then stays in flight for ever into a passing test: the assertions
    /// after it read a surface that has settled by accident or not at all, and the one fact that
    /// says which — whether the wait was fulfilled — was thrown away.
    @MainActor
    static func settle(until condition: @MainActor () async -> Bool, turns: Int = 20_000) async -> Bool {
        for _ in 0..<turns {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    /// A channel state for a double that has to answer `perform`. Invented throughout (§11).
    static func state(_ key: ChannelKey) -> ChannelState {
        ChannelState(key: key,
                     origin: .owned(.ready),
                     desired: .owned,
                     observed: HolderSet(holders: [], observedAt: InventedAgents.epoch),
                     epoch: .first,
                     identity: .known(key.session),
                     presence: .idle,
                     pendingDecisions: [],
                     lastActivity: InventedAgents.epoch)
    }

    /// Presses a button the outline's row offers, failing when the row does not offer it — an
    /// affordance that is absent and an affordance that does nothing are different defects and this
    /// tells them apart.
    func press(_ label: String, on run: AgentRunID, in rig: Rig,
               file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: try Self.actionBody(of: run, in: rig)),
                                   "the node offers no \(label) button", file: file, line: line)
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action", file: file, line: line)
    }
}

/// A lifecycle that records **both** halves of Y5 and answers `liveTaskIDs`.
///
/// `LifecycleDouble` traps on `send` and on `liveTaskIDs`, and `ThreadDouble` traps on the second;
/// the seven affordances of §8.8 split across `send`, `perform` and the census, and the whole point
/// of gate G3 is which of the three an action took.
actor ActionDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    private(set) var sent: [AnyControlRequest] = []
    /// The channels the requests went out on, so "on the node's channel" is assertable without an
    /// aggregate that would print a `ChannelKey` on failure (§11).
    private(set) var channels: [ChannelKey] = []
    private(set) var actions: [LifecycleAction] = []
    private var replies: [Result<JSONValue, WireError>] = []
    private var outcome: Result<ChannelState, LifecycleError>?
    /// What the next `perform` throws, when it is not a `LifecycleError`. `Fleet.perform` is
    /// untyped-throws and `.backgroundAll` is one `background_tasks` request, so the engine's own
    /// `WireError.controlError` really does surface from this member.
    private var performError: (any Error)?
    /// What `liveTaskIDs` answers. Ids, because that is the member's shape; nothing this double
    /// serves ever prints one.
    private var live: [String] = []
    /// How often the census was taken. A confirm that named a count without asking is caught here.
    private(set) var censusCalls = 0

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func stageReply(_ reply: Result<JSONValue, WireError>) { replies.append(reply) }
    func always(_ outcome: Result<ChannelState, LifecycleError>) { self.outcome = outcome }
    func failPerform(with error: any Error) { performError = error }
    /// Runs **inside** `perform`, once. `LifecycleDouble`'s seam, needed here for the same reason: a
    /// reservation is held only while the answer is on the wire, so the second host's press has to
    /// happen in that window and nowhere else.
    private var interlude: (@Sendable () async -> Void)?
    func duringPerform(_ body: @escaping @Sendable () async -> Void) { interlude = body }
    /// The same seam inside the census, which is the one suspension *Stop everything* has before it
    /// can present its dialog — so it is the only window in which another raise can take the slot.
    private var censusInterlude: (@Sendable () async -> Void)?
    func duringCensus(_ body: @escaping @Sendable () async -> Void) { censusInterlude = body }
    func setLive(_ ids: [String]) { live = ids }

    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        sent.append(request)
        channels.append(key)
        guard !replies.isEmpty else { return .object([:]) }
        return try replies.removeFirst().get()
    }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        actions.append(action)
        channels.append(key)
        let running = interlude
        interlude = nil
        await running?()
        if let performError { throw performError }
        guard let outcome else { unreachable("perform with no staged outcome") }
        return try outcome.get()
    }

    func liveTaskIDs(of key: ChannelKey) async -> [String] {
        censusCalls += 1
        let running = censusInterlude
        censusInterlude = nil
        await running?()
        censusesReturned += 1
        return live
    }

    /// How many censuses have **come back**, which is not the same as how many were taken: what the
    /// race below waits for is the late one completing, and a count of calls is one before it does.
    private(set) var censusesReturned = 0

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func reviewTrustInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("reviewTrustInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID { unreachable("sendPrompt") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ActionDouble.\(member) is not part of the Agents panel's surface")
    }
}
