import Foundation

/// Single-resume settlement: the first settle() wins; value() suspends until settled and settles itself with
/// CancellationError if its task is cancelled. Timeouts are separate tasks that call settle(); nothing is raced in a task group.
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
                if let r = result { lock.unlock(); c.resume(with: r) } else { continuation = c; lock.unlock() }
            }
        } onCancel: { settle(.failure(CancellationError())) }
    }
    /// Convenience: settle with `failure` after `timeout` unless settled first. Returns the timer task so the caller can cancel it.
    public func timeout(after timeout: Duration, failure: @escaping @Sendable () -> any Error) -> Task<Void, Never> {
        Task { try? await Task.sleep(for: timeout); settle(.failure(failure())) }
    }
}
