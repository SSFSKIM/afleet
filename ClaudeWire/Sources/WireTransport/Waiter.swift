import Foundation

/// Single-resume settlement: the first settle() wins; value() suspends until settled and settles itself with
/// CancellationError if its task is cancelled. Timeouts are separate tasks that call settle(); nothing is raced in a task group.
///
/// **One awaiter.** A Waiter carries a single parked continuation, because that is all its three uses in the
/// transport — correlation, handshake and exit — need. The incumbent awaiter is never displaced: a second
/// concurrent `value()` throws `Waiter.AlreadyAwaited` instead of overwriting the first caller's continuation
/// and abandoning it forever. Two callers that must both learn one settlement need one owner awaiting and
/// republishing, not two `value()` calls; if that shape ever becomes the common one, promote this to a list of
/// continuations deliberately, and note that per-caller cancellation would then have to replace the current
/// whole-box cancellation.
public final class Waiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    public init() {}
    @discardableResult
    public func settle(_ r: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = r; let c = continuation; continuation = nil
        lock.unlock()
        c?.resume(with: r); return true
    }
    public var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    public func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, any Error>) in
                lock.lock()
                if let r = result { lock.unlock(); c.resume(with: r) }
                else if continuation != nil { lock.unlock(); c.resume(throwing: AlreadyAwaited()) }
                else { continuation = c; lock.unlock() }
            }
        } onCancel: { settle(.failure(CancellationError())) }
    }
    /// Thrown to the *second* concurrent `value()`; the first caller keeps its place and its settlement.
    public struct AlreadyAwaited: Error, Sendable {}
    /// Convenience: settle with `failure` after `timeout` unless settled first. Returns the timer task so the caller can cancel it.
    ///
    /// **Cancelling the timer disables it; it never fires it.** The sleep's cancellation error is caught and
    /// returned on rather than swallowed with `try?` — a swallowed one falls straight through to
    /// `settle(.failure(...))`, so `timer.cancel()`, which every call site writes in a `defer` to *stop* the
    /// timeout, would instead deliver it. That inversion is invisible wherever the waiter happens to be settled
    /// already, which is a property of each call site rather than a guarantee of this type.
    public func timeout(after timeout: Duration, failure: @escaping @Sendable () -> any Error) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            settle(.failure(failure()))
        }
    }
}
