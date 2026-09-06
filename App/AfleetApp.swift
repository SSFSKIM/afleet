import SwiftUI
import PanelHostAPI

/// The application entry point: one window routed on `AppModel.route`, the Settings scene the
/// system's Settings… menu item opens, and the shell's keyboard shortcuts.
@main
struct AfleetApp: App {
    @State private var model = AppModel()

    /// Spike S-C5-1, on an environment variable nothing but the spike sets. An ordinary launch
    /// reads one variable and does nothing else here.
    init() { NotificationSpike.runIfRequested() }

    /// What the window is looking at. It lives here rather than inside a view because `commands`
    /// is a scene builder: the menu items below are constructed outside every view body and can
    /// only move state that is owned above the window.
    @State private var shell = ShellModel()

    var body: some Scene {
        WindowGroup("afleet") {
            RootView(model: model, shell: shell)
        }
        .commands { shellCommands }

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

    /// §8.7's shortcuts, the four C5 owns.
    ///
    /// **Cmd+, is absent on purpose and is not missing.** SwiftUI gives a `Settings` scene the
    /// standard *Settings…* item under the application menu with Cmd+, already bound; declaring a
    /// second one would put two items in the menu bar competing for one key.
    ///
    /// Esc, Cmd+Enter, Shift+Tab and Cmd+Shift+Esc belong to the composer and are C6's;
    /// Cmd+Shift+T is C7's. None is declared here, so neither child inherits a key already taken.
    @CommandsBuilder
    private var shellCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Quick Switcher…") { shell.presentSwitcher() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Activity") { shell.showActivity() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(PanelTabID.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.defaultTitle) { shell.selectPanelTab(at: index + 1) }
                    .keyboardShortcut(Self.digit(index + 1), modifiers: .command)
            }
        }
    }

    /// `KeyEquivalent` for 1…7. The tab set is closed at seven cases by contract X7, so the
    /// character always exists; a wider set would need a second modifier rather than a second digit.
    private static func digit(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(number)"))
    }
}
