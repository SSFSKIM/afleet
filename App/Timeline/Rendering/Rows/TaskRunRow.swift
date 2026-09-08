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

    /// Read here and handed down, so the seam below is a value a test can construct and drive: a
    /// property wrapper reads its default outside a render pass.
    @Environment(\.timelineContext) private var context

    var body: some View {
        RowFrame(author: TaskRunRow.name(of: item), badge: item.status.rawValue, timestamp: item.timestamp) {
            TaskCardSeam(item: item, context: context)
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

/// **The seam named for the task card, now filled** (contract Y2's second host, spec D15).
///
/// One call site, one row. With a context it draws `TaskCardView` — §8.4's card, whose *Stop* and
/// *Move to background* are `stop_task` and `background_tasks` control requests and never answers —
/// and with none it draws this leaf's own reading, which is what an archived channel and a row
/// outside the timeline's subtree get: there is nothing to send a request through, and a button
/// that went nowhere would say the task had been stopped.
///
/// The output file's link is drawn either way, because a task's output is readable whether or not
/// the task can still be acted on.
struct TaskCardSeam: View {

    let item: TaskRunItem
    let context: TimelineRenderContext?

    /// The card's model, built once from the context. `@State` for the decision row's reason: it
    /// carries the banner and the in-flight flag, and a fresh one per body evaluation would blank
    /// both the moment anything else on the channel streamed.
    @State private var card: TaskCardModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let card {
                // Pinned to the same identity the model is keyed by. `TaskCardView` takes its model
                // into `@State`, which SwiftUI carries across a body evaluation: without this, a
                // replaced model would be built and then ignored.
                TaskCardView(model: card).id(TaskCardSeam.identity(of: item))
            } else {
                Text(TextSanitiser.sanitise(TaskRunRow.activeForm(of: item)))
                    .font(.caption)
                    .lineLimit(2)
            }
            if let output = item.outputFile {
                FileLinkLabel(path: output.path, context: context)
            }
        }
        .task(id: TaskCardSeam.identity(of: item)) {
            card = context?.makeTaskCard(item)
        }
    }

    /// What makes this the *same* card: the task, and the status the card's actions are derived
    /// from.
    ///
    /// Keyed by the task so a row reused for a different run does not go on holding the first run's
    /// model — its *Stop* would stop the task the reader left. Keyed by the status as well because
    /// the model takes the item by value and the fold's later ones would otherwise never reach it,
    /// so a finished task would go on reading *Running* and offering *Stop*. Not keyed by the whole
    /// item: `task_progress` arrives repeatedly while a run is live, and rebuilding on each one
    /// would drop a refusal banner and an in-flight request the reader is watching.
    static func identity(of item: TaskRunItem) -> String {
        "\(item.taskID)#\(item.status.rawValue)"
    }
}
