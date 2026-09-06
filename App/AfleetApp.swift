import SwiftUI

/// The application entry point: one window routed on `AppModel.route`, and the Settings scene the
/// system's Settings… menu item opens.
@main
struct AfleetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("afleet") {
            RootView(model: model)
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
