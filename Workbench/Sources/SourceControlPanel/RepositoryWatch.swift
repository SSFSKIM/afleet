// C7.7 spec Design §5: the working tree's freshness, and the only timing-bound thing in this leaf.
import Foundation
import Dispatch
import CoreServices

/// Watches one repository root and says what class of thing changed. It re-reads nothing and runs
/// no process: W7 is binding that every `git` invocation in this leaf is C7.3's, and a watcher
/// that spawned one would be a second reader nobody asked for. It classifies, coalesces, and hands
/// the answer to whoever owns the reads.
///
/// **The exclusion is the point.** `git status` writes `.git/index` when it refreshes stat
/// information, so a watcher that treated any `.git` write as a change would re-read the status
/// because it had just read the status, for ever. `classify(path:root:)` is a pure function over
/// two paths with no file system in it, which is what lets the whole policy be asserted as a table
/// rather than inferred from a delivery.
///
/// **The bound, and what actually buys it.** G1 gives the working-tree row one second from the
/// edit. `NoDefer` is the documented guarantee that the *first* event after a quiet period is
/// delivered at once rather than at the end of the latency window, and it is set for that reason.
/// It is not, on this system, what the bound rests on: measured here, an edit is delivered in
/// ~12 ms at a latency of 0.5 s or 1 s whether the flag is set or not, and the deferral only
/// becomes visible at latencies far above the bound (~1.79 s at a latency of 3 s with the flag
/// dropped). So the bound rests on the latency being well under it — half of it — and `NoDefer`
/// is kept as the contract with the API rather than as a load-bearing trick.
///
/// Deliveries are leading-edge with a trailing coalesced follow-up: the first change after quiet is
/// delivered immediately, everything inside the debounce window that follows is merged into one
/// delivery at the end of it, and `.history` outranks `.workingTree` in that merge because
/// re-reading the history re-reads the status with it.
///
/// `@unchecked Sendable`, and soundly so: every mutable field lives in `WatchState` behind an
/// `NSLock`, and the stream handle is only ever touched under this class's own lock.
public final class RepositoryWatch: @unchecked Sendable {

    /// What a changed path means. `ignore` never reaches a delivery; it is the answer the
    /// classifier gives for the paths that must not become one.
    public enum Change: Sendable, Equatable, CustomStringConvertible {
        /// A path outside `.git`: the working tree may have changed.
        case workingTree
        /// `.git/HEAD`, `.git/packed-refs`, `.git/refs/…` or `.git/logs/…`: history may have
        /// changed, and the window, the status and the assignment are all re-read.
        case history
        /// Every other path under `.git`.
        case ignore

        public var description: String {
            switch self {
            case .workingTree: return "working tree"
            case .history: return "history"
            case .ignore: return "ignored"
            }
        }
    }

    /// What is delivered. Never `.changed(.ignore)`.
    public enum Event: Sendable, Equatable {
        case changed(Change)
        /// The root was deleted or replaced — `WatchRoot`'s own event. The owner's answer is the
        /// `.notARepository` empty state; a stream left armed on an inode nobody will write again
        /// would simply go quiet and the panel would show a repository that is not there.
        case rootGone
    }

    /// The FSEvents latency, in seconds: half of G1's bound, so that even a system that defers
    /// the first event by the whole of it answers inside the second.
    public static let latency: TimeInterval = 0.5
    /// The window a leading delivery opens, inside which further changes are merged into one
    /// trailing delivery. Deliberately *below* the latency rather than above it: a change that
    /// arrives while the window is open is delivered at the end of it, and latency plus debounce
    /// is what that change costs — 0.75 s here, which still fits inside G1's second.
    public static let debounce: Duration = .milliseconds(250)

    private let state: WatchState
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// `root` is canonicalised here, because FSEvents reports the resolved path of every event and
    /// a root spelled through a symbolic link would match none of them.
    public init(root: URL,
                latency: TimeInterval = RepositoryWatch.latency,
                debounce: Duration = RepositoryWatch.debounce,
                onEvent: @escaping @Sendable (Event) -> Void) {
        state = WatchState(root: RepositoryWatch.canonical(root), latency: latency,
                           debounce: debounce, onEvent: onEvent)
    }

    deinit { stop() }

    /// Arms the stream. False when it could not be created or started; the owner shows its own
    /// row for that rather than pretending the tree is fresh.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard stream == nil, !state.isStopped else { lock.unlock(); return false }
        // Retained, not unretained: the callback may already be in flight when this object goes
        // away, and the box is released on the stream's own queue after the stream is invalidated.
        let info = Unmanaged.passRetained(state).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil,
                                           copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot)
        let created = FSEventStreamCreate(kCFAllocatorDefault, repositoryWatchCallback, &context,
                                          [state.root.path(percentEncoded: false)] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          state.latency, flags)
        guard let created else {
            lock.unlock()
            Unmanaged<WatchState>.fromOpaque(info).release()
            return false
        }
        FSEventStreamSetDispatchQueue(created, state.queue)
        guard FSEventStreamStart(created) else {
            lock.unlock()
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Unmanaged<WatchState>.fromOpaque(info).release()
            return false
        }
        stream = created
        lock.unlock()
        return true
    }

    /// Tears the stream down. Nothing is delivered after this returns: the stopped flag is taken
    /// under the same lock a delivery holds, so a callback already inside `onEvent` finishes and
    /// no later one starts.
    public func stop() {
        lock.lock()
        let taken = stream
        stream = nil
        lock.unlock()
        state.markStopped()
        guard let taken else { return }
        FSEventStreamStop(taken)
        FSEventStreamInvalidate(taken)
        FSEventStreamRelease(taken)
        // On the stream's own serial queue, so an in-flight callback has returned before the box
        // it is holding is released.
        let info = Unmanaged.passUnretained(state).toOpaque()
        state.queue.async { Unmanaged<WatchState>.fromOpaque(info).release() }
    }

    // MARK: - The policy

    /// What a changed path means, as a pure function of the path and the root.
    ///
    /// Compared component by component and never by string prefix: `foo.gitignore`, a top-level
    /// `.github/` and a sibling directory whose name merely begins with the root's are all things
    /// a prefix match gets wrong.
    public static func classify(path: String, root: URL) -> Change {
        let rootComponents = components(of: root.path(percentEncoded: false))
        let pathComponents = components(of: path)
        guard pathComponents.count >= rootComponents.count else { return .ignore }
        for (mine, theirs) in zip(pathComponents, rootComponents) where mine != theirs {
            return .ignore
        }
        let relative = pathComponents.dropFirst(rootComponents.count)
        guard let first = relative.first else { return .workingTree }
        guard first == ".git" else { return .workingTree }
        let inside = relative.dropFirst()
        // `<root>/.git` itself. In an ordinary repository it is the directory whose modification
        // time every index write moves, which is the feedback loop again; in a worktree or a
        // submodule it is a regular file holding a `gitdir:` pointer whose real git directory is
        // outside the root and delivers no event here at all. Ignored either way.
        guard let head = inside.first else { return .ignore }
        if inside.count == 1, head == "HEAD" || head == "packed-refs" { return .history }
        if head == "refs" || head == "logs" { return .history }
        return .ignore
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The path with every symbolic link on it resolved, which is the spelling FSEvents uses.
    private static func canonical(_ url: URL) -> URL {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }
}

/// Everything mutable, behind one lock, so the C callback's context pointer can be a plain box.
private final class WatchState: @unchecked Sendable {

    let root: URL
    let latency: TimeInterval
    let debounce: Duration
    let queue = DispatchQueue(label: "dev.afleet.sourcecontrolpanel.repositorywatch")

    private let onEvent: @Sendable (RepositoryWatch.Event) -> Void
    private let lock = NSLock()
    private var stopped = false
    /// True while a delivery window is open: the leading delivery has gone out and a trailing one
    /// is scheduled.
    private var windowOpen = false
    private var pending: RepositoryWatch.Change?
    /// The root's identity when it was last observed, so a delete and a replace are both seen.
    private var identity: (dev_t, ino_t)?

    init(root: URL, latency: TimeInterval, debounce: Duration,
         onEvent: @escaping @Sendable (RepositoryWatch.Event) -> Void) {
        self.root = root
        self.latency = latency
        self.debounce = debounce
        self.onEvent = onEvent
        identity = WatchState.identity(of: root)
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func markStopped() {
        lock.lock()
        stopped = true
        pending = nil
        windowOpen = false
        lock.unlock()
    }

    /// One FSEvents batch.
    func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        var rootMayHaveMoved = false
        var coalesced: RepositoryWatch.Change?
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootMayHaveMoved = true
                continue
            }
            // Events were dropped or a subtree must be rescanned: what changed is unknown, so the
            // wider answer is the safe one — re-reading the history re-reads the status with it.
            let uncertain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                    | kFSEventStreamEventFlagUserDropped
                                                    | kFSEventStreamEventFlagKernelDropped)
            if flag & uncertain != 0 {
                coalesced = .history
                continue
            }
            switch RepositoryWatch.classify(path: path, root: root) {
            case .ignore: continue
            case .history: coalesced = .history
            case .workingTree: if coalesced != .history { coalesced = .workingTree }
            }
        }
        if rootMayHaveMoved, rootIdentityChanged() {
            deliver(.rootGone)
            return
        }
        guard let change = coalesced else { return }
        note(change)
    }

    /// True when the root is no longer the directory it was — deleted, or a different one now.
    /// Recording what it found means a root that went away is reported once and not on every
    /// event that follows.
    private func rootIdentityChanged() -> Bool {
        let now = WatchState.identity(of: root)
        return lock.withLock {
            guard identity?.0 != now?.0 || identity?.1 != now?.1 else { return false }
            identity = now
            return true
        }
    }

    private static func identity(of url: URL) -> (dev_t, ino_t)? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    private func note(_ change: RepositoryWatch.Change) {
        lock.lock()
        if stopped { lock.unlock(); return }
        if windowOpen {
            pending = (pending == .history || change == .history) ? .history : change
            lock.unlock()
            return
        }
        windowOpen = true
        lock.unlock()
        deliver(.changed(change))
        scheduleFlush()
    }

    private func scheduleFlush() {
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        guard !stopped, let change = pending else {
            windowOpen = false
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        deliver(.changed(change))
        // The window stays open while changes keep arriving, so a file being written continuously
        // is delivered at the debounce's rate rather than on every batch.
        scheduleFlush()
    }

    /// The callback is invoked **under the lock**, which is what makes "nothing after `stop()`
    /// returns" true rather than nearly true: `stop()` waits behind a delivery already in flight.
    /// It follows that the callback must not call back into the watch.
    private func deliver(_ event: RepositoryWatch.Event) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        onEvent(event)
    }
}

/// The C callback. `kFSEventStreamCreateFlagUseCFTypes` is not set, so `eventPaths` is a `char **`.
private let repositoryWatchCallback: FSEventStreamCallback = {
    _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let state = Unmanaged<WatchState>.fromOpaque(info).takeUnretainedValue()
    let raw = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []
    paths.reserveCapacity(numEvents)
    flags.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        guard let path = raw[index] else { continue }
        paths.append(String(cString: path))
        flags.append(eventFlags[index])
    }
    state.receive(paths: paths, flags: flags)
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
