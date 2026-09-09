import Foundation
import SwiftUI
import FleetKit

/// The compaction divider (§8): what triggered it, and whether it was a hard truncation.
///
/// §7.3's reopen behaviour — what a channel shows above the boundary once the earlier records are
/// loaded — is C3's and needs nothing here: this row draws a boundary the projection already placed.
struct CompactBoundaryRow: View {

    let item: CompactBoundaryItem

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(CompactBoundaryRow.label(of: item))
                .font(.caption2)
                .foregroundStyle(item.hardTruncation ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    static func label(of item: CompactBoundaryItem) -> String {
        let trigger = item.trigger ?? "unstated"
        let tokens = [item.preTokens, item.postTokens]
        guard let pre = tokens[0], let post = tokens[1] else {
            return item.hardTruncation ? "Truncated (\(trigger))" : "Compacted (\(trigger))"
        }
        let head = item.hardTruncation ? "Truncated" : "Compacted"
        return "\(head) (\(trigger)) · \(pre) → \(post) tokens"
    }
}
