// C7.5 spec Design §8: one watcher per open file, with the re-arm and the poll fallback.
import Foundation
import Dispatch

/// Watches one path and reports what it observes. It decides nothing — `outcome(…)` does — so the
/// two halves of §8 are testable apart.
///
/// A `DispatchSource` vnode source watches an **inode**, not a path. An editor that writes by
/// rename — which the engine's own edit path may do — leaves the source armed on an inode nobody
/// will ever write again: it delivers `.delete` or `.rename` once and then goes silent forever.
/// So every event schedules a settle after a short coalescing delay, and the settle **re-opens the
/// path**: the source that comes back is armed on whatever is there now. A path that has not come
/// back by then is reported deleted, and the poll keeps looking in case it returns later.
///
/// The poll is also the fallback for a file system where the source cannot be armed at all. Both
/// triggers end in the same `evaluate()`, so there is one delivery rule and one thing to test.
public actor FileWatch {

    /// What one observation was. Never a decision.
    public enum Event: Sendable, Equatable {
        case changed(FileSnapshot)
        case deleted
    }

    public enum Mode: Sendable, Equatable, CustomStringConvertible {
        /// The vnode source, falling back to the poll when the path cannot be armed.
        case vnode
        /// The stat poll only, for a file system that cannot arm a source.
        case poll

        public var description: String { self == .vnode ? "the vnode source" : "the poll" }
    }

    private let url: URL
    private let mode: Mode
    private let coalescingDelay: Duration
    private let pollInterval: Duration
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.afleet.filespanel.filewatch")

    /// The armed source, held outside the actor's isolation so `deinit` can cancel it.
    private let armed = VnodeSource()
    private var settleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastObserved: FileSnapshot?
    private var started = false
    private var stopped = false

    public init(url: URL,
                mode: Mode = .vnode,
                coalescingDelay: Duration = .milliseconds(120),
                pollInterval: Duration = .milliseconds(500),
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.mode = mode
        self.coalescingDelay = coalescingDelay
        self.pollInterval = pollInterval
        self.onEvent = onEvent
    }

    /// A watch is released by its owner going away, not by anyone remembering to end it: X7's host
    /// drops a session's reference under LRU pressure and has no teardown hook. A resumed vnode
    /// source is registered with Dispatch and outlives the object that holds it, so the descriptor
    /// would stay open for the life of the process; cancelling here closes it. The tasks need
    /// nothing: both hold the watch weakly and end at their next wake.
    deinit { armed.cancel() }

    /// `baseline` is what the session loaded; deliveries are the changes away from it. Passing
    /// `nil` reads the path now, and a path that is not there yet is watched for its arrival.
    public func start(baseline: FileSnapshot? = nil) {
        guard !started, !stopped else { return }
        started = true
        lastObserved = baseline ?? FileSnapshot.read(url)
        switch mode {
        case .poll: startPolling()
        case .vnode: if !arm() { startPolling() }
        }
        // The gap between the session's read and the arming belongs to nobody: a write that
        // completed inside it fired no source event, and under the vnode source there is no poll
        // to notice it later. One evaluation here is what closes it.
        evaluate()
    }

    /// Releases the descriptor and the timers. Not a `deinit`: an actor's isolated state cannot be
    /// torn down from one, so the owner ends the watch explicitly.
    public func stop() {
        stopped = true
        settleTask?.cancel()
        settleTask = nil
        stopPolling()
        disarm()
    }

    /// True while the poll is carrying the watch — the fallback, observable so it can be asserted.
    public var isPolling: Bool { pollTask != nil }

    // MARK: - The source

    private func arm() -> Bool {
        guard !armed.isArmed else { return true }
        // `O_CLOEXEC` for the reason C7.3 gives for its own reads: this leaf spawns `git`
        // through C7.3's runner while watches are live, and a descriptor without it is inherited
        // by every one of those children.
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.sourceFired() }
        }
        source.setCancelHandler { close(descriptor) }
        armed.hold(source)
        source.resume()
        return true
    }

    private func disarm() {
        armed.cancel()
    }

    private func sourceFired() {
        guard !stopped, settleTask == nil else { return }
        // A leading schedule with a fixed window rather than a restart on each event: a burst is
        // still coalesced, and a file being written continuously is still delivered on time.
        settleTask = Task { [weak self, coalescingDelay] in
            try? await Task.sleep(for: coalescingDelay)
            await self?.settle()
        }
    }

    private func settle() {
        settleTask = nil
        guard !stopped else { return }
        // The re-arm. Unconditional: an event mask says which inode ended, not which path is now
        // interesting, and re-opening is correct for an in-place write too.
        disarm()
        if arm() { stopPolling() } else { startPolling() }
        evaluate()
    }

    // MARK: - The poll

    private func startPolling() {
        guard pollTask == nil, !stopped else { return }
        // **Weakly.** The watch owns the task and the task must not own the watch back: a session
        // the host released is never told to stop, and a strong capture here would keep both alive
        // and stat the path for the life of the process. The strong reference exists only for the
        // duration of one tick, and the loop ends the moment the watch is gone.
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() {
        guard !stopped else { return }
        // A path that has come back can be armed again, and the poll steps aside when it is.
        if mode == .vnode, !armed.isArmed, arm() { stopPolling() }
        evaluate()
    }

    // MARK: - The one delivery rule

    /// Delivers when the observation differs from the last one. Identical bytes at a new time are
    /// a difference here and are delivered: whether that matters is the policy's decision, not the
    /// watcher's. Only "nothing at all happened" is filtered, which is what keeps the poll quiet.
    private func evaluate() {
        // `unchangedFrom:` is what keeps a quiet tick to one `stat(2)`: the contents are digested
        // only when the size or the modification time moved, and an observation that did not move
        // comes back as the last one and is filtered below.
        let observed = FileSnapshot.read(url, unchangedFrom: lastObserved)
        guard observed != lastObserved else { return }
        lastObserved = observed
        onEvent(observed.map(Event.changed) ?? .deleted)
    }
}

/// The armed source, held behind a lock rather than in the actor's isolated state.
///
/// An actor's `deinit` is not isolated and may not reach isolated properties, and a resumed
/// `DispatchSource` that is merely released is never cancelled — so its cancel handler never runs
/// and the `O_EVTONLY` descriptor stays open. Holding it here is what lets a watch nobody stopped
/// still give the descriptor back.
final class VnodeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var source: (any DispatchSourceFileSystemObject)?

    var isArmed: Bool { lock.withLock { source != nil } }

    /// Takes ownership of `source`, cancelling whatever was armed before it.
    func hold(_ source: any DispatchSourceFileSystemObject) {
        lock.lock()
        let previous = self.source
        self.source = source
        lock.unlock()
        previous?.cancel()
    }

    /// Cancels what is armed, which runs the cancel handler and closes the descriptor.
    func cancel() {
        lock.lock()
        let held = source
        source = nil
        lock.unlock()
        held?.cancel()
    }
}
