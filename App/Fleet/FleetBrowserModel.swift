import Foundation
import Observation
import AfleetCore
import FleetKit

/// The fleet browser: every channel on the machine, grouped by project (spec §4).
///
/// Three feeds meet here and each owns a different half of a row. `IndexSnapshot` and `IndexDelta`
/// carry the static half; `LifecycleAPI.updates` carries the live half; `ListingPolicy` decides
/// which entries become rows at all. The model joins them per session id and re-derives the
/// sections, and it decides nothing on its own — no listing rule is re-implemented here and no
/// origin is invented here.
///
/// **Ruling 3 (tracker entry 21's closer).** Origins live only in `states`, which starts empty on
/// every launch and is fed only by `apply(_ state:)`. A restored snapshot therefore paints rows with
/// no origin glyph at all, which is the honest answer: nothing yet knows whether any of those
/// sessions has a process behind it. The alternative — persisting the last origin — would greet the
/// user with a fleet of live-looking channels that all died when the machine last slept.
///
/// The loop that feeds it is `LifecycleAPI.updates` and never a `state(of:)` taken right after
/// registering: C4 seeds a new supervisor's holders in a *detached* task, so a read taken
/// immediately after `register` is a read taken before the answer exists.
@MainActor
@Observable
final class FleetBrowserModel {

    // MARK: - What the sidebar shows

    /// The project sections, ordered. Recent channels live here.
    private(set) var sections: [ProjectSection] = []
    /// Channels older than the thirty-day window with nothing live behind them, and channels whose
    /// transcript never named a working directory. Dimmed, at the bottom.
    private(set) var archived: [ChannelRow] = []
    /// The roster, from `LifecycleAPI.jobs()`.
    private(set) var background: [JobEntry] = []
    private(set) var selected: SessionID?

    /// Every entry the last snapshot carried, listed or not, with the rule that decided it. A row's
    /// *absence* is explainable through this and nowhere else.
    private(set) var decisions: [SessionID: ChannelRegistrar.Decision] = [:]
    /// Listed rows the last snapshot carried with no working directory. Counted, per §11, because
    /// they are the rows registration deliberately skipped.
    private(set) var listedWithoutCWD = 0
    /// True between `restore(from:)` and the first `apply(_ snapshot:)` — the restore-then-swap
    /// paint. Every row painted while it holds is `isProvisional`.
    private(set) var isProvisional = false

    // MARK: - Seams

    private let lifecycle: any LifecycleAPI
    private let configHome: URL
    private let now: @Sendable () -> Date
    private var groupingModel: ProjectGrouping
    private var updatesTask: Task<Void, Never>?

    // MARK: - The join's three sides

    private var entries: [SessionID: IndexEntry] = [:]
    private var states: [SessionID: ChannelState] = [:]
    private var banners: [SessionID: RowBanner] = [:]

    init(lifecycle: any LifecycleAPI,
         configHome: URL,
         grouping: ProjectGrouping = ProjectGrouping(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifecycle = lifecycle
        self.configHome = configHome
        self.groupingModel = grouping
        self.now = now
    }

    // MARK: - Lookup

    /// Every row the model holds, sections first. Tests and the Cmd+K switcher both read it.
    var allRows: [ChannelRow] { sections.flatMap(\.allRows) + archived }

    func row(_ id: SessionID) -> ChannelRow? { allRows.first { $0.id == id } }

    // MARK: - The index feed

    /// The persisted snapshot's paint. Rows are marked provisional and carry no origin.
    func restore(from snapshot: IndexSnapshot) {
        isProvisional = true
        ingest(snapshot)
    }

    /// The fresh build's swap. Same join, provisional cleared.
    func apply(_ snapshot: IndexSnapshot) {
        isProvisional = false
        ingest(snapshot)
    }

    private func ingest(_ snapshot: IndexSnapshot) {
        let listing = ChannelRegistrar.listed(snapshot, configHome: configHome, now: now())
        entries = snapshot.entries
        decisions = listing.decisions
        listedWithoutCWD = listing.rows.filter { $0.cwd == nil }.count
        // A session that left the index has no row, so its live half and its banner are dropped with
        // it; keeping them would resurrect a row the moment an unrelated update rebuilt the sections.
        let known = Set(snapshot.entries.keys)
        states = states.filter { known.contains($0.key) }
        banners = banners.filter { known.contains($0.key) }
        rebuild()
    }

    /// One watcher delta. `resolving` is the index's `entry(_:)`; a session the index can no longer
    /// resolve is dropped rather than left stale.
    func apply(_ delta: IndexDelta, resolving: (SessionID) async -> IndexEntry?) async {
        for id in delta.removed {
            entries[id] = nil
            decisions[id] = nil
            states[id] = nil
            banners[id] = nil
            if selected == id { selected = nil }
        }
        for id in delta.added + delta.updated {
            guard let entry = await resolving(id) else {
                entries[id] = nil
                decisions[id] = nil
                continue
            }
            entries[id] = entry
            decisions[id] = ChannelRegistrar.decide(entry)
        }
        rebuild()
    }

    // MARK: - The lifecycle feed

    /// Starts the `updates` loop (spec §2 step 11). Idempotent.
    func startUpdates() {
        guard updatesTask == nil else { return }
        let stream = lifecycle.updates
        updatesTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                self.apply(state)
            }
        }
    }

    /// Cancels the `updates` loop. The model is main-actor-bound and `deinit` is not, so the loop
    /// cannot be cancelled from one; the coordinator that started it is what ends it, and a loop
    /// left running holds only a weak reference to the model it feeds.
    func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// One channel's live half. The only way an origin ever enters this model.
    func apply(_ state: ChannelState) {
        states[state.key.session] = state
        rebuild()
    }

    func refreshBackground() async {
        background = await lifecycle.jobs()
    }

    // MARK: - Selection and actions

    func select(_ id: SessionID) { selected = id }

    /// One action on one row, through X5 and nothing else.
    ///
    /// **It never retries.** `busy` means another lifecycle operation holds this channel and a second
    /// attempt from the surface would be a second entrant; `notEligible` means a precondition the
    /// user has to clear. Both become a banner on the row and the user decides what to do next.
    func perform(_ action: LifecycleAction, on row: ChannelRow) async {
        do {
            let state = try await lifecycle.perform(action, on: row.key)
            banners[row.id] = nil
            apply(state)
        } catch let error as LifecycleError {
            banners[row.id] = RowBanner(error)
            rebuild()
        } catch {
            banners[row.id] = RowBanner(text: "The action failed: \(type(of: error)).")
            rebuild()
        }
    }

    /// Clears a row's banner, which is what the user dismissing it does.
    func dismissBanner(on id: SessionID) {
        guard banners[id] != nil else { return }
        banners[id] = nil
        rebuild()
    }

    // MARK: - Grouping

    func updateGrouping(_ grouping: ProjectGrouping) {
        groupingModel = grouping
        rebuild()
    }

    // MARK: - Derivation

    private func rebuild() {
        let moment = now()
        var live: [ChannelRow] = []
        var old: [ChannelRow] = []
        for (id, entry) in entries {
            guard let decision = decisions[id], let mode = decision.listedMode else { continue }
            var row = ChannelRegistrar.row(for: entry, configHome: configHome, mode: mode,
                                           rule: decision.rule, now: moment,
                                           isProvisional: isProvisional)
            row.state = states[id]
            row.banner = banners[id]
            if row.isArchived { old.append(row) } else { live.append(row) }
        }
        archived = old.sorted { $0.mtime > $1.mtime }
        sections = groupingModel.sections(from: live)
    }
}
