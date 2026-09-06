import Foundation
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
/// **What actually pins the main thread, measured on a real config home of 306 projects and 3,006
/// transcripts:** `LifecycleAPI.updates` delivers a `ChannelState` continuously — C4 re-runs
/// `claude agents` every few hundred milliseconds to observe foreign holders — and every one of
/// them makes `FleetBrowserModel.rebuild()` re-derive all 306 sections, which then makes SwiftUI
/// re-diff the whole row tree. A six-second sample of the shipped build put 39 percent of the main
/// thread in `rebuild()` and its sort and 60 percent in `OutlineListCoordinator.diffRows`. That is
/// tech-debt entry 55, whose closer is an incremental rebuild in `FleetBrowserModel`, and it is not
/// something the shell can fix from up here.
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

    /// Which panel tab the right-hand column shows. Task 8 owns what is drawn in it; which one is
    /// selected is the shell's, because Cmd+1…7 is a shell shortcut.
    var panelTab: PanelTabID = .thread

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

    /// Cmd+1…7. **One-based over `PanelTabID.allCases`**, which is the canonical order contract X7
    /// closes at seven cases, so the mapping cannot drift from the tab bar's. An index outside the
    /// set changes nothing rather than trapping: a key combination is not an assertion.
    func selectPanelTab(at index: Int) {
        guard index >= 1, index <= PanelTabID.allCases.count else { return }
        let next = PanelTabID.allCases[index - 1]
        guard next != panelTab else { return }
        panelTab = next
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
