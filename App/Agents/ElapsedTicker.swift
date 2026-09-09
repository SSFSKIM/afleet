import Foundation
import SwiftUI

/// How long one run has been going, ticked **at the leaf** (child spec D7).
///
/// §8.8 requires elapsed to be ticked locally from `task_started`, because `task_progress` is
/// tool-paced and a run that is thinking sends none. The obvious implementation — one timer that
/// invalidates the tree every second — would put a periodic layout pass on a surface whose sibling
/// column is the S7 budget's tenant, and it would do it for every node whether or not any of them
/// is running.
///
/// So the tick lives here, in a view small enough that invalidating it costs one label: the tree's
/// row identities, its order and its node values change only when the tree itself moved. Nothing
/// above this view reads the clock, which is the property `AgentTreeGateTests` asserts.
///
/// `TimelineView(.periodic)` rather than a `Timer`: SwiftUI owns the schedule, stops it when the
/// view is off screen and tears it down with the view, so a collapsed branch or a closed panel
/// leaves nothing running. A finished run has a fixed span and is drawn with no schedule at all.
struct ElapsedTicker: View {

    let origin: Date
    /// When the run ended, or nil while it is going. A finished run's span never moves.
    let endedAt: Date?

    var body: some View {
        if let endedAt {
            label(at: endedAt)
        } else {
            TimelineView(.periodic(from: origin, by: 1)) { context in
                label(at: context.date)
            }
        }
    }

    private func label(at now: Date) -> Text {
        Text(Self.label(origin: origin, now: now))
    }

    /// The span as it reads, from a whole number of seconds. Pure and static, so a test can watch
    /// one tick move it without a render pass — and so the only place a clock is read for this tree
    /// is inside this view.
    ///
    /// It states a duration and nothing else (§6.3, §11).
    static func label(origin: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(origin)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
