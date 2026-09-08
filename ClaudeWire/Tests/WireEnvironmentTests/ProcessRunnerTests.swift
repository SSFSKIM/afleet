import Foundation
import XCTest
@testable import WireEnvironment

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

    // MARK: - one drain pass is bounded (tracker entry 125)

    /// The property the runner depends on: **one readable event does a bounded amount of work**.
    /// The timeout, the `SIGKILL` escalation and the settlement all run on the same serial queue as
    /// the pipe drains, so a pass that reads while data keeps arriving is time in which none of the
    /// three can run — the budget passes unobserved and nothing signals the child.
    ///
    /// Demonstrated against a descriptor that *always* has more to give rather than against a
    /// flooding child, and that is the point: a regular file never says `EAGAIN`, so an unbounded
    /// loop's only exit is end-of-file. No producer and no scheduling race, and the same read loop
    /// the runner installs on its pipes.
    func testOneDrainPassStopsAtItsBoundOnADescriptorThatAlwaysHasMore() throws {
        let available = 8 * 1024 * 1024
        let fd = try openScratchFile(ofSize: available)
        defer { close(fd) }

        var taken = 0
        let outcome = PipeDrain.pass(fd) { taken += $0.count }

        XCTAssertEqual(outcome, .open, "a pass that stopped at its bound reported the descriptor closed")
        XCTAssertGreaterThan(taken, 0, "the pass read nothing at all")
        XCTAssertLessThanOrEqual(taken, PipeDrain.bytesPerPass,
                                 "one pass took \(taken) bytes from a descriptor holding \(available); it does not yield the queue between passes")
    }

    /// And the bound loses nothing. Passes repeated until the descriptor reports itself closed
    /// deliver every byte, in the order it was written: a bound that dropped or reordered the tail
    /// would be a runner that hands the transport a truncated or scrambled stream under load, which
    /// is worse than the defect it fixes. The scratch bytes are a generated pattern, so a swap of
    /// two passes is visible and not merely a count that still adds up.
    func testRepeatedDrainPassesPreserveEveryByteAndTheirOrderThenReportTheDescriptorClosed() throws {
        let available = 8 * 1024 * 1024
        let pattern = Self.scratchPattern(ofSize: available)
        let fd = try openScratchFile(ofSize: available)
        defer { close(fd) }

        var collected = Data(), passes = 0
        var outcome = PipeDrain.Outcome.open
        while outcome == .open, passes < 1_000 {
            outcome = PipeDrain.pass(fd) { collected.append($0) }
            passes += 1
        }

        XCTAssertEqual(outcome, .closed, "the descriptor was never reported closed")
        XCTAssertEqual(collected.count, available,
                       "the passes together delivered a different number of bytes than the descriptor held")
        XCTAssertEqual(collected, pattern, "the bytes came back in a different order than they were written")
        XCTAssertGreaterThanOrEqual(passes, available / PipeDrain.bytesPerPass,
                                    "\(passes) pass(es) covered the whole descriptor, so a pass is not bounded")
    }

    /// The two other outcomes, which the bound must not disturb: a pipe with nothing in it right now
    /// is *open* — the reader comes back when the source fires again — while a pipe whose only
    /// writer is gone is *closed*, which is what cancels the source and closes the descriptor.
    func testADrainPassReadsAnEmptyPipeAsOpenAndAWriterlessOneAsClosed() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }

        var taken = 0
        XCTAssertEqual(PipeDrain.pass(fd) { taken += $0.count }, .open, "a pipe that is merely empty was reported closed")
        XCTAssertEqual(taken, 0, "a pass over an empty pipe appended bytes")

        try pipe.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(PipeDrain.pass(fd) { taken += $0.count }, .closed,
                       "a pipe whose only writer has gone was not reported closed")
        XCTAssertEqual(taken, 5, "the writer's last bytes did not arrive with the end of the pipe")
    }

    /// A child that streams continuously past its budget is still signalled and still settles. This
    /// is a floor rather than the discriminator for the bound — it passes with the drain unbounded
    /// too, because no user-space producer keeps a 64 KiB pipe fed faster than the drain empties it
    /// — but it is the property a reader would expect to be pinned, and a bound that broke the
    /// re-arm would fail it by hanging.
    ///
    /// Byte counts, never bytes: nothing here prints a payload.
    func testAChildStreamingContinuouslyIsStillTimedOutAndSettles() async throws {
        let start = ContinuousClock.now
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz"],
            environment: [:], timeout: .milliseconds(500))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertTrue(out.timedOut, "a child that streamed past its budget was not reported as timed out")
    }

    /// The integration half of the bound, and the property a bounded drain could plausibly break: a
    /// child whose output is many passes long still arrives whole and in order. The re-arm carries
    /// it — the readable event fires again while the pipe still holds data — and if it did not, this
    /// is where the stream would come back truncated.
    func testAChildsOutputArrivesWholeAndInOrderWhenItIsManyPassesLong() async throws {
        let expected = 8 * 1024 * 1024
        let out = try await FoundationProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -c \(expected)"],
            environment: [:], timeout: .seconds(60))
        XCTAssertFalse(out.timedOut, "a producer well inside its budget was reported as timed out")
        XCTAssertEqual(out.stdout.count, expected,
                       "the drain delivered a different number of bytes than the child wrote")
        let line = Data("abcdefghijklmnopqrstuvwxyz\n".utf8)
        var offset = 0, mismatches = 0
        while offset + line.count <= expected {
            if out.stdout[offset ..< offset + line.count] != line { mismatches += 1 }
            offset += line.count
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) block(s) came back out of order across drain passes")
    }

    /// `size` bytes of a generated, position-dependent pattern.
    private static func scratchPattern(ofSize size: Int) -> Data {
        Data((0 ..< size).map { UInt8($0 % 251) })
    }

    /// A scratch file of `size` bytes opened for reading. The descriptor is returned rather than the
    /// path: nothing in this suite prints one.
    private func openScratchFile(ofSize size: Int) throws -> Int32 {
        let url = FileManager.default.temporaryDirectory.appending(path: "wire-drain-\(UUID().uuidString)")
        try Self.scratchPattern(ofSize: size).write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path(percentEncoded: false), O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "the scratch file could not be opened for reading")
        return fd
    }
}
