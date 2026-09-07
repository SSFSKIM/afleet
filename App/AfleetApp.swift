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

    /// What the window is looking at. It lives on `AppModel` rather than in this scene because
    /// Activity's notifications have to know which channel is in view whether or not the Activity
    /// view is on screen, and the model that decides them is built beside `AppModel`. One owner;
    /// the menu items below move it and the window reads it.
    private var shell: ShellModel { model.shell }

    var body: some Scene {
        WindowGroup("afleet") {
            RootView(model: model, shell: shell)
                // The sidebar's unread badge is Activity's answer, and `RootView` is closed to
                // further edits, so the model reaches `ChannelRowView` through the environment
                // rather than through four more initialiser arguments.
                .environment(model)
        }
        .commands { shellCommands }

        // One window per popped-out panel tab (spec §7). Keyed by tab and channel rather than by
        // the context, which holds capabilities that are not `Codable`; the scene resolves the
        // context from the host by that key, which is what keeps the window on the channel it was
        // popped from when the main window moves on.
        WindowGroup(for: PoppedOutPanel.self) { $panel in
            PoppedOutPanelScene(app: model, panel: panel)
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
