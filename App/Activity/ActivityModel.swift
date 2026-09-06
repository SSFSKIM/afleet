import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// One row of Activity as the view draws it: C4's `ActivityRow`, plus the two things a view needs
/// that a pure query over states and frames cannot know — whether this row may be answered where it
/// stands, and a stable identity to draw it under.
struct ActivityItem: Identifiable, Sendable {

    /// The permission ask a row may answer inline. Non-nil for exactly one shape: a `can_use_tool`
    /// request, still open, that does not carry `requires_user_interaction` (spec §5, §8.4).
    struct PermissionAsk: Hashable, Sendable {
        var id: RequestID
        var toolName: String
    }

    let row: ActivityRow
    let ask: PermissionAsk?
    /// Position in the query's output. Rows repeat — two failed results of the same tool are two
    /// rows with identical contents — so the position is what separates them.
    let position: Int

    var id: String { "\(position)" }
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
    /// The last refusal an inline answer met, if any. Cleared by the next successful answer.
    private(set) var answerFailure: String?

    // MARK: - Seams

    private let lifecycle: any LifecycleAPI
    private let configHome: URL
    private let store: (any StateStore)?
    private let shell: ShellModel
    private let router: NotificationRouter
    private let now: @Sendable () -> Date

    // MARK: - State

    private var states: [ChannelKey: ChannelState] = [:]
    private var pumps: [ChannelKey: ChannelEventPump] = [:]
    /// The last marker the user has seen on each channel, by session id. Persisted under
    /// `FleetKitKeys.unreadCursors`; the store sits beside one config home, so the session alone
    /// identifies the channel in it.
    private var cursors: [String: String] = [:]
    private var rebuildTask: Task<Void, Never>?
    /// The last cursor write. Each waits for the one before it, so two viewings in quick succession
    /// cannot write the older cursor last.
    private var cursorWrite: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var starting: Set<ChannelKey> = []

    /// How many times the rows a view reads have been rewritten. A count, for the tests that assert
    /// a burst does not become a paint each (§11: counts, never identifiers).
    private(set) var rebuildCount = 0

    init(lifecycle: any LifecycleAPI,
         configHome: URL,
         shell: ShellModel,
         router: NotificationRouter,
         store: (any StateStore)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.lifecycle = lifecycle
        self.configHome = configHome
        self.shell = shell
        self.router = router
        self.store = store
        self.now = now
    }

    // MARK: - Starting

    /// Loads the persisted cursors, takes the fleet's current states and begins following the
    /// channels that are owned. Returns once the first rows are on screen.
    func start() async {
        if let store,
           let persisted = try? await store.read([String: String].self,
                                                 namespace: .fleetKit,
                                                 key: FleetKitKeys.unreadCursors) {
            cursors = persisted ?? [:]
        }
        for state in await lifecycle.states() { states[state.key] = state }
        for key in states.keys where isOwned(states[key]) { await follow(key) }
        states = states.filter { isWorthKeeping($0.value) }
        rebuild()
        observeFocus()
    }

    func stop() {
        rebuildTask?.cancel(); rebuildTask = nil
        focusTask?.cancel(); focusTask = nil
        for pump in pumps.values { pump.stop() }
        pumps.removeAll()
    }

    /// The one feed of `ChannelState`s: `FleetBrowserModel` consumes `updates` and hands each state
    /// on. Wired here rather than in the browser so the browser knows nothing about Activity.
    func attach(to browser: FleetBrowserModel) {
        browser.stateObserver = { [weak self] state in self?.apply(state) }
    }

    /// One channel's state. Also the return value of an answered decision, which is why it is not
    /// private.
    func apply(_ state: ChannelState) {
        if isOwned(state), pumps[state.key] == nil {
            Task { await follow(state.key) }
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

    /// An owned channel counts whether or not its pump exists yet: `follow` is asynchronous, so a
    /// state that arrives with the channel newly owned reaches here before the subscription does,
    /// and dropping it would leave the pump feeding a channel the query never looks at. C4's cap
    /// bounds how many channels can be owned at once, so this keeps the bound.
    private func isWorthKeeping(_ state: ChannelState) -> Bool {
        !state.pendingDecisions.isEmpty || state.systemItem != nil
            || pumps[state.key] != nil || isOwned(state)
    }

    private func isOwned(_ state: ChannelState?) -> Bool {
        guard let state else { return false }
        if case .owned = state.origin { return true }
        return false
    }

    /// Takes this channel's one `events(of:)` subscription, unless the app is already following as
    /// many channels as C4 lets run at once.
    private func follow(_ key: ChannelKey) async {
        guard pumps[key] == nil, !starting.contains(key),
              pumps.count + starting.count < ChannelEventPump.maximumPumps else { return }
        starting.insert(key)
        defer { starting.remove(key) }
        guard let stream = await lifecycle.events(of: key) else { return }
        guard pumps[key] == nil else { return }
        let pump = ChannelEventPump(key: key) { [weak self] pump, event in
            self?.pumpDelivered(event, from: pump)
        }
        pumps[key] = pump
        pump.start(stream)
    }

    /// This channel's pump, or nil if the app is not following it. Read by a test that has to know
    /// the events it pushed have arrived before it asserts on the rows they produce — the wait is
    /// on the input, the assertion on the output.
    func pump(for key: ChannelKey) -> ChannelEventPump? { pumps[key] }

    private func pumpDelivered(_ event: WireEvent, from pump: ChannelEventPump) {
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
        var recent: [ChannelKey: [Frame]] = [:]
        for (key, pump) in pumps {
            mirrors[key] = pump.liveWork
            recent[key] = pump.recent
        }
        let rows = ActivityQuery.rows(states: ordered, mirrors: mirrors, recent: recent)
        items = rows.enumerated().map { position, row in
            ActivityItem(row: row, ask: ask(for: row), position: position)
        }
        releaseWaiters()
    }

    /// The inline-answer affordance, or nil.
    ///
    /// Nil for every kind but a decision, and for a decision it is nil unless the request the pump
    /// holds is a `can_use_tool` without `requires_user_interaction`. §8.4 makes that flag the
    /// engine saying the tool's own card is the surface, so an *Allow once* button here would be
    /// answering a question the user has not been shown. Every other kind — question, plan,
    /// elicitation, dialog — gets its row and a *Go to channel*, because those cards are C6's and
    /// half a card is a wrong affordance rather than a partial one.
    private func ask(for row: ActivityRow) -> ActivityItem.PermissionAsk? {
        guard case .decision(let id) = row.kind,
              let request = pumps[row.key]?.requests[id],
              case .canUseTool(let tool) = request.payload,
              tool.requiresUserInteraction != true else { return nil }
        return ActivityItem.PermissionAsk(id: id, toolName: tool.toolName)
    }

    // MARK: - Answering

    /// *Allow once*: `allow`, classified `user_temporary` (§8.4's binding mapping).
    ///
    /// *Always allow* is deliberately absent. It needs the request's `permission_suggestions` and a
    /// choice of destination, and that card is C6's.
    func allowOnce(_ ask: ActivityItem.PermissionAsk, on key: ChannelKey) async {
        await answer(.permission(.allow(updatedInput: nil, updatedPermissions: nil,
                                        classification: .userTemporary)),
                     to: ask.id, on: key)
    }

    /// *Deny*: `deny`, classified `user_reject`, without interrupting the turn.
    func deny(_ ask: ActivityItem.PermissionAsk, on key: ChannelKey) async {
        await answer(.permission(.deny(message: "Denied from Activity.", interrupt: false,
                                       classification: .userReject)),
                     to: ask.id, on: key)
    }

    /// The one path an answer leaves by. `LifecycleAPI` has no `answer` member; the action is
    /// `LifecycleAction.answer(RequestID, InboundAnswer)`.
    private func answer(_ answer: InboundAnswer, to id: RequestID, on key: ChannelKey) async {
        do {
            let state = try await lifecycle.perform(.answer(id, answer), on: key)
            answerFailure = nil
            pumps[key]?.forget(id)
            apply(state)
            rebuild()
        } catch let error as LifecycleError {
            answerFailure = RowBanner(error).text
        } catch {
            answerFailure = "The answer failed: \(type(of: error))."
        }
    }

    // MARK: - Badges and the unread cursor

    /// What the sidebar draws beside a channel (G2b).
    func badge(for session: SessionID) -> ChannelBadge {
        let key = ChannelKey(configHome: configHome, session: session)
        guard let marker = marker(of: key) else { return .none }
        guard cursors[session.description] != marker else { return .none }
        return ChannelBadge(count: states[key]?.pendingDecisions.count ?? 0, isUnread: true)
    }

    /// The newest thing that has happened on a channel, as one token.
    ///
    /// A pending decision has no transcript item — `PendingDecision` carries an id, not a uuid — so
    /// the token is the request id where there is no uuid. What matters is only that it changes
    /// when something new arrives and does not change when nothing does.
    private func marker(of key: ChannelKey) -> String? {
        var token: String?
        for row in items where row.key == key {
            if let uuid = row.row.itemUUID {
                token = uuid
            } else if case .decision(let id) = row.row.kind {
                token = id.rawValue
            }
        }
        return token
    }

    /// The user looked at this channel: its badge clears, and the cursor is persisted so a rebuilt
    /// model does not bring it back.
    func markSeen(_ session: SessionID) {
        let key = ChannelKey(configHome: configHome, session: session)
        guard let marker = marker(of: key), cursors[session.description] != marker else { return }
        cursors[session.description] = marker
        let snapshot = cursors
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
    private func observeFocus() {
        if let session = shell.focus.session { markSeen(session) }
        withObservationTracking {
            _ = shell.focus
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
