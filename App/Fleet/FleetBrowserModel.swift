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

    /// True once the composition root has applied the ordering inputs — `.claude.json`'s project
    /// order and the persisted `SidebarGrouping`.
    ///
    /// Both are read off the main actor and land after the first paint, deliberately: the sidebar is
    /// correct without them and falls back to activity order, so making the window wait for a file
    /// read and a store hop buys nothing. What that costs is one visible re-sort, and this is how a
    /// view knows which side of it a section list is on — and how a measurement knows when the read
    /// it is timing has actually finished.
    private(set) var hasGrouping = false

    // MARK: - Seams

    private let lifecycle: any LifecycleAPI
    private let configHome: URL
    private let now: @Sendable () -> Date
    private var groupingModel: ProjectGrouping
    private var updatesTask: Task<Void, Never>?
    /// The filesystem answers grouping needs, paid once per distinct directory per launch rather
    /// than once per rebuild.
    private let paths = PathMemo()

    // MARK: - The join's three sides

    /// **The one map that decides whether a session has a row.** It holds listed sessions only, with
    /// the entry and the verdict that listed them together. An earlier shape iterated `entries` and
    /// gated on `decisions`, so a row could be dropped by clearing either — two independent switches
    /// for one fact, which is a standing trap for anyone editing the delta path and which once made
    /// a mutation of the removal path invisible to its own test.
    private var listed: [SessionID: Listed] = [:]
    private var states: [SessionID: ChannelState] = [:]
    private var banners: [SessionID: RowBanner] = [:]

    /// One listed session: what to draw and which rule said to draw it.
    private struct Listed {
        var entry: IndexEntry
        var mode: ListingPolicy.Mode
        var rule: String
    }

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
        paint(snapshot, listing: nil, origin: .restored)
    }

    /// The fresh build's swap. Same join, provisional cleared.
    func apply(_ snapshot: IndexSnapshot) {
        paint(snapshot, listing: nil, origin: .built)
    }

    /// The form the composition root uses: it has already run the listing join to decide what to
    /// register, and running it a second time here would be a second full pass and a second set of
    /// row allocations over every entry in the snapshot — twice, on a warm launch.
    func paint(_ snapshot: IndexSnapshot, listing: ChannelRegistrar.Listing?, origin: SnapshotOrigin) {
        let listing = listing ?? ChannelRegistrar.listed(snapshot, configHome: configHome, now: now())
        isProvisional = origin == .restored
        decisions = listing.decisions
        listedWithoutCWD = listing.rows.filter { $0.cwd == nil }.count
        listed = [:]
        listed.reserveCapacity(listing.rows.count)
        for (id, decision) in listing.decisions {
            guard let mode = decision.listedMode, let entry = snapshot.entries[id] else { continue }
            listed[id] = Listed(entry: entry, mode: mode, rule: decision.rule)
        }
        // A session that left the index has no row, so its live half, its banner and the selection
        // pointing at it go with it; keeping any of them would leave the sidebar holding a reference
        // to a channel it can no longer draw.
        let known = Set(listed.keys)
        states = states.filter { known.contains($0.key) }
        banners = banners.filter { known.contains($0.key) }
        if let selected, !known.contains(selected) { self.selected = nil }
        rebuild()
    }

    /// One watcher delta. `resolving` is the index's `entry(_:)`; a session the index can no longer
    /// resolve is dropped rather than left stale.
    func apply(_ delta: IndexDelta, resolving: (SessionID) async -> IndexEntry?) async {
        for id in delta.removed {
            listed[id] = nil
            decisions[id] = nil
            states[id] = nil
            banners[id] = nil
            if selected == id { selected = nil }
        }
        for id in delta.added + delta.updated {
            guard let entry = await resolving(id) else {
                listed[id] = nil
                decisions[id] = nil
                continue
            }
            let decision = ChannelRegistrar.decide(entry)
            decisions[id] = decision
            if let mode = decision.listedMode {
                listed[id] = Listed(entry: entry, mode: mode, rule: decision.rule)
            } else {
                // A transcript that was listed and now is not — a fork's source gaining its
                // `continued-in` line is the ordinary way this happens — loses its row here.
                listed[id] = nil
                states[id] = nil
                banners[id] = nil
                if selected == id { selected = nil }
            }
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

    // MARK: - Background jobs

    /// Why the last action on a background job did not happen, by `JobShort.rawValue`. Separate
    /// from `banners` because a job is not a row: an exec job has no session id at all, so there is
    /// no `SessionID` to key its failure under.
    private(set) var jobBanners: [String: String] = [:]

    /// *Adopt*: take over a job's session through X5. A job that runs no session — an exec job —
    /// has nothing to adopt, and says so rather than silently doing nothing.
    func adopt(_ job: JobEntry) async {
        guard let session = job.sessionID else {
            jobBanners[job.short.rawValue] = "This job runs no session, so there is nothing to adopt."
            return
        }
        let key = ChannelKey(configHome: configHome, session: session)
        do {
            let state = try await lifecycle.perform(.adopt, on: key)
            jobBanners[job.short.rawValue] = nil
            apply(state)
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
        }
        await refreshBackground()
    }

    /// *Attach*: the `PaneRequest` X5 hands back for the job's pane. **C5 renders no pane** — the
    /// Terminal panel is C7's — so the request is returned to the caller, which holds it, rather
    /// than being dropped on the floor as though attaching had happened.
    func attach(_ job: JobEntry) async -> PaneRequest? {
        do {
            let request = try await lifecycle.attach(job.short)
            jobBanners[job.short.rawValue] = nil
            return request
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
            return nil
        }
    }

    /// *Stop*: `claude stop <short>` through X5's job verb, never a signal of our own.
    func stop(_ job: JobEntry) async {
        do {
            try await lifecycle.performJob(.stop, job.short)
            jobBanners[job.short.rawValue] = nil
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
        }
        await refreshBackground()
    }

    /// The same sentences a row's banner uses, so a refusal reads identically wherever it surfaced.
    private static func sentence(for error: any Error) -> String {
        if let lifecycle = error as? LifecycleError { return RowBanner(lifecycle).text }
        return "The action failed: \(type(of: error))."
    }

    // MARK: - Grouping

    func updateGrouping(_ grouping: ProjectGrouping) {
        groupingModel = grouping
        hasGrouping = true
        rebuild()
    }

    // MARK: - Derivation

    private func rebuild() {
        let moment = now()
        var live: [ChannelRow] = []
        var old: [ChannelRow] = []
        for (id, entry) in listed {
            var row = ChannelRegistrar.row(for: entry.entry, configHome: configHome, mode: entry.mode,
                                           rule: entry.rule, now: moment,
                                           isProvisional: isProvisional)
            row.state = states[id]
            row.banner = banners[id]
            if row.isArchived { old.append(row) } else { live.append(row) }
        }
        archived = old.sorted { $0.mtime > $1.mtime }
        sections = groupingModel.sections(from: live, paths: paths)
        releaseWaiters()
    }

    // MARK: - Being told, rather than asked

    /// Suspends until `predicate` holds of this model, resumed by the rebuild that makes it true.
    ///
    /// The alternative a consumer outside SwiftUI is otherwise left with is re-reading the model on
    /// a timer, which makes the answer depend on how much of the machine the polling task got. This
    /// is the same rule the composition root's own test doubles follow: the thing that satisfies the
    /// wait is what ends it. Returns immediately when the predicate already holds, so there is no
    /// ordering to lose between arming the wait and causing the change.
    func whenChanged(_ predicate: @escaping @MainActor (FleetBrowserModel) -> Bool) async {
        if predicate(self) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: predicate, continuation: continuation))
        }
    }

    private struct Waiter {
        let predicate: @MainActor (FleetBrowserModel) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []

    private func releaseWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(self) { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }
}
