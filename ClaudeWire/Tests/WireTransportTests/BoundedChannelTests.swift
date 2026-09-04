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
        await ch.push(9)                                        // after finish: dropped, never blocks
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
        XCTAssertEqual(live, 1, "the element must reach a live consumer, not the cancelled waiter")
        await ch.push(2)                                        // full
        let cancelledPush = Task { await ch.push(3) }
        try await Task.sleep(for: .milliseconds(30)); cancelledPush.cancel(); await cancelledPush.value
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
}
