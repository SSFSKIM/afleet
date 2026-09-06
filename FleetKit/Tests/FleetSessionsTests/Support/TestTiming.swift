import Foundation
import XCTest
@testable import FleetSessions

/// The suite's two waiting primitives, in one place.
///
/// They live here rather than on `Rig` because the facade's harness needs the same two, and two copies of a timing
/// helper drift: this suite has already been bitten twice by waits that looked equivalent and were not.
enum TestTiming {

    /// A failure guard for delivery-driven XCTest expectations; no passing path waits on this clock.
    static let hangGuard: TimeInterval = 30

    struct DeliveryTimeout: Error {}

    /// Records the deliveries the waiter was still missing, so a failure names those rather than the whole set.
    private final class UnfulfilledDeliveries: NSObject, XCTWaiterDelegate, @unchecked Sendable {
        // `lock` serialises `missing`.
        private let lock = NSLock()
        private var missing: [String] = []
        func waiter(_ waiter: XCTWaiter,
                    didTimeoutWithUnfulfilledExpectations unfulfilledExpectations: [XCTestExpectation]) {
            let names = unfulfilledExpectations.map(\.expectationDescription)
            lock.lock(); missing = names; lock.unlock()
        }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return missing }
    }

    /// Waits for delivery-driven expectations, and *throws* when one never arrives so the safety deadline aborts
    /// the test instead of letting it run on into an unbounded await. Nothing polls: the delivery fulfils the
    /// expectation and `hangGuard` is only the guard.
    static func awaitDelivery(_ expectations: [XCTestExpectation],
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let waiter = XCTWaiter()
        let unfulfilled = UnfulfilledDeliveries()
        waiter.delegate = unfulfilled
        let result = await waiter.fulfillment(of: expectations, timeout: hangGuard)
        guard result == .completed else {
            let named = unfulfilled.names.isEmpty ? expectations.map(\.expectationDescription) : unfulfilled.names
            XCTFail("timed out waiting for delivery of \(named.joined(separator: ", ")) (\(result))",
                    file: file, line: line)
            throw DeliveryTimeout()
        }
    }

    /// A flag one task sets and another reads, for a loop that has to stop when the work it is driving is done.
    final class LockedFlag: @unchecked Sendable {   // `lock` serialises `flag`
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Steps the manual clock in the release wait's own poll interval while `body` runs, up to `limit` of test
    /// time, so a clock-driven wait makes progress. Nothing here sleeps on wall time to move the lifecycle: every
    /// step is the test moving the clock, and the wall-clock race is only a failure guard.
    ///
    /// The default limit is the handoff budget itself: a wait cannot outlast it, so a shorter default can only ever
    /// end a wait early and fail a test that was going to pass. A test that means to *reach* the timeout passes the
    /// budget explicitly, which is the same number and says so at the call site.
    static func steppingClock<T: Sendable>(_ clock: TestClock,
                                           upTo limit: Duration = ChannelSupervisor.handoffBudget,
                                           file: StaticString = #filePath, line: UInt = #line,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let done = LockedFlag()
        let interval = OwnershipCheck.releasePollInterval
        let stepper = Task {
            var stepped = Duration.zero
            while !done.value && stepped < limit {
                // Only a parked sleeper is stepped past, so `limit` counts the wait's own polls and not the wall
                // time this loop happened to spend: ten seconds of limit is exactly the ten-second handoff budget,
                // and a budget any larger than that does not expire.
                guard clock.sleeperCount(due: interval) >= 1 else {
                    try? await Task.sleep(for: .milliseconds(1))
                    continue
                }
                await clock.advance(by: interval)
                stepped += interval
            }
        }
        let work = Task { try await body() }
        // A wall-clock guard, not a race: whatever `body` throws is what the caller sees, so a break shows up as
        // the error the code produced rather than as a timeout.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, !done.value else { return }
            XCTFail("the clock-stepped call never returned", file: file, line: line)
            work.cancel()
        }
        defer { done.set(); stepper.cancel(); watchdog.cancel() }
        return try await work.value
    }

    /// Waits for any condition the test can read, on wall time. It moves no part of the lifecycle: only the manual
    /// clock does that, and this is how a test waits for work already in flight to reach a point it can observe.
    static func waitFor(_ description: String, timeout: Duration = .seconds(30),
                        file: StaticString = #filePath, line: UInt = #line,
                        _ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        struct Timeout: Error {}
        throw Timeout()
    }
}
