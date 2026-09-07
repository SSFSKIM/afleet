import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// The panel column: contract X7's tab bar and the selected tab's pane (spec §7).
///
/// Which tab is selected is `shell.panelTab`, because Cmd+1…7 is a shell shortcut and the menu item
/// that carries it lives above the window — so the host is *told* the selection rather than owning
/// it. What the host owns is everything below the selection: the registered tabs, the per-channel
/// sessions, the context and its capabilities, and the link routing.
///
/// The context is resolved from `app.panels` by the selected channel's key, and never built here.
/// The host caches one per channel, so the tab this column draws and a popped-out window drawing
/// the same channel hold the same capabilities — in particular the same recent-URL feed.
struct PanelColumnView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let row = Self.channel(shell: shell, browser: app.browser),
               let cwd = row.cwd,
               let context = app.panels.context(for: row.key, cwd: cwd) {
                PanelTabColumn(host: app.panels, shell: shell, context: context)
            } else {
                PlaceholderColumn(title: shell.panelTab.defaultTitle,
                                  detail: "Pick a channel in the sidebar to give the panel a context.")
            }
        }
        .onAppear {
            // The one place SwiftUI's window action is reachable from. The host records a pop-out
            // whether or not this is set; this is what makes the window appear.
            app.panels.presentWindow = { panel in openWindow(value: panel) }
        }
        .task(id: Self.channel(shell: shell, browser: app.browser)?.key) {
            app.panels.focusChannel(Self.channel(shell: shell, browser: app.browser)?.key)
        }
    }

    /// The channel the main window is looking at, resolved through the browser so a row that
    /// changed since the click is the one drawn.
    ///
    /// A static function rather than a computed property because it is the main window's half of
    /// G4c — a popped-out window keeps its channel while this one moves on — and that comparison
    /// has to be assertable without a window.
    static func channel(shell: ShellModel, browser: FleetBrowserModel?) -> ChannelRow? {
        guard let session = shell.focus.session else { return nil }
        return browser?.row(session)
    }

    /// Resolves a pending Cmd+N against the channel in view: the host indexes one-based over
    /// `available(for:)`, and the shell's selection follows whatever it named.
    ///
    /// **This is the whole of the keyboard half of G4a, and it is a function for that reason.** The
    /// shortcut is declared in a `Scene`'s `commands`, above the window, where no `ChannelContext`
    /// exists; the context lives here. A line that existed only inside an `onChange` could not be
    /// asserted without a window, and this child has already recorded once what that costs — so the
    /// modifier below is one call to this, and the test is the same call.
    ///
    /// Returns the tab it selected, or nil when the index names none — which is the ordinary
    /// outcome of Cmd+5 on a channel showing two tabs, and changes nothing.
    @discardableResult
    static func resolvePendingPanelIndex(shell: ShellModel, host: PanelHostModel,
                                        context: ChannelContext) -> PanelTabID? {
        guard let index = shell.takePendingPanelIndex() else { return nil }
        guard let chosen = host.tab(at: index, in: context) else { return nil }
        host.selectIndex(index, in: context)
        shell.panelTab = chosen
        return chosen
    }
}

/// The tab bar and the selected tab's pane, for one channel.
private struct PanelTabColumn: View {

    let host: PanelHostModel
    @Bindable var shell: ShellModel
    let context: ChannelContext

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if available.contains(shell.panelTab) {
                host.view(for: shell.panelTab, context: context)
            } else {
                PlaceholderColumn(title: shell.panelTab.defaultTitle,
                                  detail: "This tab is not available for this channel.")
            }
        }
        // The host's own selection follows the shell's, so `available(for:)` and `selectIndex` —
        // which C6 and C7 call through the protocol — agree with what the window is showing.
        .task(id: shell.panelTab) { host.select(shell.panelTab) }
        // What the menu above the window is allowed to write beside Cmd+1…7. In a task rather than
        // in `body`, because `mainWindowTabs` is observed.
        .task(id: available) { host.mainWindowShows(available) }
        // Cmd+1…7. The shortcut is declared above the window and records the press; this is the
        // only place that holds both the shell and a resolved context, so this is where it lands.
        .onChange(of: shell.pendingPanelIndex) { _, pending in
            guard pending != nil else { return }
            PanelColumnView.resolvePendingPanelIndex(shell: shell, host: host, context: context)
        }
    }

    private var available: [PanelTabID] { host.available(for: context) }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(available, id: \.self) { id in
                Button {
                    shell.panelTab = id
                } label: {
                    Label(host.title(for: id), systemImage: host.systemImage(for: id))
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.accessoryBar)
                .background(id == shell.panelTab ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .accessibilityAddTraits(id == shell.panelTab ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
            Button {
                host.popOut(shell.panelTab, channel: context.key)
            } label: {
                Image(systemName: "macwindow.badge.plus")
            }
            .buttonStyle(.accessoryBar)
            .help("Open this tab in its own window")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
