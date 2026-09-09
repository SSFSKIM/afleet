import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The agent-run tree as the **ingestion** builds it, for both kinds of channel (parent §8.8, X4).
///
/// `AgentRunTreeTests` drives the tree's three parent sources by hand; this suite asserts that
/// production reaches them — that a live channel's `agent_metadata` mirror entries and a file-only
/// channel's `.meta.json` sidecars both arrive at the tree the app reads, and that the fold's
/// registry mirror is on the value the app reads it from.
///
/// Nothing here asserts a fixture byte, and every invented identifier is invented (§11).
final class AgentTreeSourcesTests: XCTestCase {

    // MARK: - Doubles

    /// The channel's tap as this suite drives it.
    private final class Tap: @unchecked Sendable {
        let events: AsyncStream<WireEvent>
        private let continuation: AsyncStream<WireEvent>.Continuation
        init() { (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded) }
        func send(_ event: WireEvent) { continuation.yield(event) }
        func finish() { continuation.finish() }
    }

    /// Every change the ingestion published, flattened. Consumed by one task, as the stream requires.
    private final class ChangeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TimelineChange] = []
        private var task: Task<Void, Never>?
        init(_ ingestion: StreamIngestion) {
            let effects = ingestion.effects
            task = Task { [self] in
                for await effect in effects { lock.withLock { items += effect.changes } }
            }
        }
        deinit { task?.cancel() }
        var all: [TimelineChange] { lock.withLock { items } }
        var agentsChanged: Int { all.filter { if case .agentsChanged = $0 { true } else { false } }.count }
    }

    // MARK: - Corpus helpers

    private static let fixtureName = "nested-depth-2"

    /// The fixture's agent task ids, read from its sidecar file names — the corpus pin, derived from the
    /// fixture tree and never from the fold under test.
    private func sidecarTaskIDs(_ fx: FixtureCorpus.Fixture) throws -> [String] {
        try fx.metaFiles().compactMap { stream, _ in
            guard case .agent(let id) = stream.name else { return nil }
            return id
        }.sorted()
    }

    /// A recording's `transcript_mirror` frame with its `filePath` moved onto a temp tree's root.
    private func rehome(_ frame: TranscriptMirrorFrame, to root: URL) -> Frame {
        var rewritten = frame
        rewritten.filePath = frame.filePath.replacingOccurrences(
            of: FixtureCorpus.recordedConfigHome.standardizedFileURL.path,
            with: root.standardizedFileURL.path)
        return .transcriptMirror(rewritten)
    }

    /// The recording's main transcript path under a temp tree, taken from the mirror's own `filePath`.
    private func mirroredMainPath(_ fx: FixtureCorpus.Fixture, in tree: TempTree) throws -> URL {
        for recorded in try fx.frames() {
            guard case .transcriptMirror(let m) = recorded.frame,
                  let (stream, kind) = TranscriptPath.resolve(URL(fileURLWithPath: m.filePath),
                                                              under: FixtureCorpus.recordedConfigHome),
                  stream.sessionID == fx.sessionID, case .mainTranscript = kind else { continue }
            return URL(fileURLWithPath: m.filePath.replacingOccurrences(
                of: FixtureCorpus.recordedConfigHome.standardizedFileURL.path,
                with: tree.root.standardizedFileURL.path))
        }
        throw FixtureCorpus.Failure("fixture \(fx.name): no mirror frame names a main transcript")
    }

    /// The recording through one tap, in `t` order, mirror frames rehomed onto the tree. `where` selects which
    /// events are sent, so a test can withhold an arm and put the sources in an order the recording did not
    /// happen to produce.
    private func replayWire(_ fx: FixtureCorpus.Fixture, to tap: Tap, under root: URL,
                            where include: (WireEvent) -> Bool = { _ in true }) throws {
        for step in try FixtureWireReplay.steps(for: fx) {
            for event in step.events where include(event) {
                if case .frame(.transcriptMirror(let mirror), let epoch) = event {
                    tap.send(.frame(rehome(mirror, to: root), epoch))
                } else {
                    tap.send(event)
                }
            }
        }
    }

    /// The two arms the parent sources ride on. A `transcript_mirror` frame carries the `agent_metadata` entry;
    /// an `assistant` or `user` frame is the two-step join's only input. Everything else moves neither.
    private static func isMirror(_ event: WireEvent) -> Bool {
        if case .frame(.transcriptMirror, _) = event { return true }
        return false
    }
    private static func isJoinInput(_ event: WireEvent) -> Bool {
        switch event {
        case .frame(.assistant, _), .frame(.user, _): return true
        default: return false
        }
    }

    /// The tree's shape, as the two channel kinds can be compared on it: the parent link, the depth, the
    /// agent type and the spawning tool-use id of every node. Deliberately **not** status, model, activity
    /// line or elapsed origin — those are the live half's own readings and a channel with no wire has none.
    private struct Shape: Equatable, CustomStringConvertible {
        var parents: [String: String?]
        var depths: [String: Int]
        var agentTypes: [String: String?]
        var toolUses: [String: String?]
        var roots: [String]
        init(_ tree: AgentRunTree) {
            parents = tree.nodes.mapValues(\.parent)
            depths = tree.nodes.mapValues(\.depth)
            agentTypes = tree.nodes.mapValues(\.agentType)
            toolUses = tree.nodes.mapValues(\.toolUseID)
            roots = tree.roots
        }
        var description: String { "parents \(parents), depths \(depths), roots \(roots)" }
    }

    /// The depth-1 and depth-2 nodes of `nested-depth-2`, checked to be exactly the sidecar ids.
    private func depths(_ tree: AgentRunTree, _ fx: FixtureCorpus.Fixture) throws -> (one: AgentRunNode, two: AgentRunNode) {
        let ids = try sidecarTaskIDs(fx)
        XCTAssertEqual(ids.count, 2, "nested-depth-2 carries two agent sidecars")
        XCTAssertEqual(Set(tree.nodes.keys), Set(ids), "the ingestion's node ids are not the fixture's agent stream ids")
        let byDepth = Dictionary(grouping: tree.nodes.values, by: \.depth)
        let one = try XCTUnwrap(byDepth[1]?.first, "no depth-1 node")
        let two = try XCTUnwrap(byDepth[2]?.first, "no depth-2 node")
        return (one, two)
    }

    // MARK: - A live channel: the mirror entry reaches the tree

    /// **The `agent_metadata` mirror entry answers when it is the first source to speak** — through the
    /// ingestion, which is where the entry actually arrives.
    ///
    /// The recording's own order does not produce this: the assistant frame carrying the depth-2 spawning
    /// block (t=7525) and that run's `task_started` (t=7537) both precede its `agent_metadata` entry
    /// (t=7559), so on the whole wire the two-step join answers first and `parentSource` says `twoStepJoin`
    /// (`testTheWholeWireLetsEverySourceAnswer`, and `AgentRunTreeTests` at the tree's own level). The join's
    /// input is therefore **withheld** here and delivered afterwards: the mirror entry answers, and the join
    /// — which the second phase proves really ran — is retained beside it rather than overwriting it.
    ///
    /// Withholding one arm makes this a statement about source ordering and not about what the channel
    /// renders; the render is the whole-wire test's.
    func testTheMirrorEntryAnswersWhenItSpeaksBeforeTheJoinCan() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        // The wire alone: no file on disk, so nothing but the tap can name an agent run.
        try FileManager.default.createDirectory(at: mainPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: mainPath)

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = ChangeLog(ingestion)
        let tap = Tap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // Phase one: everything except the join's input.
        try replayWire(fx, to: tap, under: tree.root, where: { !Self.isJoinInput($0) })
        let answered = try await awaitTree(ingestion, "the mirror entry's parent link") {
            $0.nodes.count == 2 && $0.nodes.values.contains { $0.parent != nil }
        }
        let (one, two) = try depths(answered, fx)
        XCTAssertEqual(two.parent, one.id, "the depth-2 run's parent is the depth-1 task id")
        XCTAssertEqual(two.parentSource, .agentMetadata,
                       "the mirror entry was the only source that could answer, and it did")
        XCTAssertEqual(answered.parentAnswers[two.id], [.agentMetadata: one.id],
                       "no other source had spoken yet")
        XCTAssertNil(one.parent, "a depth-1 run has no parent to find")

        // Phase two: the join's input, which agrees. Non-vacuous — without it this test would pass just as
        // well against an ingestion whose join never runs, a state the tree cannot tell from agreement.
        try replayWire(fx, to: tap, under: tree.root, where: Self.isJoinInput)
        tap.finish()
        let agents = try await awaitTree(ingestion, "the join's own answer") {
            $0.parentAnswers[two.id]?[.twoStepJoin] != nil
        }
        XCTAssertEqual(agents.parentAnswers[two.id]?[.twoStepJoin], one.id,
                       "the join ran and agreed; its answer is kept beside the one that won")
        XCTAssertEqual(agents.node(two.id)?.parentSource, .agentMetadata, "the source of record does not move")
        XCTAssertEqual(agents.node(two.id)?.parent, one.id)
        XCTAssertEqual(agents.conflicts, [], "the sources agree, so nothing is in conflict")
        XCTAssertGreaterThan(log.agentsChanged, 0, "the tree moved and nothing said so")

        await ingestion.close()
    }

    /// **The whole wire, in its own order: every source answers, and the corpus decides which one is first.**
    ///
    /// The discriminating clause is `parentAnswers`, which holds each source's answer whether or not it won:
    /// before the ingestion fed the tree its `agent_metadata` records, the mirror's entry was absent from it
    /// however the recording was ordered.
    func testTheWholeWireLetsEverySourceAnswer() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try FileManager.default.createDirectory(at: mainPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: mainPath)

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let tap = Tap()
        try await ingestion.open(file: mainPath, events: tap.events)
        try replayWire(fx, to: tap, under: tree.root)
        tap.finish()

        let ids = try sidecarTaskIDs(fx)
        let agents = try await awaitTree(ingestion, "both sources' answers") { tree in
            guard tree.nodes.count == 2, let two = ids.first(where: { tree.nodes[$0]?.depth == 2 }) else { return false }
            return tree.parentAnswers[two]?.count == 2
        }
        let (one, two) = try depths(agents, fx)
        XCTAssertEqual(agents.parentAnswers[two.id], [.agentMetadata: one.id, .twoStepJoin: one.id],
                       "both wire-side sources answered, and with the depth-1 task id")
        XCTAssertEqual(two.parentSource, .twoStepJoin,
                       "in the recording's own order the join's input precedes the mirror entry")
        XCTAssertEqual(two.parent, one.id)
        XCTAssertEqual(agents.conflicts, [])

        await ingestion.close()
    }

    // MARK: - A file-only channel: the sidecars reach the tree

    /// **A channel opened from its files alone has a tree.** No wire means no `task_started`, so before this
    /// corrective every node the sidecars describe was dropped and C6.4's Agents tab was empty for every
    /// archived and every foreign session (tracker 187).
    func testAFileOnlyOpenBuildsTheTreeFromTheSidecars() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "nested")

        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = ChangeLog(ingestion)
        // A stream that is already over: what the app hands a channel it owns no process for.
        let (events, continuation) = AsyncStream<WireEvent>.makeStream()
        continuation.finish()
        try await ingestion.open(file: mainPath, events: events)

        let built = await ingestion.agents
        let agents = try XCTUnwrap(built, "a file-only channel built no tree")
        XCTAssertFalse(agents.nodes.isEmpty, "the sidecars beside the transcript named no run")
        let (one, two) = try depths(agents, fx)
        XCTAssertEqual(two.parent, one.id, "the sidecar's parentAgentId is the depth-1 task id")
        XCTAssertEqual(two.parentSource, .metaFile, "on disk the sidecar is the source, not the mirror")
        XCTAssertEqual(agents.roots, [one.id], "the depth-1 run is the tree's only root")
        XCTAssertEqual(agents.children(of: one.id), [two.id])
        XCTAssertEqual(agents.conflicts, [])
        XCTAssertGreaterThan(log.agentsChanged, 0, "the open's tree is not reported as having moved")

        await ingestion.close()
    }

    /// **One corpus, two channel kinds, one tree.** C6.4 reads the same model whichever way the channel was
    /// opened, so the shape the two produce has to be the same value — not merely both non-empty.
    func testALiveAndAFileOnlyChannelAgreeOnTheTree() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)

        let liveTree = try TempTree()
        let livePath = try mirroredMainPath(fx, in: liveTree)
        try FileManager.default.createDirectory(at: livePath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: livePath)
        let live = StreamIngestion(session: fx.sessionID, configHome: liveTree.root, mode: .filePrimary)
        let tap = Tap()
        try await live.open(file: livePath, events: tap.events)
        try replayWire(fx, to: tap, under: liveTree.root)
        tap.finish()

        let fileTree = try TempTree()
        let filePath = try fileTree.add(fx, slug: "nested")
        let fileOnly = StreamIngestion(session: fx.sessionID, configHome: fileTree.root, mode: .filePrimary)
        let (events, continuation) = AsyncStream<WireEvent>.makeStream()
        continuation.finish()
        try await fileOnly.open(file: filePath, events: events)

        let liveAgents = try await awaitTree(live, "the live channel's two linked nodes") {
            $0.nodes.count == 2 && $0.nodes.values.contains { $0.parent != nil }
        }
        let fileBuilt = await fileOnly.agents
        let fileAgents = try XCTUnwrap(fileBuilt, "the file-only channel built no tree")
        XCTAssertFalse(fileAgents.nodes.isEmpty, "an empty tree would make this comparison vacuous")
        XCTAssertEqual(Shape(fileAgents), Shape(liveAgents),
                       "the same corpus produced two different trees depending on how the channel was opened")
        // The one thing that legitimately differs, asserted so the shape comparison is not read as claiming
        // more than it does: each kind records the source that was actually available to it.
        XCTAssertNotEqual(try depths(fileAgents, fx).two.parentSource, try depths(liveAgents, fx).two.parentSource)

        await live.close()
        await fileOnly.close()
    }

    /// **A later source that disagrees is recorded and the parent does not move** — first-source-wins, held
    /// where the ingestion is what feeds the sources rather than the test.
    ///
    /// The sidecars on disk answer during `open`; then an invented mirror entry names a different parent for
    /// the same run. The invented parent id is invented and is not a node of this tree, so a re-parenting
    /// would be visible as a node hanging off nothing.
    func testADisagreeingMirrorEntryIsRecordedAndDoesNotReParent() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)
        let tree = try TempTree()
        let mainPath = try tree.add(fx, slug: "nested")
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let tap = Tap()
        try await ingestion.open(file: mainPath, events: tap.events)

        let openedTree = await ingestion.agents
        let opened = try XCTUnwrap(openedTree, "a file-only open built no tree")
        let (one, two) = try depths(opened, fx)
        XCTAssertEqual(two.parent, one.id)
        XCTAssertEqual(two.parentSource, .metaFile)

        // An invented mirror entry for the depth-2 run's own stream, naming a parent that is not a node.
        let wrongParent = "an-invented-parent-task-id"
        XCTAssertFalse(opened.nodes.keys.contains(wrongParent), "the invented parent must not be a real node")
        let sidecar = mainPath.deletingLastPathComponent()
            .appendingPathComponent("\(fx.sessionID)", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(two.id).jsonl")
        let entry = JSONValue.object(["type": .string("agent_metadata"),
                                      "agentType": .string("InventedAgentType"),
                                      "description": .string("an invented run"),
                                      "toolUseId": .string("toolu_invented0000"),
                                      "spawnDepth": .integer(2),
                                      "parentAgentId": .string(wrongParent)])
        let frame = FrameDecoder.decode(line: try JSONValue.object([
            "type": .string("transcript_mirror"),
            "filePath": .string(sidecar.standardizedFileURL.path),
            "entries": .array([entry]),
        ]).canonicalData())
        tap.send(.frame(frame, .first))
        tap.finish()

        let after = try await awaitTree(ingestion, "the disagreement recorded") { !$0.conflicts.isEmpty }

        XCTAssertEqual(after.node(two.id)?.parent, one.id, "the first answer is kept, not overwritten")
        XCTAssertEqual(after.node(two.id)?.parentSource, .metaFile, "the source of record does not move")
        XCTAssertEqual(after.conflicts.count, 1, "the disagreement is recorded exactly once")
        let sentence = try XCTUnwrap(after.conflicts.first)
        XCTAssertTrue(sentence.contains(two.id), "the conflict names the node")
        XCTAssertTrue(sentence.contains(wrongParent), "and the answer that disagreed")
        XCTAssertFalse(sentence.contains("/"), "a conflict sentence carries identifiers, never a path")
        XCTAssertEqual(after.parentAnswers[two.id]?[.agentMetadata], wrongParent,
                       "both answers are kept, so the disagreement is inspectable and not merely counted")
        XCTAssertEqual(after.children(of: one.id), [two.id], "the branch did not move")

        await ingestion.close()
    }

    // MARK: - The published registry mirror

    /// **`ChannelTimeline` carries the fold's registry mirror**, so the read the renderer holds is the one
    /// §8.4 gates *Move to background* on. Before this corrective the fold's mirror was inside the ingestion
    /// and the timeline carried nothing (tracker 321).
    func testThePublishedTimelineCarriesTheFoldsRegistryMirror() async throws {
        let fx = try FixtureCorpus.named(Self.fixtureName)
        let tree = try TempTree()
        let mainPath = try mirroredMainPath(fx, in: tree)
        try FileManager.default.createDirectory(at: mainPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: mainPath)
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let tap = Tap()
        try await ingestion.open(file: mainPath, events: tap.events)

        // Empty before a task frame arrives, and that is a reading and not an absence.
        let atOpen = await ingestion.timeline.registry
        XCTAssertEqual(atOpen.entries.count, 0)

        try replayWire(fx, to: tap, under: tree.root)
        tap.finish()
        _ = try await awaitTree(ingestion, "the recording's two runs") { $0.nodes.count == 2 }

        let timeline = await ingestion.timeline
        let folded = await ingestion.registry
        XCTAssertEqual(timeline.registry, folded, "the published mirror is not the fold's")
        XCTAssertFalse(timeline.registry.entries.isEmpty,
                       "the recording's task frames folded into no registry row")
        let agentRows = timeline.registry.entries.values.filter { $0.kind == .localAgent }
        XCTAssertEqual(Set(agentRows.map(\.id)), Set(try sidecarTaskIDs(fx)),
                       "the mirror's agent rows are the fixture's two runs")
        for row in agentRows {
            XCTAssertNotNil(row.toolUseID, "a row with no tool-use id can never name one in background_tasks")
        }

        await ingestion.close()
    }

    // MARK: - Waiting

    /// The tree once it satisfies `until`. **Delivery-fulfilled, never a fixed span**: the tap is consumed on
    /// another task, so a fixed wait would measure the host and not the fold (`TestTiming`). The guard turns a
    /// hang into a failure and decides no assertion — every clause the callers care about is asserted after
    /// this returns.
    private func awaitTree(_ ingestion: StreamIngestion, _ what: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           until: @Sendable (AgentRunTree) -> Bool) async throws -> AgentRunTree {
        let deadline = ContinuousClock.now.advanced(by: TestTiming.hangGuard)
        while true {
            let tree = await ingestion.agents
            if let tree, until(tree) { return tree }
            if ContinuousClock.now >= deadline {
                XCTFail("\(what): not reached inside the hang guard (nodes: \(tree?.nodes.count ?? -1))",
                        file: file, line: line)
                let last = tree
                return try XCTUnwrap(last, what, file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
