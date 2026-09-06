import SwiftUI
import AfleetCore
import FleetKit

/// The conversation column: a channel's header and its timeline (spec §8).
///
/// **A stub. Task 7 fills it, and this file is the only one Task 7's view work opens.** The type
/// name and the initialiser below are final; `RootView` calls this and no later task edits
/// `RootView`. Task 7 reaches its per-channel timeline through `app.timelines`, the single
/// app-scoped `ChannelTimelineRegistry` it adds to `AppModel`, and never constructs one here.
struct ChannelColumnView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        if let row {
            PlaceholderColumn(title: row.title,
                              detail: "This channel's timeline renders here.")
        } else {
            PlaceholderColumn(title: "No channel selected",
                              detail: "Pick a channel in the sidebar, or press Command-K.")
        }
    }

    /// The selected row, resolved through the browser rather than carried, so a row that changed
    /// since the click is the one drawn.
    private var row: ChannelRow? {
        guard let session = shell.focus.session else { return nil }
        return app.browser?.row(session)
    }
}
