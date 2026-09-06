import XCTest
import WireEnvironment

/// Covers `FoundationProcessRunner` itself. These spawn `/bin/sh` and write nothing anywhere.
final class ProcessRunnerTests: XCTestCase {
    func testNormalRunReturnsOutputAndExitCode() async throws {
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf hi; printf oops >&2; exit 3"],
            environment: [:], timeout: .seconds(10))
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hi")
        XCTAssertEqual(String(decoding: out.stderr, as: UTF8.self), "oops")
        XCTAssertEqual(out.exitCode, 3)
        XCTAssertFalse(out.timedOut)
    }
    /// `sleep 30 &` is deliberately orphaned: the shell exits immediately, leaving a grandchild that afleet
    /// never learns about and cannot signal, still holding the inherited write end of the stdout pipe.
    /// A grandchild that inherited stdout keeps the pipe's write end open long after the child exits.
    /// Settlement must not wait on the pipe: `run` returns at the timeout plus its grace, with what was read.
    func testGrandchildHoldingStdoutDoesNotOutlastTheTimeout() async throws {
        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & printf hi"],
            environment: [:], timeout: .milliseconds(500))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(5), "run must not wait for the grandchild: took \(elapsed)")
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hi")
    }
    /// The discriminating case, and the one the live `claude stop` hit: the child exits *promptly* while a
    /// grandchild still holds the inherited write end, and the timeout is generous. Settlement must key on the
    /// child's exit, not on end-of-file, so `run` returns in about the child's own lifetime rather than burning
    /// the whole budget and reporting a SIGTERM.
    func testGrandchildHoldingStdoutDoesNotDelaySettlementPastTheChildsExit() async throws {
        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & printf hi; exit 0"],
            environment: [:], timeout: .seconds(30))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(5), "run must settle on the child's exit, not on EOF: took \(elapsed)")
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hi")
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertFalse(out.timedOut)
    }
    /// A timeout small enough to elapse during start-up must still resume the caller rather than latching
    /// settlement before there is a continuation to resume.
    func testNearZeroTimeoutStillReturns() async throws {
        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"],
            environment: [:], timeout: .zero)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertTrue(out.timedOut)
    }
    /// Output far larger than one read buffer arrives whole: the non-blocking reads must loop to EOF
    /// rather than stopping at the first short read or a spurious EAGAIN.
    func testLargeOutputIsFullyRead() async throws {
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -c 1000000"],
            environment: [:], timeout: .seconds(30))
        XCTAssertEqual(out.stdout.count, 1_000_000)
        XCTAssertFalse(out.timedOut)
        XCTAssertEqual(out.exitCode, 0)
    }
    /// A child that outlives its timeout is terminated and reported as timed out.
    func testHungChildIsKilledAndReportedTimedOut() async throws {
        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"],
            environment: [:], timeout: .milliseconds(500))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertTrue(out.timedOut)
    }
}
