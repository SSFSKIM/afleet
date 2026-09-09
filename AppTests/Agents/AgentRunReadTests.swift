import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.4 Task 1: the Agents tab's read of C3's run tree, and a node's drawn content.
///
/// **Every identifier below is invented** — a word and a repeated nibble — so nothing here can be
/// mistaken for an engine byte or for anybody's own session (§11). The one exception is the
/// `nested-depth-2` arm, which folds a *committed, reviewed* recording through C3's own
/// `WireReducer`; it asserts counts and shapes and prints no id.
///
/// **X9:** nothing in this file writes anything. The config home the tree is constructed over is a
/// value used to compute a transcript URL, and no path here is opened.
@MainActor
final class AgentRunReadTests: XCTestCase {

    // MARK: - The three states

    /// A channel with **no tree at all** and a channel with an **empty tree** are different facts
    /// (child spec D10).
    ///
    /// Discriminating: a read that mapped both to an empty roots array passes every assertion about
    /// the roots and misinforms every archived and every foreign channel — which is most of what
    /// this app lists — by telling them "no agent runs" when the truth is that the tree is wire-fed
    /// and this channel has no wire.
    func testANilTreeIsNotAnEmptyTree() {
        let noWire = AgentRunRead(timeline: ChannelTimeline())
        XCTAssertEqual(noWire.state, .noWire, "a channel with no tree did not read as the no-wire state")

        let empty = AgentRunRead(timeline: ChannelTimeline(agents: Self.tree()))
        XCTAssertEqual(empty.state, .noRuns, "a channel with an empty tree did not read as the no-runs state")

        XCTAssertNotEqual(noWire.state, empty.state,
                          "the two empty states are one value, so nothing downstream can word them apart")
        XCTAssertEqual(noWire.roots.count, 0, "the no-wire state offered \(noWire.roots.count) root(s)")
        XCTAssertEqual(empty.roots.count, 0, "the no-runs state offered \(empty.roots.count) root(s)")
    }

    // MARK: - Nesting

    /// Over the committed `nested-depth-2` recording, folded through C3's own wire reducer: the
    /// tree has **one** root and the depth-2 run is that root's child.
    ///
    /// Failing-first against a read that answers every node as a root — which is what a tree built
    /// from `spawn_depth` alone, or from `task_started` alone, would produce, since `task_started`
    /// carries no parent id.
    func testADepthTwoNodeIsNotARoot() throws {
        let read = try Self.nestedDepthTwo()

        XCTAssertEqual(read.roots.count, 1,
                       "the recording's tree read as \(read.roots.count) root(s), not the 1 it holds")
        let root = try XCTUnwrap(read.roots.first, "the tree offered no root")
        let children = read.children(of: root)
        XCTAssertEqual(children.count, 1,
                       "the root has \(children.count) child(ren), not the 1 the recording nests under it")
        let child = try XCTUnwrap(read.content(of: try XCTUnwrap(children.first, "the root has no child")),
                                  "the tree holds no content for its own child")
        XCTAssertEqual(child.depth, 2, "the nested run draws depth \(child.depth), not 2")
    }

    /// A node whose parent **no source answered** surfaces in `roots`, with its own depth stated
    /// (child spec D8, tracker 13).
    ///
    /// Failing-first against a read that filtered the roots to `depth == 1`: the two readings agree
    /// on every well-formed session and diverge exactly here, and the depth-1 filter would drop this
    /// run out of the tree with no sign that it existed.
    func testAnOrphanSurfacesAsARootWithItsDepthDrawn() throws {
        var tree = Self.tree()
        tree.apply(taskStarted: Self.taskStarted(taskID: "task_invented0001", toolUseID: "toolu_invented0001",
                                                 agentType: "an-invented-agent", depth: 1),
                   at: Self.epoch)
        // Depth 2, and nothing anywhere names its parent: no metadata, no sidecar, and no frame
        // carrying the block that spawned it.
        tree.apply(taskStarted: Self.taskStarted(taskID: "task_invented0002", toolUseID: "toolu_invented0002",
                                                 agentType: "an-invented-orphan", depth: 2),
                   at: Self.epoch)

        let read = AgentRunRead(timeline: ChannelTimeline(agents: tree))

        XCTAssertEqual(read.roots.count, 2,
                       "the orphan is not at the top: \(read.roots.count) root(s) for 2 parentless runs")
        let orphan = try XCTUnwrap(read.content(of: "task_invented0002"),
                                   "the read holds no content for the orphaned run")
        XCTAssertEqual(orphan.depth, 2, "the orphan draws depth \(orphan.depth) rather than the 2 it was spawned at")
        XCTAssertTrue(read.roots.contains("task_invented0002"), "the orphan is not among the tree's roots")
    }

    // MARK: - Sanitising and the waiting count

    /// Every wire string a node draws passes `TextSanitiser` once, where the content is built
    /// (child spec D11, §12).
    func testEveryDrawnStringIsSanitised() throws {
        var tree = Self.tree()
        tree.apply(taskStarted: Self.taskStarted(taskID: "task_invented0004", toolUseID: "toolu_invented0004",
                                                 agentType: "an\u{202E}invented\u{200B}agent",
                                                 description: "an\u{2028}invented\u{0007}errand",
                                                 depth: 1),
                   at: Self.epoch)
        tree.apply(taskProgress: Self.taskProgress(taskID: "task_invented0004",
                                                   summary: "read\u{FEFF}ing an\u{202D}invented file",
                                                   lastToolName: "Re\u{200D}ad"),
                   at: Self.epoch)

        let read = AgentRunRead(timeline: ChannelTimeline(agents: tree))
        let content = try XCTUnwrap(read.content(of: "task_invented0004"), "the read holds no content for the run")

        for drawn in [content.agentType, content.description, content.activityLine, content.lastToolName] {
            guard let drawn else { continue }
            let stripped = drawn.unicodeScalars.filter(TextSanitiser.isStripped).count
            XCTAssertEqual(stripped, 0, "a drawn string kept \(stripped) scalar(s) the sanitiser strips")
        }
        // And the sanitising is a strip, not a blanking: the readable text survives it.
        XCTAssertTrue(content.description.contains("invented"), "the sanitiser removed the readable text with the rest")
    }

    /// The waiting badge's count is the channel's **pending** decisions whose `agent_id` is this
    /// node's, and a sibling's card is not on this node.
    func testTheWaitingCountComesFromTheDecisionsAgentID() throws {
        var tree = Self.tree()
        tree.apply(taskStarted: Self.taskStarted(taskID: "task_invented0005", toolUseID: "toolu_invented0005",
                                                 agentType: "an-invented-agent", depth: 1),
                   at: Self.epoch)
        tree.apply(taskStarted: Self.taskStarted(taskID: "task_invented0006", toolUseID: "toolu_invented0006",
                                                 agentType: "an-invented-sibling", depth: 1),
                   at: Self.epoch)
        var overlay = Overlay.empty
        overlay.decisions = [
            RequestID(rawValue: "req_invented0001"): Self.decision("req_invented0001", agent: "task_invented0005"),
            RequestID(rawValue: "req_invented0002"): Self.decision("req_invented0002", agent: "task_invented0006"),
        ]

        let read = AgentRunRead(timeline: ChannelTimeline(overlay: overlay, agents: tree))

        let mine = try XCTUnwrap(read.content(of: "task_invented0005"), "the read holds no content for the run")
        let sibling = try XCTUnwrap(read.content(of: "task_invented0006"), "the read holds no content for the sibling")
        XCTAssertEqual(mine.waitingCount, 1, "the node reports \(mine.waitingCount) waiting decision(s), not 1")
        XCTAssertEqual(sibling.waitingCount, 1, "the sibling reports \(sibling.waitingCount) waiting decision(s), not 1")
    }

    // MARK: - Invented material

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static let session = SessionID("eeeeeeee-5555-4555-8555-eeeeeeeeeeee")!

    /// A tree over an invented config home. Nothing opens it: the tree computes URLs from it and
    /// this file asks for none (X9).
    static func tree() -> AgentRunTree {
        AgentRunTree(configHome: URL(fileURLWithPath: "/invented/config-home"),
                     sessionID: session, slug: "an-invented-slug")
    }

    /// `nested-depth-2` folded through C3's own wire reducer — the same reducer a live channel runs,
    /// and the only source of the tree on this baseline.
    static func nestedDepthTwo() throws -> AgentRunRead {
        let reducer = try TimelineCorpus.wire("nested-depth-2")
        return AgentRunRead(timeline: ChannelTimeline(durable: reducer.durable,
                                                      overlay: reducer.overlay,
                                                      agents: reducer.agents))
    }

    /// A `task_started`, decoded rather than constructed: ClaudeWire's field structs synthesise an
    /// *internal* memberwise initialiser, and building from JSON also keeps the invented frame in
    /// the shape the wire uses.
    static func taskStarted(taskID: String, toolUseID: String, agentType: String,
                            description: String = "an invented errand", depth: Int) -> TaskStarted {
        decode(["type": .string("system"), "subtype": .string("task_started"),
                "task_id": .string(taskID), "tool_use_id": .string(toolUseID),
                "description": .string(description), "subagent_type": .string(agentType),
                "spawn_depth": .integer(Int64(depth)), "task_type": .string("local_agent"),
                "uuid": .string("aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"),
                "session_id": .string(session.description)])
    }

    static func taskProgress(taskID: String, summary: String, lastToolName: String) -> TaskProgress {
        decode(["type": .string("system"), "subtype": .string("task_progress"),
                "task_id": .string(taskID), "description": .string("an invented step"),
                "usage": .object([:]), "summary": .string(summary), "last_tool_name": .string(lastToolName),
                "uuid": .string("aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa"),
                "session_id": .string(session.description)])
    }

    private static func decode<T: Decodable>(_ object: [String: JSONValue]) -> T {
        guard let data = try? JSONValue.object(object).canonicalData(),
              let frame = try? JSONDecoder().decode(T.self, from: data) else {
            preconditionFailure("an invented frame did not decode as one")
        }
        return frame
    }

    private static var stream: LogicalStream {
        LogicalStream(configHome: URL(fileURLWithPath: "/invented/config-home"), sessionID: session, name: .main)
    }

    static func decision(_ request: String, agent: String) -> DecisionItem {
        DecisionItem(id: ItemID(stream: stream, key: request),
                     timestamp: epoch,
                     provenance: Provenance(stream: stream, agentID: agent, origin: .wire),
                     requestID: RequestID(rawValue: request),
                     kind: .permission,
                     title: "an invented permission",
                     agentID: agent,
                     state: .pending,
                     payload: .object([:]))
    }
}
