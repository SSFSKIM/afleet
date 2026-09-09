import SwiftUI
import PanelHostAPI
import Workbench

/// The application entry point: one window routed on `AppModel.route`, the Settings scene the
/// system's Settings… menu item opens, and the shell's keyboard shortcuts.
@main
struct AfleetApp: App {
    @State private var model = AppModel()

    /// §7.4's *Quit* clause, and the only reason this scene carries a delegate: `applicationShouldTerminate`
    /// is `NSApplicationDelegate`'s and SwiftUI publishes it nowhere else. The hook itself, the
    /// dialog and the termination order all live in `App/Header/QuitGuard.swift`.
    @NSApplicationDelegateAdaptor(AfleetQuitDelegate.self) private var quitDelegate

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
                // Where the keyboard is pointed, for the composer's shortcut bar (tracker 350).
                // The object rather than its boolean, so a focus move re-evaluates the one view
                // that reads it instead of the whole window.
                .environment(shell.keyboard)
                .task { shell.keyboard.startObserving() }
                // The guard is built at quit time, not here: `bindWorkspace` may not have run when
                // the window first appears, and a guard captured before it would hold no fleet.
                .task { quitDelegate.makeGuard = { QuitGuard.forApp(model) } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    shell.isApplicationActive = NSApplication.shared.isActive
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    shell.isApplicationActive = NSApplication.shared.isActive
                }
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
            AppSettingsView(model: model)
        }
    }

    /// §8.7's shortcuts: the four C5 owns, C7.4's Cmd+Shift+T and C7.5's Cmd+S.
    ///
    /// **Cmd+, is absent on purpose and is not missing.** SwiftUI gives a `Settings` scene the
    /// standard *Settings…* item under the application menu with Cmd+, already bound; declaring a
    /// second one would put two items in the menu bar competing for one key.
    ///
    /// Esc, Cmd+Enter, Shift+Tab and Cmd+Shift+Esc belong to the composer and are C6's. None is
    /// declared here, so that child does not inherit a key already taken.
    ///
    /// **Cmd+Shift+T is declared here and not inside the Terminal panel**, because a shortcut
    /// declared in the panel's own view would only work while the Terminal tab was already showing,
    /// which is not what a user pressing it from the Thread tab means.
    @CommandsBuilder
    private var shellCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Quick Switcher…") { shell.presentSwitcher() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Activity") { shell.showActivity() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("New Terminal Pane") { Self.openTerminalPane(host: model.panels) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // **Over the tabs the panel host says this channel can show, not over `allCases`.**
            // Cmd+N is the Nth *registered and available* tab (X7, gate G4a), so the item that
            // carries Cmd+2 has to be labelled with the tab Cmd+2 selects — indexing `allCases`
            // here wrote a name beside a key that would select something else. When the window is
            // on Activity, or on a channel with no context, the list is empty and the menu offers
            // no panel shortcuts, which is honest: there is nothing for them to select.
            ForEach(Array(model.panels.mainWindowTabs.enumerated()), id: \.element) { index, tab in
                Button(model.panels.title(for: tab)) { shell.selectPanelTab(at: index + 1) }
                    .keyboardShortcut(Self.digit(index + 1), modifiers: .command)
            }
        }
        // Cmd+S for the Files panel (C7.5 Design §7; §8.7's list gains it by Parent revision 1,
        // which the architect accepted). W4's editor vocabulary is closed, so Monaco cannot report
        // the key press and the host owns it: this is the same action the panel's own *Save*
        // button performs. Offered only while the window is showing Files over a dirty buffer, and
        // the disabled state resolves a session the host already holds rather than creating one.
        //
        // It sits at `.saveItem` and not beside the panel shortcuts above, because that placement
        // is what puts *Save* in the **File** menu, where every macOS user reaches for it. The
        // group above is the View region; a Save item there carries the right key and stands under
        // the wrong heading.
        //
        // **It is aimed at the key window**, which is what the focused scene value below carries:
        // a popped-out Files panel holds a channel of its own and never touches the main window's
        // selection, so a resolution from that selection alone saved another window's channel, or
        // was disabled over a dirty buffer the user was looking at (tracker 243).
        CommandGroup(after: .saveItem) {
            FilesSaveButton(model: model)
        }
    }

    /// Cmd+Shift+T (§8.7): a new shell pane in the channel the window is showing.
    ///
    /// **A static function taking its collaborator**, the precedent `PanelColumnView
    /// .resolvePendingPanelIndex` set: a `commands` closure is outside every view body and cannot
    /// be reached by a test, so what the menu item calls is this and the test calls the same thing
    /// without a window.
    ///
    /// It grows no protocol member. `PanelHost.session(for:context:)` already vends the channel's
    /// panel session and the Terminal tab's session is the object that owns its panes, so asking
    /// that object for a pane is the whole of the action.
    ///
    /// **With no focused channel it does nothing**, on the same rule as Cmd+1…7: a key combination
    /// is not an assertion, and there is no channel for a pane to belong to. A tab that is not
    /// registered lands in the same place — the host vends a session that is not the panel's, the
    /// cast fails, and nothing moves.
    static func openTerminalPane(host: PanelHostModel) {
        guard let channel = host.selectedChannel, let context = host.context(for: channel) else { return }
        guard let session = host.session(for: .terminal, context: context) as? TerminalPanelSession else { return }
        host.select(.terminal)
        session.openShellPane()
    }

    /// `KeyEquivalent` for 1…7. The tab set is closed at seven cases by contract X7, so the
    /// character always exists; a wider set would need a second modifier rather than a second digit.
    private static func digit(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(number)"))
    }
}

/// The *Save* item, as a view of its own so it can read the focused scene value.
///
/// `@FocusedValue` resolves against the key window's scene, so this is nil while the main window is
/// key and carries the pop-out's identity while one of its windows is. Everything the item decides
/// — the target and whether it is offered at all — follows from that one value, and both questions
/// are answered by `AppModel` so they can be asserted without a window.
private struct FilesSaveButton: View {

    let model: AppModel
    @FocusedValue(\.poppedOutPanel) private var focused: PoppedOutPanel?

    var body: some View {
        Button("Save") { model.saveFilesPanel(inFocused: focused) }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.canSaveFiles(inFocused: focused))
    }
}

/// Which popped-out panel window is key, for the commands that have to resolve against it rather
/// than against the main window's selection. `PoppedOutPanelScene` publishes it; the main window
/// publishes nothing, so the value is absent exactly when the main window is the key one.
private struct PoppedOutPanelFocusKey: FocusedValueKey {
    typealias Value = PoppedOutPanel
}

extension FocusedValues {
    var poppedOutPanel: PoppedOutPanel? {
        get { self[PoppedOutPanelFocusKey.self] }
        set { self[PoppedOutPanelFocusKey.self] = newValue }
    }
}
