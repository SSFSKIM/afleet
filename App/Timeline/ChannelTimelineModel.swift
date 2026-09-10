import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

// MARK: - The header

/// The four things spec §8 puts above the timeline — origin, presence, banner and
/// system item — plus the title the index already knows, read off the row's `ChannelState`.
///
/// A value rather than a set of accessors on the model, so the header a test asserts on is the
/// header the view draws and there is no second derivation to disagree with the first.
struct ChannelHeader: Hashable, Sendable {
    var title: String
    /// Nil until a `ChannelState` for this channel has arrived — `ChannelRow`'s ruling 3, inherited
    /// unchanged: a restored row carries no origin and this header carries none either.
    var origin: ChannelOrigin?
    var presence: Presence?
    var banner: ChannelBanner?
    var systemItem: SystemItem?
    /// The row's `gitBranch`, which C3's index reads from the transcript's own `gitBranch` field
    /// (child spec §10). It rides on the header rather than being read off the row at the readout,
    /// because the column already watches this value and calls `adopt` on every change to it: a
    /// branch that moves under a selected channel therefore moves on screen, with no second watcher
    /// and no edit to a file another leaf owns.
    var branch: String?

    var glyph: OriginGlyph? { origin.map(OriginGlyph.init) }

    init(title: String = "No channel selected", origin: ChannelOrigin? = nil, presence: Presence? = nil,
         banner: ChannelBanner? = nil, systemItem: SystemItem? = nil, branch: String? = nil) {
        self.title = title; self.origin = origin; self.presence = presence
        self.banner = banner; self.systemItem = systemItem; self.branch = branch
    }

    init(row: ChannelRow) {
        self.init(title: row.title, origin: row.origin, presence: row.presence,
                  banner: row.channelBanner, systemItem: row.systemItem, branch: row.gitBranch)
    }
}

// MARK: - One row of a channel's list

/// One row of a channel's list: **the item itself**, plus the three fields C5's placeholder row
/// draws, each derived from it.
///
/// **Superseded 2026-09-08 (C6.1; contract Y1 amended by the architect's ruling).** What stood here
/// said a row was "the item's category, its timestamp and a one-line summary. Nothing else", because
/// that is all C5's placeholder needed. It is not what a row is. Y1 hands a leaf's builder one of
/// these and nothing else, and no builder can draw an assistant message's blocks, a tool call's
/// typed input, a cluster's members or an agent chip's status from a flattened 140-character string.
/// So the row carries `item`, and `category`, `timestamp` and `summary` stay exactly what they were
/// and stay derived from it: `PlaceholderRowView`, the closed switch below and every existing
/// assertion are untouched, and C6.3's builders — written against this type in a parallel worktree —
/// keep compiling. The amendment is one stored field, and the builder's arity is deliberately
/// unchanged.
///
/// **The switch below is closed and total on purpose.** The category test compares the set of
/// categories this builder produced against the set the projection holds, in both directions, and
/// that comparison only means something while every item yields exactly one row. A `default:` here
/// that returned nil for a kind nobody thought about would drop that kind's items silently.
struct TimelineRow: Identifiable, Hashable, Sendable {
    /// What the row is of. `TimelineItem` is `Hashable` and `Sendable`, so this type's own
    /// conformances are unaffected by carrying it.
    let item: TimelineItem
    let id: ItemID
    let category: TimelineCategory
    let timestamp: Date?
    let summary: String

    init(_ item: TimelineItem) {
        self.item = item
        id = item.id
        category = item.category
        timestamp = item.timestamp
        summary = Self.summary(of: item)
    }

    /// At most one line, whatever the item carries.
    static func summary(of item: TimelineItem) -> String {
        switch item {
        case .userMessage(let i): oneLine(i.text)
        case .assistantMessage(let i): oneLine(text(of: i.blocks))
        case .toolCall(let i): oneLine("\(i.name) — \(i.status.rawValue)")
        case .cluster(let i): oneLine(i.label ?? "\(i.toolUseIDs.count) tool calls")
        case .taskRun(let i): oneLine("\(i.kind.wire) — \(i.status.rawValue) — \(i.description)")
        case .decision(let i): oneLine("\(i.kind.rawValue) — \(i.title)")
        case .hookRun(let i): oneLine("\(i.event) — \(i.hookName)")
        case .notification(let i): oneLine(i.text.isEmpty ? i.key : i.text)
        case .peerMessage(let i): oneLine(i.text.isEmpty ? i.originKind : i.text)
        case .compactBoundary(let i): oneLine("compacted (\(i.trigger ?? "unstated"))")
        case .sentFile(let i): oneLine(i.caption ?? "\(i.files.count) file(s) sent")
        case .turnSummary(let i): oneLine("\(i.numTurns) turn(s) in \(i.durationMs) ms")
        case .opaque(let i): oneLine(i.type ?? i.reason)
        }
    }

    /// How many characters of a summary the placeholder shows.
    static let summaryLimit = 140

    private static func oneLine(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > summaryLimit else { return flattened }
        return String(flattened.prefix(summaryLimit)) + "…"
    }

    private static func text(of blocks: [ContentBlock]) -> String {
        blocks.compactMap { if case .text(let block) = $0 { block.fields.text } else { nil } }
            .joined(separator: " ")
    }
}

// MARK: - The model

/// One channel's timeline, owned for as long as the app knows about the channel (spec §8).
///
/// It drives exactly one `StreamIngestion` over the channel's transcript. **One path serves both
/// origins:** an owned channel is opened over its own `events(of:)` subscription and an archived
/// one over a stream that is already finished, so the ingestion's tap-then-file ordering runs
/// identically either way and the archived case is the live case with an empty tap.
///
/// **The event subscription is this model's own**, not the Activity pump's. C3's tap contract has
/// `StreamIngestion` consume the raw stream, where `ChannelEventPump` keeps three folded summaries;
/// `LifecycleAPI.events(of:)` hands back a fresh unbounded fan-out per call, which is what makes
/// two independent consumers of one channel legal and correct.
///
/// **On the window between opening and subscribing to the change feed.** `TranscriptChangeFeed`
/// does not replay: a `subscribe()` taken after `start()` sees batches from its own attachment
/// onward and nothing before it. So the subscription is taken *before* `StreamIngestion.open`
/// reads the file, and the window is closed by construction: a write before the read is in the
/// read, and a write after it is in the subscription's unbounded buffer. C3's tap does not close
/// this window on its own — an archived or foreign channel has no tap at all — and relying on it
/// would make the ordering correct for owned channels only.
/// `testTheChangeSubscriptionIsTakenBeforeTheFileIsRead` holds the order, by parking the model
/// inside `subscribe()` and asserting the read has not run.
///
/// Subscribing first does mean a `fileChanged` can enter this actor's ingestion before or during
/// `open` — `open` suspends in its settle loop, which is a reentrancy point. That is benign and not
/// a race this model has to serialise: the apply path is idempotent by `RecordKey`, and `open`'s own
/// `StreamState` and whole-file read replace whatever an early `fileChanged` built. `StreamIngestion`
/// documents only that a second `open` is a programmer error and says nothing about this
/// interleaving, so it is written down here rather than assumed.
@MainActor
@Observable
final class ChannelTimelineModel {

    let key: ChannelKey

    /// The read model, contract X4's. Replaced whole on every ingestion effect that changed items.
    private(set) var timeline = ChannelTimeline()

    var items: [TimelineItem] { timeline.items }

    /// What the list draws, one row per item.
    ///
    /// **Superseded 2026-09-09 (C6.1 Task 4).** What stood here said "what the placeholder draws":
    /// eleven of the thirteen kinds now resolve to a C6.1 row through contract Y1's registry, and
    /// only `decision` and `sentFile` — C6.3's — still draw C5's placeholder.
    var rows: [TimelineRow] { timeline.items.map(TimelineRow.init) }

    /// The reads a row makes of the timeline around it, rebuilt only when the items moved.
    ///
    /// **On the model for the reason `retraction` is.** The list builds one per body evaluation and
    /// a body evaluates on every streaming publish, so the cache has to outlive the view value it is
    /// read from — and the channel a reader switches away from and back to keeps the one it had.
    var neighbourhood: TimelineNeighbourhood { neighbourhoods.neighbourhood(for: timeline) }

    @ObservationIgnored let neighbourhoods = TimelineNeighbourhoodCache()

    private(set) var header = ChannelHeader()

    /// What the header's readback strip draws (child spec §10): the branch, and the four values the
    /// engine answers for. Replaced field by field as answers arrive, and never from a request this
    /// app made — see `ChannelHeaderReadout`.
    private(set) var readout = ChannelHeaderReadout()

    /// What a settled refusal dialog took back on this channel (spec D11), and what the list filters
    /// through before it draws.
    ///
    /// **On the model and not in the list's `@State`.** The column keys the timeline view by the
    /// channel, so a switch away and back destroys the view value and builds a fresh one — while
    /// this model, and the unfiltered items in it, are exactly what the registry retains. A registry
    /// rebuilt with the view is empty, so every message a resolved dialog took back comes back on
    /// screen and stays back: the dialog is settled, and nothing will retract them a second time.
    @ObservationIgnored let retraction = RetractionRegistry()

    /// True once `open(_:)` has driven the ingestion; a channel switch away and back does not
    /// restart it, which is what the registry retains this object for.
    private(set) var hasOpened = false

    /// Why the transcript could not be read, as a shape and never a path (§11).
    private(set) var failure: String?

    /// True for a channel the fleet has minted and whose transcript does not exist yet (§8.2's
    /// *New channel*, §14 item 3).
    ///
    /// **Not a failure, and that distinction is the whole of it.** The engine creates no transcript
    /// at startup — `sessionFile` is null until the first `user`, `assistant` or `system` record is
    /// written (bundle `SPEC/35-session-persistence.md` §35.6.3) — so a channel created and not yet
    /// sent to has no file for the index to hold, and reporting "no transcript in the index" would
    /// tell the user something is broken about a channel that is simply new. The column draws its
    /// own placeholder for it and the composer is enabled: a send is what makes the transcript
    /// exist.
    private(set) var awaitsTranscript = false

    /// The transcript the ingestion is reading, as the index spelled it. Held so a relocation is a
    /// comparison rather than a call: the coordinator hands the entry's path on every update to a
    /// channel, and only a path that actually moved is worth rebinding.
    @ObservationIgnored private var transcriptPath: URL?

    /// Set by `close()`, and never cleared: a released model is over. The opening task's awaits are
    /// checked against it, because cancelling that task only ends it where the code looks.
    @ObservationIgnored private var isTerminated = false

    /// Every applied timeline, from this call onward. A fresh fan-out per call, like
    /// `LifecycleAPI.events(of:)`: the panel host's recent-URL feed is one consumer and a test is
    /// another, and a single shared `AsyncStream` would split the elements between them.
    nonisolated var timelineUpdates: AsyncStream<ChannelTimeline> { fanout.subscribe() }

    @ObservationIgnored private nonisolated let fanout = TimelineFanout()
    /// How the model reaches the transcript change feed.
    ///
    /// A seam beside `lifecycle` because the subscribe-before-read ordering is only observable from
    /// *inside* the subscribe call: both orders converge on the same timeline — a missed batch is
    /// recovered by the next `fileChanged`, which reads from the stored offset — so no assertion
    /// over the result can separate them, and a double that suspends here can.
    typealias ChangeFeedSubscribing = @Sendable () async -> AsyncStream<TranscriptChangeBatch>?

    @ObservationIgnored private let workspace: Workspace?
    @ObservationIgnored private let lifecycle: (any LifecycleAPI)?
    @ObservationIgnored private let subscribeToChanges: ChangeFeedSubscribing
    @ObservationIgnored private var ingestion: StreamIngestion?
    @ObservationIgnored private var effectsTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// The readback loop, and whether anything has asked for one. Both are needed: a header that has
    /// never been drawn asks the engine nothing, and a channel that had no process when the strip
    /// was drawn is asked as soon as it has one.
    @ObservationIgnored private var readbackTask: Task<Void, Never>?
    @ObservationIgnored private var readbacksWanted = false
    /// The ingestion's own lifetime, owned here and not by whatever called `open`. See `open`.
    @ObservationIgnored private var openingTask: Task<Void, Never>?

    /// `lifecycle` is the events seam. Production passes `workspace.fleet`, which is an `AppFleet`
    /// and therefore a `LifecycleAPI`; a test passes a `LifecycleAPI` double, which is the only way
    /// the `events(of:)` call log the tap-contract test asserts on can exist.
    init(key: ChannelKey, workspace: Workspace?, lifecycle: (any LifecycleAPI)? = nil,
         changeFeed: ChangeFeedSubscribing? = nil) {
        self.key = key
        self.workspace = workspace
        self.lifecycle = lifecycle ?? workspace?.fleet
        if let changeFeed {
            subscribeToChanges = changeFeed
        } else {
            let feed = workspace?.changes
            subscribeToChanges = { await feed?.subscribe() }
        }
    }

    deinit {
        effectsTask?.cancel()
        changesTask?.cancel()
        openingTask?.cancel()
        readbackTask?.cancel()
    }

    // MARK: - The header

    /// Takes the row's live half without touching the ingestion.
    ///
    /// The header and the opening are separate concerns: origin, presence, banner and system item
    /// change under a channel that stays selected, and the read must not be restarted — or, worse,
    /// cancelled mid-flight — every time one of them does. The column calls this on every change to
    /// those fields and calls `open` once per channel.
    ///
    /// **Superseded 2026-09-09 (C6.1 Task 5).** What stood here said "those four fields": the branch
    /// is a fifth, and the column's `onChange` compares the whole `ChannelHeader`, so a rebase under
    /// a selected channel arrives here like any other change.
    func adopt(_ header: ChannelHeader) {
        self.header = header
        readout.branch = header.branch
        // A channel that was archived or connecting when the strip was first drawn has a process
        // now, and this is the moment that becomes true. Nothing is armed on a timer, and nothing
        // starts here for a channel whose header nobody has drawn.
        beginReadbacks()
    }

    // MARK: - The header's readbacks

    /// Asks the engine for the readbacks, and keeps asking after each turn. Called by
    /// `HeaderReadoutView`'s `task`, which is what makes the strip's presence the thing that asks.
    ///
    /// Idempotent, and safe to call for a channel with no process: it records that the readbacks are
    /// wanted and starts them when there is something to ask.
    func startReadbacks() {
        readbacksWanted = true
        beginReadbacks()
    }

    /// One pass: `get_settings` for the model and the effort, the channel's retained handshake for
    /// the mode, and `get_context_usage` for the meter.
    ///
    /// **Only for a channel with a live process**, and a refusal leaves the last readback standing —
    /// each answer is folded in only when there is one, and nothing here retries (X5).
    func refreshReadbacks() async {
        guard let poller else { return }
        if let settings = await poller.settings() { readout.apply(settings) }
        if let context = await poller.contextUsage() { readout.context = context }
    }

    /// The poller for a channel that has a process to ask, and nil for one that has not.
    private var poller: ReadbackPoller? {
        guard let lifecycle, ReadbackPoller.hasLiveProcess(header.origin) else { return nil }
        return ReadbackPoller(key: key, lifecycle: lifecycle)
    }

    /// Takes the opening readback and then one after each `result` frame — the one moment a turn is
    /// known to have ended. **Not a timer**: nothing pushes the context meter (parity §41.15.4), and
    /// an interval would ask a question of an idle channel over and over.
    ///
    /// **The permission mode is the exception, and it is pushed** (child spec §10, corrected
    /// 2026-09-09). It is in no control answer: `get_settings` reports the model and the effort, the
    /// handshake reports the mode the process launched with and is minted once, and a mode changed
    /// mid-session — by a `/mode`, by an *exit plan mode* approval, by any host's
    /// `set_permission_mode` — arrives on a `system/status` frame and nowhere else. So this loop
    /// reads those frames as they pass and the readout follows them, rather than showing the launch
    /// mode until a restart.
    ///
    /// The subscription is this model's own fan-out, which `events(of:)` documents as legal and is
    /// how the ingestion and the Activity pump already share one channel. It ends when the channel
    /// archives — the stream is finished then. Once its buffered events have drained, it clears
    /// itself and rechecks the live header: reopening may have arrived while this task was still
    /// occupied. A nil subscription waits for a new lifecycle trigger; it never retries itself.
    private func beginReadbacks() {
        guard readbacksWanted, readbackTask == nil, !isTerminated, poller != nil, let lifecycle else { return }
        let key = key
        readbackTask = Task { @MainActor [weak self] in
            // **Subscribed before the opening readback is taken, and not after it.** `events(of:)`
            // registers a future-only fan-out — which is why `engineReports(of:)` exists at all —
            // and the readback below is a round trip to a process that may be mid-turn. A mode
            // change reported inside that window reaches whoever is listening at the time and is
            // never reissued, so a subscription taken afterwards loses it and the header shows the
            // launch mode until the next change, which on a quiet channel is never.
            let stream = await lifecycle.events(of: key)
            guard !Task.isCancelled else { return }
            await self?.refreshReadbacks()
            guard let stream else { self?.readbackTask = nil; return }
            // A restart replaces the process under a channel this model outlives, and the mode a
            // status frame reported belongs to the process that reported it: the precedence resets
            // with the process, or the replacement's handshake is rejected for ever. The epoch is
            // recorded on the readout rather than here, so it survives an archival that ends this
            // subscription — see `ChannelHeaderReadout.observed(epoch:)`.
            //
            // **And the readbacks are re-taken on the spot.** The replacement's mode is in its own
            // handshake, a handshake is not a turn end, and the poll below is the only other thing
            // that would read one — so a replacement that runs no turn would leave the header naming
            // the mode of a process that is gone.
            for await event in stream {
                guard let self, !self.isTerminated, !Task.isCancelled else { return }
                if let seen = ReadbackPoller.epoch(of: event), self.readout.observed(epoch: seen) {
                    await self.refreshReadbacks()
                }
                if let mode = ReadbackPoller.liveMode(event) { self.readout.apply(liveMode: mode) }
                guard ReadbackPoller.isTurnEnd(event) else { continue }
                await self.refreshReadbacks()
            }
            guard !Task.isCancelled else { return }
            self?.readbackTask = nil
            self?.beginReadbacks()
        }
    }

    // MARK: - Opening

    /// Reads the channel's history from disk and keeps it current.
    ///
    /// Idempotent past the header: the header follows the row on every call, because the live half
    /// of a row changes under the model, and the ingestion runs once.
    ///
    /// **The ingestion's lifetime is this model's, not the caller's.** The work runs in an
    /// unstructured `Task` stored here, and `open` awaits that task rather than doing the work
    /// inline. A view's `.task(id:)` cancels its body when the id changes, cancellation propagates
    /// into `StreamIngestion.open`'s settle sleep, and that call's own `catch` cancels the tap,
    /// finishes `effects` and marks the actor closed before it rethrows — so a channel switch
    /// landing inside the tens of milliseconds an open occupies used to leave a half-closed
    /// ingestion behind a model that would never re-open it. An unstructured task does not inherit
    /// the caller's cancellation, so the read completes whatever the view does; only `close()`,
    /// which the registry owns, ends it.
    func open(_ row: ChannelRow) async {
        adopt(ChannelHeader(row: row))
        if let openingTask {
            // A second caller waits for the first rather than starting a second ingestion. Awaiting
            // a non-throwing task is not itself cancellable, so this is safe from a cancelled view.
            await openingTask.value
            return
        }
        guard !hasOpened, let workspace, let lifecycle else { return }
        let task = Task { @MainActor [weak self] () -> Void in
            await self?.performOpen(workspace: workspace, lifecycle: lifecycle)
        }
        openingTask = task
        await task.value
        openingTask = nil
    }

    /// The read itself, run by `open`'s stored task.
    ///
    /// **Tracker 66 closed here, 2026-09-08.** What stood above said a genuine failure latches
    /// because `hasOpened` is set before the lookup, and that the entry was filed rather than closed.
    /// It is closed now: `hasOpened` is set *after* the index lookup succeeds, so a channel whose
    /// entry is momentarily absent — a transcript deleted between listing and opening, or written a
    /// moment later — is retried on its next appearance instead of reporting a failure for the life
    /// of the model, which the registry retains across every switch away and back. A second caller
    /// arriving while the first is in flight is still serialised, by `open`'s `openingTask` await and
    /// not by this flag.
    private func performOpen(workspace: Workspace, lifecycle: any LifecycleAPI) async {
        guard let entry = await workspace.index.entry(key.session) else {
            // A created channel, or a transcript that has gone. The two are told apart by whether
            // the fleet owns a supervisor for the key: `events(of:)` answers a stream for any
            // *registered* channel and nil for one the fleet was never told about (X5), and a
            // channel `Fleet.create` minted is registered by construction. So a live stream with
            // no index entry is a channel whose first record has not been written yet, and a nil
            // stream with no index entry is a row whose file is missing.
            //
            // The subscription is taken and dropped rather than held: this model's one consumer of
            // the channel's events is the ingestion, which cannot exist without a file, and the
            // header's readbacks take their own. What is wanted here is the *answer*.
            if await lifecycle.events(of: key) != nil {
                awaitsTranscript = true
                failure = nil
            } else {
                failure = "this channel has no transcript in the index"
            }
            return
        }
        // The other half of tracker 66: a retry that found the entry has to clear the failure the
        // attempt before it recorded, or the channel keeps reporting a condition that is over.
        failure = nil
        awaitsTranscript = false
        hasOpened = true
        // Every `await` below is a point where `close()` can run — the registry releases a channel
        // that left the index, and the model it releases must not go on to build what the release
        // just took down. Cancellation alone is not the test: `close()` cancels the opening task,
        // but a resumption that installed a change-feed loop, took an event subscription and read
        // the file would leave a released model subscribed and publishing.
        guard !isTerminated else { return }

        // **The index's spelling of the config home, not the workspace's.** `TranscriptIndex`
        // canonicalises its root and every path it discovers, `TranscriptPath.resolve` is a lexical
        // prefix check, and `StreamIngestion.open` traps rather than fails when the path it is given
        // names no stream under the root it was given. Two spellings of one directory — a linked
        // `TMPDIR`, a linked home, tracker entry 54's disagreement — therefore took the app down on
        // the first channel opened. Read from the index rather than re-canonicalised here, so there
        // is one derivation of the canonical root and not a second that can drift from it.
        let canonicalHome = await workspace.index.currentSnapshot.configHome
        guard !isTerminated else { return }

        let ingestion = StreamIngestion(session: key.session,
                                        configHome: canonicalHome,
                                        mode: .filePrimary,
                                        diagnostics: workspace.diagnostics.timeline)
        self.ingestion = ingestion
        transcriptPath = entry.path

        // The one consumer of `effects` — the stream is documented single-consumer — started before
        // the read so nothing the open publishes is dropped.
        effectsTask = Task { @MainActor [weak self] in
            for await effect in ingestion.effects {
                guard let self else { return }
                guard !effect.changes.isEmpty else { continue }
                // Requested, not performed (§4). Deltas arrive as fast as the engine writes them and
                // the read model is republished whole for each one; the coalescer turns a burst into
                // one publish on a thirty-hertz trailing edge, and a lone delta after quiet into one
                // publish 33 ms later. Everything downstream — the table, its diff, the row heights
                // — costs what a publish costs, so this is the one place the rate is set.
                self.coalescer.request()
            }
        }

        // Before the read, and the order is the guarantee rather than a preference: the change feed
        // does not replay, so a subscription taken after the read never sees a batch that arrived in
        // the window between them, and for an archived channel — no tap, nothing writing the file
        // again — that batch is lost for as long as the channel stays open. Taken here, a write
        // before the read is inside the read and a write after it is in this subscription's
        // unbounded buffer. See the note on the type, and the test that holds this order.
        let subscription = await subscribeToChanges()
        // `close()` cancelled the effects loop and dropped the ingestion while this call was in
        // flight; installing a loop over that subscription now would resurrect both.
        guard !isTerminated else { return }
        if let subscription {
            changesTask = Task { [weak ingestion] in
                for await batch in subscription {
                    guard let ingestion else { return }
                    for path in batch.paths { _ = await ingestion.fileChanged(path) }
                }
            }
        }

        // The one path, both origins: a live fan-out for a channel the fleet owns a supervisor for,
        // and a stream that is already over for one it does not.
        let events = await lifecycle.events(of: key) ?? Self.finishedEvents()
        guard !isTerminated else { return }

        do {
            _ = try await ingestion.open(file: entry.path, events: events)
        } catch {
            failure = "the channel's transcript could not be opened"
        }
        await publish()
    }

    /// Rebinds the ingestion to the transcript's new path.
    ///
    /// The engine renames a project's slug directory and the index re-arbitrates the survivor;
    /// `FleetCoordinator` forwards the entry's path here on every update. `StreamIngestion`
    /// resolves the *logical* stream from a changed path and then reads the path its own state
    /// holds, so without this the channel would keep reading a file that is no longer there and a
    /// channel with no live tap would go quietly stale.
    func transcriptMoved(to path: URL) async {
        // **The created channel's first transcript arrives here, and this is what reopens it.**
        // `FleetCoordinator.indexChanged` forwards every added and updated entry's path to this
        // registry, so the delta that first lists a created channel reaches this method — and the
        // column's `.task(id:)` will not run again for a channel that stayed selected, which is
        // the case *New channel* is always in. Tracker 66's retry left `hasOpened` false for
        // exactly this, and this is the trigger it needed.
        if awaitsTranscript, ingestion == nil {
            awaitsTranscript = false
            guard let workspace, let lifecycle else { return }
            await performOpen(workspace: workspace, lifecycle: lifecycle)
            return
        }
        // `ingestion != nil` rather than a binding: since the rebind moved into
        // `signal(.relocated:)` nothing here needs the actor itself, and a bound-but-unused value
        // is a compiler warning, which the floor does not allow. The condition still matters — a
        // model with no ingestion has nothing to relocate and must not raise the signal.
        guard ingestion != nil, transcriptPath != path else { return }
        transcriptPath = path
        // **One call, not two.** C3's `signal(.relocated:)` performs the path rebind itself — it
        // calls `relocated(mainPath:)` and says so at its own definition — so raising the signal is
        // the whole of the move: the paths this actor holds, and the fold hearing about something no
        // frame states. Calling both, as this did while the corrective was still in flight, ran the
        // rebind twice (tracker 130, closed here).
        await signal(.relocated(mainPath: path))
    }

    /// The app's raise site for the host signals no frame states: a prompt this host sent, a
    /// decision this host answered, a rewind this host asked for, a transcript this host moved.
    ///
    /// **`HostSignal` is modelled by C3 and was constructed nowhere in the tree.** That is why no
    /// decision card could leave `.pending` and why no turn summary could carry a `.prompted`
    /// attribution: the fold has always known how to apply these, and nothing ever raised one. This
    /// method is where they are raised, and it is a **forwarder** — the fold itself lives in
    /// `StreamIngestion`, one per channel, and not on this side.
    ///
    /// **C6.1 drives exactly one of the four** — `relocated`, from `transcriptMoved(to:)`, because it
    /// owns the path the index reports. The other three are called from the leaves that own the
    /// host's side of them: C6.2 after a `.send` and after an honoured rewind, C6.3 after a
    /// successful `perform(.answer)`. The name is theirs as much as this leaf's and is a cross-leaf
    /// contract rather than a local choice.
    func signal(_ signal: HostSignal) async {
        guard let ingestion else { return }
        let effect = await ingestion.signal(signal)
        // The fold answers with what changed. Republishing on an empty effect would push an
        // identical timeline at every subscriber for a signal that moved nothing.
        guard !effect.changes.isEmpty else { return }
        await publish()
    }

    /// Releases the ingestion and both loops. The registry calls it when a new launch replaces the
    /// workspace this model was built over.
    func close() {
        isTerminated = true
        coalescer.cancel()
        openingTask?.cancel(); openingTask = nil
        effectsTask?.cancel(); effectsTask = nil
        changesTask?.cancel(); changesTask = nil
        readbackTask?.cancel(); readbackTask = nil
        let ingestion = self.ingestion
        self.ingestion = nil
        Task { await ingestion?.close() }
        fanout.finish()
    }

    // MARK: - Publishing

    /// Republishes the channel's read model from the fold that owns it.
    ///
    /// **One read, not three.** `StreamIngestion.timeline` returns the durable projection, the
    /// overlay and the streaming preview together; assembling them from `projection`, `overlay` and
    /// `preview` would be three awaits on an actor, and a mutation landing between any two of them
    /// would publish a timeline that never existed. C3 says so at the property's own definition and
    /// this is the only place the app reads it.
    ///
    /// **Superseded 2026-09-08 (C6.1).** What stood here built `ChannelTimeline(durable:)` alone,
    /// which is why every running channel had an empty overlay and no streaming preview: C3's wire
    /// fold had no consumer anywhere in the app. The fold now lives in the ingestion — one fold, one
    /// subscription, in the layer that already owns the tap — and this reads its result.
    private func publish() async {
        guard let ingestion else { return }
        let next = await ingestion.timeline
        timeline = next
        // D11's eviction, read from the state the fold published rather than from a view's callback.
        // §8.4 counts a `control_cancel_request` that retired a refusal dialog as a resolution, and
        // nobody presses that: a registry fed only where a card answers never hears about it, and
        // the messages the refusal took back stay on screen for the life of the channel.
        retraction.observe(next.overlay, in: key)
        fanout.yield(next)
    }

    /// The publish path's rate limiter, built here so its lifetime is this model's.
    ///
    /// It is `lazy` because it captures `self`: the closure is what a publish *is*, and a coalescer
    /// that published something else would be measuring nothing.
    @ObservationIgnored private lazy var coalescer = PublishCoalescer { [weak self] in
        await self?.publish()
    }

    /// The archived channel's tap: a sequence that is over before anybody reads it.
    private static func finishedEvents() -> AsyncStream<WireEvent> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - The thirty-hertz trailing edge

/// One publish per thirty-hertz window, on the trailing edge (child spec §4).
///
/// **Why the model and not the renderer.** The renderer is handed a timeline and draws it; how often
/// it is handed one is the model's to decide, and a burst of deltas that each republish the whole
/// read model costs the table a diff and a reload apiece however cheap the row is.
///
/// **Trailing edge, and what that buys.** The first request of a quiet stream arms the window and
/// the publish happens at its end, so every delta that arrived inside it is already in the read
/// model the publish reads — the coalescer buffers nothing and can drop nothing. A hundred deltas
/// inside one window are one publish; a single delta after quiet is one publish within the window's
/// length. A leading edge would publish the first delta of a burst and then the state at the end of
/// it, which is one publish more for no reader.
@MainActor
final class PublishCoalescer {

    /// Thirty hertz, as §4 states it.
    static let window = Duration.milliseconds(33)

    private let window: Duration
    private let publish: @Sendable () async -> Void
    private var armed: Task<Void, Never>?

    /// How many publishes this coalescer has performed. What a rate is asserted in.
    private(set) var publishCount = 0

    init(window: Duration = PublishCoalescer.window, publish: @escaping @Sendable () async -> Void) {
        self.window = window
        self.publish = publish
    }

    /// Asks for a publish. Cheap, synchronous and idempotent inside one window.
    func request() {
        guard armed == nil else { return }
        armed = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.window)
            guard !Task.isCancelled else { return }
            self.armed = nil
            self.publishCount += 1
            await self.publish()
        }
    }

    /// Drops a window that is still armed. The model's `close()` calls it: a publish landing after
    /// the release would push a timeline at subscribers the release just finished.
    func cancel() {
        armed?.cancel()
        armed = nil
    }
}

/// The fan-out behind `timelineUpdates`.
///
/// `@unchecked Sendable` is sound because the one mutable field is `continuations`, and every read
/// and every write of it happens between `lock.lock()` and `lock.unlock()` of this instance's
/// private `NSLock`. That lock is the serialising mechanism.
final class TimelineFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ChannelTimeline>.Continuation] = [:]
    private var finished = false

    func subscribe() -> AsyncStream<ChannelTimeline> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChannelTimeline>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        let over = finished
        if !over { continuations[id] = continuation }
        lock.unlock()
        if over { continuation.finish(); return stream }
        continuation.onTermination = { [weak self] _ in self?.drop(id) }
        return stream
    }

    func yield(_ timeline: ChannelTimeline) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(timeline) }
    }

    func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations = [:]
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }

    private func drop(_ id: UUID) {
        lock.lock(); continuations[id] = nil; lock.unlock()
    }
}
