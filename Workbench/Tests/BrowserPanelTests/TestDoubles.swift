import Foundation
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI

/// The doubles the headless half of C7.6 is tested against.
///
/// None of them reaches disk, a network or a real store: the tests must be able to run in any
/// order, in parallel, and leave nothing behind (the ledger's *Idempotence and Recovery*).

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
    private var expectations: [(target: Int, expectation: XCTestExpectation)] = []

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

    /// Fulfils `expectation` once at least `count` write attempts have been made.
    ///
    /// The expectation-shaped twin of `waitForWriteAttempts`, and the one a test should reach for:
    /// the continuation form has no deadline, so an implementation that never writes hangs the
    /// suite instead of failing it — measured, when a mutation that stopped the model committing at
    /// all produced a 900-second nothing rather than a named red test.
    func expectWriteAttempts(_ count: Int, _ expectation: XCTestExpectation) {
        if attemptedWrites >= count {
            expectation.fulfill()
            return
        }
        expectations.append((count, expectation))
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
        let due = expectations.filter { $0.target <= attemptedWrites }
        expectations.removeAll { $0.target <= attemptedWrites }
        for waiter in due { waiter.expectation.fulfill() }
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
    private var arrivalExpectations: [XCTestExpectation] = []
    private var arrivals = 0
    private var observedArrivals = 0

    /// The seam to hand the store.
    nonisolated var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in await enter(duration) }
    }

    /// Fulfils `expectation` once one more sleep than has already been observed has begun — the
    /// deadline-bearing twin of `waitForSleep`, for the reason `expectWriteAttempts` records.
    func expectSleep(_ expectation: XCTestExpectation) {
        if arrivals > observedArrivals {
            observedArrivals += 1
            expectation.fulfill()
            return
        }
        arrivalExpectations.append(expectation)
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
        if !arrivalExpectations.isEmpty {
            let due = arrivalExpectations.removeFirst()
            observedArrivals += 1
            due.fulfill()
        }
        await withCheckedContinuation { sleepers.append($0) }
    }
}

// MARK: - The recent-URL feed

/// An `any RecentURLFeed` the test drives: a seeded snapshot, a stream it yields into by hand, and
/// a count of the subscriptions that have been torn down.
///
/// The termination count is what makes Q8's "cancelled when the sheet closes" assertable at all. A
/// subscription that is merely *not read from* looks identical to one that was cancelled, from
/// outside; `AsyncStream`'s `onTermination` fires only when the consuming task goes away, so it is
/// the one observable difference.
///
/// `@unchecked Sendable` with a lock rather than an actor, because `updates` is a **non-async**
/// property of the protocol and cannot hop.
final class StubRecentURLFeed: RecentURLFeed, @unchecked Sendable {

    private let lock = NSLock()
    private var seeded: [SeenURL]
    private var continuations: [UUID: AsyncStream<[SeenURL]>.Continuation] = [:]
    private var limits: [Int] = []
    private var terminated = 0
    private var terminationWaiters: [XCTestExpectation] = []
    private var subscriptionWaiters: [XCTestExpectation] = []

    init(seeded: [SeenURL]) {
        self.seeded = seeded
    }

    /// Every limit `current(limit:)` was called with, in order — Q8 names 50 and a test that did
    /// not read the number back would not notice it changing.
    var requestedLimits: [Int] {
        lock.lock(); defer { lock.unlock() }
        return limits
    }

    var terminationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    /// Publishes a new list to every live subscriber.
    func yield(_ urls: [SeenURL]) {
        lock.lock()
        let live = Array(continuations.values)
        lock.unlock()
        for continuation in live { continuation.yield(urls) }
    }

    /// An expectation fulfilled when a subscriber's stream is torn down.
    func expectTermination(_ expectation: XCTestExpectation) {
        lock.lock()
        if terminated > 0 {
            lock.unlock()
            expectation.fulfill()
            return
        }
        terminationWaiters.append(expectation)
        lock.unlock()
    }

    /// An expectation fulfilled once a subscriber has attached, so a test never yields into a
    /// stream nobody is reading yet.
    func expectSubscription(_ expectation: XCTestExpectation) {
        lock.lock()
        if !continuations.isEmpty {
            lock.unlock()
            expectation.fulfill()
            return
        }
        subscriptionWaiters.append(expectation)
        lock.unlock()
    }

    // MARK: RecentURLFeed

    func current(limit: Int) async -> [SeenURL] {
        snapshot(limit: limit)
    }

    /// The locked half, kept out of the `async` member: `NSLock` is unavailable from an
    /// asynchronous context, and a stub is not the place to invent a lock discipline.
    private func snapshot(limit: Int) -> [SeenURL] {
        lock.lock(); defer { lock.unlock() }
        limits.append(limit)
        return Array(seeded.prefix(limit))
    }

    var updates: AsyncStream<[SeenURL]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let arrived = subscriptionWaiters
            subscriptionWaiters.removeAll()
            lock.unlock()
            for waiter in arrived { waiter.fulfill() }
            continuation.onTermination = { [self] _ in
                lock.lock()
                continuations[id] = nil
                terminated += 1
                let waiting = terminationWaiters
                terminationWaiters.removeAll()
                lock.unlock()
                for waiter in waiting { waiter.fulfill() }
            }
        }
    }
}

/// A `SeenURL` for `string`, with invented item identity. Nothing here reads a real config home.
func seenURL(_ string: String) -> SeenURL {
    let stream = LogicalStream(configHome: URL(filePath: "/invented/config-home"),
                               sessionID: SessionID(uuid: UUID()),
                               name: .main)
    let item = ItemID(stream: stream, key: "invented-\(string.hashValue)")
    return SeenURL(url: URL(string: string)!, firstSeen: item, firstSeenAt: nil,
                   lastSeen: item, lastSeenAt: nil)
}

// MARK: - The channel

/// A `ChannelContext` for an invented channel. Two of them, differing only in the session, are what
/// the item-39 assertion switches between.
@MainActor
func makeChannelContext(mark: String,
                        store: any ScopedStore = InMemoryScopedStore(),
                        recentURLs: any RecentURLFeed = StubRecentURLFeed(seeded: [])) -> ChannelContext {
    let key = ChannelKey(configHome: URL(filePath: "/invented/config-home"),
                         session: SessionID(uuid: UUID()))
    return ChannelContext(key: key,
                          session: key.session,
                          cwd: URL(filePath: "/invented/workspace/\(mark)"),
                          environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                           shell: "/bin/zsh",
                                                           capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                           mode: .processFallback),
                          store: store,
                          links: NoRoutingCapability(),
                          recentURLs: recentURLs,
                          reportPaneExit: { _ in })
}

/// The routing seam, unused at M4: the link targets are M5's. It registers nothing and delivers
/// nowhere, which is what a model test wants — no link in this file may reach a browser.
actor NoRoutingCapability: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}
