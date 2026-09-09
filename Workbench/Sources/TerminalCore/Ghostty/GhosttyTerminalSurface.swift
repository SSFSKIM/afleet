import AppKit
import Dispatch
import Foundation
import GhosttyTerminal
import Synchronization

private struct TerminalHandlers: Sendable {
    var onInput: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (TerminalSize) -> Void)?
}

/// The adapter is the sole owner of this box, and its `Mutex` serialises every read and write
/// made by the main-actor properties and libghostty's off-main session callbacks.
private final class TerminalHandlerBox: Sendable {
    private let handlers = Mutex(TerminalHandlers())

    var onInput: (@Sendable (Data) -> Void)? {
        get { handlers.withLock { $0.onInput } }
        set { handlers.withLock { $0.onInput = newValue } }
    }

    var onResize: (@Sendable (TerminalSize) -> Void)? {
        get { handlers.withLock { $0.onResize } }
        set { handlers.withLock { $0.onResize = newValue } }
    }

    func sendInput(_ data: Data) {
        let handler = handlers.withLock { $0.onInput }
        handler?(data)
    }

    func sendResize(_ viewport: InMemoryTerminalViewport) {
        let handler = handlers.withLock { $0.onResize }
        handler?(
            TerminalSize(
                rows: Int(viewport.rows),
                columns: Int(viewport.columns),
                pixelWidth: Int(viewport.widthPixels),
                pixelHeight: Int(viewport.heightPixels)
            )
        )
    }
}

typealias GhosttySessionFactory = (
    _ write: @escaping @Sendable (Data) -> Void,
    _ resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
    _ suppressesPixelOnlyResizes: Bool
) -> InMemoryTerminalSession

typealias GhosttySessionFinisher = @Sendable (
    _ session: InMemoryTerminalSession,
    _ exitCode: UInt32,
    _ runtimeMilliseconds: UInt64
) -> Void

/// Returns once the session has finished parsing the `byteCount` bytes just handed to it. The
/// dependency offers no completion callback, so the barrier is its queue drain, taken off the
/// main thread. A test substitutes a slower one to stand in for a renderer that is behind.
typealias GhosttyFeedBarrier = @Sendable (
    _ session: InMemoryTerminalSession,
    _ byteCount: Int
) -> Void

/// Whether the session has a surface to parse into. The dependency publishes no attachment
/// event and keeps `currentSurface` to itself, so the probe is its one public tell: a viewport
/// read answers `nil` until a view has attached a surface and a string once one has. A test
/// substitutes a stand-in for a renderer it does not put in a window.
typealias GhosttySurfaceAttachmentProbe = @Sendable (InMemoryTerminalSession) -> Bool

/// What the adapter is holding for a renderer that has not caught up.
///
/// `InMemoryTerminalSession.receive` hands each payload to a serial queue with no bound of its
/// own once a surface is attached, and the host's read loop does not wait for the parse. Without
/// this queue a child that produces faster than the terminal parses accumulates outside the PTY
/// layer's bounded buffer, where nothing measures it and the pty's own flow control never engages.
///
/// So the adapter keeps the backlog itself, hands the session one bounded chunk at a time, and
/// waits for that chunk to be parsed before handing over the next. At most one chunk is ever
/// inside the dependency, the backlog here is measurable, and a host that waits on
/// ``GhosttyTerminalSurface/awaitFeedCapacity()`` stops reading the master until the renderer
/// catches up — which is the pty's own flow control, the back-pressure a terminal is designed
/// around. Nothing is dropped anywhere on that path.
///
/// The state is under a `Mutex`: `feed` arrives on the main actor and the drain runs on a private
/// queue.
final class GhosttyFeedQueue: Sendable {
    enum Item: Sendable {
        case output(Data)
        case processExit(Int32)
    }

    /// One backlog entry. Output carries whether a later `append` may still extend it, and only
    /// an entry whose storage still starts at index zero may. Extending a `Data` that is already
    /// a slice grows its buffer while the prefix handed over earlier stays allocated inside it,
    /// so a partial drain followed by a refill, repeated, grows retained storage without bound
    /// while `outstandingByteCount` stays flat. Sealing an entry the moment it is sliced keeps
    /// the backlog a ring of whole allocations, each one retired as it is consumed.
    private enum Entry {
        case output(Data, isExtendable: Bool)
        case processExit(Int32)
    }

    private struct State {
        var pending: [Entry] = []
        var outstandingByteCount = 0
        var isDraining = false
        var isAttached = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Waits whose task was cancelled before the waiter reached ``registerWaiter(_:_:)``.
        /// Cancellation and registration race, so the cancellation is recorded against the
        /// identifier and the registration that follows refuses rather than parking for ever.
        var cancelledWaiters: Set<UUID> = []
        /// Set by ``abandon()``. Nothing is queued after it and no drain begins again: the surface
        /// it fed has been disposed of.
        var isAbandoned = false
    }

    /// What ``abandon()`` leaves its caller to finish outside the lock.
    struct Abandonment {
        let waiters: [CheckedContinuation<Void, Never>]
        /// The process exit still waiting in the backlog, if the drain never reached it. Whoever
        /// holds the item tells the session, so the session is finished exactly once.
        let pendingExitCode: Int32?
    }

    private let state = Mutex(State())
    private let highWaterByteCount: Int
    private let lowWaterByteCount: Int
    private let chunkByteLimit: Int

    init(highWaterByteCount: Int, lowWaterByteCount: Int, chunkByteLimit: Int) {
        self.highWaterByteCount = highWaterByteCount
        self.lowWaterByteCount = lowWaterByteCount
        self.chunkByteLimit = chunkByteLimit
    }

    var outstandingByteCount: Int {
        state.withLock { $0.outstandingByteCount }
    }

    /// What the backlog's allocations occupy, including any prefix already handed over. This is
    /// ``outstandingByteCount`` plus whatever a partially consumed allocation still carries, and
    /// it is the measure a retained-storage test takes: the count is exactly what stays bounded
    /// when the storage behind it does not.
    var retainedStorageByteCount: Int {
        state.withLock { state in
            state.pending.reduce(into: 0) { total, entry in
                guard case let .output(data, _) = entry else { return }
                total += data.startIndex + data.count
            }
        }
    }

    /// Appends `data`, coalescing it with whatever output is already waiting — the renderer parses
    /// a byte stream, and delivery boundaries carry no meaning it can use. Coalescing stops at an
    /// entry that has been sliced, and at one already worth a whole chunk, so the ring never
    /// becomes one growing allocation. Reports whether this caller starts the drain.
    func append(_ data: Data) -> Bool {
        state.withLock { state in
            guard !state.isAbandoned else { return false }
            state.outstandingByteCount += data.count
            if case let .output(existing, isExtendable: true) = state.pending.last,
               existing.count < chunkByteLimit {
                var extended = existing
                extended.append(data)
                state.pending[state.pending.count - 1] = .output(extended, isExtendable: true)
            } else {
                state.pending.append(.output(data, isExtendable: data.count < chunkByteLimit))
            }
            return Self.beginDrainIfIdle(&state)
        }
    }

    /// The exit rides the same queue as the output: the child's last bytes are parsed before the
    /// terminal is told the process ended.
    func appendProcessExit(code: Int32) -> Bool {
        state.withLock { state in
            guard !state.isAbandoned else { return false }
            state.pending.append(.processExit(code))
            return Self.beginDrainIfIdle(&state)
        }
    }

    /// Drops everything queued, releases every waiter, and refuses whatever arrives later. Called
    /// once, from the surface's disposal.
    func abandon() -> Abandonment {
        state.withLock { state in
            state.isAbandoned = true
            let exitCode: Int32? = state.pending.reversed().compactMap {
                if case let .processExit(code) = $0 { code } else { nil }
            }.first
            state.pending.removeAll()
            state.outstandingByteCount = 0
            state.isDraining = false
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return Abandonment(waiters: waiters, pendingExitCode: exitCode)
        }
    }

    private static func beginDrainIfIdle(_ state: inout State) -> Bool {
        guard !state.isAbandoned else { return false }
        guard !state.isDraining else { return false }
        state.isDraining = true
        return true
    }

    /// Whether the renderer has a surface to parse into. Latched: nothing is handed to the
    /// session before the first attach, because the dependency buffers unattached output in a
    /// 1 MiB window it drops the oldest bytes from, and the adapter would be reporting capacity
    /// for bytes that no longer exist. After the first attach the dependency's own replay covers
    /// a surface that is swapped or rebuilt.
    var isAttached: Bool {
        state.withLock { $0.isAttached }
    }

    func markAttached() {
        state.withLock { $0.isAttached = true }
    }

    /// Ends the drain when there is nothing waiting. The drain calls this before it waits on
    /// attachment, so a surface that never attaches and has nothing to hand over leaves no poll
    /// running behind it.
    func suspendIfIdle() -> Bool {
        state.withLock { state in
            guard state.pending.isEmpty else { return false }
            state.isDraining = false
            return true
        }
    }

    /// The next chunk, bounded, or `nil` once the queue is empty — which ends the drain under the
    /// same lock an append takes.
    func takeNext() -> Item? {
        state.withLock { state in
            guard let first = state.pending.first else {
                state.isDraining = false
                return nil
            }
            switch first {
            case let .output(data, _):
                guard data.count > chunkByteLimit else {
                    state.pending.removeFirst()
                    return .output(data)
                }
                // Sealed: what is left is a slice of this allocation, and nothing extends it.
                state.pending[0] = .output(data.dropFirst(chunkByteLimit), isExtendable: false)
                return .output(data.prefix(chunkByteLimit))
            case let .processExit(code):
                state.pending.removeFirst()
                return .processExit(code)
            }
        }
    }

    /// Records a parsed chunk and hands back the waiters the drop below the low-water mark
    /// released, so the caller resumes them outside the lock.
    func complete(byteCount: Int) -> [CheckedContinuation<Void, Never>] {
        state.withLock { state in
            state.outstandingByteCount -= byteCount
            guard state.outstandingByteCount < lowWaterByteCount else { return [] }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
    }

    /// Registers a caller waiting for room, or tells it there is room already — or that its own
    /// task was cancelled while it was on its way here.
    func registerWaiter(
        _ identifier: UUID,
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        state.withLock { state in
            guard state.cancelledWaiters.remove(identifier) == nil else { return false }
            guard state.outstandingByteCount >= highWaterByteCount else { return false }
            state.waiters[identifier] = continuation
            return true
        }
    }

    /// Takes a waiter back out on cancellation, for the caller to resume outside the lock. A
    /// cancellation that arrives before the registration is recorded instead, so the registration
    /// refuses; ``forgetWaiter(_:)`` clears that record once the wait is over.
    func releaseWaiter(_ identifier: UUID) -> CheckedContinuation<Void, Never>? {
        state.withLock { state in
            guard let waiter = state.waiters.removeValue(forKey: identifier) else {
                state.cancelledWaiters.insert(identifier)
                return nil
            }
            return waiter
        }
    }

    func forgetWaiter(_ identifier: UUID) {
        state.withLock { $0.cancelledWaiters.remove(identifier) }
    }
}

/// Hands the backlog to the renderer one bounded chunk at a time, on a queue of its own.
///
/// It holds everything back until the session has a surface. The dependency's
/// `InMemoryTerminalSurfaceAccess` buffers output that arrives unattached in a 1 MiB window and
/// drops the oldest bytes past it, and its `waitForPendingOutput` drains only the attached
/// output queue — it neither awaits an attach nor waits for that buffer to be parsed. Handing
/// bytes over before there is a surface would therefore let more than a megabyte be dropped
/// while the adapter decremented its outstanding count and told its host there was capacity.
/// Held here instead, nothing is dropped and the capacity signal is about bytes that still exist.
private final class GhosttyFeedDrain: Sendable {
    /// How often an undelivered backlog re-asks whether a surface has appeared. The dependency
    /// polls its own main-thread waits at the same interval.
    private static let attachmentPollSeconds: TimeInterval = 0.01

    private let queue: DispatchQueue
    private let backlog: GhosttyFeedQueue
    private let session: InMemoryTerminalSession
    private let barrier: GhosttyFeedBarrier
    private let finish: GhosttySessionFinisher
    private let runtimeMilliseconds: @Sendable () -> UInt64
    private let isAttached: GhosttySurfaceAttachmentProbe
    private let polls = Mutex(0)
    private let stopped = Mutex(false)

    /// How many times the drain has re-asked whether a surface has appeared. Diagnostic: it exists
    /// so "nothing is still scheduled" can be an assertion rather than a recollection.
    var attachmentPollCount: Int { polls.withLock { $0 } }

    init(
        queue: DispatchQueue,
        backlog: GhosttyFeedQueue,
        session: InMemoryTerminalSession,
        barrier: @escaping GhosttyFeedBarrier,
        finish: @escaping GhosttySessionFinisher,
        runtimeMilliseconds: @escaping @Sendable () -> UInt64,
        isAttached: @escaping GhosttySurfaceAttachmentProbe
    ) {
        self.queue = queue
        self.backlog = backlog
        self.session = session
        self.barrier = barrier
        self.finish = finish
        self.runtimeMilliseconds = runtimeMilliseconds
        self.isAttached = isAttached
    }

    func start() {
        queue.async { self.run() }
    }

    /// Ends the drain, and tells the session the process ended if the backlog was still holding
    /// that item. Both go on the drain's own queue, so they are ordered behind whatever iteration
    /// is running rather than racing it.
    ///
    /// This is what stops the attachment poll, which is the only thing that keeps a discarded
    /// unattached surface — its drain, its session and its backlog — alive for the life of the
    /// process. Nothing restarts afterwards: the backlog refuses every later append.
    func stop(finishingWith exitCode: Int32?) {
        stopped.withLock { $0 = true }
        guard let exitCode else { return }
        queue.async {
            self.finish(self.session, UInt32(bitPattern: exitCode), self.runtimeMilliseconds())
        }
    }

    private func run() {
        while true {
            guard !stopped.withLock({ $0 }) else { return }
            if !backlog.isAttached {
                guard !backlog.suspendIfIdle() else { return }
                guard isAttached(session) else {
                    polls.withLock { $0 += 1 }
                    queue.asyncAfter(deadline: .now() + Self.attachmentPollSeconds) {
                        self.run()
                    }
                    return
                }
                backlog.markAttached()
            }
            guard let item = backlog.takeNext() else { return }
            let parsedByteCount: Int
            switch item {
            case let .output(data):
                session.receive(data)
                parsedByteCount = data.count
            case let .processExit(code):
                finish(session, UInt32(bitPattern: code), runtimeMilliseconds())
                parsedByteCount = 0
            }
            // Off the main thread, so waiting for the parse cannot deadlock against the tick
            // the dependency's parse may itself be waiting for.
            barrier(session, parsedByteCount)
            for waiter in backlog.complete(byteCount: parsedByteCount) {
                waiter.resume()
            }
        }
    }
}

/// Ghostty asks a host before it honours a protected clipboard request, and its callback
/// bridge denies every one of them when the view's delegate does not adopt
/// `TerminalSurfaceClipboardConfirmationDelegate` — including a paste the user asked for.
/// W2 has no confirmation-UI seam, so there is nobody to ask; this policy answers with the
/// dependency's own documented default (`TerminalViewState.onClipboardConfirmationRequest`):
/// a paste the user started is theirs to make, a program's OSC 52 read or write stays denied.
/// A later panel that owns confirmation UI replaces `allows(_:)`, not the wiring.
@MainActor
final class TerminalClipboardPolicy: TerminalSurfaceClipboardConfirmationDelegate {
    static func allows(_ kind: TerminalClipboardRequestKind) -> Bool {
        switch kind {
        case .paste: true
        case .osc52Read, .osc52Write: false
        }
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: Self.allows(request.kind))
    }
}

@MainActor
public final class GhosttyTerminalSurface: TerminalSurface {
    /// Pixel-only resize suppression stays off because `TerminalSize` carries pixels; otherwise
    /// a sub-cell change can leave the PTY's `TIOCSWINSZ` pixel metrics stale indefinitely.
    private static let suppressesPixelOnlyResizes = false

    /// Resize delivery stays unthrottled so a full-screen TUI receives each size. Revisit this
    /// only if the S1 harness shows that a live window drag outruns the TUI.
    private static let resizeThrottleMilliseconds: Double = 0

    /// What the adapter will hold for a renderer that is behind before it asks its host to stop
    /// reading the master. The same MiB the PTY layer's own buffer is bounded by: past it the
    /// two bounds together are what makes the pty's flow control engage instead of memory growth.
    public nonisolated static let feedBufferByteLimit = 1 * 1024 * 1024

    /// Where a waiting host is let go again. A quarter of the cap keeps the read loop from
    /// stopping and starting on every chunk while a flood is running.
    public nonisolated static let feedResumeByteCount = 256 * 1024

    /// At most this much is inside the dependency's own unbounded queue at any moment.
    nonisolated static let feedChunkByteLimit = 64 * 1024

    private let handlers: TerminalHandlerBox
    let session: InMemoryTerminalSession
    /// Owned by this adapter alone; see the initializer for why it is not the shared one.
    let terminalController: TerminalController
    private let terminalView: AppTerminalView
    /// `AppTerminalView.delegate` is weak, so the adapter owns the policy's lifetime.
    let clipboardPolicy: TerminalClipboardPolicy
    private let finishSession: GhosttySessionFinisher
    private let runtimeMilliseconds: @Sendable () -> UInt64
    private let feedQueue: GhosttyFeedQueue
    private let feedDrain: GhosttyFeedDrain

    public let terminalDescription: TerminalDescription

    /// What the last ``setAppearance(_:)`` made of its theme name. `.unknownName` says the pane is
    /// rendering the system-appearance default because the name was not in the catalog, which is
    /// the one thing the rendered pane itself cannot say.
    public private(set) var themeResolution: TerminalThemeResolution = .systemAppearance

    public var view: NSView { terminalView }

    public var onInput: (@Sendable (Data) -> Void)? {
        get { handlers.onInput }
        set { handlers.onInput = newValue }
    }

    public var onResize: (@Sendable (TerminalSize) -> Void)? {
        get { handlers.onResize }
        set { handlers.onResize = newValue }
    }

    public convenience init() {
        self.init(
            terminfoDirectory: GhosttyRuntimeResources.terminfoDirectoryURL,
            runtimeMilliseconds: Self.elapsedRuntimeMeasurement()
        )
    }

    init(
        terminfoDirectory: URL?,
        sessionFactory: GhosttySessionFactory = { write, resize, suppressesPixelOnlyResizes in
            InMemoryTerminalSession(
                write: write,
                resize: resize,
                suppressesPixelOnlyResizes: suppressesPixelOnlyResizes
            )
        },
        finishSession: @escaping GhosttySessionFinisher = { session, exitCode, runtimeMilliseconds in
            session.finish(exitCode: exitCode, runtimeMilliseconds: runtimeMilliseconds)
        },
        runtimeMilliseconds: @escaping @Sendable () -> UInt64 = GhosttyTerminalSurface.elapsedRuntimeMeasurement(),
        feedBarrier: @escaping GhosttyFeedBarrier = { session, _ in session.waitForPendingOutput() },
        isAttached: @escaping GhosttySurfaceAttachmentProbe = { $0.readViewportText() != nil }
    ) {
        let handlers = TerminalHandlerBox()
        let session = sessionFactory(
            { handlers.sendInput($0) },
            { handlers.sendResize($0) },
            Self.suppressesPixelOnlyResizes
        )
        // One controller per surface, never `TerminalController.shared`: the controller owns
        // the resolved configuration, so a shared one makes `setAppearance` a process-wide
        // change every other surface inherits, new ones included.
        let terminalController = TerminalController()
        let terminalView = AppTerminalView(frame: .zero)
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            resizeThrottleMilliseconds: Self.resizeThrottleMilliseconds
        )
        // AppTerminalView's coordinator cannot construct a surface without a controller.
        terminalView.controller = terminalController
        let clipboardPolicy = TerminalClipboardPolicy()
        terminalView.delegate = clipboardPolicy

        self.handlers = handlers
        self.session = session
        self.terminalController = terminalController
        self.terminalView = terminalView
        self.clipboardPolicy = clipboardPolicy
        self.finishSession = finishSession
        self.runtimeMilliseconds = runtimeMilliseconds
        let feedQueue = GhosttyFeedQueue(
            highWaterByteCount: Self.feedBufferByteLimit,
            lowWaterByteCount: Self.feedResumeByteCount,
            chunkByteLimit: Self.feedChunkByteLimit
        )
        self.feedQueue = feedQueue
        feedDrain = GhosttyFeedDrain(
            queue: DispatchQueue(label: "app.afleet.terminal-core.surface-feed"),
            backlog: feedQueue,
            session: session,
            barrier: feedBarrier,
            finish: finishSession,
            runtimeMilliseconds: runtimeMilliseconds,
            isAttached: isAttached
        )
        terminalDescription = Self.describeTerminal(terminfoDirectory: terminfoDirectory)
    }

    /// Bytes accepted from the host that the renderer has not parsed yet. The measure a host uses
    /// to see whether it is ahead of the terminal, and what ``awaitFeedCapacity()`` bounds.
    public var outstandingFeedByteCount: Int {
        feedQueue.outstandingByteCount
    }

    /// What the backlog's allocations occupy, prefixes already handed over included. Diagnostic:
    /// it exists so a partial drain/refill loop can assert on retained storage rather than on the
    /// count, which is the pair that comes apart when a consumed prefix is never reclaimed.
    var retainedFeedStorageByteCount: Int {
        feedQueue.retainedStorageByteCount
    }

    /// How many times the drain has re-asked whether this surface has a view to parse into. See
    /// ``GhosttyFeedDrain``: an unattached surface polls, and this is what says it has stopped.
    public var feedDrainAttachmentPollCount: Int {
        feedDrain.attachmentPollCount
    }

    public func feed(_ output: Data) {
        guard !output.isEmpty else { return }
        guard feedQueue.append(output) else { return }
        feedDrain.start()
    }

    /// Returns at once unless the renderer is more than ``feedBufferByteLimit`` behind, and
    /// otherwise once it has caught up to ``feedResumeByteCount``.
    ///
    /// A host awaits this between deliveries. Not consuming the PTY layer's events is what stops
    /// the read loop, fills its bounded buffer and leaves the child blocked on the pty — the flow
    /// control a terminal is built around, reaching all the way from the renderer to the child.
    ///
    /// Waiting is cancellable (tracker 93), the way the PTY layer's write gate already is: a
    /// pane's read loop has a lifetime of its own, and a renderer that never catches up — a
    /// surface that never attaches, a window that has gone away — would otherwise make a pane
    /// impossible to close. A cancelled waiter returns without ever having had capacity, which is
    /// the only meaning cancellation can carry here: its caller is being torn down.
    public func awaitFeedCapacity() async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard feedQueue.registerWaiter(identifier, continuation) else {
                    continuation.resume()
                    return
                }
            }
        } onCancel: {
            feedQueue.releaseWaiter(identifier)?.resume()
        }
        feedQueue.forgetWaiter(identifier)
    }

    /// Ends this surface for good: the drain stops, the backlog is abandoned and released, and
    /// the backend session is told the process ended if nobody has told it yet.
    ///
    /// C7.4's **second** recorded change to C7.1's adapter (the first is tracker 93's cancellable
    /// `awaitFeedCapacity()`). A pane that is closed before its surface ever attached — discarded
    /// while off screen, or closed from a window it was never put in — otherwise leaves the drain
    /// re-asking for a surface every 10 ms through a closure that captures itself, holding the
    /// session and the backlog for the life of the process. A pane's surface has a lifetime, and
    /// this is where it ends; feeding a disposed surface is a no-op rather than a resurrection.
    public func dispose() {
        let abandonment = feedQueue.abandon()
        for waiter in abandonment.waiters { waiter.resume() }
        feedDrain.stop(finishingWith: abandonment.pendingExitCode)
    }

    public func processDidExit(code: Int32) {
        guard feedQueue.appendProcessExit(code: code) else { return }
        feedDrain.start()
    }

    /// The rendered viewport, read back through the in-memory backend's own host-side read after
    /// every pending `receive` has been parsed. `nil` until a view has attached a surface, which
    /// is why it answers nothing in a headless test and everything in the S1 harness. Diagnostic
    /// only: it exists so "it rendered" can be an assertion rather than a recollection, and no
    /// pane path calls it.
    public func renderedViewportText() -> String? {
        // The adapter's own backlog first. `waitForPendingOutput` ticks while it waits on the main
        // thread, which is what lets the drain make progress underneath this loop; the bound is
        // there so a stalled renderer cannot turn a diagnostic into a hang.
        var attempts = 0
        while feedQueue.outstandingByteCount > 0, attempts < Self.viewportDrainAttemptLimit {
            session.waitForPendingOutput()
            attempts += 1
        }
        session.waitForPendingOutput()
        return session.readViewportText()
    }

    private static let viewportDrainAttemptLimit = 1_000

    public func setAppearance(_ appearance: TerminalAppearance) {
        let ghosttyAppearance = GhosttyAppearance(appearance)
        themeResolution = ghosttyAppearance.themeResolution
        terminalController.setTheme(ghosttyAppearance.theme)
        terminalController.setTerminalConfiguration(ghosttyAppearance.configuration)
    }

    private static func describeTerminal(terminfoDirectory: URL?) -> TerminalDescription {
        guard let terminfoDirectory else {
            return TerminalDescription(term: "xterm-256color")
        }
        return TerminalDescription(
            term: "xterm-ghostty",
            terminfoDirectory: terminfoDirectory
        )
    }

    private static func elapsedRuntimeMeasurement() -> @Sendable () -> UInt64 {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        return {
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            guard finishedAt >= startedAt else { return 0 }
            return (finishedAt - startedAt) / 1_000_000
        }
    }
}
