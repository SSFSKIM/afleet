import Foundation
import XCTest

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
    private var _requested: [Duration] = []
    private typealias CountWaiter = (threshold: Int, id: UUID, continuation: CheckedContinuation<Void, Never>)
    /// Parties waiting for `waiters.count` to reach a threshold, registered and checked under `lock` so the
    /// registration cannot straddle the moment the count actually gets there.
    private var countWaiters: [CountWaiter] = []
    public init() {}
    /// Every duration a sleeper asked for, in the order it asked. The backoff row asserts on this: "how long did the
    /// supervisor wait" is invisible in the state and is exactly what a constant backoff would get wrong.
    public var requestedDurations: [Duration] { lock.lock(); defer { lock.unlock() }; return _requested }
    public var now: Instant { lock.lock(); defer { lock.unlock() }; return _now }
    public var minimumResolution: Duration { .zero }
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // Under the lock, so a cancellation that arrived after the handler was installed but before this
                // body ran cannot leave a sleeper nobody will ever resume.
                _requested.append(_now.duration(to: deadline))
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                if deadline <= _now { lock.unlock(); c.resume(); return }
                waiters.append((deadline, id, c))
                let ready = takeReadyCountWaiters()
                lock.unlock()
                for w in ready { w.resume() }
            }
        } onCancel: {
            lock.lock(); let i = waiters.firstIndex { $0.id == id }; let w = i.map { waiters.remove(at: $0) }; lock.unlock()
            w?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `n` sleepers are parked — resumed the instant whichever `sleep` call makes that true,
    /// registered under the same lock that governs `waiters` so the check-and-register cannot straddle the count
    /// actually reaching `n`. No polling, no wall time: a genuine synchronisation point on the clock's own state,
    /// the thing tests that need both of the observer's timers armed are actually waiting on.
    ///
    /// Bounded by a wall-clock guard that is never reached on a correct path: the count is normally there within
    /// microseconds. It exists so a misuse — waiting for timers that will never be armed, say after `stop()` — fails
    /// with the count it was waiting for and the count it got, rather than hanging until XCTest's global timeout
    /// with nothing said. The guard moves no part of the lifecycle; only `advance(by:)` does that.
    func waitForSleeperCount(atLeast n: Int, within limit: Duration = .seconds(30),
                             file: StaticString = #filePath, line: UInt = #line) async {
        let id = UUID()
        let guardTask = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, !Task.isCancelled, self.expireCountWaiter(id) else { return }
            XCTFail("the clock never parked \(n) sleepers; \(self.sleeperCount) are parked", file: file, line: line)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if waiters.count >= n { lock.unlock(); continuation.resume(); return }
            countWaiters.append((n, id, continuation))
            lock.unlock()
        }
        guardTask.cancel()
    }

    /// Removes the count-waiter with this id and resumes it, answering whether it was still registered. The guard
    /// only reports when this says yes, so a wait that was satisfied a moment earlier reports nothing.
    private func expireCountWaiter(_ id: UUID) -> Bool {
        lock.lock()
        guard let index = countWaiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return false }
        let waiter = countWaiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume()
        return true
    }

    /// Removes and returns every registered count-waiter now satisfied by the current waiter count. Must be called
    /// with `lock` held; the caller resumes the continuations after unlocking, so none of them runs while the lock
    /// is taken.
    private func takeReadyCountWaiters() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        countWaiters.removeAll { waiter in
            guard waiters.count >= waiter.threshold else { return false }
            ready.append(waiter.continuation)
            return true
        }
        return ready
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
    /// How many sleepers are parked with exactly this much time left. A count of sleepers of *any* kind is satisfied
    /// by whichever timer happens to exist, so a test that means "the one-second backoff is armed" asks for that.
    public func sleeperCount(due duration: Duration) -> Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.filter { _now.duration(to: $0.deadline) == duration }.count
    }
}
