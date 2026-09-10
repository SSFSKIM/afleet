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
    /// The `jobUpdates` loop. Separate from `updatesTask` because the two streams are separate: `updates` is keyed
    /// by channel and an exec job has none, so a roster change is not expressible as a `ChannelState`.
    private var rosterTask: Task<Void, Never>?
    /// Whether X5 has published a roster into this model. The initial `jobs()` snapshot is a starting point and
    /// nothing more: once the stream has spoken, its roster is the current one and the snapshot is behind it.
    private var rosterPublished = false
    /// The filesystem answers grouping needs, paid once per distinct directory per launch rather
    /// than once per rebuild.
    private let paths = PathMemo()

    /// Where each row currently sits, rebuilt whenever `sections` and `archived` are. It is what
    /// makes `apply(_ state:)` a patch rather than a re-derivation.
    ///
    /// Every read of it re-checks the row's own id at the position it names, so a stale index
    /// cannot write a state into the wrong channel: a mismatch falls back to the full rebuild.
    private var rowIndex: [SessionID: RowLocation] = [:]

    /// Handed every `ChannelState` this model ingests, before the model does anything with it.
    ///
    /// `LifecycleAPI.updates` is **one stream and not a fan-out**: a second `for await` over it
    /// would take half the states and leave the sidebar with the other half. This model is the one
    /// consumer, so anything else in the app that needs the live half — Activity, and the
    /// notification router behind it — is told from here. It is a closure rather than a reference
    /// to the thing that wants it so that the sidebar keeps knowing nothing about Activity.
    var stateObserver: (@MainActor (ChannelState) -> Void)?
    /// Lets a consumer install its non-replaying event subscription before an action can spawn.
    /// The returned cleanup brackets the action, including intermediate states and refusals.
    /// The browser owns no consumer and awaits preparation before anything can spawn.
    var beforeAction: (@MainActor (ChannelKey) async -> (@MainActor () -> Void))?

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

    /// Channels the fleet has minted and the index cannot see yet (§8.2's *New channel*, §14 item 3).
    ///
    /// **A fourth, deliberately small side of the join, not a fourth kind of row.** A created
    /// channel has a supervisor, a working directory and a key, and no transcript at all — the
    /// engine writes none at startup (bundle `SPEC/35-session-persistence.md` §35.6.3), so
    /// `IndexEntry` cannot exist for it until the first turn. Without a row here the channel the
    /// user just made has nowhere to be seen and nothing to type into.
    ///
    /// It holds only what the request said, because that is all anybody knows yet. The moment the
    /// index lists the id, `rebuild()` drops the entry and the indexed row takes its place — one
    /// row throughout, and never two.
    ///
    /// **In memory only.** Persisting a created-but-unsent channel across a relaunch is a product
    /// decision that has not been taken; it would hook in here, beside `AfleetSelectionState`,
    /// which is the other thing about the window that survives a launch.
    private var pending: [SessionID: Pending] = [:]

    /// One created channel, as the request described it.
    private struct Pending {
        var key: ChannelKey
        /// The session name the user typed, or nil for the *New channel* placeholder title.
        var name: String?
        /// The request's directory, or the worktree path a `-w` creation will run in.
        var cwd: URL
        var createdAt: Date
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

    // MARK: - Created channels

    /// Draws a row for a channel the fleet has just minted, so the window has something to select
    /// and the column has something to mount (§8.2, §14 item 3).
    ///
    /// `cwd` is the directory the channel will run in — for a worktree creation the checkout the
    /// CLI is about to make — so the row lands under its repository from the first paint rather
    /// than moving section once the transcript appears.
    func addPending(_ key: ChannelKey, name: String?, cwd: URL) {
        guard listed[key.session] == nil else { return }
        pending[key.session] = Pending(key: key, name: name, cwd: cwd, createdAt: now())
        rebuild()
    }

    /// The placeholder title a created channel carries until the engine has an AI title of its own.
    /// The engine mints that title and C3 indexes it (`TitlePrecedence.aiTitle`); nothing here asks
    /// for one.
    nonisolated static let newChannelTitle = "New channel"

    /// The name `ChannelRow.decidingRule` carries for a created channel: no `ListingPolicy` rule
    /// listed it, because there is no entry for a rule to have read.
    nonisolated static let creationRule = "new-channel"

    private func pendingRow(_ entry: Pending) -> ChannelRow {
        ChannelRow(key: entry.key,
                   title: entry.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.newChannelTitle,
                   // The user's own name when they typed one, and the placeholder otherwise. Never
                   // `.aiTitle`: the engine mints that after the first turn and C3 indexes it, and
                   // this row exists precisely because no turn has happened.
                   titleSource: entry.name?.isEmpty == false ? .customTitle : .fallback,
                   // Empty, and honestly so: a preview is the transcript's first line and there is
                   // no transcript. The row shows presence instead once the channel has a process.
                   preview: "",
                   cwd: entry.cwd,
                   gitBranch: nil,
                   agentName: nil,
                   mtime: entry.createdAt,
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: Self.creationRule,
                   // **Not `isProvisional`.** That flag means *painted from the persisted snapshot
                   // and not yet replaced by the fresh build*, and the sidebar italicises it to say
                   // so. A created channel is the opposite kind of uncertainty — it is the newest
                   // thing the fleet knows about — and overloading the flag would draw it as stale.
                   isProvisional: false,
                   state: states[entry.key.session],
                   banner: banners[entry.key.session])
    }

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
        // A pending channel is drawn by this model and by nothing in the snapshot, so it counts as
        // known: filtering on `listed` alone dropped the created channel's live half, its banner
        // and the selection pointing at it on the next index build.
        let known = Set(listed.keys).union(pending.keys)
        states = states.filter { known.contains($0.key) }
        banners = banners.filter { known.contains($0.key) }
        if let selected, !known.contains(selected) { self.selected = nil }
        rebuild()
    }

    /// One watcher delta. `resolving` is the index's `entry(_:)`; a session the index can no longer
    /// resolve is dropped rather than left stale.
    ///
    /// **A delta that names nothing returns without touching anything a view reads.** `IndexDelta`
    /// is not always a change: `TranscriptIndex.update` reconciles every candidate and emits a
    /// delta carrying only its own duration when each one came back `.skipped`, and it does the same
    /// for a subagent-only write whose session's `hasSubagents` was already what the write makes it.
    /// That is the ordinary shape of a running subagent, so the empty deltas arrive at the watcher's
    /// rate for as long as the work lasts. Re-deriving every row and every section on the main actor
    /// for them is the whole of tracker entry 55's cost with none of its output: `rebuild()` reads
    /// `listed`, and nothing above this line can have changed it.
    func apply(_ delta: IndexDelta, resolving: (SessionID) async -> IndexEntry?) async {
        guard !delta.added.isEmpty || !delta.updated.isEmpty || !delta.removed.isEmpty else { return }
        for id in delta.removed {
            listed[id] = nil
            decisions[id] = nil
            forget(id)
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
                forget(id)
            }
        }
        rebuild()
    }

    /// Drops everything the model held *about* a session, unless a created channel still draws it.
    ///
    /// **The delta path has to ask the same question `paint` asks**, and for the same reason: a
    /// pending channel is drawn by this model and named by nothing in the index, so a delta that
    /// removes an id — or re-reads an entry the listing policy no longer lists — must not take its
    /// live half, its banner or the selection with it. It is the created channel's *own* id that
    /// arrives here in the ordinary case: the first delta that lists it names it as `added`, and a
    /// transcript deleted a moment later names it as `removed` while the channel is still there,
    /// with a process, being typed into.
    private func forget(_ id: SessionID) {
        guard pending[id] == nil else { return }
        states[id] = nil
        banners[id] = nil
        if selected == id { selected = nil }
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
        startRosterUpdates()
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
        rosterTask?.cancel()
        rosterTask = nil
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
        stateObserver?(state)
        let id = state.key.session
        states[id] = state
        guard listed[id] != nil || pending[id] != nil else { return }
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

    /// Subscribes the Background list to X5's roster signal and takes the one snapshot it starts from.
    ///
    /// **The subscription is installed before the snapshot is asked for.** `jobs()` runs `agents --json` and takes
    /// its time; a roster published while it is in flight would otherwise be the one change the sidebar never hears
    /// about, and the list would be wrong until the next one happened to arrive. For the same reason the snapshot
    /// is dropped rather than written once the stream has spoken: what the stream carries is the current roster,
    /// and overwriting it with a read that began earlier would be the sidebar arguing with itself.
    func refreshBackground() async {
        startRosterUpdates()
        let snapshot = await lifecycle.jobs()
        guard !rosterPublished else { return }
        applyRoster(snapshot)
    }

    /// The roster loop. Idempotent, and started from both ends — the coordinator's `startUpdates` and the sidebar's
    /// own first load — because either may run first and neither may be the one that leaves the list unsubscribed.
    private func startRosterUpdates() {
        guard rosterTask == nil else { return }
        let stream = lifecycle.jobUpdates
        rosterTask = Task { @MainActor [weak self] in
            for await roster in stream {
                guard let self else { return }
                self.rosterPublished = true
                self.applyRoster(roster)
            }
        }
    }

    /// Writes a published roster into the list, by row where the rows are the same ones.
    ///
    /// A roster that names the same jobs in the same order is patched entry by entry, so a job changing state
    /// touches one row rather than replacing the list SwiftUI has already diffed; a roster whose membership moved
    /// replaces it outright, because that is what actually happened. A roster equal to the one on screen writes
    /// nothing at all — the same rule the observer publishes under, held again here because `jobs()` and the stream
    /// can legitimately deliver the same list one after the other.
    private func applyRoster(_ roster: [JobEntry]) {
        guard roster != background else { return }
        if roster.map(\.short) == background.map(\.short) {
            for index in roster.indices where roster[index] != background[index] { background[index] = roster[index] }
        } else {
            background = roster
        }
        releaseWaiters()
    }

    // MARK: - Selection and actions

    func select(_ id: SessionID) { selected = id }

    /// One action on one row, through X5 and nothing else.
    ///
    /// **It never retries.** `busy` means another lifecycle operation holds this channel and a second
    /// attempt from the surface would be a second entrant; `notEligible` means a precondition the
    /// user has to clear. Both become a banner on the row and the user decides what to do next.
    func perform(_ action: LifecycleAction, on row: ChannelRow) async {
        let finish = await beforeAction?(row.key)
        defer { finish?() }
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
    ///
    /// It takes no roster refresh of its own. What adoption does to the roster is a change to the files the
    /// observer already watches, so X5 publishes it on `jobUpdates` like any other; re-reading it here would run
    /// `agents --json` — booting the CLI — to learn something already on its way.
    func adopt(_ job: JobEntry) async {
        guard let session = job.sessionID else {
            jobBanners[job.short.rawValue] = "This job runs no session, so there is nothing to adopt."
            return
        }
        let key = ChannelKey(configHome: configHome, session: session)
        let finish = await beforeAction?(key)
        defer { finish?() }
        do {
            let state = try await lifecycle.perform(.adopt, on: key)
            jobBanners[job.short.rawValue] = nil
            apply(state)
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
        }
    }

    /// *Attach*: the `PaneRequest` X5 hands back for the job's screen. The request is returned
    /// rather than run here, because which channel a job's pane belongs to is the caller's to name
    /// (X7 as amended 2026-09-09) and this model does not know what the window is showing.
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

    /// *Logs*: the same shape as *Attach* over X5's other job pane, `claude logs <short>`. Two
    /// members rather than one with a flag, because the two verbs are two X5 calls and a surface
    /// that ran one through the other would be invisible in a single call record.
    func logs(_ job: JobEntry) async -> PaneRequest? {
        do {
            let request = try await lifecycle.logs(job.short)
            jobBanners[job.short.rawValue] = nil
            return request
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
            return nil
        }
    }

    /// Which channel a job's pane belongs to, and the refusal when there is none.
    ///
    /// A job that runs a session names that session's channel under this browser's own config home
    /// — the same key *Adopt* builds one method above, so the two verbs cannot disagree about which
    /// channel a job is — **and only while this browser has a row for it**. A channel with no row
    /// is not one the app can show: `PanelColumnView` resolves what it draws through `row(_:)`, and
    /// the channel's own working directory is the row's, so a job whose session has left the index
    /// has neither a place to be seen nor a directory of its own to be built from.
    ///
    /// With no row the pane goes to `inView`, the channel the window is showing — the same fallback
    /// an exec job takes, which has no session at all. When neither exists there is nothing to
    /// name, and the row says so rather than running a `claude attach` whose pane could never be
    /// placed.
    ///
    /// **The refusal is a banner and never a thrown error** (§10): a job action that cannot happen
    /// is the row's news, not the channel's.
    func paneChannel(for job: JobEntry, inView: ChannelKey?) -> ChannelKey? {
        if let session = job.sessionID, row(session) != nil {
            return ChannelKey(configHome: configHome, session: session)
        }
        if let inView { return inView }
        jobBanners[job.short.rawValue] = "This job has no channel in the fleet, and none is open to show its pane in."
        return nil
    }

    /// The working directory a job's pane channel can be built from, so a caller that has named a
    /// channel can also make it *resolvable*.
    ///
    /// The panel host holds a context only for a channel it has rendered, and drops it again under
    /// LRU pressure. A job's channel is very often neither: the sidebar's Background section is
    /// full of channels no window has ever shown. So the directory comes from the channel's own
    /// row, and from nowhere else. **The job's own directory is not a candidate**: seeding a
    /// channel with it records it as that channel's, and every later shell opened there — a
    /// Cmd+Shift+T pane, and then the W6 document — inherits a directory that belongs to a job
    /// rather than to the channel.
    func paneCWD(for job: JobEntry, in channel: ChannelKey) -> URL? {
        row(channel.session)?.cwd
    }

    /// A job action that failed after X5 had already answered — the pane could not be placed. It
    /// reads as the same sentence any other refusal on the row does.
    func noteJobFailure(_ job: JobEntry, _ error: any Error) {
        jobBanners[job.short.rawValue] = Self.sentence(for: error)
    }

    /// *Stop*: `claude stop <short>` through X5's job verb, never a signal of our own. The job leaving the roster
    /// arrives on `jobUpdates`, for the same reason Adopt takes no refresh of its own.
    func stop(_ job: JobEntry) async {
        do {
            try await lifecycle.performJob(.stop, job.short)
            jobBanners[job.short.rawValue] = nil
        } catch {
            jobBanners[job.short.rawValue] = Self.sentence(for: error)
        }
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
        // The index has caught up with these: the entry it now holds is a better row than the
        // request was, and keeping both would draw the channel twice.
        pending = pending.filter { listed[$0.key] == nil }
        for entry in pending.values {
            let row = pendingRow(entry)
            // A created channel is `isRecent` and has a directory, so `isArchived` is false and this
            // is the section arm. Kept as a branch rather than an append, because a row that
            // *reported* itself archived and was filed live is the one shape `reindex` cannot fix.
            if row.isArchived { old.append(row) } else { live.append(row) }
        }
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

