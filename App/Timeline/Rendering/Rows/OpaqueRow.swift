import Foundation
import SwiftUI
import FleetKit

/// §6.3's row for a frame this host does not model: collapsed, named by whatever the frame did
/// carry, with its JSON behind a disclosure.
///
/// **Never nothing, and never fatal.** An unmodelled frame that drew no row would make the timeline
/// quietly disagree with the transcript, and one that trapped would take the window down for a field
/// the engine added in a point release.
struct OpaqueRow: View {

    let item: OpaqueItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        RowFrame(author: "Unrecognized event", badge: item.type, timestamp: item.timestamp) {
            Button {
                context?.collapse.toggle(item.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    Text(OpaqueRow.label(of: item)).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(TextSanitiser.sanitise(OpaqueRow.json(of: item)))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isExpanded: Bool { context?.collapse.isCollapsed(item.id) ?? false }

    /// The frame's own JSON, canonicalised. A frame that cannot be re-encoded shows its reason
    /// rather than nothing, for the same reason this row exists at all.
    static func json(of item: OpaqueItem) -> String {
        guard let data = try? item.value.canonicalData(), let text = String(data: data, encoding: .utf8) else {
            return item.reason
        }
        return text
    }

    static func label(of item: OpaqueItem) -> String {
        let name = [item.type, item.subtype].compactMap { $0 }.joined(separator: "/")
        return name.isEmpty ? item.reason : "\(name) · \(item.reason)"
    }
}
