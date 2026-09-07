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
                app.panels.view(for: panel.tab, context: context)
                    .navigationTitle(panel.tab.defaultTitle)
            } else {
                PlaceholderColumn(title: "This panel has no channel",
                                  detail: "The channel this window was opened for is no longer in the index.")
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onDisappear {
            guard let panel else { return }
            app.panels.closePopOut(panel)
        }
    }
}
