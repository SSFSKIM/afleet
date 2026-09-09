import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Gate **G1**: the run tree, on `nested-depth-2`, replayed through the app's own ingestion.
///
/// **Both parent sources reach the tree.** Since the C3 corrective, `StreamIngestion` feeds the
/// mirrored `agent_metadata` record and the `.meta.json` sidecars beside the transcript into the
/// tree for live *and* file-only channels, so `agents` is non-nil once `open` has built the fold.
/// G1's sentence — the depth-2 tree renders from the two-step join **before** the sidecar is written
/// and is corrected by it afterwards — therefore has two reachable arms, and they are two tests: one
/// on a channel whose sidecars are not yet on disk, one on a channel whose are.
///
/// **Every wait is fulfilled by the delivery it waits for.** Pushing an event into a fan-out is not
/// consuming it, and counting yields after a push measures the scheduler. So each replay ends with a
/// **barrier frame** — an invented `tool_use_summary` naming an invented tool-use id, which opens a
/// cluster nothing else can open — and every wait below is on the row that barrier makes, with the
/// wait's own outcome asserted.
///
/// §11: no assertion prints a path, a session id, a slug or a task id. **A task id is drawable and
/// never printable**: the tree draws one and every comparison over one here is spelled as a boolean
/// with a message this file wrote, because `XCTAssertEqual` prints both operands.
///
/// X9: every tree here is a `TempTree`, which canonicalises its root and skips before creating
/// anything if it resolves inside a config home.
@MainActor
final class AgentTreeGateTests: XCTestCase {

    // MARK: - Nesting (G1)

    /// Two nodes, one per task id, the depth-2 run **under** the depth-1 run, with the parent link
    /// answered by C3's two-step join.
    ///
    /// The recording carries one depth-1 run, so the *nesting* half of this gate is discriminated by
    /// `AgentRunReadTests.testANestedRunGoesUnderTheRunThatSpawnedItAndNotTheNewestRoot`, whose
    /// corpus has two roots and nests the depth-2 run under the older one.
    ///
    /// `parentSource` is the discriminating field: `task_started` carries no parent id and
    /// `spawn_depth` says how deep a run is without saying *under which* run, so a tree built from
    /// either alone answers `.none` here. The outline's own half is the last clause — closing the
    /// root hides the child, which is what "under" means on screen and what a flat list of nodes in
    /// the same order cannot do.
    ///
    /// **This is G1's first arm: before the `.meta.json` is written.** The channel is opened with the
    /// recording's sidecars withheld from disk — the ordinary case §7.3 describes, where the engine
    /// has spawned the run and not yet flushed its sidecar — so no metadata source can answer the
    /// parent question and the join is the only source that reaches it. The withholding is the whole
    /// discrimination: with the sidecars in place `StreamIngestion.loadMetadata` answers during
    /// `open`, before a single frame is replayed, and this arm's `parentSource` clause fails.
    func testTheDepthTwoTreeRendersFromTheTwoStepJoin() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2", sidecars: false)
        defer { Task { await rig.finish() } }
        let replayed = try await rig.replay()
        let settled1 = await rig.settleOnBarrier()
        XCTAssertTrue(settled1,
                      "the barrier never reached the model after \(replayed) event(s), so nothing below "
                      + "measures a replay")
        let settled2 = await rig.settleOnRuns(2)
        XCTAssertTrue(settled2, "the replay armed a tree with 2 runs in it")

        let read = rig.read()
        XCTAssertEqual(read.roots.count, 1, "the tree read as \(read.roots.count) root(s), not the 1 it holds")
        let root = try XCTUnwrap(read.roots.first, "the tree offered no root")
        let children = read.children(of: root)
        XCTAssertEqual(children.count, 1, "the root has \(children.count) child(ren), not 1")
        let child = try XCTUnwrap(children.first, "the root has no child")

        let tree = try XCTUnwrap(rig.model.timeline.agents, "the channel carries no run tree after the replay")
        XCTAssertEqual(tree.node(child)?.parentSource, .twoStepJoin,
                       "the nested run's parent was not answered by the two-step join")
        XCTAssertEqual(read.content(of: child)?.depth, 2, "the nested run does not draw depth 2")

        // The outline: two rows, the child second, and the root disclosable.
        let open = AgentTreeView.visibleRows(read: read, collapsed: [])
        XCTAssertEqual(open.count, 2, "the outline drew \(open.count) row(s) for 2 runs")
        XCTAssertTrue(open.first?.id == root, "the first row is not the root")
        XCTAssertTrue(open.last?.id == child, "the second row is not the root's child")
        XCTAssertEqual(open.first?.disclosure, .expanded, "the root's branch is not disclosable")
        XCTAssertEqual(open.last?.disclosure, .leaf, "the nested run reports a branch of its own")

        // And the child is *under* the root, not beside it: closing the root takes it with it.
        let closed = AgentTreeView.visibleRows(read: read, collapsed: [root])
        XCTAssertEqual(closed.count, 1,
                       "closing the root left \(closed.count) row(s), so the nested run is not under it")

        // The arm's premise, asserted rather than assumed: no sidecar was on disk to answer, so the
        // file source produced nothing at all for this run.
        XCTAssertTrue(tree.parentAnswers[child]?[.metaFile] == nil,
                      "a sidecar answered the parent question on the arm that withholds every sidecar")
        XCTAssertEqual(tree.conflicts.count, 0,
                       "the tree holds \(tree.conflicts.count) parent disagreement(s) where one source answered")
    }

    /// **G1's second arm: after the sidecar exists.** The same recording opened with its `.meta.json`
    /// sidecars in place — every archived channel, and every live one once the engine has flushed
    /// them — has the parent question answered by the file source during `open`, before a frame is
    /// replayed.
    ///
    /// What is asserted is what D1 rules and **not a re-parenting**: `AgentRunTree.link` is
    /// first-source-wins, C3 pins that with its own test, and a surface demanding the parent move on
    /// a late source would be asserting against the fold's stated invariant. So: the nesting is the
    /// same nesting, the answering source is the metadata source rather than the join, the join's own
    /// answer is **retained** beside it in `parentAnswers`, and the two agree — which is why nothing
    /// is in `conflicts`.
    ///
    /// The source is `.metaFile` and not `.agentMetadata`. Both are metadata sources and the child
    /// spec's D1 and the acceptance clause name the mirror's; on a channel opened from disk the
    /// sidecar is read while `open` is still buffering, so it is the one that speaks first. The
    /// divergence is reported rather than papered over — the observable fact is that a *metadata*
    /// source answered and the join did not.
    func testTheSidecarAnswersTheParentAndTheJoinsAnswerIsRetained() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2")
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let settledBarrier = await rig.settleOnBarrier()
        XCTAssertTrue(settledBarrier, "the replay never reached the model")
        let armed = await rig.settleOnRuns(2)
        XCTAssertTrue(armed, "the replay armed a tree with 2 runs in it")

        let read = rig.read()
        XCTAssertEqual(read.roots.count, 1, "the tree read as \(read.roots.count) root(s), not the 1 it holds")
        let root = try XCTUnwrap(read.roots.first, "the tree offered no root")
        let child = try XCTUnwrap(read.children(of: root).first, "the root has no child")
        XCTAssertEqual(AgentTreeView.visibleRows(read: read, collapsed: [root]).count, 1,
                       "the nested run is not drawn under the root")

        let tree = try XCTUnwrap(rig.model.timeline.agents, "the channel carries no run tree after the replay")
        XCTAssertEqual(tree.node(child)?.parentSource, .metaFile,
                       "the nested run's parent was not answered by the sidecar the channel was opened with")
        // The join ran and its answer is kept: a fold that let a later source erase the earlier
        // answers would show the same parent and the same nesting, and would have lost the evidence
        // that the two sources ever agreed.
        let answers = try XCTUnwrap(tree.parentAnswers[child], "the tree kept no parent answer for the nested run")
        XCTAssertEqual(answers.count, 2,
                       "the nested run kept \(answers.count) parent answer(s) where 2 sources spoke")
        XCTAssertTrue(answers[.twoStepJoin] == answers[.metaFile] && answers[.twoStepJoin] != nil,
                      "the two-step join's answer was not retained beside the sidecar's")
        XCTAssertTrue(answers[.twoStepJoin] == tree.node(child)?.parent,
                      "the join's retained answer is not the parent the tree holds")
        XCTAssertEqual(tree.conflicts.count, 0,
                       "two agreeing sources left \(tree.conflicts.count) disagreement(s) on the tree")
    }

    /// And where two sources **disagree**, the disagreement is visible rather than hidden: the tree
    /// keeps the parent the first source gave, and says so.
    ///
    /// Driven on the join-only arm — the join has answered, and a sidecar then arrives naming a
    /// different parent, which is the ordering §7.3 makes possible and the one `conflicts` exists
    /// for. The sidecar is invented whole (an invented parent id, an invented type) and written into
    /// the test's own temporary tree; the record is applied through C3's own reader, so what is
    /// asserted is the fold's behaviour and not a hand-built tree.
    ///
    /// The discriminating clause is the pair: a fold that silently took the later answer and a fold
    /// that silently dropped it draw the *same* tree, and only `conflicts` tells them apart.
    func testASecondSourceThatDisagreesIsRecordedAndDoesNotReParent() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2", sidecars: false)
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let settledBarrier = await rig.settleOnBarrier()
        XCTAssertTrue(settledBarrier, "the replay never reached the model")
        let armed = await rig.settleOnRuns(2)
        XCTAssertTrue(armed, "the replay armed a tree with 2 runs in it")

        let read = rig.read()
        let root = try XCTUnwrap(read.roots.first, "the tree offered no root")
        let child = try XCTUnwrap(read.children(of: root).first, "the root has no child")
        var tree = try XCTUnwrap(rig.model.timeline.agents, "the channel carries no run tree after the replay")
        XCTAssertEqual(tree.node(child)?.parentSource, .twoStepJoin,
                       "the join did not answer, so a later disagreement would disagree with nothing")

        try tree.apply(metaFile: try rig.disagreeingSidecar(taskID: child), at: Date())

        XCTAssertEqual(tree.node(child)?.parentSource, .twoStepJoin,
                       "a later source re-parented the run, which first-source-wins refuses")
        XCTAssertTrue(tree.node(child)?.parent == root, "the disagreeing source moved the run's parent")
        XCTAssertEqual(tree.conflicts.count, 1,
                       "the tree recorded \(tree.conflicts.count) disagreement(s) where 2 sources named "
                       + "2 different parents")
        let answers = try XCTUnwrap(tree.parentAnswers[child], "the tree kept no parent answer for the nested run")
        XCTAssertEqual(answers.count, 2,
                       "the tree kept \(answers.count) parent answer(s) where 2 sources spoke")
        XCTAssertTrue(answers[.metaFile] != answers[.twoStepJoin],
                      "the disagreeing source's own answer was not kept as it gave it")
        var timeline = rig.model.timeline
        timeline.agents = tree
        XCTAssertEqual(AgentTreeView.visibleRows(read: AgentRunRead(timeline: timeline), collapsed: [root]).count, 1,
                       "the nested run left the branch it was drawn under")
    }

    /// A second `task_started` for an id the tree already holds is **one** node that ran twice —
    /// the re-engagement `nested-depth-2`'s README says a host must expect.
    ///
    /// The elapsed-origin clause is the discriminating one: a fold that recreated the node on the
    /// second start would show the same row, the same nesting and the same status, and would have
    /// silently reset how long the run has been going.
    func testARepeatedTaskStartedIsOneNode() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2")
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let settled3 = await rig.settleOnBarrier()
        XCTAssertTrue(settled3, "the replay never reached the model")
        let settled4 = await rig.settleOnRuns(2)
        XCTAssertTrue(settled4, "the replay armed a tree with 2 runs in it")

        let before = rig.read()
        let run = try XCTUnwrap(before.roots.first, "the tree offered no root")
        let origin = try XCTUnwrap(before.content(of: run)?.elapsedOrigin, "the root has no elapsed origin")
        let started = try XCTUnwrap(before.content(of: run)?.startedCount, "the root has no start count")
        let toolUse = try XCTUnwrap(before.content(of: run)?.toolUseID, "the root names no spawning block")

        await rig.push(try AgentGateRig.taskStartedFrame(taskID: run, toolUseID: toolUse))
        try await rig.pushBarrier("toolu_invented_gate_restart")
        let settled5 = await rig.settle(on: "toolu_invented_gate_restart")
        XCTAssertTrue(settled5,
                      "the injected start never reached the model")

        let after = rig.read()
        XCTAssertEqual(after.roots.count, before.roots.count,
                       "the re-armed id made \(after.roots.count) root(s) where the tree had \(before.roots.count)")
        XCTAssertEqual(AgentTreeView.visibleRows(read: after, collapsed: []).count, 2,
                       "the re-armed id drew a second row")
        let content = try XCTUnwrap(after.content(of: run), "the re-armed run left the tree")
        XCTAssertEqual(content.startedCount, started + 1,
                       "the run reports \(content.startedCount) start(s) where it has run \(started + 1) time(s)")
        XCTAssertTrue(content.elapsedOrigin == origin, "the re-armed run's elapsed origin moved")
    }

    // MARK: - Parking (G1, child spec D13)

    /// A run that is not running with a child that is draws **Parked**, not **Completed**.
    ///
    /// Driven on the recording rather than on a hand-made node: the replay leaves both runs settled,
    /// and re-arming the *child* is what puts the branch back into the state §8.8 is about — a node
    /// that looks finished while work continues under it.
    func testParkingRendersAsParked() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2")
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let settled6 = await rig.settleOnBarrier()
        XCTAssertTrue(settled6, "the replay never reached the model")
        let settled7 = await rig.settleOnRuns(2)
        XCTAssertTrue(settled7, "the replay armed a tree with 2 runs in it")

        let settled = rig.read()
        let root = try XCTUnwrap(settled.roots.first, "the tree offered no root")
        let child = try XCTUnwrap(settled.children(of: root).first, "the root has no child")
        XCTAssertNotEqual(settled.content(of: root)?.status, .running,
                          "the replay left the root running, so re-arming its child proves nothing")
        XCTAssertEqual(AgentNodeRow.statusLabel(try XCTUnwrap(settled.content(of: root))), "Completed",
                       "the settled root does not draw as completed, so the change below is not the parked one")

        let toolUse = try XCTUnwrap(settled.content(of: child)?.toolUseID, "the nested run names no spawning block")
        await rig.push(try AgentGateRig.taskStartedFrame(taskID: child, toolUseID: toolUse))
        try await rig.pushBarrier("toolu_invented_gate_park")
        let settled8 = await rig.settle(on: "toolu_invented_gate_park")
        XCTAssertTrue(settled8,
                      "the injected start never reached the model")

        let parked = rig.read()
        let content = try XCTUnwrap(parked.content(of: root), "the root left the tree")
        XCTAssertTrue(content.isParked, "a settled run with a running child does not read as parked")
        XCTAssertEqual(AgentNodeRow.statusLabel(content), "Parked",
                       "the parked run draws \(AgentNodeRow.statusLabel(content)) rather than Parked")
        XCTAssertNotEqual(AgentNodeRow.statusLabel(content), "Completed",
                          "a branch with work still under it is drawn as finished")
    }

    // MARK: - The two empty states (G1, child spec D10)

    /// A channel whose tree is empty and a channel that has no tree at all draw two different
    /// sentences.
    ///
    /// The first arm is a real channel: `background-shell`'s task frames are a background shell —
    /// a registry row and **not** an agent run — so the fold arms a tree with nothing in it.
    ///
    /// The second arm is asserted over the value the read is defined on, and **not** over an opened
    /// channel, because on this baseline no opened channel produces it. `StreamIngestion.open`
    /// builds the wire fold unconditionally — a file-only channel is handed an already-finished
    /// event stream rather than none — so `agents` is a non-nil empty tree for every archived and
    /// every foreign channel. That contradicts `StreamIngestion.swift:155`'s own comment ("nil for
    /// good on a file-only channel") and the child spec's grounding, and it means an archived
    /// channel is told *No agent runs in this channel* today, which is exactly the misinformation
    /// D10 exists to prevent. Reported to the architect rather than papered over: the read keeps
    /// the honest three-state shape, and the state becomes reachable the moment the producer does.
    func testTheTwoEmptyStatesAreDistinct() async throws {
        let wired = try await AgentGateRig(fixture: "background-shell")
        defer { Task { await wired.finish() } }
        _ = try await wired.replay()
        let settled = await wired.settleOnBarrier()
        XCTAssertTrue(settled, "the replay never reached the model")
        XCTAssertNotNil(wired.model.timeline.agents,
                        "the replayed channel carries no tree at all, so this is not the no-runs arm")
        XCTAssertTrue(wired.read().state == .noRuns,
                      "a wire channel whose task frames are not agent runs did not read as having no runs")

        let noWire = AgentRunRead(timeline: ChannelTimeline())
        XCTAssertTrue(noWire.state == .noWire, "a timeline with no tree did not read as having no wire")

        XCTAssertNotEqual(AgentTreeEmptyState.noRuns, AgentTreeEmptyState.noWire,
                          "the two empty states are one sentence, so a user told the first when the "
                          + "second is true has been misinformed")
        XCTAssertEqual(ViewTree.values(of: String.self, in: AgentTreeView(model: wired.pane()).body)
                            .filter { $0 == AgentTreeEmptyState.noRuns }.count, 1,
                       "the no-runs channel does not draw its own sentence")
        let paneWithNoWire = AgentsModel(channel: wired.key, timelines: { _ in nil }, store: AgentSelectionStore())
        XCTAssertEqual(ViewTree.values(of: String.self, in: AgentTreeView(model: paneWithNoWire).body)
                            .filter { $0 == AgentTreeEmptyState.noWire }.count, 1,
                       "the no-wire state does not draw its own sentence")
    }

    // MARK: - The tick (child spec D7)

    /// A tick moves no row identity, and the span it moves is drawn **inside** one leaf view.
    ///
    /// The second clause is the discriminating one. Row identity alone cannot fail: the outline does
    /// not read the clock, so two evaluations are identical whatever the label says. What a wrong
    /// implementation would show is the span computed by the row — one timer invalidating the whole
    /// outline every second, on a surface whose sibling column is the S7 budget's tenant — and that
    /// is what the search of the row's own body catches.
    func testATickMovesNoRowIdentity() async throws {
        let rig = try await AgentGateRig(fixture: "nested-depth-2")
        defer { Task { await rig.finish() } }
        _ = try await rig.replay()
        let settledBarrier = await rig.settleOnBarrier()
        XCTAssertTrue(settledBarrier, "the replay never reached the model")
        let armed = await rig.settleOnRuns(2)
        XCTAssertTrue(armed, "the replay armed a tree with 2 runs in it")

        let read = rig.read()
        let before = AgentTreeView.visibleRows(read: read, collapsed: []).map { AgentTreeView.identity(of: $0.id) }
        let after = AgentTreeView.visibleRows(read: rig.read(), collapsed: []).map { AgentTreeView.identity(of: $0.id) }
        XCTAssertEqual(before.count, 2, "the outline pinned \(before.count) row identity(s) for 2 runs")
        XCTAssertTrue(before == after, "a re-derivation moved a row identity")

        // A tick has something to change.
        let content = try XCTUnwrap(read.roots.first.flatMap { read.content(of: $0) }, "the tree offered no root")
        let first = ElapsedTicker.label(origin: content.elapsedOrigin, now: content.elapsedOrigin)
        let later = ElapsedTicker.label(origin: content.elapsedOrigin,
                                        now: content.elapsedOrigin.addingTimeInterval(90))
        XCTAssertNotEqual(first, later, "a 90-second tick does not move the label, so this proves nothing")

        // And the tick is *scheduled*, not merely formattable: a running run's ticker holds one
        // periodic schedule and that schedule delivers a second apart. Without this clause a ticker
        // that drew the span once and never again passes everything else here, because a label
        // computed twice by a test says nothing about whether anything ever recomputes it.
        let running = ViewTree.values(of: PeriodicTimelineSchedule.self,
                                      in: ElapsedTicker(origin: content.elapsedOrigin, endedAt: nil).body)
        XCTAssertEqual(running.count, 1,
                       "a running run's ticker holds \(running.count) periodic schedule(s), not 1")
        let entries = Array(try XCTUnwrap(running.first, "the ticker holds no schedule")
            .entries(from: content.elapsedOrigin, mode: .normal).prefix(3))
        XCTAssertEqual(entries.count, 3, "the schedule offered \(entries.count) entry(s) of the 3 asked for")
        let span = (entries.last?.timeIntervalSince(content.elapsedOrigin)).map { Int($0.rounded()) } ?? -1
        XCTAssertTrue(span > 0 && span <= 3,
                      "the ticker's third scheduled tick is \(span) second(s) after the run began")
        // A finished run has a fixed span and is drawn with no schedule at all.
        let finished = ViewTree.values(of: PeriodicTimelineSchedule.self,
                                       in: ElapsedTicker(origin: content.elapsedOrigin,
                                                         endedAt: content.elapsedOrigin.addingTimeInterval(5)).body)
        XCTAssertEqual(finished.count, 0,
                       "a finished run's ticker still holds \(finished.count) periodic schedule(s)")

        // And the change is one leaf's, not the row's: the row hosts exactly one ticker and draws no
        // span of its own.
        let row = AgentNodeRow(content: content, isSelected: false, disclosure: .expanded,
                               toggle: {}, select: {}).body
        XCTAssertEqual(ViewTree.values(of: ElapsedTicker.self, in: row).count, 1,
                       "the row hosts \(ViewTree.values(of: ElapsedTicker.self, in: row).count) elapsed ticker(s), not 1")
        XCTAssertEqual(ViewTree.values(of: String.self, in: row).filter { $0 == first || $0 == later }.count, 0,
                       "the row computed an elapsed span of its own, so a tick invalidates the outline")
    }

    /// A tick delivered to a **mounted** ticker redraws the leaf and moves nothing on the tree.
    ///
    /// The clause above reads the schedule off the view value; this one lets a real second pass over
    /// a drawn tree in a window and asks what changed. The frame the panel draws moves — the span is
    /// a second longer — while the outline's rows and the read behind them are the values they were.
    /// That is D7's whole claim: the clock reaches one label, and the tree is invalidated only by the
    /// tree moving.
    ///
    /// The run's origin is the wall clock rather than the invented epoch, because a run that started
    /// years ago draws a span that moves once a minute and this test waits one second.
    func testAMountedTickRedrawsTheLeafAndNotTheTree() throws {
        let started = Date()
        let timeline = ChannelTimeline(agents: InventedAgents.treeOfRoots(1, at: started))
        let pane = AgentsModel(channel: PanelFixtures.key(11), timelines: { _ in timeline },
                               store: AgentSelectionStore())
        let read = pane.read
        let before = AgentTreeView.visibleRows(read: read, collapsed: []).map { AgentTreeView.identity(of: $0.id) }
        XCTAssertEqual(before.count, 1, "the outline pinned \(before.count) row identity(s) for 1 run")

        let hosting = NSHostingView(rootView: AgentTreeView(model: pane))
        let moved: Bool = FrameTimeHarness.hosted(hosting, size: NSSize(width: 420, height: 240)) { window in
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            let first = Self.drawnFrame(of: hosting)
            // A whole second of the main run loop, so the schedule the mounted ticker armed fires.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            hosting.layoutSubtreeIfNeeded()
            let second = Self.drawnFrame(of: hosting)
            return first != nil && second != nil && first != second
        }

        XCTAssertTrue(ElapsedTicker.label(origin: started, now: started)
                        != ElapsedTicker.label(origin: started, now: Date()),
                      "less than a whole second passed while the tree was mounted, so nothing was due")
        XCTAssertTrue(moved, "the mounted tree drew the same frame across a whole second, so no tick reached it")

        let after = AgentTreeView.visibleRows(read: pane.read, collapsed: []).map { AgentTreeView.identity(of: $0.id) }
        XCTAssertTrue(before == after, "the tick moved a row identity")
        XCTAssertTrue(pane.read == read, "the tree itself moved across the tick, so nothing above is about the clock")
    }

    /// What the hosted view is drawing, as bytes. Compared, never printed, and never written (X9).
    @MainActor
    private static func drawnFrame(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.tiffRepresentation
    }

    // MARK: - §11

    /// **A task id is drawable and never printable.** No code under `App/Agents/` writes one to a
    /// log, a diagnostic or a trap message.
    ///
    /// A trace assertion, and stated as one: the property is an *absence*, so no mutation of the
    /// shipped code makes it fail by running. What is asserted is the surface a violation would have
    /// to use — this leaf reaches no logging facility at all, and its only trap messages are fixed
    /// sentences with nothing interpolated into them.
    func testATaskIdIsNeverPrinted() throws {
        let directory = FixtureRunner.repositoryRoot.appending(path: "App").appending(path: "Agents")
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(sources.count, 0, "the directory holds no Swift source, so this proves nothing")

        var logging = 0
        var interpolatedTraps = 0
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for facility in ["print(", "NSLog(", "os_log(", "Logger("] where text.contains(facility) {
                logging += 1
            }
            for trap in ["assertionFailure(", "preconditionFailure(", "fatalError("] {
                var searched = text[...]
                while let start = searched.range(of: trap) {
                    let message = searched[start.upperBound...].prefix(while: { $0 != "\n" })
                    if message.contains("\\(") { interpolatedTraps += 1 }
                    searched = searched[start.upperBound...]
                }
            }
        }
        XCTAssertEqual(logging, 0, "\(sources.count) source(s) reach \(logging) logging facility(s)")
        XCTAssertEqual(interpolatedTraps, 0,
                       "\(interpolatedTraps) trap message(s) interpolate a value into a fixed sentence")
    }
}

// MARK: - The rig

/// One channel of the app over a committed recording, in the shape `TimelineFixtureGateTests`'
/// `GateRig` takes — that one is `private` to its file, so this is its shape and not a second route
/// to it.
///
/// It drives `ChannelTimelineModel`, not `StreamIngestion`: what this gate is about is what the
/// panel draws, and the panel reads the model's published timeline.
@MainActor
private struct AgentGateRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey
    let fixture: String

    var model: ChannelTimelineModel { registry.model(for: key) }

    /// The tool-use id the replay's barrier names. Invented, so the cluster it opens is one no
    /// recorded frame can open and its arrival means the replay before it was consumed.
    static let barrierLead = "toolu_invented_agent_barrier"

    static func rowKey(of lead: String) -> String { "cluster:\(lead)" }

    /// `owned: false` opens the channel from its transcript files alone and never opens an event
    /// stream — every archived and every foreign session.
    ///
    /// `sidecars: false` copies the recording's transcripts **without** their `.meta.json` files, so
    /// the channel opens on a session whose sidecars the engine has not flushed yet — §7.3's ordinary
    /// case, and G1's "before the `.meta.json` is written". Nothing else about the open changes: the
    /// same frames are replayed into the same fold, and the only source withheld is the file one.
    init(fixture: String, owned: Bool = true, sidecars: Bool = true) async throws {
        self.fixture = fixture
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        guard let main = try Self.mainTranscript(of: fixture) else {
            throw AgentGateBail("fixture carries no main transcript")
        }
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copied = projects.appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: main.slugDirectory, to: copied)
        if !sidecars { try Self.removeSidecars(under: copied) }
        key = ChannelKey(configHome: home.configHome.root, session: main.session)

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: home.configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs",
                                                                                              directoryHint: .isDirectory)),
                              rawCapture: nil)
        registry = ChannelTimelineRegistry()
        registry.attach(to: workspace, lifecycle: lifecycle)
        if owned { await lifecycle.openEvents(of: key) }
        await model.open(row())
    }

    func finish() async {
        await lifecycle.finishEvents(of: key)
        registry.release(key)
    }

    // MARK: - What the panel reads

    /// The read the panel derives, through the same expression the pane uses.
    func read() -> AgentRunRead { AgentRunRead(timeline: model.timeline) }

    /// The pane's session over this channel, reaching the one registry through a closure.
    func pane() -> AgentsModel {
        AgentsModel(channel: key, timelines: { [registry] key in registry.model(for: key).timeline },
                    store: AgentSelectionStore())
    }

    // MARK: - The replay

    @discardableResult
    func replay() async throws -> Int {
        let events = try FixtureRunner.events(fixture)
        for event in events { await push(event) }
        try await pushBarrier(Self.barrierLead)
        return events.count
    }

    func push(_ event: WireEvent) async { await lifecycle.push(event, to: key) }

    func pushBarrier(_ lead: String) async throws {
        await lifecycle.push(try Self.summaryFrame(lead: lead), to: key)
    }

    func settleOnBarrier() async -> Bool { await settle(on: Self.barrierLead) }

    /// Waits for the row a barrier's cluster makes. `ItemID.cluster(stream:leadToolUseID:)` prefixes
    /// the lead id, so a wait keyed on the bare id waits for a row the fold never makes.
    func settle(on lead: String) async -> Bool {
        await settle { model in model.rows.contains { $0.id.key == Self.rowKey(of: lead) } }
    }

    func settleOnRuns(_ count: Int) async -> Bool {
        await settle { $0.timeline.agents?.nodes.count == count }
    }

    /// A file-only channel pushes nothing, so its wait is on the open having produced items.
    func settleOnOpen() async -> Bool {
        await settle { $0.hasOpened && !$0.timeline.items.isEmpty }
    }

    /// Waits, bounded, for the model to satisfy `predicate`, and **answers whether it did**, so
    /// every caller asserts the outcome of its own wait.
    func settle(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<600 {
            if predicate(model) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(model)
    }

    // MARK: - Injected frames

    /// A `tool_use_summary`, built by hand because no committed fixture carries one. Every
    /// identifier in it is invented — a word and a repeated nibble (§11).
    static func summaryFrame(lead: String) throws -> WireEvent {
        try frame(["type": .string("tool_use_summary"),
                   "summary": .string("an invented replay barrier"),
                   "preceding_tool_use_ids": .array([.string(lead)]),
                   "uuid": .string("bbbbbbbb-3333-4333-8333-bbbbbbbbbbbb"),
                   "session_id": .string("cccccccc-4444-4444-8444-cccccccccccc")])
    }

    /// A second `task_started` for an id the tree already holds — the re-engagement
    /// `nested-depth-2`'s README says a host must expect. The task id and the tool-use id are the
    /// recording's own, read back out of the tree rather than written down here.
    static func taskStartedFrame(taskID: String, toolUseID: String) throws -> WireEvent {
        try frame(["type": .string("system"), "subtype": .string("task_started"),
                   "task_id": .string(taskID), "tool_use_id": .string(toolUseID),
                   "description": .string("an invented re-engagement"),
                   "task_type": .string("local_agent"),
                   "uuid": .string("bbbbbbbb-5555-4555-8555-bbbbbbbbbbbb"),
                   "session_id": .string("cccccccc-4444-4444-8444-cccccccccccc")])
    }

    /// Every `.meta.json` under a copied transcript tree, removed before the channel is opened.
    /// Counted and asserted: a copy that held none would make the withholding a no-op and the arm
    /// above would be measuring nothing.
    private static func removeSidecars(under directory: URL) throws {
        var removed = 0
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        for case let url as URL in files ?? .init() where url.lastPathComponent.hasSuffix(".meta.json") {
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        guard removed > 0 else { throw AgentGateBail("the copied transcripts carry no sidecar to withhold") }
    }

    /// An invented `agent-<taskId>.meta.json` naming an invented parent: a second source that
    /// **disagrees** with what the tree already holds. Every value in it is this test's own — the
    /// task id is the one the tree is keyed on and is written into the file name, never printed.
    func disagreeingSidecar(taskID: String) throws -> URL {
        try temp.file("sidecars/agent-\(taskID).meta.json",
                      #"{"agentType": "an-invented-type", "description": "an invented disagreement", "#
                      + #""toolUseId": "toolu_invented_conflict", "parentAgentId": "a0000000invented0", "#
                      + #""spawnDepth": 2}"#)
    }

    private static func frame(_ object: [String: JSONValue]) throws -> WireEvent {
        .frame(FrameDecoder.decode(line: try JSONValue.object(object).canonicalData()), .first)
    }

    // MARK: - Layout

    func row() -> ChannelRow {
        ChannelRow(key: key,
                   title: "a recorded channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: URL(fileURLWithPath: "/invented/project"),
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: SidebarFixtures.state(key, origin: .owned(.ready)))
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = FixtureRunner.repositoryRoot.appending(path: "Fixtures")
            .appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, slug)
            }
        }
        return nil
    }
}

/// A bail with a fixed sentence: it names no fixture, no path and no session (§11).
private struct AgentGateBail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
