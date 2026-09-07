import Foundation
import AppKit
import Observation
import AfleetCore
import FleetKit
import PanelHostAPI

/// What the window is showing and what the keyboard is pointed at (spec §6).
///
/// It exists because the shell's four shortcuts — Cmd+K, Cmd+Shift+A, Cmd+1…7 and Cmd+, — are
/// declared in a `Scene`'s `commands`, which is outside every view's body and therefore cannot
/// reach `@State` living inside one. The state they move has to be owned above the window, and the
/// two places that could own it are `AppModel` and something new. `AppModel` belongs to Task 7 for
/// the timeline registry, so this is something new: additive, owned by one task, and holding
/// nothing but presentation state.
///
/// Everything the sidebar and the switcher *decide* lives here or in `QuickSwitcherModel`, and the
/// views read it. No view below computes which rows the thirty-day default hides or which panel tab
/// a number key means.
///
/// **On what a `ChannelState` costs the sidebar — closed, and the note kept because C6 opens this
/// file first.** An earlier version of this comment blamed a continuous holder poll and said the
/// cost was not something the shell could fix. Both halves were wrong. Instrumenting the stream
/// showed the load is `Fleet.fanOut` broadcasting each observer publication to *every* supervisor,
/// so one holder-set change costs one published state per registered channel — thousands of them,
/// recurring for the life of the process, of which the registration burst is the first and largest
/// instance rather than the whole. It is fixed in `FleetBrowserModel`: a state patches the row it
/// names instead of re-deriving, a state for a session with no row publishes nothing, and the
/// `updates` loop ingests and defers so a flood becomes a handful of paints. Idle CPU against a
/// real config home went from a sustained 100 percent to 0.1 percent, tech-debt entry 55 is closed,
/// and the remaining half — the fan-out itself — is tracker 60 against C4.
@MainActor
@Observable
final class ShellModel {

    /// What the middle column is showing. Activity is a peer of a channel rather than a mode on
    /// top of one, because Cmd+Shift+A has to be able to leave a channel and come back to it.
    enum Focus: Hashable {
        case activity
        case channel(SessionID)

        var session: SessionID? {
            if case .channel(let id) = self { return id }
            return nil
        }

        var isActivity: Bool {
            if case .activity = self { return true }
            return false
        }
    }

    var focus: Focus = .activity

    /// C5's single-window approximation: app activation plus selection. NSApplication activity
    /// does not prove this particular window is key and visible; C6's multi-window work owns
    /// that refinement. Both notifications and unread cursors read this one predicate.
    var isApplicationActive = NSApplication.shared.isActive

    func isInView(_ key: ChannelKey) -> Bool {
        isApplicationActive && focus.session == key.session
    }

    /// `List(selection:)` wants an optional and the shell always shows something, so a deselection
    /// — which AppKit produces on a click in the empty space below the last row — leaves the focus
    /// where it was rather than blanking the window.
    ///
    /// **The equality guard is not decoration.** `@Observable` invalidates on assignment, not on
    /// change, so writing back the value the property already holds still tells every observer the
    /// model moved — and `List` writes its selection back on each update pass. An unguarded setter
    /// therefore turns every list update into a model change and every model change back into a
    /// list update. It was added while hunting a sustained 100-percent main thread, and profiling
    /// then showed a different cause (see the note below), so this is a hazard closed on its own
    /// merits rather than a measured fix. The same guard is on every other writer here for the
    /// same reason.
    var listSelection: Focus? {
        get { focus }
        set {
            guard let newValue, newValue != focus else { return }
            focus = newValue
        }
    }

    /// Cmd+K's sheet.
    var isSwitcherPresented = false

    private let panels: PanelHostModel

    init(panels: PanelHostModel = PanelHostModel()) {
        self.panels = panels
    }

    /// The host is the sole selection owner. This synchronous projection is what the window
    /// reads and its tab bar writes; observation tracks the host's `selected` getter directly.
    /// No stored mirror or asynchronous write-back exists, so selection cannot ping-pong.
    /// With no selection (including an unregistered tab), Thread names the empty placeholder.
    var panelTab: PanelTabID {
        get { panels.selected ?? .thread }
        set { panels.select(newValue) }
    }

    /// The project sections whose *Show all (N)* has been pressed, by `ProjectSection.id`.
    var expandedProjects: Set<String> = []

    /// *All projects*: whether the sections the thirty-day default hides entirely are revealed.
    var showsAllProjects = false

    /// The `PaneRequest` the last *Attach* produced. Nothing in C5 renders a pane — the Terminal
    /// panel is C7's — so the request is held rather than dropped, and the sidebar says so.
    var pendingPane: PaneRequest?

    // MARK: - The shortcuts' verbs

    func presentSwitcher() {
        guard !isSwitcherPresented else { return }
        isSwitcherPresented = true
    }

    func showActivity() { set(.activity) }

    func select(_ id: SessionID) { set(.channel(id)) }

    /// One writer for `focus`, and it never writes a value the model already holds — see
    /// `listSelection`.
    private func set(_ next: Focus) {
        guard next != focus else { return }
        focus = next
    }

    /// One press of Cmd+N, waiting for the panel column to resolve it against the channel in view.
    ///
    /// The sequence number is what makes two presses of one key two events: without it a second
    /// Cmd+2 would write the value the property already holds and no observer would move.
    struct PendingPanelIndex: Hashable {
        let index: Int
        let sequence: Int
    }

    private(set) var pendingPanelIndex: PendingPanelIndex?
    private var panelIndexSequence = 0

    /// Cmd+1…7. **One-based over the tabs the panel host reports available for the channel in
    /// view**, which is what X7 and gate G4a say.
    ///
    /// That answer is not this model's to compute: availability is `PanelTab.isAvailable(in:)` over
    /// a `ChannelContext`, and the context lives in the panel column. So the shortcut *records* the
    /// press and `PanelColumnView.resolvePendingPanelIndex` resolves it through
    /// `PanelHost.selectIndex(_:in:)`.
    ///
    /// **It used to index `PanelTabID.allCases` here, and that was a different shortcut from the one
    /// the gate names.** With one tab registered, Cmd+2 set `panelTab` to a tab the channel could
    /// not show; the column drew "not available", the host refused the selection, and the two
    /// disagreed — while the host's `selectIndex(_:in:)`, which gets it right and is tested, had no
    /// production caller at all. The bound below stays `allCases.count` because seven is the closed
    /// size of the key range; which of the seven an index names is the host's answer, not this one.
    func selectPanelTab(at index: Int) {
        guard index >= 1, index <= PanelTabID.allCases.count else { return }
        panelIndexSequence += 1
        pendingPanelIndex = PendingPanelIndex(index: index, sequence: panelIndexSequence)
    }

    /// Takes the pending press, if there is one.
    ///
    /// A press nobody resolves — no channel in view, so no context and no available tabs — is
    /// dropped rather than queued: a shortcut is not a command, and replaying one the user pressed
    /// while looking at Activity would move a panel they have since navigated away from.
    func takePendingPanelIndex() -> Int? {
        defer { pendingPanelIndex = nil }
        return pendingPanelIndex?.index
    }

    func toggleShowAll(_ sectionID: String) {
        if expandedProjects.contains(sectionID) {
            expandedProjects.remove(sectionID)
        } else {
            expandedProjects.insert(sectionID)
        }
    }
}

/// The thirty-day default, as a set of pure functions over what `FleetBrowserModel` already
/// derived (spec §4, §8.2).
///
/// It is deliberately *not* a second grouping pass. `FleetBrowserModel.rebuild()` has already
/// decided which rows are archived and which project each surviving row belongs to; all that is
/// left is the age split inside a section, which is a filter on a flag `ChannelRegistrar` set. A
/// section can still hold a row older than thirty days — a channel with a live `ChannelState` is
/// never archived however old its transcript is — and that is exactly the row *Show all (N)*
/// exists for.
enum SidebarOutline {

    /// The rows of one group under the thirty-day default.
    static func visibleRows(_ rows: [ChannelRow], expanded: Bool) -> [ChannelRow] {
        expanded ? rows : rows.filter(\.isRecent)
    }

    /// How many rows of a section the default is hiding. The number in *Show all (N)*.
    static func hiddenCount(in section: ProjectSection) -> Int {
        section.allRows.filter { !$0.isRecent }.count
    }

    /// The sections the sidebar lists by default: those with at least one row inside the window.
    static func recentSections(_ sections: [ProjectSection]) -> [ProjectSection] {
        sections.filter { section in section.allRows.contains(where: \.isRecent) }
    }

    /// The sections *All projects* reveals: every project whose channels are all older than the
    /// window. Together with `recentSections` this partitions `sections`, so no project can be
    /// unreachable from the sidebar.
    static func olderSections(_ sections: [ProjectSection]) -> [ProjectSection] {
        sections.filter { section in !section.allRows.contains(where: \.isRecent) }
    }
}
