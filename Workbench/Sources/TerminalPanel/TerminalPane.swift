import Darwin
import FleetKit
import Foundation
import Observation
import Synchronization
import TerminalCore

/// The grid the renderer last reported, shared with its off-actor callback.
///
/// A box and not a bare `Mutex` because the callbacks capture it: `Mutex` is non-copyable, and
/// what the closures need is a reference they can hold without the pane.
private final class GridBox: Sendable {
    private let size = Mutex<TerminalSize?>(nil)

    var latest: TerminalSize? {
        size.withLock { $0 }
    }

    func report(_ reported: TerminalSize) {
        size.withLock { $0 = reported }
    }
}

/// One pane: a renderer, a child, the request it echoes, and the loop between them.
///
/// The wiring is the S1 harness's, promoted rather than reinvented, because it is the only shape
/// that has been measured against a live `claude attach`. What a pane adds to it is a lifetime —
/// a pane is closed, and the loop, the child and the renderer all have to end together.
@MainActor
@Observable
public final class TerminalPane {
    /// The grid a child is spawned into before the renderer has reported one. A pane whose view
    /// is not in a window never lays out and never reports a grid, and a child still has to be
    /// given a screen size; the first real report reaches the child through `sendResize`.
    private static let unreportedGrid = TerminalSize(
        rows: 24,
        columns: 80,
        pixelWidth: 640,
        pixelHeight: 480
    )

    /// What the renderer is told when a pane is closed before its child ended on its own. Close
    /// hangs the child up, so the terminal is told the status a hung-up child would have carried.
    private static let closedExitCode = 128 + SIGHUP

    /// Concrete, not `any TerminalSurface`: tracker 94 ruled that back-pressure lives on the
    /// adapter because this leaf holds the concrete type, and the read loop below awaits
    /// `awaitFeedCapacity()` on every delivery.
    public let surface: GhosttyTerminalSurface

    /// The request this pane echoes, or `nil` for a pane the panel made itself. A shell pane is
    /// nobody's request, so it has none to echo and its exit is reported to no one (spec §6).
    public private(set) var request: PaneRequest?

    public private(set) var state: PaneState = .starting

    /// Fired once, with the termination the pty layer observed. The session installs it; the pane
    /// itself performs no ownership work of any kind.
    public var onTerminated: ((PTYTermination) -> Void)?

    @ObservationIgnored private var pty: PTYProcess?
    @ObservationIgnored private var readLoop: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var hasFiredTermination = false
    @ObservationIgnored private var hasReportedExitToSurface = false
    @ObservationIgnored private var observedTermination: PTYTermination?
    /// The renderer reports its grid from an off-actor callback. Held under a `Mutex` rather than
    /// hopped onto the actor so a report that arrives in the same turn as the spawn is the size
    /// the child is spawned with, instead of arriving one scheduler turn too late.
    @ObservationIgnored private let latestGrid = GridBox()

    public init(surface: GhosttyTerminalSurface = GhosttyTerminalSurface()) {
        self.surface = surface
        // Installed before a child exists: the surface reports its first grid as soon as it lays
        // out, and an observer installed after the spawn misses it. Nothing is written to a pty
        // that has not been spawned.
        observeGridBeforeSpawn()
    }

    /// Whether the read loop is still running. Diagnostic: it exists so "close ended the loop"
    /// can be an assertion rather than a recollection.
    var hasRunningReadLoop: Bool {
        guard let readLoop else { return false }
        return !readLoop.isCancelled
    }

    /// Runs an X5-originated request. The request is stored and echoed; nothing about it is
    /// rewritten (spec Design §3).
    public func start(_ request: PaneRequest) {
        self.request = request
        launch(PaneSpawn.spawnRequest(
            for: request,
            size: currentGrid,
            terminal: surface.terminalDescription
        ))
    }

    /// Runs a pane the panel made itself — the Cmd+Shift+T pane, and the pane a channel opens
    /// with. It carries no `PaneRequest`, because reporting an exit nobody is waiting on would
    /// put a `.staleExit` in C4's log for every closed shell (spec Design §6).
    public func startShell(
        executable: URL,
        arguments: [String],
        cwd: URL,
        environment: [String: String]
    ) {
        launch(PTYSpawnRequest(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            size: currentGrid,
            terminal: surface.terminalDescription,
            stopPolicy: .report
        ))
    }

    /// Resumes a child the user suspended, by continuing the process group that owns this pane's
    /// terminal.
    ///
    /// The only group named is the foreground group of the pty this pane spawned, so the only
    /// process that can be reached is a descendant of that child (§7.8, X9). The pty layer
    /// reports stops and not continuations, so the state is moved here rather than awaited.
    public func continueStopped() async {
        guard case .stopped = state, let pty else { return }
        let group = (try? await pty.foregroundProcessGroup()) ?? pty.processIdentifier
        guard group > 1 else { return }
        _ = Darwin.kill(-group, SIGCONT)
        state = .running(pty.processIdentifier)
    }

    /// Ends the pane: the child, the loop and the renderer's notion of a live process.
    ///
    /// Idempotent, because a user closing a pane that is already exiting is ordinary. The loop is
    /// awaited rather than abandoned so that nothing feeds the surface after it has been told the
    /// process ended — which is only bounded because cancelling the loop leaves its
    /// `awaitFeedCapacity()` wait (tracker 93).
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        surface.onInput = nil
        surface.onResize = nil
        let pty = self.pty
        self.pty = nil
        await pty?.teardown()
        readLoop?.cancel()
        await readLoop?.value
        readLoop = nil
        reportExitToSurface(code: observedTermination?.paneExitCode ?? Self.closedExitCode)
    }

    // MARK: Spawning

    private var currentGrid: TerminalSize {
        latestGrid.latest ?? Self.unreportedGrid
    }

    private func launch(_ spawn: PTYSpawnRequest) {
        let pty: PTYProcess
        do {
            pty = try PTYProcess(spawning: spawn)
        } catch {
            // §10: a pty failure is a pane that shows why, never an error that reaches the
            // channel. What C4 is told about an X5-originated one is the session's to send.
            state = .failed((error as? PTYError).map(PaneSpawnFailure.pty)
                ?? .other(String(describing: error)))
            return
        }
        self.pty = pty
        state = .running(pty.processIdentifier)
        wire(to: pty)
    }

    private func observeGridBeforeSpawn() {
        let latestGrid = latestGrid
        surface.onResize = { size in
            latestGrid.report(size)
        }
    }

    private func wire(to pty: PTYProcess) {
        let latestGrid = latestGrid
        // Synchronous, and off the main actor. They hand bytes and grids straight to the pty
        // layer's ordered ingress rather than starting a task each: one task per callback lets N
        // callbacks race to enter the actor, and a fast typist sees `ba` for `ab` (C7.1, 3 of 3).
        surface.onInput = { data in
            pty.sendInput(data)
        }
        surface.onResize = { size in
            latestGrid.report(size)
            pty.sendResize(to: size)
        }
        readLoop = Task { @MainActor [weak self] in
            for await event in pty.events {
                guard let self else { return }
                switch event {
                case let .output(data):
                    surface.feed(data)
                    // Stop pulling events while the renderer is more than its cap behind. The pty
                    // layer's bounded buffer then fills and the child blocks on the pty, instead
                    // of a backlog piling up inside the renderer where nothing bounds it.
                    await surface.awaitFeedCapacity()
                case let .stopped(signal):
                    state = .stopped(signal: signal)
                case let .ended(termination):
                    observedTermination = termination
                    state = .exited(termination)
                    reportExitToSurface(code: termination.paneExitCode)
                    fireTermination(termination)
                }
            }
        }
    }

    private func reportExitToSurface(code: Int32) {
        guard !hasReportedExitToSurface else { return }
        hasReportedExitToSurface = true
        surface.processDidExit(code: code)
    }

    private func fireTermination(_ termination: PTYTermination) {
        guard !hasFiredTermination else { return }
        hasFiredTermination = true
        onTerminated?(termination)
    }
}
