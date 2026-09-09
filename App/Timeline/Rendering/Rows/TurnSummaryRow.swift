import Foundation
import SwiftUI
import FleetKit

/// The turn's own line: how long it took, what it cost, why it stopped, and what was denied (§8).
/// Folded by default — a reader opens a turn summary deliberately.
struct TurnSummaryRow: View {

    let item: TurnSummaryItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        RowFrame(author: "Turn", badge: item.stopReason, timestamp: item.timestamp) {
            Button {
                context?.collapse.toggle(item.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text(TurnSummaryRow.headline(of: item)).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                let denials = TurnSummaryRow.denials(of: item)
                if denials > 0 {
                    Text("\(ToolResultForms.count(denials, "permission denial")) this turn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.subtype).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var isExpanded: Bool { context?.collapse.isCollapsed(item.id) ?? false }

    static func headline(of item: TurnSummaryItem) -> String {
        let seconds = Double(item.durationMs) / 1000
        let cost = String(format: "$%.4f", item.costUSD)
        return "\(ToolResultForms.count(item.numTurns, "turn")) · \(String(format: "%.1fs", seconds)) · \(cost)"
    }

    static func denials(of item: TurnSummaryItem) -> Int {
        item.permissionDenials?.arrayValue?.count ?? 0
    }
}
