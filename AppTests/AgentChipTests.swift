import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 4: the `Agent` chip, contract Y4's call site, and the two arms a tree that is usually
/// absent gives it.
@MainActor
final class AgentChipTests: XCTestCase {

    // MARK: - The name

    /// **The tool is named `Agent`, not `Task`.** The composite and §8.8 both speak of "Agent
    /// calls"; the parity map's tool tables and the fixtures name the tool `Agent`, and a chip keyed
    /// on the wrong string renders nothing at all. Asserted from the corpus, which is what carries
    /// the name.
    func testAgentIsTheToolName() throws {
        var agents = 0
        var tasks = 0
        for name in try TimelineCorpus.names() {
            for item in try TimelineCorpus.durable(name).items {
                guard case .toolCall(let call) = item else { continue }
                if call.name == "Agent" { agents += 1 }
                if call.name == "Task" { tasks += 1 }
            }
        }
        XCTAssertGreaterThan(agents, 0, "the corpus carries \(agents) call(s) named Agent")
        XCTAssertEqual(tasks, 0, "the corpus carries \(tasks) call(s) named Task")

        // The routing itself, and then the view it produces. A row's `body` is evaluated here
        // rather than read off the registry's `AnyView`, which holds an unevaluated view value.
        XCTAssertTrue(ToolCallRow.isAgentChip(Self.call(name: "Agent")),
                      "a call named Agent does not route to the chip")
        XCTAssertFalse(ToolCallRow.isAgentChip(Self.call(name: "Task")),
                       "a call named Task routes to the chip, which is the wrong string")

        let chip = ToolCallRow(item: Self.call(name: "Agent")).body
        XCTAssertEqual(ViewTree.values(of: AgentChipRow.self, in: chip).count, 1,
                       "a call named Agent drew \(ViewTree.values(of: AgentChipRow.self, in: chip).count) chip(s)")
        let plain = ToolCallRow(item: Self.call(name: "Task")).body
        XCTAssertEqual(ViewTree.values(of: AgentChipRow.self, in: plain).count, 0,
                       "a call named Task drew a chip, which is the wrong string")
        XCTAssertTrue(ViewTree.values(of: String.self, in: plain).contains("Task"),
                      "a call named Task drew no ordinary tool row either")
    }

    // MARK: - Navigation

    /// Contract Y4: the chip calls `show(run:in:)` with the **run id** the tree resolves for the
    /// spawning call, not with the `tool_use_id` the call carries.
    func testTheChipCallsShowWithTheRunId() throws {
        let call = Self.call(name: "Agent")
        var tree = AgentRunTree(configHome: InventedItems.stream.configHome,
                                sessionID: InventedItems.stream.sessionID,
                                slug: "_slug_")
        tree.apply(taskStarted: InventedItems.taskStarted(taskID: "task_invented0007",
                                                          toolUseID: call.toolUseID,
                                                          agentType: "an-invented-type"),
                   at: InventedItems.epoch)
        let navigation = CountingAgentNavigation()
        let context = InventedItems.context(agents: navigation,
                                            neighbourhood: TimelineNeighbourhood(items: [.toolCall(call)],
                                                                                 agents: tree))

        let content = AgentChip.content(for: call, in: context)
        XCTAssertTrue(content.canNavigate, "a chip with a tree behind it reported itself unable to navigate")
        XCTAssertEqual(content.runID, "task_invented0007",
                       "the chip resolved \(content.runID ?? "no run id")")
        XCTAssertNotEqual(content.runID, call.toolUseID, "the chip passed the tool_use_id as the run id")

        // The call itself, which is what Y4's counter records.
        context.agents.show(run: try XCTUnwrap(content.runID, "the chip had no run id to navigate with"),
                            in: context.key)
        XCTAssertEqual(navigation.calls, 1, "the seam recorded \(navigation.calls) navigation(s)")
        XCTAssertEqual(navigation.runs, ["task_invented0007"],
                       "the seam was given \(navigation.runs.count) run id(s)")
    }

    /// The other arm, and the ordinary one: **a channel opened from its files has no tree at all** —
    /// every archived channel and every foreign session, which is most of what this app lists
    /// (tracker 187 on `main`). The chip renders from what the call carries and does not navigate,
    /// because `show(run:in:)` takes a run id and there is none to give.
    func testTheChipRendersWithoutATreeAndDoesNotNavigate() {
        let call = Self.call(name: "Agent")
        let navigation = CountingAgentNavigation()
        let context = InventedItems.context(agents: navigation,
                                            neighbourhood: TimelineNeighbourhood(items: [.toolCall(call)],
                                                                                 agents: nil))

        let content = AgentChip.content(for: call, in: context)
        XCTAssertNil(content.runID, "a channel with no tree resolved a run id anyway")
        XCTAssertFalse(content.canNavigate, "a chip with no run id reported itself able to navigate")
        // It still renders: the type, the status and the elapsed time are the call's own.
        XCTAssertEqual(content.agentType, "an-invented-type", "the chip read \(content.agentType ?? "no type")")
        XCTAssertEqual(content.status, .running, "the chip read the status as \(content.status.rawValue)")
        XCTAssertEqual(content.title, "an-invented-type", "the chip reads \(content.title)")
        XCTAssertEqual(navigation.calls, 0, "a chip with no run id navigated \(navigation.calls) time(s)")
    }

    // MARK: - Parallel calls

    /// Parallel `Agent` calls sharing one `message.id` are one "Running N agents" group, not N
    /// chips (§7.3's reducer rule). The floor: two calls in *different* messages stay two rows.
    func testParallelAgentCallsRenderAsOneGroup() {
        let first = Self.call(name: "Agent", id: "toolu_invented0001", messageID: "msg_invented0001")
        let second = Self.call(name: "Agent", id: "toolu_invented0002", messageID: "msg_invented0001")
        let context = InventedItems.context(neighbourhood: TimelineNeighbourhood(items: [.toolCall(first),
                                                                                         .toolCall(second)]))

        let lead = AgentChip.content(for: first, in: context)
        let follower = AgentChip.content(for: second, in: context)
        XCTAssertEqual(lead.groupCount, 2, "the group holds \(lead.groupCount) call(s)")
        XCTAssertTrue(lead.isGroupLead, "the first call by tool_use_id did not lead the group")
        XCTAssertFalse(follower.isGroupLead, "both calls of one message drew the group")
        XCTAssertEqual(lead.title, "Running 2 agents", "the group reads \(lead.title)")

        let apart = Self.call(name: "Agent", id: "toolu_invented0003", messageID: "msg_invented0002")
        let separate = AgentChip.content(for: apart,
                                         in: InventedItems.context(neighbourhood: TimelineNeighbourhood(
                                             items: [.toolCall(first), .toolCall(apart)])))
        XCTAssertEqual(separate.groupCount, 1,
                       "a call in its own message joined a group of \(separate.groupCount)")
    }

    /// **A group's status is its members', not its lead's** (review sweep#3).
    ///
    /// Parallel `Agent` calls in one message draw one row, and the lead draws it. Reading the
    /// lead's own status makes that row a report on one member: a lead that finished while its
    /// siblings work reads *Done* over a group that is still running, and a group with a failed
    /// member reads *Done* over a failure. The elapsed time goes with it — the group ends when its
    /// last member ends, not when the lead did.
    func testAGroupsStatusComesFromEveryMember() {
        let lead = Self.call(name: "Agent", id: "toolu_invented0001", status: .completed, at: 0)
        let running = Self.call(name: "Agent", id: "toolu_invented0002", status: .running, at: 0)
        let live = InventedItems.context(neighbourhood: TimelineNeighbourhood(items: [.toolCall(lead),
                                                                                     .toolCall(running)]))

        let group = AgentChip.content(for: lead, in: live, now: InventedItems.epoch.addingTimeInterval(40))
        XCTAssertTrue(group.isGroupLead, "the finished call did not lead the group, so this proves nothing")
        XCTAssertEqual(group.status, .running,
                       "a group with a working sibling reads \(group.status.rawValue)")
        XCTAssertEqual(group.title, "Running 2 agents", "the group reads \(group.title)")
        XCTAssertEqual(group.headline, "Initializing…",
                       "the group's headline reads \(group.headline) while a sibling is still running")
        XCTAssertEqual(group.elapsed, 40, "a running group's elapsed time is \(group.elapsed ?? -1)s")

        // A failed sibling, with nothing left running.
        let failed = Self.call(name: "Agent", id: "toolu_invented0002", status: .failed,
                               result: .string("an invented refusal"), at: 20)
        let broken = InventedItems.context(neighbourhood: TimelineNeighbourhood(items: [.toolCall(lead),
                                                                                       .toolCall(failed)]))
        let after = AgentChip.content(for: lead, in: broken, now: InventedItems.epoch.addingTimeInterval(40))
        XCTAssertEqual(after.status, ToolCallItem.Status.failed,
                       "a group with a failed sibling reads \(after.status.rawValue)")
        XCTAssertNotEqual(after.headline, "Done",
                          "the group's headline reads Done over a member that failed")
        XCTAssertEqual(after.elapsed, 20,
                       "the group ended with its lead rather than its last member: \(after.elapsed ?? -1)s")

        // All done: the group is done, and it ends when the last of them ended.
        let done = Self.call(name: "Agent", id: "toolu_invented0002", status: .completed, at: 30)
        let settled = AgentChip.content(for: lead,
                                        in: InventedItems.context(neighbourhood: TimelineNeighbourhood(
                                            items: [.toolCall(lead), .toolCall(done)])),
                                        now: InventedItems.epoch.addingTimeInterval(90))
        XCTAssertEqual(settled.status, .completed, "a finished group reads \(settled.status.rawValue)")
        XCTAssertEqual(settled.elapsed, 30, "a finished group ran for \(settled.elapsed ?? -1)s")

        // The floor: a call on its own still reads its own status.
        let alone = Self.call(name: "Agent", id: "toolu_invented0003", status: .completed, at: 0,
                              messageID: "msg_invented0002")
        let solo = AgentChip.content(for: alone,
                                     in: InventedItems.context(neighbourhood: TimelineNeighbourhood(
                                         items: [.toolCall(alone)])),
                                     now: InventedItems.epoch.addingTimeInterval(40))
        XCTAssertEqual(solo.groupCount, 1, "the lone call joined a group of \(solo.groupCount)")
        XCTAssertEqual(solo.status, .completed, "a lone finished call reads \(solo.status.rawValue)")
    }

    // MARK: - Sanitising (round 2, scalpel-3 #2)

    /// **Everything the chip draws is sanitised** (spec §12).
    ///
    /// The chip's title is the call's own `subagent_type` or `description`, and its headline is the
    /// result's first line — all three engine-supplied, all three drawn raw while the description
    /// line beneath them and the surrounding tool output were stripped. A bidi override in an agent
    /// type reverses the rest of the chip's title, a zero-width mark hides a word boundary, and an
    /// ANSI escape in a failure's first line reaches the layout intact. Sanitising happens where
    /// `AgentChipContent` is built, so every reader of it — the title, the badge, the headline and
    /// the description line — gets the stripped value. The text here is invented (§11).
    func testTheChipsTitleAndHeadlineAreSanitised() {
        let call = InventedItems.toolCall("Agent",
                                          id: "toolu_invented0001",
                                          input: .object(["description": .string("an invented\u{200B} errand"),
                                                          "prompt": .string("an invented brief"),
                                                          "subagent_type": .string("an-invented\u{202E}type")]),
                                          result: .string("\u{1B}[31man invented refusal\u{1B}[0m"),
                                          isError: true,
                                          status: .failed,
                                          messageID: "msg_invented0001")
        let context = InventedItems.context(neighbourhood: TimelineNeighbourhood(items: [.toolCall(call)]))
        let content = AgentChip.content(for: call, in: context)

        let carried = [content.agentType ?? "", content.description, content.title, content.headline]
            .filter { $0.unicodeScalars.contains(where: TextSanitiser.isStripped) }
        XCTAssertEqual(carried.count, 0,
                       "\(carried.count) of the chip's 4 derived string(s) still carry a stripped scalar")
        XCTAssertEqual(content.title, "an-inventedtype", "the chip's title is \(content.title.unicodeScalars.count) scalar(s)")
        XCTAssertEqual(content.description, "an invented errand",
                       "the chip's description is \(content.description.unicodeScalars.count) scalar(s)")
        // The escape's ESC is gone; its printable remainder stays as text, which is exactly the
        // strip set parity §41.7 names — the sanitiser removes control and format scalars, it does
        // not parse ANSI sequences.
        XCTAssertEqual(content.headline, "Error: [31man invented refusal[0m",
                       "the chip's headline is \(content.headline.unicodeScalars.count) scalar(s)")

        // The four strings above are exactly the ones `AgentChipRow` hands to a `Text` or to the
        // frame's badge, and they are asserted here rather than off the drawn body because the row
        // builds them inside `RowFrame`'s stored `@ViewBuilder` closure, which reflection cannot
        // enter (TimelineFixtureGateTests states the same limit). Sanitising at the content is what
        // makes every reader of it — including the ones a test cannot reach — carry the same value.
    }

    // MARK: - Fixtures

    private static func call(name: String, id: String = "toolu_invented0001",
                             status: ToolCallItem.Status = .running,
                             result: JSONValue? = nil,
                             at offset: TimeInterval = 0,
                             messageID: String? = "msg_invented0001") -> ToolCallItem {
        InventedItems.toolCall(name,
                               id: id,
                               input: .object(["description": .string("an invented errand"),
                                               "prompt": .string("an invented brief"),
                                               "subagent_type": .string("an-invented-type")]),
                               result: result,
                               status: status,
                               messageID: messageID,
                               at: offset)
    }

}

/// Contract Y4's seam, counting. It records the run ids it was given — invented strings, never a
/// path or a session (§11).
@MainActor
final class CountingAgentNavigation: AgentNavigating {
    private(set) var calls = 0
    private(set) var runs: [AgentRunID] = []
    func show(run: AgentRunID, in key: ChannelKey) {
        calls += 1
        runs.append(run)
    }
}
