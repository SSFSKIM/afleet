import SwiftUI
import FleetKit

/// Activity (spec §5): one row per decision, rate-limit notice and authentication problem across
/// the whole fleet, with an inline answer for a plain permission ask.
///
/// **A stub. Task 6 fills it, and this file is the only one Task 6's view work opens.** The type
/// name and the initialiser below are final: `RootView` calls this and no later task edits
/// `RootView`, so the three arguments are the whole surface a filled Activity view may reach for —
/// `app` for the models the composition root owns (`browser`, and whatever Task 6 hangs off
/// `AppModel`), `shell` for what the window is looking at, and `workspace` for the fleet itself.
struct ActivityView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        PlaceholderColumn(title: "Activity",
                          detail: "Decisions, rate limits and authentication problems across the fleet arrive here.")
    }
}

/// The empty state the three column stubs share until their tasks land. One type so that three
/// files do not each grow their own, and so removing it is a compile error in every place that
/// still has one.
struct PlaceholderColumn: View {

    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
