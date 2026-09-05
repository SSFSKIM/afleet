import XCTest
import WireTransport

final class WaiterTests: XCTestCase {
    /// Cancelling a timeout must **disable** it. It used to fire it: the timer task swallowed the sleep's
    /// cancellation with `try?` and fell straight through to `settle(.failure(...))`, so every
    /// `defer { timer.cancel() }` in the transport delivered the very failure it was written to call off.
    /// That is invisible wherever the waiter is already settled by then — which is every current call site,
    /// and none of the ones a later change would add.
    func testCancellingATimeoutDisablesItInsteadOfFiringIt() async throws {
        struct Fired: Error {}
        let w = Waiter<Int>()
        let timer = w.timeout(after: .milliseconds(50)) { Fired() }
        timer.cancel()
        try await Task.sleep(for: .milliseconds(300))       // well past when the timeout would have fired
        XCTAssertFalse(w.isSettled, "a cancelled timeout settled the waiter")
        w.settle(.success(7))
        let v = try await w.value()
        XCTAssertEqual(v, 7, "the waiter must still be free to take its real settlement")
    }
    /// The other half: an uncancelled timeout still fires, so the test above cannot pass by disabling timeouts.
    func testAnUncancelledTimeoutStillFires() async throws {
        struct Fired: Error, Equatable {}
        let w = Waiter<Int>()
        _ = w.timeout(after: .milliseconds(50)) { Fired() }
        do { _ = try await w.value(); XCTFail("the timeout never fired") }
        catch is Fired {} catch { XCTFail("expected Fired, got \(error)") }
    }
}
