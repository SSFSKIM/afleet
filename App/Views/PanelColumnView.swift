import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// The panel column: contract X7's tab bar and the selected tab's pane (spec §7).
///
/// **A stub. Task 8 fills it, and this file is the only one Task 8's view work opens.** The type
/// name and the initialiser below are final; `RootView` calls this and no later task edits
/// `RootView`. Which tab is selected is `shell.panelTab`, because Cmd+1…7 is a shell shortcut and
/// the menu item that carries it lives above the window — so the panel host reads the selection
/// rather than owning it.
struct PanelColumnView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        PlaceholderColumn(title: shell.panelTab.defaultTitle,
                          detail: "The panel host renders contract X7's tabs here.")
    }
}
