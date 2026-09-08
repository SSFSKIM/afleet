import Foundation
import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - What a chip says

/// One `Agent` call, as the chip draws it (child spec §9).
///
/// **The tool is named `Agent`, not `Task`.** The composite and §8.8 both speak of "Agent calls"
/// while some of the engine's own docs name the spawning tool `Task`; the fixtures and the parity
/// map's tool tables carry `Agent`, and a chip keyed on the wrong string renders nothing at all.
struct AgentChipContent: Equatable {

    /// From the call's own input — `subagent_type` — and not from the tree, which is usually absent.
    var agentType: String?
    var description: String

    /// The unmatched-`tool_use` rule of §8: `set_in_progress_tool_use_ids` never reaches the wire
    /// (parity §41.16.2), so running is exactly a call with no result yet.
    var status: ToolCallItem.Status

    /// The span from the call to its result, or to now while it is still running.
    var elapsed: TimeInterval?

    /// The run `AgentNavigating.show(run:in:)` would be given — `nil` for a channel with no tree.
    ///
    /// A nil run id is not a failure and not a placeholder: it is what a channel opened from its
    /// files has, which is every archived channel and every foreign session (tracker 187). The chip
    /// renders and does not navigate, because a fabricated id would land C6.4 on a node that does
    /// not exist.
    var runID: AgentRunID?

    /// How many `Agent` calls share this one's `message.id`. Parallel calls the model issued in one
    /// message are one group row, not N chips (§7.3's reducer rule).
    var groupCount: Int = 1

    /// Whether this call is the one that draws the group. The first by `tool_use_id` in sorted
    /// order, so the choice does not depend on which row the table happened to build first.
    var isGroupLead: Bool = true

    var canNavigate: Bool { runID != nil }

    /// `Running 2 agents` for a group, else the run's own description.
    var title: String {
        if groupCount > 1 && status == .running { return "Running \(groupCount) agents" }
        if groupCount > 1 { return "\(groupCount) agents" }
        if let agentType, !agentType.isEmpty { return agentType }
        return description.isEmpty ? "Agent" : description
    }
}

enum AgentChip {

    /// The chip for one call, read from the call itself and from the neighbourhood around it.
    static func content(for call: ToolCallItem, in context: TimelineRenderContext?,
                        now: Date = Date()) -> AgentChipContent {
        var type: String?
        var description = ""
        if case .agent(let input) = call.input {
            type = input.subagentType
            description = input.description
        }
        let siblings = group(of: call, in: context)
        var elapsed: TimeInterval?
        if let at = call.timestamp {
            elapsed = max(0, (call.status == .running ? now : (endedAt(of: call) ?? now)).timeIntervalSince(at))
        }
        return AgentChipContent(agentType: type,
                                description: description,
                                status: call.status,
                                elapsed: elapsed,
                                runID: context?.neighbourhood.agents?.node(withToolUse: call.toolUseID)?.id,
                                groupCount: siblings.count,
                                isGroupLead: siblings.first == call.toolUseID)
    }

    /// The `tool_use_id`s of every `Agent` call sharing this one's `message.id`, sorted.
    ///
    /// A call with no `message.id` is its own group: two calls the host cannot prove were issued
    /// together are two rows, which is the safe direction to be wrong in.
    static func group(of call: ToolCallItem, in context: TimelineRenderContext?) -> [String] {
        guard let messageID = call.messageID, let context else { return [call.toolUseID] }
        let siblings = context.neighbourhood.toolCalls.values
            .filter { $0.name == "Agent" && $0.messageID == messageID }
            .map(\.toolUseID)
        return siblings.isEmpty ? [call.toolUseID] : siblings.sorted()
    }

    /// When a finished call's result landed. The item carries the call's instant, and the result
    /// updates the item in place, so the honest answer for a finished call with no separate
    /// timestamp is the item's own.
    private static func endedAt(of call: ToolCallItem) -> Date? { call.timestamp }
}

// MARK: - The chip

/// The row an `Agent` call draws: a compact chip with the agent's type, its status and its elapsed
/// time, which navigates to the run when there is a run id to navigate to.
struct AgentChipRow: View {

    let item: ToolCallItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        let content = AgentChip.content(for: item, in: context)
        // Parallel calls in one message are one row: the lead draws the group and the others draw
        // nothing, rather than the table showing the same group N times.
        if content.groupCount > 1 && !content.isGroupLead {
            EmptyView()
        } else {
            RowFrame(author: "Agent", badge: content.agentType, timestamp: item.timestamp) {
                Button {
                    if let run = content.runID, let context { context.agents.show(run: run, in: context.key) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.caption2)
                        Text(content.title).font(.caption.weight(.medium))
                        Text(ToolResultForms.form(for: item).headline)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let elapsed = content.elapsed {
                            Text("\(Int(elapsed.rounded()))s")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                // With no tree there is no run id, and a chip that navigated to a fabricated one
                // would land another leaf on a node that does not exist (§9).
                .disabled(!content.canNavigate)
                if !content.description.isEmpty && content.groupCount == 1 {
                    Text(TextSanitiser.sanitise(content.description))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
