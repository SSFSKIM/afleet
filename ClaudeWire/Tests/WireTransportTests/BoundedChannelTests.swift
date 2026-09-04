import XCTest
@testable import WireTransport

final class BoundedChannelTests: XCTestCase {
    func testPushSuspendsWhenFullAndResumesOnPop() async throws {
        let ch = BoundedChannel<Int>(capacity: 2)
        await ch.push(1); await ch.push(2)
        let pushed = Task { await ch.push(3); return true }
        try await Task.sleep(for: .milliseconds(50))
        let countWhileBlocked = await ch.count
        XCTAssertEqual(countWhileBlocked, 2)                    // third push is still suspended
        let first = await ch.pop()
        XCTAssertEqual(first, 1)
        let didPush = await pushed.value
        XCTAssertTrue(didPush)
        let second = await ch.pop(), third = await ch.pop()
        XCTAssertEqual(second, 2); XCTAssertEqual(third, 3)
    }
    func testFinishEndsIterationAfterDraining() async {
        let ch = BoundedChannel<Int>(capacity: 8)
        await ch.push(7); await ch.finish()
        var got: [Int] = []
        for await x in WireEventStream(channel: ch) { got.append(x) }
        XCTAssertEqual(got, [7])
        let acceptedAfterFinish = await ch.push(9)              // after finish: dropped, never blocks
        XCTAssertFalse(acceptedAfterFinish)
        let afterFinish = await ch.pop()
        XCTAssertNil(afterFinish)
    }
    func testPopSuspendsUntilPush() async throws {
        let ch = BoundedChannel<String>(capacity: 1)
        let popped = Task { await ch.pop() }
        try await Task.sleep(for: .milliseconds(30))
        await ch.push("late")
        let value = await popped.value
        XCTAssertEqual(value, "late")
    }
    func testCancelledPopDoesNotStealALaterElementAndCancelledPushDoesNotAppend() async throws {
        let ch = BoundedChannel<Int>(capacity: 1)
        let cancelledPop = Task { await ch.pop() }
        try await Task.sleep(for: .milliseconds(30)); cancelledPop.cancel()
        let popResult = await cancelledPop.value
        XCTAssertNil(popResult)
        await ch.push(1)
        let live = await ch.pop()
        // A steal is caught here, but as a CheckedContinuation misuse trap at push time rather than as this
        // assertion's message: handing the element to a waiter that was already resumed traps in the runtime.
        // A crash from this test is a real failure, not flakiness.
        XCTAssertEqual(live, 1, "the element must reach a live consumer, not the cancelled waiter")
        await ch.push(2)                                        // full
        let cancelledPush = Task { await ch.push(3) }
        try await Task.sleep(for: .milliseconds(30)); cancelledPush.cancel()
        let cancelledPushAccepted = await cancelledPush.value
        XCTAssertFalse(cancelledPushAccepted)
        let a = await ch.pop(), afterCancelled = await ch.count
        XCTAssertEqual(a, 2); XCTAssertEqual(afterCancelled, 0, "a cancelled push must not append later")
    }
    func testWaiterSettlesOnceAndTimesOutWithoutDeadlock() async throws {
        let w = Waiter<Int>()
        XCTAssertTrue(w.settle(.success(1))); XCTAssertFalse(w.settle(.success(2)))
        let v = try await w.value(); XCTAssertEqual(v, 1)
        struct Late: Error {}
        let slow = Waiter<Int>()
        let timer = slow.timeout(after: .milliseconds(50)) { Late() }
        do { _ = try await slow.value(); XCTFail("should time out") } catch { XCTAssertTrue(error is Late) }
        timer.cancel()
        let cancelled = Waiter<Int>()
        let t = Task { try await cancelled.value() }
        try await Task.sleep(for: .milliseconds(20)); t.cancel()
        do { _ = try await t.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPushReportsWhetherTheElementWasAccepted() async throws {
        let ch = BoundedChannel<Int>(capacity: 1)
        let accepted = await ch.push(1)
        XCTAssertTrue(accepted, "a push with room must report acceptance")
        let blocked = Task { await ch.push(2) }              // capacity is 1: this parks
        try await Task.sleep(for: .milliseconds(30)); blocked.cancel()
        let acceptedWhileCancelled = await blocked.value
        XCTAssertFalse(acceptedWhileCancelled, "a cancelled push is dropped and must say so")
        await ch.finish()
        let acceptedAfterFinish = await ch.push(3)
        XCTAssertFalse(acceptedAfterFinish, "a push after finish is dropped and must say so")
    }
    func testSecondConcurrentValueThrowsAndTheIncumbentStillSettles() async throws {
        let w = Waiter<Int>()
        let incumbent = Task { try await w.value() }
        try await Task.sleep(for: .milliseconds(30))         // incumbent is parked
        do { _ = try await w.value(); XCTFail("a second awaiter must not be admitted") }
        catch { XCTAssertTrue(error is Waiter<Int>.AlreadyAwaited, "got \(error)") }
        XCTAssertTrue(w.settle(.success(42)))
        let v = try await incumbent.value
        XCTAssertEqual(v, 42, "the first awaiter must keep its place and receive the settlement")
    }

    /// The wakeup a pop() hands a producer must not die with that producer. Deliberately a loop: the
    /// interleaving that loses it — the cancel landing after pop() woke the waiter but before the waiter
    /// re-runs — is a race, not a schedule this test can dictate. Measured against the pre-fix
    /// implementation it lost the wakeup on 49 of 50 iterations, so 50 makes the red essentially certain;
    /// against the fixed one it is 0 of 50, repeatably.
    func testCancelledPushHandsItsWakeupToAnotherWaitingProducer() async throws {
        var wedged = 0
        for _ in 0..<50 {
            let ch = BoundedChannel<Int>(capacity: 1)
            await ch.push(0)
            let a = Task { await ch.push(1) }
            try await Task.sleep(for: .milliseconds(3))
            let b = Task { await ch.push(2) }
            try await Task.sleep(for: .milliseconds(3))
            _ = await ch.pop()                              // frees the slot and hands the wakeup to a
            a.cancel()                                      // a bails; its wakeup must reach b
            _ = await a.value
            var appended = false
            for _ in 0..<20 {
                if await ch.count == 1 { appended = true; break }
                try await Task.sleep(for: .milliseconds(2))
            }
            if !appended { wedged += 1 }
            await ch.finish()                               // releases b whether or not it was woken
            _ = await b.value
        }
        XCTAssertEqual(wedged, 0, "a producer stayed parked while a slot was free")
    }

    /// `pushFinal` exists because the `push`-then-`finish()` pair a caller would write is not equivalent:
    /// between the two calls another producer's element can land, and it is then delivered after the terminal
    /// one. This pins the atomicity, not just the finishing.
    func testPushFinalPublishesTheTerminalElementAndEndsTheStream() async throws {
        let c = BoundedChannel<Int>(capacity: 8)
        await c.push(1)
        let accepted = await c.pushFinal(99)
        XCTAssertTrue(accepted)
        let finished = await c.isFinished; XCTAssertTrue(finished)
        let late = await c.push(2); XCTAssertFalse(late, "no element may be accepted after the terminal one")
        var seen: [Int] = []
        while let v = await c.pop() { seen.append(v) }
        XCTAssertEqual(seen, [1, 99], "the terminal element is last and nothing follows it")

        // The contrast, which is the whole reason the method exists: spelled as a push and a separate
        // finish(), an element pushed between the two is accepted and delivered *after* the terminal one.
        let split = BoundedChannel<Int>(capacity: 8)
        await split.push(1)
        await split.push(99)                      // "terminal", published by itself
        let inWindow = await split.push(2)        // ... and here is the window
        await split.finish()
        XCTAssertTrue(inWindow, "a split push/finish accepts a late element — this is what pushFinal closes")
        var splitSeen: [Int] = []
        while let v = await split.pop() { splitSeen.append(v) }
        XCTAssertEqual(splitSeen, [1, 99, 2], "and delivers it after the terminal element")
    }
}
