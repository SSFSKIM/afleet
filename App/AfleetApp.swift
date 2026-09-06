import SwiftUI
import PanelHostAPI

/// The application entry point: one window routed on `AppModel.route`, the Settings scene the
/// system's Settings… menu item opens, and the shell's keyboard shortcuts.
@main
struct AfleetApp: App {
    @State private var model = AppModel()

    /// What the window is looking at. It lives here rather than inside a view because `commands`
    /// is a scene builder: the menu items below are constructed outside every view body and can
    /// only move state that is owned above the window.
    @State private var shell = ShellModel()

    var body: some Scene {
        WindowGroup("afleet") {
            RootView(model: model, shell: shell)
        }

        Settings {
            if let readout = model.settingsReadout {
                SettingsView(readout: readout)
            } else {
                Text("Settings become available once afleet has reached a workspace.")
                    .foregroundStyle(.secondary)
                    .padding(40)
                    .frame(width: 420)
            }
        }
    }
}
