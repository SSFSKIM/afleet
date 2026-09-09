import Foundation
import AfleetCore
import FleetKit
import PanelHostAPI

/// Contract Y4, implemented: an `Agent` chip in the timeline lands on that run in the Agents tab
/// (child spec D5).
///
/// Three things, in this order: focus the channel the run belongs to, select `.agents`, write the
/// run into the app-scoped selection store. The order is the whole of the behaviour — a navigation
/// that selected only the tab would leave the user looking at *another* channel's Agents pane, with
/// the run they clicked nowhere on screen.
///
/// **It reaches the shell and the host through injected closures, never references.** A navigation
/// object holding the host is a retain path, X7 hands surfaces capabilities rather than the host,
/// and `Mirror` does not descend into a capture — which is what lets a test assert that no host was
/// stored. Focusing is unconditional because `ShellModel` writes `focus` only when the value moves,
/// so asking for the channel already on screen costs nothing and the "if it is not the one on
/// screen" rule needs no second copy of the shell's own guard here.
@MainActor
final class AgentNavigator: AgentNavigating {

    /// Brings the run's channel into the middle column — `ShellModel.select(_:)`.
    private let focusChannel: @MainActor (ChannelKey) -> Void
    /// Brings the Agents tab forward — `PanelHostModel.select(.agents)`.
    private let selectTab: @MainActor () -> Void
    private let selection: AgentSelectionStore

    init(selection: AgentSelectionStore,
         focusChannel: @escaping @MainActor (ChannelKey) -> Void,
         selectTab: @escaping @MainActor () -> Void) {
        self.selection = selection
        self.focusChannel = focusChannel
        self.selectTab = selectTab
    }

    func show(run: AgentRunID, in key: ChannelKey) {
        focusChannel(key)
        selectTab()
        selection.select(run, in: key)
    }
}
