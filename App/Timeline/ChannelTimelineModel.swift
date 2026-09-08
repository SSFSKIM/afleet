import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

// MARK: - The header

/// The four things spec §8 puts above the placeholder timeline — origin, presence, banner and
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

    var glyph: OriginGlyph? { origin.map(OriginGlyph.init) }

    init(title: String = "No channel selected", origin: ChannelOrigin? = nil, presence: Presence? = nil,
         banner: ChannelBanner? = nil, systemItem: SystemItem? = nil) {
        self.title = title; self.origin = origin; self.presence = presence
        self.banner = banner; self.systemItem = systemItem
    }

    init(row: ChannelRow) {
        self.init(title: row.title, origin: row.origin, presence: row.presence,
                  banner: row.channelBanner, systemItem: row.systemItem)
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

    /// What the placeholder draws, one row per item.
    var rows: [TimelineRow] { timeline.items.map(TimelineRow.init) }

    private(set) var header = ChannelHeader()

    /// True once `open(_:)` has driven the ingestion; a channel switch away and back does not
    /// restart it, which is what the registry retains this object for.
    private(set) var hasOpened = false

    /// Why the transcript could not be read, as a shape and never a path (§11).
    private(set) var failure: String?

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
    }

    // MARK: - The header

    /// Takes the row's live half without touching the ingestion.
    ///
    /// The header and the opening are separate concerns: origin, presence, banner and system item
    /// change under a channel that stays selected, and the read must not be restarted — or, worse,
    /// cancelled mid-flight — every time one of them does. The column calls this on every change to
    /// those four fields and calls `open` once per channel.
    func adopt(_ header: ChannelHeader) { self.header = header }

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
        header = ChannelHeader(row: row)
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
            failure = "this channel has no transcript in the index"
            return
        }
        // The other half of tracker 66: a retry that found the entry has to clear the failure the
        // attempt before it recorded, or the channel keeps reporting a condition that is over.
        failure = nil
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
                await self.publish()
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
        guard let ingestion, transcriptPath != path else { return }
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
        openingTask?.cancel(); openingTask = nil
        effectsTask?.cancel(); effectsTask = nil
        changesTask?.cancel(); changesTask = nil
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
        fanout.yield(next)
    }

    /// The archived channel's tap: a sequence that is over before anybody reads it.
    private static func finishedEvents() -> AsyncStream<WireEvent> {
        AsyncStream { $0.finish() }
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
