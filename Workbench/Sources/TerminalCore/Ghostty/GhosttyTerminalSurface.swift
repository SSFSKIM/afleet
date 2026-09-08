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
private final class GhosttyFeedQueue: Sendable {
    enum Item: Sendable {
        case output(Data)
        case processExit(Int32)
    }

    private struct State {
        var pending: [Item] = []
        var outstandingByteCount = 0
        var isDraining = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
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

    /// Appends `data`, coalescing it with whatever output is already waiting — the renderer parses
    /// a byte stream, and delivery boundaries carry no meaning it can use. Reports whether this
    /// caller starts the drain.
    func append(_ data: Data) -> Bool {
        state.withLock { state in
            state.outstandingByteCount += data.count
            if case .output(var existing) = state.pending.last {
                state.pending.removeLast()
                existing.append(data)
                state.pending.append(.output(existing))
            } else {
                state.pending.append(.output(data))
            }
            return Self.beginDrainIfIdle(&state)
        }
    }

    /// The exit rides the same queue as the output: the child's last bytes are parsed before the
    /// terminal is told the process ended.
    func appendProcessExit(code: Int32) -> Bool {
        state.withLock { state in
            state.pending.append(.processExit(code))
            return Self.beginDrainIfIdle(&state)
        }
    }

    private static func beginDrainIfIdle(_ state: inout State) -> Bool {
        guard !state.isDraining else { return false }
        state.isDraining = true
        return true
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
            case let .output(data):
                guard data.count > chunkByteLimit else {
                    state.pending.removeFirst()
                    return .output(data)
                }
                state.pending[0] = .output(data.dropFirst(chunkByteLimit))
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

    /// Registers a caller waiting for room, or tells it there is room already.
    func registerWaiter(
        _ identifier: UUID,
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        state.withLock { state in
            guard state.outstandingByteCount >= highWaterByteCount else { return false }
            state.waiters[identifier] = continuation
            return true
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
    private let feedBarrier: GhosttyFeedBarrier
    private let feedDrainQueue = DispatchQueue(label: "app.afleet.terminal-core.surface-feed")

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
        feedBarrier: @escaping GhosttyFeedBarrier = { session, _ in session.waitForPendingOutput() }
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
        self.feedBarrier = feedBarrier
        feedQueue = GhosttyFeedQueue(
            highWaterByteCount: Self.feedBufferByteLimit,
            lowWaterByteCount: Self.feedResumeByteCount,
            chunkByteLimit: Self.feedChunkByteLimit
        )
        terminalDescription = Self.describeTerminal(terminfoDirectory: terminfoDirectory)
    }

    /// Bytes accepted from the host that the renderer has not parsed yet. The measure a host uses
    /// to see whether it is ahead of the terminal, and what ``awaitFeedCapacity()`` bounds.
    public var outstandingFeedByteCount: Int {
        feedQueue.outstandingByteCount
    }

    public func feed(_ output: Data) {
        guard !output.isEmpty else { return }
        guard feedQueue.append(output) else { return }
        startFeedDrain()
    }

    /// Returns at once unless the renderer is more than ``feedBufferByteLimit`` behind, and
    /// otherwise once it has caught up to ``feedResumeByteCount``.
    ///
    /// A host awaits this between deliveries. Not consuming the PTY layer's events is what stops
    /// the read loop, fills its bounded buffer and leaves the child blocked on the pty — the flow
    /// control a terminal is built around, reaching all the way from the renderer to the child.
    public func awaitFeedCapacity() async {
        let identifier = UUID()
        await withCheckedContinuation { continuation in
            guard feedQueue.registerWaiter(identifier, continuation) else {
                continuation.resume()
                return
            }
        }
    }

    public func processDidExit(code: Int32) {
        guard feedQueue.appendProcessExit(code: code) else { return }
        startFeedDrain()
    }

    private func startFeedDrain() {
        let queue = feedQueue
        let session = session
        let barrier = feedBarrier
        let finish = finishSession
        let runtime = runtimeMilliseconds
        feedDrainQueue.async {
            while let item = queue.takeNext() {
                let parsedByteCount: Int
                switch item {
                case let .output(data):
                    session.receive(data)
                    parsedByteCount = data.count
                case let .processExit(code):
                    finish(session, UInt32(bitPattern: code), runtime())
                    parsedByteCount = 0
                }
                // Off the main thread, so waiting for the parse cannot deadlock against the tick
                // the dependency's parse may itself be waiting for.
                barrier(session, parsedByteCount)
                for waiter in queue.complete(byteCount: parsedByteCount) {
                    waiter.resume()
                }
            }
        }
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
