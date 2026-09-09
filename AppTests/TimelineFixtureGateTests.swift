import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Gate **G2**: the four fixtures the child spec names, replayed through the app's own ingestion and
/// through the pipeline the channel column draws — `ChannelTimelineModel.rows`, filtered by
/// `TimelineListView.retained(_:by:)`, which is the expression the list evaluates and not a second
/// derivation written for a test.
///
/// **Both halves of the channel run here.** The transcript is copied into a scratch config home and
/// read by the ingestion exactly as an archived channel's is; the recording's frames are pushed
/// through the lifecycle double's fan-out, which is the same seam a live channel's tap arrives on.
/// The wire half is what carries the agent-run tree, the overlay's turn summaries and the injected
/// cluster label, and none of the three exists on a file-only channel.
///
/// **Every wait is fulfilled by the delivery it waits for.** Pushing an event into a fan-out is not
/// consuming it, and counting `Task.yield()`s after a push measures the scheduler rather than the
/// fold. So the replay ends with a **barrier frame** — an invented `tool_use_summary` naming an
/// invented tool-use id, which opens exactly one cluster nothing else can open — and every gate
/// below waits for the row that barrier makes. The stream preserves order, so the barrier's arrival
/// is the proof that every recorded frame before it was folded and published.
///
/// §11 throughout: no assertion prints a path, a session id, a slug or an engine byte. `ItemID`
/// carries the config home, so identity is compared as `.key` strings — never as an `ItemID`, and
/// never with `XCTAssertEqual` over a value read out of a fixture. What a failure states is counts.
///
/// X9: every tree here is a `TempTree`, which canonicalises its root and skips before creating
/// anything if it resolves inside a config home. Nothing in this file writes under one.
@MainActor
final class TimelineFixtureGateTests: XCTestCase {

    /// The four recordings G2 names.
    private static let corpus = ["compact-boundary", "nested-depth-2", "background-shell", "session-mirror-resume"]

    // MARK: - The differential clause

    /// For every fixture: the set of id keys the rows carry is the set the `ChannelTimeline` holds,
    /// in both directions, over a set asserted non-empty first — without the floor a failed
    /// ingestion compares two empty sets and passes — and the rows are in the timeline's order.
    ///
    /// The comparison is over `ItemID.key` strings and never over `ItemID`s: the id carries the
    /// config-home path, so an `XCTAssertEqual` over one prints it.
    func testEveryFixturesRowsCarryTheTimelinesIdsInTheTimelinesOrder() async throws {
        var totals: [(String, Int)] = []
        for fixture in Self.corpus {
            let rig = try await GateRig(fixture: fixture)
            let replayed = try await rig.replay()
            let settled = await rig.settleOnBarrier()
            XCTAssertTrue(settled,
                          "\(fixture): the barrier never reached the model after \(replayed) event(s), " +
                          "so nothing below measures a replay")

            let (rowKeys, itemKeys) = rig.keys()
            XCTAssertGreaterThan(itemKeys.count, 0,
                                 "\(fixture): the timeline holds no items at all, so the comparison below is vacuous")
            XCTAssertGreaterThan(rowKeys.count, 0,
                                 "\(fixture): the list drew no rows at all, so the comparison below is vacuous")

            let unrendered = Set(itemKeys).subtracting(rowKeys)
            let unheld = Set(rowKeys).subtracting(itemKeys)
            XCTAssertTrue(unrendered.isEmpty && unheld.isEmpty,
                          "\(fixture): \(unrendered.count) of \(itemKeys.count) item(s) drew no row and " +
                          "\(unheld.count) of \(rowKeys.count) row(s) name no item")

            let divergence = zip(rowKeys, itemKeys).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            XCTAssertNil(divergence,
                         "\(fixture): the rows leave the timeline's order at position " +
                         "\(divergence ?? -1) of \(itemKeys.count)")
            totals.append((fixture, itemKeys.count))
            await rig.finish()
        }
        // Counts only, and one line per fixture: the gate's own evidence (§11).
        print("G2 the differential clause\n" + totals.map { "  \($0.0) — \($0.1) item(s), one row each" }
            .joined(separator: "\n"))
    }

    // MARK: - Clusters, both arms

    /// **The corpus carries no `tool_use_summary` frame anywhere** — asserted here over the fixture's
    /// own recorded frames, not taken on trust — so the labelled arm injects one, naming two tool
    /// calls `nested-depth-2` really made, and the fallback arm is the same cluster with the label
    /// taken away.
    ///
    /// Both arms on one cluster is deliberate: the label is then the only difference between them,
    /// where two clusters built separately could differ in their member count or their span and pass
    /// for a reason the gate is not about.
    func testAClusterTakesAnInjectedLabelAndFallsBackToCountsAndElapsed() async throws {
        let fixture = "nested-depth-2"
        let rig = try await GateRig(fixture: fixture)
        XCTAssertEqual(try GateRig.recordedSummaryFrames(fixture), 0,
                       "\(fixture) now carries a tool_use_summary of its own: this gate must read it, not inject one")
        _ = try await rig.replay()
        let settled = await rig.settleOnBarrier()
        XCTAssertTrue(settled, "the replay never reached the model")

        // Two calls the recording really made. Their ids are values the injection carries; nothing
        // below prints them.
        let calls = rig.toolCalls()
        XCTAssertGreaterThanOrEqual(calls.count, 2,
                                    "\(fixture) holds \(calls.count) tool call(s); the cluster arm needs two")
        let members = Array(calls.prefix(2))
        let lead = "cluster:\(members[0].toolUseID)"
        try await rig.push(GateRig.summaryFrame(summary: GateRig.injectedLabel,
                                                leads: members.map(\.toolUseID),
                                                uuid: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"))
        let opened = await rig.settle { $0.rows.contains { $0.id.key == lead } }
        XCTAssertTrue(opened, "the injected summary opened no cluster row")

        let clustered = rig.clusters().first { $0.id.key == lead }
        let cluster = try XCTUnwrap(clustered, "the cluster the summary named is not an item of the timeline")
        let resolved = rig.neighbourhood().members(of: cluster)
        XCTAssertEqual(resolved.count, members.count,
                       "the cluster resolved \(resolved.count) of its \(cluster.toolUseIDs.count) member(s); " +
                       "a cluster keyed differently from the calls it names shows an empty body")

        // The labelled arm.
        let labelled = ClusterRowContent.content(for: cluster, members: resolved)
        XCTAssertTrue(labelled.isLabelled, "the cluster reports itself unlabelled after a summary named it")
        XCTAssertEqual(labelled.title, GateRig.injectedLabel, "the cluster's line is not the injected label")

        // The fallback arm: the same cluster, the same members, no label.
        var unlabelled = cluster
        unlabelled.label = nil
        let counted = ClusterRowContent.content(for: unlabelled, members: resolved)
        XCTAssertFalse(counted.isLabelled, "a cluster with no label reported itself labelled")
        XCTAssertNotEqual(counted.title, labelled.title, "both arms drew the same line, so the label decided nothing")
        XCTAssertTrue(counted.title.hasPrefix("\(resolved.count) tool call"),
                      "the unlabelled cluster's line does not open with its \(resolved.count) call(s)")
        XCTAssertEqual(counted.count, resolved.count,
                       "the unlabelled cluster counted \(counted.count) call(s), not \(resolved.count)")
        await rig.finish()
    }

    // MARK: - Thinking

    /// Thinking is collapsed with **its duration**, on `nested-depth-2`, which is the corpus's
    /// richest recording of thinking blocks.
    ///
    /// **And not its live token estimate.** The recording carries nine `system/thinking_tokens`
    /// frames — counted here off its own bytes — and every one of them reaches the `default:` arm of
    /// C3's `WireReducer.route(_ system:)`: neither `Overlay` nor `StreamingPreview` carries a field
    /// for `estimated_tokens`, so after the architect's ruling removed this leaf's own event
    /// subscription there is no route by which that number could reach the app. The break cannot be
    /// executed, so the substitute is a trace assertion that the dangerous path was never entered:
    /// the summary the disclosure renders from carries three members and none of them is a token
    /// count, so nothing here can be showing an invented one. Tracker 127.
    func testThinkingIsCollapsedWithItsDurationAndNoInventedTokenEstimate() async throws {
        let fixture = "nested-depth-2"
        let rig = try await GateRig(fixture: fixture)
        _ = try await rig.replay()
        let settled = await rig.settleOnBarrier()
        XCTAssertTrue(settled, "the replay never reached the model")

        let estimates = try GateRig.recordedThinkingTokenFrames(fixture)
        XCTAssertEqual(estimates, 9, "\(fixture) carries \(estimates) thinking_tokens frame(s), not the nine measured")

        let neighbourhood = rig.neighbourhood()
        var summaries: [ThinkingSummary] = []
        for case .assistantMessage(let message) in rig.model.timeline.items {
            guard let summary = ThinkingDisclosure.summary(of: message,
                                                           since: neighbourhood.precedingTimestamps[message.id.key])
            else { continue }
            summaries.append(summary)
        }
        XCTAssertGreaterThan(summaries.count, 0,
                             "\(fixture) produced \(summaries.count) message(s) with thinking, so this gate is vacuous")
        XCTAssertTrue(summaries.allSatisfy { $0.blocks > 0 }, "a thinking summary was built from no blocks")

        let timed = summaries.filter { $0.duration != nil }
        XCTAssertGreaterThan(timed.count, 0,
                             "none of the \(summaries.count) thinking summary(s) is bounded by an earlier instant, " +
                             "so no duration is rendered anywhere")
        XCTAssertTrue(timed.allSatisfy { $0.title.hasPrefix("Thought") },
                      "a bounded thinking disclosure does not read as a duration")

        // The trace assertion: what the disclosure can render is the summary's own members, and a
        // token estimate is not one of them.
        let members = Set(Mirror(reflecting: summaries[0]).children.compactMap(\.label))
        XCTAssertEqual(members, ["text", "duration", "blocks"],
                       "the thinking summary carries \(members.count) member(s); a fourth is a number this leaf " +
                       "has no route to and must not invent")
        await rig.finish()
    }

    // MARK: - Hidden records

    /// **Hidden meta is not a row and never was.** The obligation is that `hidden` never becomes one,
    /// and which fixture witnesses it matters: the two halves are pinned separately because neither
    /// half produces the other's records.
    ///
    /// - the **file** half, from the transcript the ingestion reads: `compact-boundary` and
    ///   `session-mirror-resume` each hide at least one `isMeta` record, and the corpus-wide total is
    ///   pinned so a record that stopped being hidden is a failure and not a smaller number nobody
    ///   reads.
    /// - the **wire** half: `isSynthetic` appears on the wire in `compact-boundary` alone across the
    ///   whole corpus — the engine's echoed compaction summary — and the ingestion discards the wire
    ///   fold's own durable half by contract (§7.3 makes the record reducer primary), so that half is
    ///   folded here through C3's reducer to be looked at at all.
    func testHiddenRecordsAreNeverRows() async throws {
        var fileSide = 0
        for fixture in ["compact-boundary", "session-mirror-resume"] {
            let rig = try await GateRig(fixture: fixture)
            _ = try await rig.replay()
            let settled = await rig.settleOnBarrier()
            XCTAssertTrue(settled, "\(fixture): the replay never reached the model")

            let hidden = rig.model.timeline.durable.hidden
            let meta = hidden.filter { $0.reason == .isMeta }
            XCTAssertGreaterThan(meta.count, 0,
                                 "\(fixture): the fold hid \(hidden.count) record(s) and \(meta.count) of them for " +
                                 "isMeta, so the assertion below has nothing to exclude")
            let keys = Set(rig.model.rows.map(\.id.key))
            let drawn = hidden.filter { keys.contains(TimelineCorpus.key(of: $0)) }
            XCTAssertEqual(drawn.count, 0,
                           "\(fixture): \(drawn.count) of \(hidden.count) hidden record(s) reached the list as rows")
            fileSide += meta.count
            await rig.finish()
        }

        // The corpus-wide pin for the file half.
        var corpusMeta = 0
        for name in try TimelineCorpus.names() {
            corpusMeta += try TimelineCorpus.durable(name).hidden.filter { $0.reason == .isMeta }.count
        }
        XCTAssertEqual(corpusMeta, GateRig.corpusIsMetaRecords,
                       "the corpus folds \(corpusMeta) isMeta record(s) on the file side, not " +
                       "\(GateRig.corpusIsMetaRecords); a record that stopped being hidden is a row that appeared")
        XCTAssertGreaterThan(fileSide, 0, "the two fixtures this gate names hid nothing between them")

        // The wire half, corpus-wide: one `isSynthetic`, in `compact-boundary` alone.
        var synthetic: [String: Int] = [:]
        for name in try TimelineCorpus.names() {
            let count = try TimelineCorpus.wire(name).durable.hidden.filter { $0.reason == .isSynthetic }.count
            if count > 0 { synthetic[name] = count }
        }
        XCTAssertEqual(synthetic["compact-boundary"], 1,
                       "compact-boundary's wire fold hides \(synthetic["compact-boundary"] ?? 0) synthetic record(s), " +
                       "not the one measured")
        XCTAssertEqual(synthetic.count, 1,
                       "\(synthetic.count) fixture(s) carry isSynthetic on the wire, not the one this gate expects")
    }

    // MARK: - The compaction divider

    /// The divider is drawn, on `compact-boundary` — the one recording in the corpus that carries a
    /// compaction boundary at all.
    func testTheCompactionDividerIsDrawn() async throws {
        let rig = try await GateRig(fixture: "compact-boundary")
        _ = try await rig.replay()
        let settled = await rig.settleOnBarrier()
        XCTAssertTrue(settled, "the replay never reached the model")

        let boundaries = rig.model.rows.filter { $0.category == .compactBoundary }
        XCTAssertEqual(boundaries.count, 1,
                       "the list drew \(boundaries.count) compaction row(s) out of \(rig.model.rows.count) row(s)")
        guard case .compactBoundary(let item) = boundaries[0].item else {
            return XCTFail("the compaction row does not carry a compaction item")
        }

        // The row itself, evaluated, and the line it draws. The label is a value the fixture
        // supplied; it is compared, never printed (§11).
        let body = CompactBoundaryRow(item: item).body
        let label = CompactBoundaryRow.label(of: item)
        XCTAssertFalse(label.isEmpty, "the divider's label is empty, so drawing it witnesses nothing")
        XCTAssertTrue(ViewTree.values(of: String.self, in: body).contains(label),
                      "the compaction row drew \(ViewTree.values(of: String.self, in: body).count) string(s) and " +
                      "none of them is its own label")
        XCTAssertEqual(ViewTree.values(of: Rectangle.self, in: body).count, 2,
                       "the divider drew \(ViewTree.values(of: Rectangle.self, in: body).count) rule(s), not the two " +
                       "that make it a divider")
        await rig.finish()
    }

    // MARK: - The agent chip

    /// An `Agent` chip's click calls `AgentNavigation.show(run:in:)` with **the run's own task id**,
    /// asserted on a counting double, on `nested-depth-2` — the recording that carries both the
    /// `Agent` calls, in its transcript, and the `system/task_started` frames that arm the run tree,
    /// on its wire.
    ///
    /// **This is the arm where the tree exists.** It exists only because the recording's frames are
    /// pushed through the tap: `StreamIngestion.agents` is wire-fed, so a channel opened from its
    /// files alone has none (tracker 187 on `main`). G5 is the opposite arm — a foreign session,
    /// where the tree is nil and the chip renders without navigating — and the two are asserted
    /// separately rather than one standing in for the other.
    ///
    /// **The tool is named `Agent`, not `Task`.** A chip keyed on the wrong string renders nothing.
    ///
    /// What the press performs is asserted through the content the button's action reads and the
    /// capability it calls, rather than by synthesising a press: the chip's button is built inside
    /// `RowFrame`'s stored `@ViewBuilder` closure, which reflection cannot enter, and the row reads
    /// its context from the SwiftUI environment, which a body evaluated outside a render pass does
    /// not carry. Stated here rather than left to be inferred.
    func testAnAgentChipNavigatesWithTheRunsOwnTaskID() async throws {
        let fixture = "nested-depth-2"
        let rig = try await GateRig(fixture: fixture)
        _ = try await rig.replay()
        let settled = await rig.settleOnBarrier()
        XCTAssertTrue(settled, "the replay never reached the model")
        let armed = await rig.settle { $0.timeline.agents?.nodes.isEmpty == false }
        XCTAssertTrue(armed, "the replayed task_started frames armed no run tree, so this arm has no tree to resolve")

        let tree = try XCTUnwrap(rig.model.timeline.agents, "the channel carries no run tree after the wire replay")
        let agentCalls = rig.toolCalls().filter { $0.name == "Agent" }
        XCTAssertGreaterThan(agentCalls.count, 0, "\(fixture) holds no call named Agent, so the chip has no subject")
        XCTAssertEqual(rig.toolCalls().filter { $0.name == "Task" }.count, 0,
                       "the recording names the spawning tool Task, which is the wrong string")

        let resolvable = agentCalls.filter { tree.node(withToolUse: $0.toolUseID) != nil }
        XCTAssertGreaterThan(resolvable.count, 0,
                             "none of the \(agentCalls.count) Agent call(s) resolves to a run in the tree, so the " +
                             "chip could only navigate to a fabricated id")

        let call = resolvable[0]
        let navigation = CountingAgentNavigation()
        let context = InventedItems.context(agents: navigation,
                                            neighbourhood: rig.neighbourhood(),
                                            key: rig.key)
        let content = AgentChip.content(for: call, in: context)
        XCTAssertTrue(content.canNavigate, "a chip with a tree behind it reported itself unable to navigate")
        let run = try XCTUnwrap(content.runID, "the chip resolved no run id for a call the tree knows")
        XCTAssertTrue(run == tree.node(withToolUse: call.toolUseID)?.id,
                      "the chip's run id is not the one the tree resolves for this call")
        XCTAssertTrue(run != call.toolUseID, "the chip passed the tool_use_id as the run id")

        // The action the chip's button performs, on the counting double the context carries.
        context.agents.show(run: run, in: context.key)
        XCTAssertEqual(navigation.calls, 1, "the seam recorded \(navigation.calls) navigation(s), not 1")
        XCTAssertEqual(navigation.runs.count, 1, "the seam was given \(navigation.runs.count) run id(s), not 1")
        XCTAssertTrue(navigation.runs.first == run, "the seam was given a run id the chip did not resolve")

        // And it renders: the chip is what a call named Agent draws.
        let drawn = ToolCallRow(item: call).body
        XCTAssertEqual(ViewTree.values(of: AgentChipRow.self, in: drawn).count, 1,
                       "a call named Agent drew \(ViewTree.values(of: AgentChipRow.self, in: drawn).count) chip(s)")
        await rig.finish()
    }
}

// MARK: - The rig

/// One channel of the app, over a committed recording: the transcript in a scratch config home, the
/// ingestion the channel model drives over it, and the recording's frames pushed through the
/// lifecycle double's fan-out — the same seam a live channel's tap arrives on.
///
/// It drives `ChannelTimelineModel`, not `StreamIngestion` directly, because what G2 is about is the
/// list the app draws: `model.rows` through `TimelineListView.retained(_:by:)` is the expression the
/// column evaluates.
@MainActor
private struct GateRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey
    let fixture: String

    var model: ChannelTimelineModel { registry.model(for: key) }

    /// The label the cluster arm injects. Invented, and visibly nobody's.
    static let injectedLabel = "an invented cluster label"

    /// The tool-use id the barrier frame names. Invented, so the cluster it opens is one no recorded
    /// frame can open and its arrival means the replay before it was consumed.
    static let barrierLead = "toolu_invented_gate_barrier"

    /// The row key that barrier's cluster carries. `ItemID.cluster(stream:leadToolUseID:)` prefixes
    /// the lead id, so a wait keyed on the bare id waits for a row the fold never makes.
    static var barrierKey: String { "cluster:\(barrierLead)" }

    /// The file half's hidden `isMeta` records across the whole corpus, as the folds produce them —
    /// not as a grep over the fixture tree counts them, which counts occurrences in `frames.ndjson`,
    /// `fixture.json` and a README alike and is a floor a comment could satisfy.
    /// **Corrected 2026-09-09 from this gate's own run.** The child spec's §8 says four, counted
    /// before the folds were run; the folds produce three — `compact-boundary` one,
    /// `session-mirror-relocation` one, `session-mirror-resume` one. Tracker 324.
    static let corpusIsMetaRecords = 3

    init(fixture: String) async throws {
        self.fixture = fixture
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        guard let main = try Self.mainTranscript(of: fixture) else {
            throw GateBail("fixture \(fixture) carries no main transcript")
        }
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: main.slugDirectory,
                                         to: projects.appending(path: "\(fixture)-\(main.slug)",
                                                                directoryHint: .isDirectory))
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
        // An owned channel, so `events(of:)` really answers and the pushed frames have somewhere to
        // arrive.
        await lifecycle.openEvents(of: key)
        await model.open(row())
    }

    func finish() async {
        await lifecycle.finishEvents(of: key)
        registry.release(key)
    }

    // MARK: - The replay

    /// Pushes every recorded event of the fixture, then the barrier. Answers how many were pushed.
    @discardableResult
    func replay() async throws -> Int {
        let events = try FixtureRunner.events(fixture)
        for event in events { await lifecycle.push(event, to: key) }
        try await push(Self.summaryFrame(summary: "an invented replay barrier",
                                         leads: [Self.barrierLead],
                                         uuid: "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"))
        return events.count
    }

    func push(_ event: WireEvent) async { await lifecycle.push(event, to: key) }

    /// Waits for the barrier's own cluster row, which only the last pushed frame can make.
    func settleOnBarrier() async -> Bool {
        await settle { $0.rows.contains { $0.id.key == Self.barrierKey } }
    }

    /// Waits, bounded, for the model to satisfy `predicate`, and **answers whether it did**, so
    /// every caller asserts the outcome of its wait.
    func settle(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<600 {
            if predicate(model) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(model)
    }

    // MARK: - What the list shows

    /// The rows the column draws and the items the timeline holds, read in one main-actor step so
    /// the two cannot straddle a publish, as `.key` strings (§11).
    func keys() -> (rows: [String], items: [String]) {
        let rows = TimelineListView.retained(model.rows, by: RetractionRegistry())
        return (rows.map(\.id.key), model.timeline.items.map(\.id.key))
    }

    func toolCalls() -> [ToolCallItem] {
        model.timeline.items.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    func clusters() -> [ToolClusterItem] {
        model.timeline.items.compactMap { if case .cluster(let cluster) = $0 { cluster } else { nil } }
    }

    /// The reads a row makes of the items around it, built the way the list builds them.
    func neighbourhood() -> TimelineNeighbourhood {
        TimelineNeighbourhood(items: model.timeline.items, agents: model.timeline.agents)
    }

    // MARK: - Injected frames

    /// A `tool_use_summary`, built by hand because **no committed fixture carries one**. Every
    /// identifier in it is invented — a repeated nibble — so nothing here can be mistaken for an
    /// engine byte or anybody's own session (§11).
    static func summaryFrame(summary: String, leads: [String], uuid: String) throws -> WireEvent {
        let line = JSONValue.object([
            "type": .string("tool_use_summary"),
            "summary": .string(summary),
            "preceding_tool_use_ids": .array(leads.map(JSONValue.string)),
            "uuid": .string(uuid),
            "session_id": .string("cccccccc-3333-4333-8333-cccccccccccc"),
        ])
        return .frame(FrameDecoder.decode(line: try line.canonicalData()), .first)
    }

    /// How many `tool_use_summary` frames the recording itself carries — the claim the labelled arm
    /// rests on, read rather than trusted.
    static func recordedSummaryFrames(_ fixture: String) throws -> Int {
        try FixtureRunner.frames(fixture).filter { if case .toolUseSummary = $0 { true } else { false } }.count
    }

    /// How many `system/thinking_tokens` frames the recording carries.
    static func recordedThinkingTokenFrames(_ fixture: String) throws -> Int {
        try FixtureRunner.outboundLines(fixture).filter { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
            return object["type"] as? String == "system" && object["subtype"] as? String == "thinking_tokens"
        }.count
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

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = fixtures.appending(path: name).appending(path: "transcript")
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

private struct GateBail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
