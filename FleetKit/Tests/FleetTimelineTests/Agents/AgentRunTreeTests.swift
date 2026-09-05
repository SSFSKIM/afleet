import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The agent-run tree folded from the recorded frames. Every fold runs on the recording's own clock —
/// `now = Date(timeIntervalSince1970: t / 1000)` from the `frames.ndjson` envelope — so nothing waits on wall time.
///
/// No engine identifier is written into this file. The task ids a test pins are read from the fixture's own subagent
/// sidecar **file names**, which is a corpus fact independent of the frame fold the tree performs.
final class AgentRunTreeTests: XCTestCase {

    /// The redaction placeholder every recorded transcript tree sits under, and the one it is relocated to.
    static let recordedSlug = "_slug_"
    static let otherSlug = "_other_"

    // MARK: - Reading a fixture

    /// One thing the tree folds, tagged with the recording position so ties in `t` keep the recorded order.
    enum Event {
        case system(SystemFrame, Date)
        /// A message frame's join input: its `parent_tool_use_id` and the tool-use ids its blocks carry.
        case join(parent: String?, carrying: [String])
        /// A message frame's model, with the tool-use id of the run it was forwarded out of (nil = the main stream).
        case model(String, parent: String?)
        /// An `agent_metadata` entry of a `transcript_mirror` frame, with the agent stream it belongs to.
        case metadata(AgentMetadataRecord, LogicalStream)
    }

    /// Every event of a fixture in `t` order. A frame contributes to more than one arm: an `assistant` frame is both a
    /// join input and a model observation, and each arm is applied only by the test that asks for it.
    static func events(_ fx: FixtureCorpus.Fixture) throws -> [Event] {
        var out: [(Int, Int, Event)] = []
        for recorded in try fx.frames() {
            let at = Date(timeIntervalSince1970: Double(recorded.t) / 1000)
            switch recorded.frame {
            case .system(let system):
                out.append((recorded.t, recorded.index, .system(system, at)))
            case .assistant(let f):
                out.append((recorded.t, recorded.index, .join(parent: f.parentToolUseID, carrying: blockIDs(f.message.fields.content))))
                if let model = f.message.fields.model {
                    out.append((recorded.t, recorded.index, .model(model, parent: f.parentToolUseID)))
                }
            case .user(let f):
                guard case .blocks(let blocks) = f.message.fields.content else { continue }
                out.append((recorded.t, recorded.index, .join(parent: f.parentToolUseID, carrying: blockIDs(blocks))))
            case .transcriptMirror(let m):
                guard let (stream, _) = TranscriptPath.resolve(URL(fileURLWithPath: m.filePath), under: FixtureCorpus.recordedConfigHome)
                else { continue }
                for entry in m.entries {
                    guard case .agentMetadata(let record, _) = RecordDecoder.decode(entry: entry) else { continue }
                    out.append((recorded.t, recorded.index, .metadata(record, stream)))
                }
            default: continue
            }
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// The tool-use ids a message's blocks carry: a `tool_use` block's own id, and a `tool_result` block's subject.
    static func blockIDs(_ blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { block in
            switch block {
            case .toolUse(let use): use.fields.id
            case .toolResult(let result): result.fields.toolUseID
            default: nil
            }
        }
    }

    /// A tree over the fixture's recorded config home, session and slug.
    static func tree(_ fx: FixtureCorpus.Fixture) -> AgentRunTree {
        AgentRunTree(configHome: FixtureCorpus.recordedConfigHome, sessionID: fx.sessionID, slug: recordedSlug)
    }

    /// Folds the task frames of the events, and — when asked — the other arms too. Returns the tree and how many
    /// `task_*` system frames it was handed, so a test that expects no node can still prove the fold saw the frames.
    @discardableResult
    static func fold(_ events: [Event], into tree: inout AgentRunTree,
                     metadata: Bool = false, joins: Bool = false, models: Bool = false) -> Int {
        var taskFrames = 0
        for event in events {
            switch event {
            case .system(let frame, let at):
                switch frame {
                case .taskStarted(let f): taskFrames += 1; tree.apply(taskStarted: f, at: at)
                case .taskProgress(let f): taskFrames += 1; tree.apply(taskProgress: f, at: at)
                case .taskUpdated(let f): taskFrames += 1; tree.apply(taskUpdated: f, at: at)
                case .taskNotification(let f): taskFrames += 1; tree.apply(taskNotification: f, at: at)
                default: continue
                }
            case .join(let parent, let carrying):
                if joins { tree.observe(parentToolUseID: parent, carryingToolUseIDs: carrying) }
            case .model(let model, let parent):
                guard models, let parent, let node = tree.node(withToolUse: parent) else { continue }
                tree.observe(assistantModel: model, agentID: node.id)
            case .metadata(let record, let stream):
                if metadata { tree.apply(agentMetadata: record, for: stream) }
            }
        }
        return taskFrames
    }

    /// The fixture's agent task ids, read from its `agent-<taskId>.meta.json` file names. This is the corpus pin every
    /// assertion below grounds against, and it is derived from the fixture tree, not from the fold under test.
    static func sidecarTaskIDs(_ fx: FixtureCorpus.Fixture) throws -> [String] {
        try fx.metaFiles().compactMap { stream, _ in
            guard case .agent(let id) = stream.name else { return nil }
            return id
        }.sorted()
    }

    /// The one depth-1 and the one depth-2 node of `nested-depth-2`, checked to be exactly the sidecar ids.
    func depths(_ tree: AgentRunTree, _ fx: FixtureCorpus.Fixture) throws -> (depth1: AgentRunNode, depth2: AgentRunNode) {
        let ids = try Self.sidecarTaskIDs(fx)
        XCTAssertEqual(ids.count, 2, "nested-depth-2 should carry two agent sidecars")
        XCTAssertEqual(Set(tree.nodes.keys), Set(ids), "the folded node ids are not the fixture's agent stream ids")
        let byDepth = Dictionary(grouping: tree.nodes.values, by: \.depth)
        let one = try XCTUnwrap(byDepth[1]?.first, "no depth-1 node")
        let two = try XCTUnwrap(byDepth[2]?.first, "no depth-2 node")
        XCTAssertEqual(byDepth[1]?.count, 1); XCTAssertEqual(byDepth[2]?.count, 1)
        return (one, two)
    }

    // MARK: - Source one: the `agent_metadata` mirror entry

    func testNestedDepth2FromTaskFramesAndMirrorMetadata() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree, metadata: true)

        XCTAssertEqual(tree.nodes.count, 2, "nested-depth-2 folds to two agent runs")
        let (one, two) = try depths(tree, fx)
        XCTAssertEqual(two.parent, one.id, "the depth-2 node's parent is the depth-1 task id")
        XCTAssertEqual(two.parentSource, .agentMetadata, "the mirror entry answered first")
        XCTAssertNil(one.parent, "the depth-1 node has no parent")
        XCTAssertEqual(one.parentSource, .none)
        XCTAssertEqual(tree.parentAnswers[two.id], [.agentMetadata: one.id], "only the mirror entry ran")
        XCTAssertNil(tree.parentAnswers[one.id], "no source claims a parent for the depth-1 run")
        XCTAssertEqual(tree.roots, [one.id], "the depth-1 run is the only root")
        XCTAssertEqual(tree.children(of: one.id), [two.id])
        XCTAssertEqual(tree.conflicts, [])
        XCTAssertEqual(one.status, .completed); XCTAssertEqual(two.status, .completed)
    }

    // MARK: - Source two: the `.meta.json` sidecar

    func testMetaFileGivesTheSameParent() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree)
        let (one, two) = try depths(tree, fx)
        XCTAssertNil(two.parent, "task frames alone answer nothing about the parent")

        for (_, url) in try fx.metaFiles() { try tree.apply(metaFile: url) }
        let reread = try depths(tree, fx)
        XCTAssertEqual(reread.depth2.parent, one.id, "the sidecar gives the depth-1 task id as the parent")
        XCTAssertEqual(reread.depth2.parentSource, .metaFile)
        XCTAssertNil(reread.depth1.parent)
        XCTAssertEqual(tree.parentAnswers[two.id], [.metaFile: one.id])
        XCTAssertEqual(tree.conflicts, [])
        // A URL that is not `agent-<taskId>.meta.json` is refused rather than silently ignored.
        XCTAssertThrowsError(try tree.apply(metaFile: fx.framesURL)) { error in
            XCTAssertEqual(error as? AgentRunTreeError, .notAnAgentSidecar)
        }
    }

    // MARK: - Source three: the two-step join

    func testTwoStepJoinGivesTheSameParentWhenBothAreWithheld() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree, joins: true)   // no metadata, no sidecar

        let (one, two) = try depths(tree, fx)
        XCTAssertEqual(two.parent, one.id, "the join reads the parent of the frame that CARRIED the spawning block")
        XCTAssertEqual(two.parentSource, .twoStepJoin)
        XCTAssertNil(one.parent, "the depth-1 spawn was carried by a top-level frame")
        XCTAssertEqual(tree.parentAnswers[two.id], [.twoStepJoin: one.id])
        XCTAssertNil(tree.parentAnswers[one.id])
        XCTAssertEqual(tree.conflicts, [])
    }

    // MARK: - All three together

    func testAllThreeSourcesAgreeAndConflictsAreEmpty() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree, metadata: true, joins: true)
        for (_, url) in try fx.metaFiles() { try tree.apply(metaFile: url) }

        let (one, two) = try depths(tree, fx)
        // Empty conflicts is only meaningful if all three sources actually answered, with the same id.
        XCTAssertEqual(tree.parentAnswers[two.id],
                       [.agentMetadata: one.id, .metaFile: one.id, .twoStepJoin: one.id],
                       "all three sources must have answered, and with the depth-1 task id")
        XCTAssertEqual(tree.conflicts, [], "no source disagreed")
        XCTAssertEqual(tree.nodes.count, 2)
        XCTAssertEqual(two.parent, one.id)
        // Corpus, not guesswork: in `t` order the assistant frame carrying the depth-2 spawning block (t=7525)
        // precedes that run's own `task_started` (t=7537), which precedes its `agent_metadata` mirror entry (t=7559),
        // so with all three arms folded together the two-step join is the source that answers first. The mirror entry
        // and the sidecar then agree with it and do not overwrite it.
        XCTAssertEqual(two.parentSource, .twoStepJoin, "the first source to answer keeps the link")
        XCTAssertEqual(tree.roots, [one.id])
        XCTAssertEqual(tree.children(of: one.id), [two.id])
        XCTAssertEqual(tree.children(of: two.id), [])
        XCTAssertFalse(tree.isParked(one.id), "both runs finished, so neither branch is parked")

        // Parked is the other branch of the same predicate: the parent is terminal and a child is still running.
        // Re-arming the child through the recorded `task_started` is the only way to reach it through the API.
        for event in try Self.events(fx) {
            guard case .system(.taskStarted(let f), let at) = event, f.taskID == two.id else { continue }
            tree.apply(taskStarted: f, at: at)
        }
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).status, .running)
        XCTAssertEqual(try XCTUnwrap(tree.node(one.id)).status, .completed)
        XCTAssertTrue(tree.isParked(one.id), "the parent is finished and its child is running")
        XCTAssertFalse(tree.isParked(two.id), "a running node is never parked")
    }

    // MARK: - A source that disagrees

    /// The conflict record is the only thing that distinguishes a silent overwrite from a silent drop, so it needs a
    /// disagreement to be tested against, and the corpus has none: all three sources agree everywhere. The wrong
    /// parent below is an **invented** identifier applied through the public API; no fixture is edited and no engine
    /// byte is written into this file.
    ///
    /// It also pins the record as idempotent. `resolveJoins()` re-offers every node's join answer after every single
    /// observation, so a standing disagreement is re-offered once per message frame; without idempotence `conflicts`
    /// would grow by one entry per frame for the life of the session.
    func testADisagreeingSourceIsRecordedOnceAndTheFirstAnswerIsKept() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        let events = try Self.events(fx)
        var tree = Self.tree(fx)
        Self.fold(events, into: &tree)                       // task frames only: no parent yet
        let (one, two) = try depths(tree, fx)
        XCTAssertNil(two.parent)

        // An invented mirror entry that names the wrong parent, applied to the depth-2 run's stream.
        let wrongParent = "an-invented-parent-task-id"
        XCTAssertFalse(tree.nodes.keys.contains(wrongParent), "the invented parent must not be a real node")
        let invented = AgentMetadataRecord(fields: AgentMetadataFields(
            type: "agent_metadata", agentType: "InventedAgentType", description: "an invented run",
            toolUseId: two.toolUseID, spawnDepth: 2, parentAgentId: wrongParent))
        tree.apply(agentMetadata: invented,
                   for: LogicalStream(configHome: FixtureCorpus.recordedConfigHome, sessionID: fx.sessionID,
                                      name: .agent(taskID: two.id)))
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).parent, wrongParent, "the first source to answer sets the link")
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).parentSource, .agentMetadata)
        XCTAssertEqual(tree.conflicts, [], "one source alone cannot disagree with anything")

        // Now the two-step join answers, and it disagrees. It is re-offered on every one of the fixture's frames.
        Self.fold(events, into: &tree, joins: true)
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).parent, wrongParent, "the first answer is kept, not overwritten")
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).parentSource, .agentMetadata, "the source of record does not move")
        XCTAssertEqual(tree.conflicts.count, 1, "the disagreement is recorded exactly once")
        let sentence = try XCTUnwrap(tree.conflicts.first)
        XCTAssertTrue(sentence.contains(two.id), "the conflict names the node")
        XCTAssertTrue(sentence.contains(AgentRunNode.ParentSource.twoStepJoin.rawValue), "and the source that disagreed")
        XCTAssertTrue(sentence.contains(one.id), "and the parent that source proposed")
        XCTAssertTrue(sentence.contains(wrongParent), "and the answer that was kept")
        XCTAssertFalse(sentence.contains("/"), "a conflict sentence carries identifiers, never a path")
        XCTAssertEqual(tree.parentAnswers[two.id], [.agentMetadata: wrongParent, .twoStepJoin: one.id],
                       "both answers are kept, so the disagreement is inspectable and not merely counted")

        // Folding exactly the same disagreement again must not grow the record.
        let recorded = tree.conflicts
        Self.fold(events, into: &tree, joins: true)
        Self.fold(events, into: &tree, joins: true)
        XCTAssertEqual(tree.conflicts, recorded, "a repeated disagreement is recorded once, not once per frame")
        XCTAssertEqual(try XCTUnwrap(tree.node(two.id)).parent, wrongParent)
    }

    // MARK: - Node identity

    func testARepeatedTaskStartedIsTheSameNode() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        let events = try Self.events(fx)
        var tree = Self.tree(fx)
        Self.fold(events, into: &tree, metadata: true)
        let before = tree.nodes
        let (one, _) = try depths(tree, fx)
        XCTAssertEqual(one.startedCount, 1)

        // Re-apply exactly the recorded `task_started` frames: the same ids arrive a second time.
        for event in events {
            guard case .system(.taskStarted(let f), let at) = event else { continue }
            tree.apply(taskStarted: f, at: at)
        }
        XCTAssertEqual(Set(tree.nodes.keys), Set(before.keys), "a repeat must not add a node")
        XCTAssertEqual(tree.nodes.count, 2)
        let (again, twoAgain) = try depths(tree, fx)
        XCTAssertEqual(again.startedCount, 2, "the repeat is the same node run again")
        XCTAssertEqual(twoAgain.startedCount, 2)
        XCTAssertEqual(again.toolUseID, one.toolUseID, "the spawning tool-use id is unchanged")
        XCTAssertEqual(twoAgain.parent, again.id, "the parent link survives the repeat")
        XCTAssertEqual(again.status, .running, "a re-arm puts the run back to running")
        XCTAssertNil(again.endedAt)
        XCTAssertEqual(tree.conflicts, [])
    }

    func testAShellCreatesNoNode() throws {
        let fx = try FixtureCorpus.named("background-shell")
        var tree = Self.tree(fx)
        let taskFrames = Self.fold(try Self.events(fx), into: &tree, metadata: true, joins: true)

        // Non-vacuous: the fold really was handed this fixture's task frames, and still made nothing.
        XCTAssertEqual(taskFrames, 3, "background-shell records task_started, task_updated and task_notification")
        XCTAssertEqual(tree.nodes, [:], "a local_bash task is a registry row, not an agent run")
        XCTAssertEqual(tree.roots, [])
        XCTAssertEqual(try Self.sidecarTaskIDs(fx), [], "background-shell has no agent sidecar")
    }

    // MARK: - The model badge

    func testModelComesFromTheRunsOwnFrames() throws {
        let fx = try FixtureCorpus.named("explore-depth-1")
        let events = try Self.events(fx)
        var withoutModels = Self.tree(fx)
        Self.fold(events, into: &withoutModels, metadata: true)
        let ids = try Self.sidecarTaskIDs(fx)
        XCTAssertEqual(ids.count, 1, "explore-depth-1 carries one agent sidecar")
        let id = try XCTUnwrap(ids.first)
        XCTAssertEqual(Set(withoutModels.nodes.keys), Set(ids))
        XCTAssertNil(try XCTUnwrap(withoutModels.node(id)).model,
                     "neither the task frames nor the sidecar carries a model")

        var tree = Self.tree(fx)
        Self.fold(events, into: &tree, metadata: true, models: true)
        let node = try XCTUnwrap(tree.node(id))
        let model = try XCTUnwrap(node.model, "the run's own forwarded frames carry the model")
        XCTAssertFalse(model.isEmpty)
        // The badge is the model of a frame forwarded out of THIS run, not of the main stream's frames.
        let forwarded = events.compactMap { event -> String? in
            guard case .model(let m, let parent) = event, parent == node.toolUseID else { return nil }
            return m
        }
        XCTAssertFalse(forwarded.isEmpty, "the fixture forwards assistant frames out of the run")
        XCTAssertEqual(model, forwarded.last)
    }

    // MARK: - Paths

    func testTranscriptPathFollowsTheSlug() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree, metadata: true)

        // The expectation is the fixture's own transcript layout rewritten onto the recorded config home — the same
        // aliasing `FixtureCorpus` uses to resolve a fixture file, and independent of the tree's own path arithmetic.
        let base = fx.transcriptRoot.standardizedFileURL.path
        var expected: [String: URL] = [:]
        for (stream, kind, url) in try fx.transcriptFiles() {
            guard case .agentTranscript(let slug, let taskID) = kind else { continue }
            XCTAssertEqual(slug, Self.recordedSlug, "the recorded slug placeholder changed")
            _ = stream
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            expected[taskID] = FixtureCorpus.recordedConfigHome.appendingPathComponent("projects").appendingPathComponent(relative)
        }
        XCTAssertEqual(Set(expected.keys), Set(tree.nodes.keys), "every folded node has a recorded agent transcript")
        for (id, url) in expected {
            // Not XCTAssertEqual: a mismatch would print two paths under the recorded config home, and an assertion
            // may name identifiers only (C3 constraints, parent §12).
            XCTAssertTrue(tree.transcriptURL(of: id)?.standardizedFileURL == url, "agent \(id) is not at its recorded path")
        }

        let before = tree.nodes
        tree.relocate(slug: Self.otherSlug)
        for id in tree.nodes.keys {
            let moved = try XCTUnwrap(tree.transcriptURL(of: id))
            XCTAssertTrue(moved.path.contains("/projects/\(Self.otherSlug)/"), "agent \(id) did not move to the new slug")
            XCTAssertFalse(moved.path.contains("/projects/\(Self.recordedSlug)/"), "agent \(id) kept a stale path")
            XCTAssertEqual(moved.lastPathComponent, expected[id]?.lastPathComponent, "the file name changed with the slug")
        }
        XCTAssertEqual(tree.nodes, before, "relocation changes no id, parent, status or any other node field")
        XCTAssertEqual(tree.slug, Self.otherSlug)
        XCTAssertNil(tree.transcriptURL(of: "an-invented-task-id"), "an unknown id has no path")
    }

    // MARK: - `tool_progress`

    /// `tool_progress` is **unwitnessed**: no fixture in the corpus carries the frame. The line below is invented and
    /// schema-shaped — invented uuid, session id and tool name — and only its `parent_tool_use_id` comes from the
    /// fixture, read at run time so no engine byte is written into this file. It is decoded through `FrameDecoder`,
    /// so what the tree folds is a real frame, not a hand-built value.
    func testToolProgressSetsTheAgentsLastToolOnAnUnwitnessedPath() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree, metadata: true)
        let (one, two) = try depths(tree, fx)
        let target = try XCTUnwrap(one.toolUseID)

        let line = JSONValue.object([
            "type": .string("tool_progress"),
            "tool_use_id": .string("toolu_inventedProgressBlockIdentifier"),
            "tool_name": .string("InventedProgressTool"),
            "parent_tool_use_id": .string(target),
            "elapsed_time_seconds": .number(1.5),
            "uuid": .string("00000000-0000-4000-8000-00000000ab01"),
            "session_id": .string(fx.sessionID.description),
        ])
        guard case .toolProgress(let frame) = FrameDecoder.decode(line: try line.canonicalData()) else {
            return XCTFail("the invented line did not decode as tool_progress")
        }
        tree.apply(toolProgress: frame, at: Date(timeIntervalSince1970: 0))

        let touched = try XCTUnwrap(tree.node(one.id))
        XCTAssertEqual(touched.lastToolName, "InventedProgressTool")
        XCTAssertEqual(touched.activityLine, "InventedProgressTool")
        XCTAssertEqual(tree.node(two.id), two, "the sibling run is untouched")
        XCTAssertEqual(touched.status, one.status, "tool_progress moves nothing but the tool and the activity line")
        XCTAssertEqual(touched.parent, one.parent)
        XCTAssertEqual(touched.startedCount, one.startedCount)
    }

    // MARK: - The wire reducer's route

    func testNodeWithToolUseFindsTheSpawnedNode() throws {
        let fx = try FixtureCorpus.named("nested-depth-2")
        var tree = Self.tree(fx)
        Self.fold(try Self.events(fx), into: &tree)          // task frames only
        let (one, two) = try depths(tree, fx)

        let oneUse = try XCTUnwrap(one.toolUseID), twoUse = try XCTUnwrap(two.toolUseID)
        XCTAssertNotEqual(oneUse, twoUse)
        XCTAssertEqual(tree.node(withToolUse: oneUse)?.id, one.id)
        XCTAssertEqual(tree.node(withToolUse: twoUse)?.id, two.id)
        XCTAssertEqual(tree.node(one.id), one, "node(_:) by task id agrees")
        XCTAssertEqual(tree.node(two.id), two)
        XCTAssertNil(tree.node(withToolUse: "toolu_inventedSpawningBlockIdentifier"))
        XCTAssertNil(tree.node("an-invented-task-id"))
        // A task id is not a tool-use id: looking one up in the other namespace must miss.
        XCTAssertNil(tree.node(withToolUse: one.id))
        XCTAssertNil(tree.node(oneUse))
    }
}
