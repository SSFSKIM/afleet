import Foundation
import SwiftUI
import FleetKit

// MARK: - A background task's row, and contract Y2's second host

/// The `taskRun` row: what the task is, what it is doing, and how long it has been doing it.
///
/// **It is a host under contract Y2.** §8.4's task card and its two control requests (`stop_task`
/// and `background_tasks {tool_use_id}` with the `{backgrounded: false}` rule) are answer-shaped
/// mappings C6.3 owns — but `DecisionItem.Kind` has no `task` case, so a task is not a decision: it
/// is `TimelineItem.taskRun`, which is this leaf's row kind. C6.3 builds `TaskCardView` and this row
/// mounts it exactly as the `decision` slot mounts `DecisionCardView`; until both leaves are on
/// `main` the seam below draws C6.1's own row and the two meet in one call.
struct TaskRunRow: View {

    let item: TaskRunItem

    var body: some View {
        RowFrame(author: TaskRunRow.name(of: item), badge: item.status.rawValue, timestamp: item.timestamp) {
            TaskCardSeam(item: item)
        }
    }

    /// The task's own name: the agent type where it has one, else the engine's kind.
    static func name(of item: TaskRunItem) -> String {
        item.agentType ?? item.kind.wire
    }

    /// The active form parity §20.8 states — what the row says the task is *doing*, not what it is.
    static func activeForm(of item: TaskRunItem) -> String {
        switch item.status {
        case .running: item.description.isEmpty ? "Running…" : item.description
        case .completed: item.summary ?? "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// **The seam named for C6.3's `TaskCardView`.** One call site, one row: when that leaf lands, the
/// body below becomes `TaskCardView(item:)` and nothing else about this row changes.
struct TaskCardSeam: View {

    let item: TaskRunItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TextSanitiser.sanitise(TaskRunRow.activeForm(of: item)))
                .font(.caption)
                .lineLimit(2)
            if let output = item.outputFile {
                FileLinkLabel(path: output.path)
            }
        }
    }
}
