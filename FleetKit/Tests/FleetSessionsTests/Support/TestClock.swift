import Foundation

/// A Clock whose time moves only when a test says so. `advance(by:)` resumes every sleeper whose deadline has passed,
/// in deadline order, and yields between resumptions so a resumed task can arm its next sleep before the clock moves on.
public final class TestClock: Clock, @unchecked Sendable {   // `lock` serialises every access to `_now` and `waiters`
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration
        public func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private typealias Waiter = (deadline: Instant, id: UUID, continuation: CheckedContinuation<Void, any Error>)
    private var waiters: [Waiter] = []
    public init() {}
    public var now: Instant { lock.lock(); defer { lock.unlock() }; return _now }
    public var minimumResolution: Duration { .zero }
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if deadline <= _now { lock.unlock(); c.resume(); return }
                waiters.append((deadline, id, c)); lock.unlock()
            }
        } onCancel: {
            lock.lock(); let i = waiters.firstIndex { $0.id == id }; let w = i.map { waiters.remove(at: $0) }; lock.unlock()
            w?.continuation.resume(throwing: CancellationError())
        }
    }
    /// Moves time forward and lets every sleeper whose deadline passed run, one at a time.
    ///
    /// The locked steps are separate synchronous methods because `NSLock.lock()` is unavailable from an async
    /// context: an `await` while the lock is held would be a deadlock waiting to happen, and the compiler says so.
    public func advance(by d: Duration) async {
        let target = target(after: d)
        while let w = takeNextWaiter(upTo: target) {
            w.continuation.resume()
            await Task.yield(); await Task.yield()
        }
    }
    private func target(after d: Duration) -> Instant { lock.lock(); defer { lock.unlock() }; return _now.advanced(by: d) }
    /// The earliest sleeper due by `target`, removed; nil once none is left, at which point the clock reads `target`.
    private func takeNextWaiter(upTo target: Instant) -> Waiter? {
        lock.lock(); defer { lock.unlock() }
        guard let i = waiters.indices.min(by: { waiters[$0].deadline < waiters[$1].deadline }), waiters[i].deadline <= target else { _now = target; return nil }
        let w = waiters.remove(at: i); _now = w.deadline; return w
    }
    public var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
}
