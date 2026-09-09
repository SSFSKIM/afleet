import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// One popped-out panel tab, in its own window (spec §7).
///
/// **It resolves its context from the host by `ChannelKey`, not from the current selection.** That
/// is the whole of G4c: the window keeps the channel it was popped from while the main window moves
/// on. A scene that read `shell.focus` would follow the main window and the guarantee would be
/// silently gone — nothing else in the app would notice.
///
/// The value it is keyed by carries the tab and the channel and nothing else, because a
/// `ChannelContext` holds capabilities that are not `Codable`.
struct PoppedOutPanelScene: View {

    @Bindable var app: AppModel
    let panel: PoppedOutPanel?

    var body: some View {
        Group {
            // The caches are deliberately ObservationIgnored (tracker 67). Membership is
            // the observable validity signal: release/unregister/close removes it, causing
            // this body to drop the old view and the session that view retains.
            if let panel, app.panels.poppedOut.contains(panel),
               let context = app.panels.context(for: panel.channel) {
                // The surface names *this* window, not "a popped-out window": several can be open
                // at once, one per (tab, channel), and a panel that owns an `NSView` has to be
                // able to tell which of them is asking (C7.6 fix wave C).
                app.panels.view(for: panel.tab, context: context,
                                surface: .poppedOutWindow(tab: panel.tab, channel: panel.channel))
                    .navigationTitle(panel.tab.defaultTitle)
            } else {
                PlaceholderColumn(title: "This panel has no channel",
                                  detail: "The channel this window was opened for is no longer in the index.")
            }
        }
        // What the **File** menu's *Save* resolves against while this window is key. A pop-out
        // keeps a channel of its own and never moves the main window's selection, so a command
        // that read that selection would save another window's channel from in front of this one
        // (C7.5 Design §7, tracker 243). Published from both branches: a window drawing the
        // placeholder has no channel left, and the item must be offered for *nothing* rather than
        // for whatever the main window happens to be showing.
        .focusedSceneValue(\.poppedOutPanel, panel)
        // Tracker 350, the pop-out's half: this window holds nothing but a panel, so while it is
        // key every ordinary key in it is the panel's. The region spans the window rather than
        // carrying a rect — there is no composer here for the keyboard to be in instead.
        .background(PanelKeyboardRegion(focus: app.shell.keyboard, spansWindow: true))
        .frame(minWidth: 420, minHeight: 320)
        .onDisappear {
            guard let panel else { return }
            app.panels.closePopOut(panel)
        }
    }
}
