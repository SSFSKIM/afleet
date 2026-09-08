import Foundation
import PanelHostAPI

/// The two doubles the headless half of C7.6 is tested against.
///
/// Neither reaches disk, a network or a real store: the persistence tests must be able to run in
/// any order, in parallel, and leave nothing behind (the ledger's *Idempotence and Recovery*).

// MARK: - The store

/// An `any ScopedStore` that keeps encoded documents in memory and counts what it was asked to do.
///
/// It encodes and decodes for real rather than stashing the value, so a round-trip test exercises
/// the `Codable` conformance rather than an identity function, and so a document written by a
/// *newer* build can be seeded as the JSON such a build would have left behind.
actor InMemoryScopedStore: ScopedStore {

    /// Raised by `write` when `failsWrites` is set. Its description names no path and no value.
    struct WriteRefused: Error, CustomStringConvertible {
        var description: String { "the stub store refuses writes" }
    }

    private var storage: [String: Data] = [:]

    /// Every write the store was *asked* to perform, successful or not — the number the coalescing
    /// tests assert on, because a refused write is still a write attempt that must not be repeated.
    private(set) var attemptedWrites = 0

    /// Keys written, in order, successful writes only.
    private(set) var writtenKeys: [String] = []

    /// When set, every subsequent `write` throws `WriteRefused` and stores nothing.
    var failsWrites = false

    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setFailsWrites(_ value: Bool) { failsWrites = value }

    /// Seeds the raw JSON a document at `key` would have on disk, without going through `write`.
    func seed(json: String, key: String) {
        storage[key] = Data(json.utf8)
    }

    /// The document last written at `key`, decoded — `nil` if nothing is stored there.
    func document<T: Codable & Sendable>(_ type: T.Type, key: String) throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Returns once at least `count` write attempts have been made. This is how a coalescing test
    /// waits: on an observed write, never on a wall-clock sleep.
    func waitForWriteAttempts(_ count: Int) async {
        if attemptedWrites >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    // MARK: ScopedStore

    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
        attemptedWrites += 1
        defer { releaseWaiters() }
        if failsWrites { throw WriteRefused() }
        storage[key] = try JSONEncoder().encode(value)
        writtenKeys.append(key)
    }

    func remove(key: String) async throws {
        storage[key] = nil
    }

    func keys() async throws -> [String] {
        Array(storage.keys)
    }

    private func releaseWaiters() {
        let reached = waiters.filter { $0.target <= attemptedWrites }
        waiters.removeAll { $0.target <= attemptedWrites }
        for waiter in reached { waiter.continuation.resume() }
    }
}

// MARK: - The clock

/// The coalescer's sleep seam, driven by hand.
///
/// `BrowserTabStore` takes a `@Sendable (Duration) async -> Void`; this actor supplies one that
/// suspends until the test says otherwise. No test in this suite waits 500 ms of wall clock, and
/// no test's result depends on how long anything took.
actor ManualSleeper {

    /// Every duration the store asked to sleep for, in order — the assertion that the window is
    /// the window the ledger names and not some other number.
    private(set) var requestedDurations: [Duration] = []

    /// Every sleep currently suspended. A *list* and not a single slot on purpose: a coalescer that
    /// wrongly opened two windows at once would deadlock a one-slot sleeper, and a test that hangs
    /// on a bug is a test that cannot report one.
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var arrivals = 0
    private var observedArrivals = 0

    /// The seam to hand the store.
    nonisolated var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in await enter(duration) }
    }

    /// Returns once one more sleep than has already been observed has begun.
    func waitForSleep() async {
        if arrivals > observedArrivals {
            observedArrivals += 1
            return
        }
        await withCheckedContinuation { arrivalWaiter = $0 }
        observedArrivals += 1
    }

    /// Lets every sleep in progress return.
    func advance() {
        let waiting = sleepers
        sleepers.removeAll()
        for sleeper in waiting { sleeper.resume() }
    }

    private func enter(_ duration: Duration) async {
        requestedDurations.append(duration)
        arrivals += 1
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { sleepers.append($0) }
    }
}
