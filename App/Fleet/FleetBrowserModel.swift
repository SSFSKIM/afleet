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

    /// Where each row currently sits, rebuilt whenever `sections` and `archived` are. It is what
    /// makes `apply(_ state:)` a patch rather than a re-derivation.
    ///
    /// Every read of it re-checks the row's own id at the position it names, so a stale index
    /// cannot write a state into the wrong channel: a mismatch falls back to the full rebuild.
    private var rowIndex: [SessionID: RowLocation] = [:]

    /// Sessions whose live half has been ingested and not yet written into the row that draws it.
    private var dirty: Set<SessionID> = []
    /// How many states have been ingested. Only ever compared for change.
    private(set) var ingestCount = 0
    private var flushTask: Task<Void, Never>?

    /// How many times the model has written a live half into the rows a view reads, and how many
    /// of those were full re-derivations.
    ///
    /// Counts, never identifiers (§11). They are here because the difference between them is the
    /// property this model is now built around and the only thing a test can hold it to: three
    /// thousand states that produce three thousand publishes are the defect, and asserting on
    /// elapsed time instead would be a stopwatch measuring a proxy.
    private(set) var publishCount = 0
    private(set) var rebuildCount = 0

    private enum RowLocation {
        case section(Int, worktree: Int?, row: Int)
        case archived(Int)
    }

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
    ///
    /// **The loop ingests and defers; it does not publish per state.** Registering the fleet makes
    /// C4 seed every registered channel's holders, so a launch against a real config home delivers
    /// roughly three thousand `ChannelState`s over the following minutes — one per channel, all of
    /// them first-time, almost all `.archived`. Publishing each one separately means SwiftUI walks
    /// the whole row tree once per state, which is what held the main thread at 100 percent for the
    /// length of the drain. Ingesting is a dictionary write; the flush that follows is scheduled
    /// once and merges every state that arrived before it ran.
    func startUpdates() {
        guard updatesTask == nil else { return }
        let stream = lifecycle.updates
        updatesTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                self.ingest(state)
                self.scheduleFlush()
            }
        }
    }

    /// Cancels the `updates` loop. The model is main-actor-bound and `deinit` is not, so the loop
    /// cannot be cancelled from one; the coordinator that started it is what ends it, and a loop
    /// left running holds only a weak reference to the model it feeds.
    func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
        flushTask?.cancel()
        flushTask = nil
    }

    /// One channel's live half. The only way an origin ever enters this model.
    ///
    /// **It patches one row rather than re-deriving the fleet, whenever the row cannot move.**
    /// A `ChannelState` changes a row's origin, presence, badge, banner and system item, and none
    /// of those is a sort key or a grouping key: the sections are ordered by pin, by the user's
    /// order, by `.claude.json`'s order and then by `mtime`, and every one of those comes from the
    /// static half. The one thing a state *can* move is whether the row is archived at all —
    /// `ChannelRow.isArchived` reads `state == nil` — so that is the condition the fast path
    /// checks, and a row that crosses it falls back to the full derivation.
    ///
    /// Why it matters, measured on a real config home: registering the fleet makes C4 seed each
    /// channel's holders in a detached task, so roughly three thousand first-time states arrive
    /// over several minutes, one per registered channel. Re-deriving 306 sections for each of them
    /// held the main thread at 100 percent for as long as the drain lasted, and made SwiftUI
    /// re-diff the whole row tree once per state because each rebuild got its own run-loop turn.
    func apply(_ state: ChannelState) {
        ingest(state)
        flush()
    }

    /// Records a live half without touching anything a view reads.
    ///
    /// `states` is private and no view reads it, so writing it publishes nothing. **A state for a
    /// session with no row is recorded and goes no further**: `rebuild()` derives rows from
    /// `listed` alone, so a session the listing policy did not list produces the same output before
    /// and after, and re-deriving for it is work with no possible effect on the screen. On this
    /// machine's own corpus 231 of the first 1,150 seeded states were of exactly that kind.
    private func ingest(_ state: ChannelState) {
        ingestCount &+= 1
        let id = state.key.session
        states[id] = state
        guard listed[id] != nil else { return }
        dirty.insert(id)
    }

    /// Writes every pending live half into the row that is drawn, or re-derives once if any of them
    /// has to move between `sections` and `archived`.
    private func flush() {
        guard !dirty.isEmpty else { return }
        publishCount &+= 1
        var mustRebuild = false
        for id in dirty where !patchLiveHalf(of: id) { mustRebuild = true }
        dirty.removeAll(keepingCapacity: true)
        if mustRebuild { rebuild() } else { releaseWaiters() }
    }

    /// Arranges for one flush, after the main actor has run whatever else is ready.
    ///
    /// The hop is the whole mechanism: every state the stream can hand over without suspending is
    /// ingested before this task gets its turn, so a burst of three thousand becomes a handful of
    /// publishes instead of three thousand. **It is not a deadline** — nothing here waits for a
    /// duration, and a single state arriving on a quiet fleet is published on the very next turn of
    /// the main actor, which is what keeps an origin, a badge or a presence change prompt.
    private func scheduleFlush() {
        guard flushTask == nil, !dirty.isEmpty else { return }
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var seen = self.ingestCount
            var deferrals = 0
            // Hand the main actor back so the stream can deliver whatever it already holds. Each
            // hop that brings more work starts another; the first hop that brings none means the
            // fleet has gone quiet and the batch is whole.
            while deferrals < Self.flushDeferralCeiling {
                await Task.yield()
                if Task.isCancelled {
                    self.flushTask = nil
                    return
                }
                if self.ingestCount == seen { break }
                seen = self.ingestCount
                deferrals += 1
            }
            self.flushTask = nil
            self.flush()
        }
    }

    /// How many times a flush will stand aside for more arrivals before publishing anyway.
    ///
    /// A bound on **arrivals, not on time** — nothing here waits for a duration, so nothing here
    /// can be slow on a loaded machine or fast on an idle one. Its job is to keep a fleet that
    /// never goes quiet from starving the sidebar of paints: at worst the screen lags the model by
    /// this many states, and C4's seeding burst of roughly three thousand becomes a dozen paints
    /// rather than three thousand.
    private static let flushDeferralCeiling = 256

    /// Rewrites one row's live half where it already sits, or reports that it could not.
    ///
    /// Returns false — and the caller re-derives — when the row is not in the index, when the index
    /// has gone stale under it, or when the new live half changes `isArchived`, which is the only
    /// way a `ChannelState` can move a row between the two collections.
    private func patchLiveHalf(of id: SessionID) -> Bool {
        guard let location = rowIndex[id] else { return false }
        switch location {
        case .section(let section, let worktree, let row):
            guard section < sections.count else { return false }
            if let worktree {
                guard worktree < sections[section].worktrees.count,
                      row < sections[section].worktrees[worktree].rows.count,
                      sections[section].worktrees[worktree].rows[row].id == id else { return false }
                var patched = sections[section].worktrees[worktree].rows[row]
                patched.state = states[id]
                patched.banner = banners[id]
                guard !patched.isArchived else { return false }
                sections[section].worktrees[worktree].rows[row] = patched
            } else {
                guard row < sections[section].rows.count,
                      sections[section].rows[row].id == id else { return false }
                var patched = sections[section].rows[row]
                patched.state = states[id]
                patched.banner = banners[id]
                guard !patched.isArchived else { return false }
                sections[section].rows[row] = patched
            }
            return true
        case .archived(let row):
            guard row < archived.count, archived[row].id == id else { return false }
            var patched = archived[row]
            patched.state = states[id]
            patched.banner = banners[id]
            guard patched.isArchived else { return false }
            archived[row] = patched
            return true
        }
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
        rebuildCount &+= 1
        // A full derivation reads every live half out of `states`, so anything still waiting to be
        // patched has just been written by definition. Leaving it queued would make the next flush
        // re-derive again for rows that are already correct.
        dirty.removeAll(keepingCapacity: true)
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
        reindex()
        releaseWaiters()
    }

    /// Records where every row landed, so the next `ChannelState` can be written in place.
    private func reindex() {
        rowIndex.removeAll(keepingCapacity: true)
        rowIndex.reserveCapacity(archived.count + sections.reduce(0) { $0 + $1.allRows.count })
        for (position, row) in archived.enumerated() {
            rowIndex[row.id] = .archived(position)
        }
        for (section, project) in sections.enumerated() {
            for (position, row) in project.rows.enumerated() {
                rowIndex[row.id] = .section(section, worktree: nil, row: position)
            }
            for (worktree, group) in project.worktrees.enumerated() {
                for (position, row) in group.rows.enumerated() {
                    rowIndex[row.id] = .section(section, worktree: worktree, row: position)
                }
            }
        }
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

