import Foundation
import SwiftUI
import FleetKit

// MARK: - The one-line rows

/// A hook that ran: which event fired it, which hook it was, and how it ended (§8).
struct HookRunRow: View {

    let item: HookRunItem

    var body: some View {
        RowFrame(author: item.event, badge: item.outcome, timestamp: item.timestamp) {
            HStack(spacing: 6) {
                Text(TextSanitiser.sanitise(item.hookName)).font(.caption).lineLimit(1)
                if let code = item.exitCode, code != 0 {
                    Text("exit \(code)").font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }
}

/// A notification the engine raised.
///
/// The **`timeout_ms: 2147483647` sentinel** parity §41.15.5 names is not a twenty-four-day timer:
/// C3 folds notifications into the overlay and this row draws whichever ones are there, so a
/// sentinel timeout is a notice that stays until the overlay drops it and never a scheduled wake.
/// Dedupe by `key` is first-writer-wins and is the reducer's, for the same reason.
struct NotificationRow: View {

    let item: NotificationItem

    var body: some View {
        RowFrame(author: NotificationRow.author(of: item), timestamp: item.timestamp) {
            Text(TextSanitiser.sanitise(item.text.isEmpty ? item.key : item.text))
                .font(.caption)
                .foregroundStyle(item.level == "error" ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func author(of item: NotificationItem) -> String {
        item.fileOnly ? "Notice (file only)" : "Notice"
    }
}
