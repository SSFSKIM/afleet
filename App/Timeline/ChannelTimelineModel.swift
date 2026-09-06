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

// MARK: - One line of the placeholder timeline

/// One rendered line: the item's category, its timestamp and a one-line summary. Nothing else —
/// §8's "no composer, no markdown, no cards", and C6 replaces the whole view.
///
/// **The switch below is closed and total on purpose.** The category test compares the set of
/// categories this builder produced against the set the projection holds, in both directions, and
/// that comparison only means something while every item yields exactly one row. A `default:` here
/// that returned nil for a kind nobody thought about would drop that kind's items silently.
struct TimelineRow: Identifiable, Hashable, Sendable {
    let id: ItemID
    let category: TimelineCategory
    let timestamp: Date?
    let summary: String

    init(_ item: TimelineItem) {
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
    }

    // MARK: - Opening

    /// Reads the channel's history from disk and keeps it current.
    ///
    /// Idempotent past the header: the header follows the row on every call, because the live half
    /// of a row changes under the model, and the ingestion runs once.
    func open(_ row: ChannelRow) async {
        header = ChannelHeader(row: row)
        guard !hasOpened, let workspace, let lifecycle else { return }
        hasOpened = true

        guard let entry = await workspace.index.entry(key.session) else {
            failure = "this channel has no transcript in the index"
            return
        }

        let ingestion = StreamIngestion(session: key.session,
                                        configHome: workspace.configHome.root,
                                        mode: .filePrimary,
                                        diagnostics: workspace.diagnostics.timeline)
        self.ingestion = ingestion

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
        if let subscription = await subscribeToChanges() {
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

        do {
            _ = try await ingestion.open(file: entry.path, events: events)
        } catch {
            failure = "the channel's transcript could not be opened"
        }
        await publish()
    }

    /// Releases the ingestion and both loops. The registry calls it when a new launch replaces the
    /// workspace this model was built over.
    func close() {
        effectsTask?.cancel(); effectsTask = nil
        changesTask?.cancel(); changesTask = nil
        let ingestion = self.ingestion
        self.ingestion = nil
        Task { await ingestion?.close() }
        fanout.finish()
    }

    // MARK: - Publishing

    private func publish() async {
        guard let ingestion else { return }
        let next = ChannelTimeline(durable: await ingestion.projection)
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
