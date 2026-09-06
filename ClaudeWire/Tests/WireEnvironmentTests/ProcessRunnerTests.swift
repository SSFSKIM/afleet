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
        XCTAssertLessThan(elapsed, .seconds(5),
                          "run must settle on the child's exit, not on EOF: took \(elapsed), state \(out.timeoutState ?? "nil")")
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hi")
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertFalse(out.timedOut)
    }
    /// The exit has to be observed even when no thread of ours is free to notice it.
    ///
    /// `waitUntilExit()` cannot promise that. It has to be called from somewhere, and the only somewhere
    /// available here is a dispatch worker — but the global queue does not overcommit, so once its threads are
    /// all blocked the call simply never runs, and a child that exited in milliseconds is never seen to have
    /// exited. Settlement then happens on the budget instead, reporting `-1` for a child that succeeded, which
    /// is indistinguishable from a verb the CLI refused. A saturated pool is not a contrivance: it is an
    /// ordinary loaded machine, which is why this surfaced in a long live suite and never in a probe run on its
    /// own.
    ///
    /// Against the earlier `waitUntilExit()` mechanism this settles at 7.06 s with `exitCode -1`, `timedOut`,
    /// and a state of `liveness=gone waitReturned=false pipesOpen=0` — the child reaped, both pipes at
    /// end-of-file, and only the observation missing.
    func testTheChildsExitIsSeenEvenWithEveryDispatchWorkerBlocked() async throws {
        let release = DispatchSemaphore(value: 0)
        let occupied = DispatchSemaphore(value: 0)
        let blockers = 64
        // Enough to fill the non-overcommitting global queue; the rest stay enqueued behind them.
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        for _ in 0..<blockers { DispatchQueue.global().async { occupied.signal(); release.wait() } }
        // Unblocks every worker however this test leaves, so a failure here cannot wedge the rest of the suite.
        defer { for _ in 0..<blockers { release.signal() } }
        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<width where occupied.wait(timeout: .now() + .seconds(10)) == .success {}
                resumed.resume()
            }
        }

        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf hi"],
            environment: [:], timeout: .seconds(3))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "settled at \(elapsed), state \(out.timeoutState ?? "nil")")
        XCTAssertEqual(out.exitCode, 0, "state \(out.timeoutState ?? "nil")")
        XCTAssertFalse(out.timedOut, "state \(out.timeoutState ?? "nil")")
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hi")
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
    /// An overrun has to say what the child was doing when the budget ran out, sampled before anything is
    /// signalled. Here the child is asleep and a grandchild holds stdout, so the answer names a live process and
    /// a pipe still open — the two facts that separate a hung child from one we merely failed to observe.
    func testATimeoutReportsTheChildsStateAndWhetherThePipesWereOpen() async throws {
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & sleep 30"],
            environment: [:], timeout: .milliseconds(500))
        XCTAssertTrue(out.timedOut)
        let state = try XCTUnwrap(out.timeoutState)
        XCTAssertTrue(state.contains("liveness=alive"), state)
        XCTAssertTrue(state.contains("waitReturned=false"), state)
        XCTAssertTrue(state.contains("pipesOpen=2"), state)
    }
    /// The arm that used to be lost: the child is gone by the time the budget expires, so there is nothing to
    /// signal, and the exit code is the uninformative `-1`. It is still an overrun and still has to say so.
    /// `sleep 30 &` leaves a grandchild on stdout, and `kill -9 $$` makes the shell vanish without our wait
    /// necessarily having returned.
    func testAChildThatIsAlreadyGoneAtTheBudgetIsStillReportedAsAnOverrun() async throws {
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & kill -9 $$"],
            environment: [:], timeout: .milliseconds(300))
        // Either the wait returned and this settled normally, or it did not and the budget expired; only the
        // second is this test's subject, and in that case the state must be there.
        if out.timedOut { XCTAssertNotNil(out.timeoutState) }
    }
    /// A child that settles on its own never samples anything: there is no overrun to explain.
    func testANormalRunCarriesNoTimeoutState() async throws {
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf hi"], environment: [:], timeout: .seconds(10))
        XCTAssertNil(out.timeoutState)
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
