import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// One row of Activity as the view draws it: C4's `ActivityRow`, plus the two things a view needs
/// that a pure query over states and frames cannot know — whether this row may be answered where it
/// stands, and a stable identity to draw it under.
struct ActivityItem: Identifiable, Sendable {

    let row: ActivityRow
    /// The card this row answers where it stands, or nil for a row that opens its channel instead.
    /// Non-nil for exactly one shape: a plain permission ask, still open, that does not carry
    /// `requires_user_interaction` (spec §5, §8.4, D4).
    let card: DecisionCard?
    /// Position in the query's output. Rows repeat — two failed results of the same tool are two
    /// rows with identical contents — so the position is what separates them.
    let position: Int

    /// Position **and** the row's own identity.
    ///
    /// The position alone separates two rows with identical contents, which is what it was added
    /// for; it does not separate two *different* rows that happen to occupy one position across a
    /// rebuild. A List keys its row views on this, and the compact permission card it hosts holds
    /// view state — the destination an *Always allow* would be filed at. Under the position alone,
    /// a request answered and replaced by the next one inherits that state, and the retained
    /// destination is applied to a different request's rules.
    var id: String { "\(position)|\(identity)" }

    /// What this row is *about*, as far as anything here can name it: the request a decision waits
    /// on, the transcript item a frame-derived row links to, or the row's own short text.
    private var identity: String {
        switch row.kind {
        case .decision(let request): request.rawValue
        case .agentRunning(let task), .agentFailed(let task): task
        default: row.itemUUID ?? row.text
        }
    }
    var key: ChannelKey { row.key }

    /// What kind of thing this is, in one word the view puts in front of the text. Exhaustive over
    /// `ActivityRow.Kind`, so a new kind is a compile error rather than a blank row (§5: Activity
    /// shows a row for **every** decision kind).
    var kindLabel: String {
        switch row.kind {
        case .decision: "Decision"
        case .notification: "Notice"
        case .failedResult: "Failed"
        case .permissionDenied: "Denied"
        case .rateLimitRefused: "Rate limited"
        case .rateLimitInfo: "Rate limit"
        case .authProblem: "Sign-in"
        case .agentRunning: "Agent"
        case .agentFailed: "Agent failed"
        case .systemItem: "Channel"
        }
    }
}

/// What a sidebar row shows for a channel the user is not looking at (spec §6, G2b).
///
/// Both halves clear together on viewing, which is why the count is not simply
/// `pendingDecisions.count`: a decision the user has *seen* is still pending, and a red count that
/// survived looking at it would tell the user to act on something they already looked at. A
/// decision that arrives afterwards moves the channel's marker and the badge comes back.
struct ChannelBadge: Hashable, Sendable {
    var count: Int
    var isUnread: Bool
    var isEmpty: Bool { count == 0 && !isUnread }
    static let none = ChannelBadge(count: 0, isUnread: false)
}

/// Activity (spec §5) and the two things that hang off it: the badges of §6 and the notifications
/// of §8.7.
///
/// It re-implements none of C4's query. `ActivityQuery.rows(states:mirrors:recent:)` is a pure
/// function over three inputs and this model's whole job is to hold those inputs current:
/// - `states` from `LifecycleAPI.states()` once at start, and from every `ChannelState` the fleet
///   publishes afterwards. It does **not** open a second `updates` loop: `LifecycleAPI.updates` is
///   one stream and not a fan-out, so a second consumer would take half the states and leave the
///   sidebar with the other half. `FleetBrowserModel` is the one consumer and hands each state on.
/// - `mirrors` and `recent` from one `ChannelEventPump` per owned channel.
///
/// Everything it decides itself is in three places: which rows may be answered inline, which
/// channels are unread, and — through `NotificationRouter` — which events are worth telling the
/// user about.
@MainActor
@Observable
final class ActivityModel {

    // MARK: - What the view shows

    private(set) var items: [ActivityItem] = []
    /// The in-app half of spike S-C5-1's fallback: notifications the system would not deliver,
    /// newest first, until the user dismisses them.
    private(set) var banners: [AfleetNotification] = []

    // MARK: - Seams

    /// The one path a card's answer leaves by, shared with the timeline's host (contract Y2).
    /// Activity performs no answer of its own and constructs no `InboundAnswer`.
    let answering: DecisionAnswering

    /// Where a channel's fold is, for the host signal a successful answer raises (spec D2,
    /// contract X4).
    ///
    /// The engine sends no frame back for an answer, so the only thing that can move a decision out
    /// of `.pending` is the host saying it answered. Activity answers for channels whose
    /// `ChannelTimelineModel` it does not own, so it is handed the app's one
    /// `ChannelTimelineRegistry` as a provider — the shape the composer registry already receives
    /// its own seams in — rather than reaching for a registry of its own, which is the second
    /// capability path the C6 cut exists to prevent.
    ///
    /// Nil for a model built without one: it then raises nowhere, which is right for a surface with
    /// no fold to tell.
    var timeline: (@MainActor (ChannelKey) -> ChannelTimelineModel)?

    private let lifecycle: any LifecycleAPI
    private let configHome: URL
    private let store: (any StateStore)?
    private let shell: ShellModel
    private let router: NotificationRouter
    private let unknownFrames: UnknownFrameCounter?
    private let now: @Sendable () -> Date

    // MARK: - State

    private var states: [ChannelKey: ChannelState] = [:]
    private var pumps: [ChannelKey: ChannelEventPump] = [:]
    /// Retired channels retain the bounded frame tail, not subscriptions or dead requests.
    private var history: [ChannelKey: [Frame]] = [:]
    /// The last marker the user has seen on each channel, by session id. Persisted under
    /// `FleetKitKeys.unreadCursors`; the store sits beside one config home, so the session alone
    /// identifies the channel in it.
    private struct SeenActivity: Codable, Equatable {
        var frames: Set<String>
        var decisions: Set<String>

        func containsArrivals(since seen: SeenActivity) -> Bool {
            !frames.isSubset(of: seen.frames) || !decisions.isSubset(of: seen.decisions)
        }

        // X6 keeps [String: String] at this key; each value is an app-owned opaque cursor.
        // Encoding sets of strings cannot fail (no floating-point values or custom encoders).
        var encoded: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    }
    private var cursors: [String: SeenActivity] = [:]
    private var rebuildTask: Task<Void, Never>?
    /// The last cursor write. Each waits for the one before it, so two viewings in quick succession
    /// cannot write the older cursor last.
    private var cursorWrite: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var starting: [ChannelKey: Task<Void, Never>] = [:]
    /// The channels a live `apply(_:)` reached while `start()` was sampling the fleet. Non-nil only
    /// for the duration of that sample. `LifecycleAPI.states()` asks each supervisor in turn, so a
    /// state published during the sample is *newer* than the entry the sample carries for it, and
    /// assigning the sample unconditionally would hide a pending decision or restore an answered
    /// one.
    private var liveDuringSample: Set<ChannelKey>?
    /// The pumps whose stream is being drained before it is let go, by channel. A retired pump is
    /// kept here until the frames already queued on its stream have been folded; nothing else may
    /// consult it, which is why it is not `pumps`.
    private var draining: [ChannelKey: (pump: ChannelEventPump, task: Task<Void, Never>)] = [:]
    /// Adoption may publish a still-background state while waiting for the worker to exit.
    /// Prepared pumps outlive those intermediate states until the enclosing action finishes.
    private var preparedActions: [ChannelKey: Int] = [:]

    /// How many times the rows a view reads have been rewritten. A count, for the tests that assert
    /// a burst does not become a paint each (§11: counts, never identifiers).
    private(set) var rebuildCount = 0

    init(lifecycle: any LifecycleAPI,
         configHome: URL,
         shell: ShellModel,
         router: NotificationRouter,
         store: (any StateStore)? = nil,
         reservations: DecisionReservations = DecisionReservations(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifecycle = lifecycle
        self.answering = DecisionAnswering(lifecycle: lifecycle, reservations: reservations)
        self.configHome = configHome
        self.shell = shell
        self.router = router
        self.store = store
        self.unknownFrames = store.map { UnknownFrameCounter(store: $0) }
        self.now = now
        // The engine sends no frame back for an answer and a successful one is never cancelled, so
        // the pump learns a router-answered request is closed only by being told. This is the same
        // seam the inline permission path uses; without it every completed payload the router
        // answered would sit in `requests` until the process exits.
        router.onAnswered = { [weak self] id, key in self?.pumps[key]?.forget(id) }
        // The same seam for a card's answer: the engine sends no frame back for one, so the pump
        // learns the request is closed only by being told, and the state `perform` returned is the
        // fleet's newest.
        // D2's raise: the fold this answer belongs to hears that the host answered it, so the
        // card leaves `.pending` on screen and not only in a test that hands the fold in.
        answering.raise = { [weak self] key, signal in
            guard let model = self?.timeline?(key) else { return }
            await model.signal(signal)
        }
        // **Registered on the shared set, not on this model's own answering object.** Activity is
        // the host that holds the live `InboundRequest` — its pump is what a card is built from —
        // and the request is answerable from surfaces this model knows nothing about: the Thread
        // tab, the timeline's card. An answer sent from any of them closes the request, so the
        // payload has to be released whoever sent it, or it sits in `requests` until the process
        // exits.
        reservations.observe(self) { [weak self] id, key, state in
            guard let self else { return }
            self.pumps[key]?.forget(id)
            self.apply(state)
            self.rebuild()
        }
    }

    // MARK: - Starting

    /// Loads the persisted cursors, takes the fleet's current states and begins following the
    /// channels that are owned. Returns once the first rows are on screen.
    func start() async {
        if let store,
           let persisted = try? await store.read([String: String].self,
                                                 namespace: .fleetKit,
                                                 key: FleetKitKeys.unreadCursors) {
            cursors = persisted.compactMapValues {
                try? JSONDecoder().decode(SeenActivity.self, from: Data($0.utf8))
            }
        }
        liveDuringSample = []
        let sampled = await lifecycle.states()
        let live = liveDuringSample ?? []
        liveDuringSample = nil
        for state in sampled where !live.contains(state.key) { states[state.key] = state }
        for key in states.keys where isLive(states[key]) { await follow(key) }
        states = states.filter { isWorthKeeping($0.value) }
        rebuild()
        observeFocus()
    }

    func stop() {
        rebuildTask?.cancel(); rebuildTask = nil
        focusTask?.cancel(); focusTask = nil
        for pump in pumps.values { pump.stop() }
        pumps.removeAll()
        for task in starting.values { task.cancel() }
        starting.removeAll()
        for entry in draining.values { entry.task.cancel(); entry.pump.stop() }
        draining.removeAll()
    }

    /// The one feed of `ChannelState`s: `FleetBrowserModel` consumes `updates` and hands each state
    /// on. Wired here rather than in the browser so the browser knows nothing about Activity.
    func attach(to browser: FleetBrowserModel) {
        browser.stateObserver = { [weak self] state in self?.apply(state) }
        browser.beforeAction = { [weak self] key in
            guard let self else { return {} }
            self.preparedActions[key, default: 0] += 1
            await self.follow(key)
            return { [weak self] in self?.finishAction(on: key) }
        }
    }

    /// One channel's state. Also the return value of an answered decision, which is why it is not
    /// private.
    func apply(_ state: ChannelState) {
        liveDuringSample?.insert(state.key)
        if !isLive(state) {
            if preparedActions[state.key] == nil { retire(state.key) }
        } else if pumps[state.key] == nil {
            Task {
                guard isLive(states[state.key]) else { return }
                await follow(state.key)
            }
        }
        // Activity is O(what is happening), not O(the fleet). Registering a real config home makes
        // C4 seed a `ChannelState` for every channel on the machine — thousands, almost all of them
        // archived — and a channel with nothing pending, no system item and no pump cannot produce
        // a row however long the query looks at it, because rows come from `pendingDecisions`, from
        // `systemItem` and from the two inputs only a pump fills. Keeping those states would make
        // every rebuild iterate the whole fleet to produce nothing. A channel that later has
        // something to say publishes another state and comes back.
        if isWorthKeeping(state) {
            states[state.key] = state
        } else {
            states[state.key] = nil
        }
        scheduleRebuild()
    }

    /// Live channels are kept while subscription is in flight; retired channels only while
    /// they still supply query inputs. C4 bounds processes, not channels visited or subscriptions
    /// prepared before an action. Do not impose a second process cap on event listeners here.
    private func isWorthKeeping(_ state: ChannelState) -> Bool {
        !state.pendingDecisions.isEmpty || state.systemItem != nil
            || pumps[state.key] != nil || history[state.key] != nil || draining[state.key] != nil
            || isLive(state)
    }

    private func isLive(_ state: ChannelState?) -> Bool {
        guard let state else { return false }
        switch state.origin {
        case .owned(.connecting), .owned(.ready), .owned(.contended): return true
        default: return false
        }
    }

    private func follow(_ key: ChannelKey) async {
        if let pending = starting[key] { await pending.value; return }
        guard pumps[key] == nil else { return }
        // Share the awaited preparation with an overlapping state update. Returning just because
        // another subscription is starting would reopen the pre-action delivery gap.
        let pending = Task { @MainActor [weak self] in
            guard let self, let stream = await self.lifecycle.events(of: key),
                  !Task.isCancelled else { return }
            let pump = ChannelEventPump(key: key, recent: self.history.removeValue(forKey: key) ?? [],
                                        onFinish: { [weak self] pump in
                guard let self, self.pumps[key] === pump else { return }
                self.retire(key)
                self.scheduleRebuild()
            }) { [weak self] pump, event in
                self?.pumpDelivered(event, from: pump)
            }
            self.pumps[key] = pump
            pump.start(stream)
        }
        starting[key] = pending
        await pending.value
        if starting[key] == pending { starting[key] = nil }
    }

    private func finishAction(on key: ChannelKey) {
        let remaining = (preparedActions[key] ?? 1) - 1
        if remaining > 0 { preparedActions[key] = remaining; return }
        preparedActions[key] = nil
        if !isLive(states[key]) {
            retire(key)
            scheduleRebuild()
        }
    }

    /// Lets a channel go, **after** the pump has folded what its stream had already queued.
    ///
    /// The lifecycle states and the wire events are two independently consumed streams, so the
    /// dormant state that ends a channel can overtake the last frames of it. Cancelling consumption
    /// on the spot drops those frames from the retained history and from the notifications they
    /// would have raised. The drain is bounded — a few turns of the main actor, ending as soon as
    /// the pump goes quiet — never a wait on the process.
    private func retire(_ key: ChannelKey) {
        starting.removeValue(forKey: key)?.cancel()
        guard let pump = pumps.removeValue(forKey: key) else { return }
        if !pump.recent.isEmpty { history[key] = pump.recent }
        if let superseded = draining.removeValue(forKey: key) {
            superseded.task.cancel()
            superseded.pump.stop()
        }
        let task = Task { @MainActor [weak self] in
            await pump.drainQueued()
            pump.stop()
            guard let self, !Task.isCancelled, self.draining[key]?.pump === pump else { return }
            self.draining[key] = nil
            // A pump started again in the meantime already owns this channel's history.
            if self.pumps[key] == nil, !pump.recent.isEmpty { self.history[key] = pump.recent }
            if let state = self.states[key], !self.isWorthKeeping(state) { self.states[key] = nil }
            self.scheduleRebuild()
        }
        draining[key] = (pump, task)
    }

    /// This channel's pump, or nil if the app is not following it. Read by a test that has to know
    /// the events it pushed have arrived before it asserts on the rows they produce — the wait is
    /// on the input, the assertion on the output.
    func pump(for key: ChannelKey) -> ChannelEventPump? { pumps[key] }

    private func pumpDelivered(_ event: WireEvent, from pump: ChannelEventPump) {
        // One ingestion owner for the install-wide tally. The timeline's independent fan-out
        // must not record again. Only unknown types count here, not malformed known frames.
        if case .frame(.opaque(let frame), _) = event,
           case .unknownType = frame.reason, let type = frame.type, let unknownFrames {
            Task { await unknownFrames.record(type) }
        }
        router.handle(event, on: pump.key)
        scheduleRebuild()
    }

    // MARK: - The rows

    /// Arranges for one rebuild after the main actor has run whatever else is ready, so a burst of
    /// frames costs one pass over the query rather than one per frame. Not a deadline: a single
    /// event on a quiet fleet rebuilds on the very next turn of the main actor.
    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    /// Runs C4's query over what the model holds and turns each row into an item.
    func rebuild() {
        rebuildCount &+= 1
        let ordered = states.values.sorted { $0.lastActivity > $1.lastActivity }
        var mirrors: [ChannelKey: [any TaskMirrorReading]] = [:]
        var recent = history
        for (key, pump) in pumps {
            mirrors[key] = pump.liveWork
            recent[key] = pump.recent
        }
        let rows = ActivityQuery.rows(states: ordered, mirrors: mirrors, recent: recent)
        items = rows.enumerated().map { position, row in
            ActivityItem(row: row, card: card(for: row), position: position)
        }
        markViewedChannelSeen()
        releaseWaiters()
    }

    /// The card this row answers where it stands, or nil.
    ///
    /// Activity holds no `ChannelTimeline` for a channel the user has not opened, so it cannot read
    /// C3's overlay; it holds the live `InboundRequest` in its pump and builds the item the reducer
    /// would have built for it (spec D14). The card itself, its actions and its answers are
    /// `DecisionCardView`'s and `DecisionCard.answer(_:)`'s — Activity constructs none of them.
    ///
    /// Nil for every kind but a decision, and for a decision it is nil unless **both** hold: the
    /// card's kind is `.permission`, and the request does not carry `requires_user_interaction`
    /// (spec D17). Neither implies the other. The flag is the engine saying the tool's own card is
    /// the surface, so an *Allow once* button here would answer a question the user has not been
    /// shown; the kind is the human ruling about what Activity may answer at all, so a question or
    /// a plan that arrives *without* the flag is still refused inline. Every other kind — question,
    /// plan, elicitation, dialog — gets its row and a *Go to channel*, because half a card is a
    /// wrong affordance rather than a partial one (C5's human-gate ruling 4, spec D4).
    private func card(for row: ActivityRow) -> DecisionCard? {
        guard case .decision(let id) = row.kind,
              let request = pumps[row.key]?.requests[id],
              case .canUseTool(let tool) = request.payload,
              tool.requiresUserInteraction != true,
              let item = DecisionItem(surfacing: request, in: row.key) else { return nil }
        let card = DecisionCard(item)
        guard case .permission = card.kind else { return nil }
        return card
    }

    // MARK: - Badges and the unread cursor

    /// What the sidebar draws beside a channel (G2b).
    func badge(for session: SessionID) -> ChannelBadge {
        let key = ChannelKey(configHome: configHome, session: session)
        guard let marker = marker(of: key) else { return .none }
        if let seen = cursors[session.description], !marker.containsArrivals(since: seen) { return .none }
        return ChannelBadge(count: states[key]?.pendingDecisions.count ?? 0, isUnread: true)
    }

    /// Compare current identities with what was seen, not two whole pending-set snapshots.
    /// An identity's departure (answer, cancellation or row removal) cannot be an arrival.
    /// Frames and decisions have separate identity domains so a seen frame cannot hide an ask.
    /// Both sets are bounded by the current query/pending table, not an ever-growing event log.
    private func marker(of key: ChannelKey) -> SeenActivity? {
        let frames = Set(items.filter { $0.key == key }.compactMap { $0.row.itemUUID })
        let decisions = Set(states[key]?.pendingDecisions.map { $0.id.rawValue } ?? [])
        guard !frames.isEmpty || !decisions.isEmpty else { return nil }
        return SeenActivity(frames: frames, decisions: decisions)
    }

    /// The user looked at this channel: its badge clears, and the cursor is persisted so a rebuilt
    /// model does not bring it back.
    func markSeen(_ session: SessionID) {
        let key = ChannelKey(configHome: configHome, session: session)
        guard let marker = marker(of: key), cursors[session.description] != marker else { return }
        cursors[session.description] = marker
        let snapshot = cursors.mapValues(\.encoded)
        if let store {
            let previous = cursorWrite
            cursorWrite = Task {
                await previous?.value
                try? await store.write(snapshot, namespace: .fleetKit, key: FleetKitKeys.unreadCursors)
            }
        }
        releaseWaiters()
    }

    /// Returns once every cursor written so far is on disk. A rebuilt model reads the store, so a
    /// test that rebuilds has to know the write it is relying on has landed.
    func cursorsPersisted() async { await cursorWrite?.value }

    /// Watches what the window is looking at and marks that channel seen. `withObservationTracking`
    /// re-arms itself on each change, which is how a non-SwiftUI observer follows an `@Observable`
    /// without polling it.
    private func markViewedChannelSeen() {
        guard let session = shell.focus.session,
              shell.isInView(ChannelKey(configHome: configHome, session: session)) else { return }
        markSeen(session)
    }

    private func observeFocus() {
        markViewedChannelSeen()
        withObservationTracking {
            _ = shell.focus
            _ = shell.isApplicationActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeFocus()
            }
        }
    }

    // MARK: - The in-app notification surface (spike S-C5-1's fallback)

    /// Raises a notification the system would not deliver. Newest first, bounded, and the Dock tile
    /// carries the count so it is visible with the window behind something else.
    func present(_ notification: AfleetNotification) {
        banners.removeAll { $0.identifier == notification.identifier }
        banners.insert(notification, at: 0)
        if banners.count > 8 { banners.removeLast(banners.count - 8) }
        DockBadge.set(banners.count)
    }

    func dismiss(_ notification: AfleetNotification) {
        banners.removeAll { $0.identifier == notification.identifier }
        DockBadge.set(banners.count)
    }

    func dismissAllBanners() {
        banners.removeAll()
        DockBadge.set(0)
    }

    // MARK: - Being told, rather than asked

    /// True while a rebuild is scheduled and has not run.
    ///
    /// The rows a view reads are recomputed one main-actor hop after the event that changed them, so
    /// "the pump has the frame" and "the rows account for it" are two facts and only the second is
    /// what a reader sees. A consumer waiting on the first alone would be reading a proxy.
    var isRebuildPending: Bool { rebuildTask != nil }

    /// Suspends until the inputs satisfy `ready` **and** the rows have been recomputed since.
    func whenSettled(_ ready: @escaping @MainActor (ActivityModel) -> Bool) async {
        await whenChanged { model in ready(model) && !model.isRebuildPending }
    }

    /// Suspends until `predicate` holds, resumed by the rebuild that makes it true — the same rule
    /// `FleetBrowserModel` follows, and the reason no test here waits on a duration.
    func whenChanged(_ predicate: @escaping @MainActor (ActivityModel) -> Bool) async {
        if predicate(self) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: predicate, continuation: continuation))
        }
    }

    private struct Waiter {
        let predicate: @MainActor (ActivityModel) -> Bool
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
