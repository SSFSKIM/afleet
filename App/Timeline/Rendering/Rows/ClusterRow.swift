import Foundation
import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - What a cluster says

/// A fold over several tool calls (child spec §9).
struct ClusterContent: Equatable {

    /// The engine's own label, from a `tool_use_summary` frame.
    var label: String?

    var count: Int

    /// The span from the first call the cluster names to the last. Nil when fewer than two of its
    /// members carry an instant.
    var elapsed: TimeInterval?

    /// `Searched the timeline package` when the engine labelled it; `3 tool calls · 4s` when it did
    /// not, which is the ordinary case — **no committed fixture carries a `tool_use_summary` frame**
    /// (tracker 128), so the unlabelled arm is what this app shows today.
    var title: String {
        if isLabelled, let label { return label }
        let calls = ToolResultForms.count(count, "tool call")
        guard let elapsed, elapsed >= 1 else { return calls }
        return "\(calls) · \(Int(elapsed.rounded()))s"
    }

    var isLabelled: Bool { !(label ?? "").isEmpty }
}

enum ClusterRowContent {

    static func content(for cluster: ToolClusterItem, members: [ToolCallItem]) -> ClusterContent {
        let stamps = members.compactMap(\.timestamp).sorted()
        var elapsed: TimeInterval?
        if let first = stamps.first, let last = stamps.last, stamps.count > 1 {
            elapsed = last.timeIntervalSince(first)
        }
        return ClusterContent(label: cluster.label,
                              count: max(cluster.toolUseIDs.count, members.count),
                              elapsed: elapsed)
    }
}

/// The cluster row: one line, folded, expanding to one row per call it names.
struct ClusterRow: View {

    let item: ToolClusterItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        let members = context?.neighbourhood.members(of: item) ?? []
        let content = ClusterRowContent.content(for: item, members: members)
        RowFrame(author: "Tools", timestamp: item.timestamp) {
            Button {
                context?.collapse.toggle(item.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text(content.title).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(members, id: \.toolUseID) { member in
                    ToolResultBody(id: member.id, form: ToolResultForms.form(for: member))
                        .padding(.leading, 12)
                }
            }
        }
    }

    private var isExpanded: Bool { context?.collapse.isCollapsed(item.id) ?? false }
}
