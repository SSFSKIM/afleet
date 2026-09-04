import XCTest
import WireFrames
import WireTransport
import WireTestSupport

final class ClaudeProcessTerminationTests: XCTestCase {
    func testTerminateOrderEndSessionStdinCloseThenExit() async throws {
        let h = try Harness(); let p = h.make(scenario: "")
        _ = try await p.spawn()
        let t0 = ContinuousClock.now
        await p.terminate()
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(2))
        guard case .exited(let s, _)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exited") else { return }
        XCTAssertTrue(s.isClean)
        // After the exit event the stderr reader has drained; the stand-in logs end_session before answering it.
        _ = await h.expect({ if case .stderr("HOST end_session", _) = $0 { return true }; return false }, "HOST end_session")
    }
    func testIgnoredEndSessionEscalatesToSIGTERM() async throws {
        let h = try Harness(); let p = h.make(scenario: "ignore_end_session")
        _ = try await p.spawn()
        let t0 = ContinuousClock.now
        await p.terminate()
        let elapsed = ContinuousClock.now - t0
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(5)); XCTAssertLessThan(elapsed, .seconds(9))
        guard case .exited(.signal(let sig, _), _)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exited by signal") else { return }
        XCTAssertEqual(sig, SIGTERM)
    }
    func testIgnoredSIGTERMEscalatesToSIGKILLAndStatusIsTruthful() async throws {
        let h = try Harness(); let p = h.make(scenario: "ignore_sigterm")
        _ = try await p.spawn()
        let probe = Task { () -> [ProcessStatus] in
            var seen: [ProcessStatus] = []
            for _ in 0..<60 { seen.append(await p.status); try? await Task.sleep(for: .milliseconds(200)) }
            return seen
        }
        let t0 = ContinuousClock.now
        await p.terminate()
        let elapsed = ContinuousClock.now - t0
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(10)); XCTAssertLessThan(elapsed, .seconds(14))
        guard case .exited(.signal(let sig, _), _)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exited by SIGKILL") else { return }
        XCTAssertEqual(sig, SIGKILL)
        let statuses = await probe.value
        XCTAssertTrue(statuses.contains(.terminating))
        // never .exited before the real exit: every .exited sample must come after all .terminating samples
        if let lastTerminating = statuses.lastIndex(of: .terminating), let firstExited = statuses.firstIndex(where: { if case .exited = $0 { return true }; return false }) {
            XCTAssertGreaterThan(firstExited, lastTerminating)
        }
    }
    func testTerminateIsIdempotentAndEventsStreamEnds() async throws {
        let h = try Harness(); let p = h.make(scenario: "")
        _ = try await p.spawn()
        await p.terminate(); await p.terminate()
        let drain = Task { () -> Bool in for await _ in p.events {}; return true }
        let ended = await drain.value
        XCTAssertTrue(ended)
    }
}
