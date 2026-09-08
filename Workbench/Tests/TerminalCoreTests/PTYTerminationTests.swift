import Darwin
import Foundation
@testable import TerminalCore
import XCTest

final class PTYTerminationTests: XCTestCase {
    func testExitReportsRequestedCodeExactlyOnce() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: "exit 7")
        )
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(process) }
        }

        let events = try await collectToCompletion(process.events)
        let endings = terminations(in: events)
        if !endings.isEmpty { needsCleanup = false }

        XCTAssertEqual(endings.count, 1, "one child exit must produce exactly one ended event")
        XCTAssertEqual(endings.first, .exited(code: 7), "the child's exit code was not preserved")
    }

    func testSignalReportsRequestedSignalExactlyOnce() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: "kill -TERM $$")
        )
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(process) }
        }

        let events = try await collectToCompletion(process.events)
        let endings = terminations(in: events)
        if !endings.isEmpty { needsCleanup = false }

        XCTAssertEqual(endings.count, 1, "one signalled child must produce exactly one ended event")
        XCTAssertEqual(
            endings.first,
            .signalled(signal: SIGTERM),
            "the signal that ended the child was not preserved"
        )
    }

    func testReportPolicyReportsStopWithoutEndingChild() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "kill -STOP $$; /bin/sleep 30"
            )
        )
        // A stopped process must be continued before it can be killed and reaped.
        defer { PTYTestChild.terminateAndReap(process) }

        let events = try await collectThroughStop(process.events)
        let stops = stoppedSignals(in: events)

        XCTAssertEqual(stops, [SIGSTOP], "the stop event did not carry SIGSTOP")
        XCTAssertEqual(
            Darwin.kill(process.processIdentifier, 0),
            0,
            "the child was not alive after its stop was reported"
        )
        XCTAssertEqual(
            terminations(in: events).count,
            0,
            "reporting a stop must leave the child alive rather than report an end"
        )
    }

    func testDetachPolicyContinuesThenHangsUpStoppedProcessGroup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        var request = PTYTestChild.request(
            cwd: directory,
            script: "kill -STOP $$; /bin/sleep 30"
        )
        request.stopPolicy = .detach
        let process = try PTYProcess(spawning: request)
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(process) }
        }

        let events = try await collectToCompletion(process.events)
        let endings = terminations(in: events)
        if !endings.isEmpty { needsCleanup = false }

        XCTAssertEqual(stoppedSignals(in: events), [SIGSTOP], "detach did not report the stop")
        XCTAssertEqual(endings.count, 1, "detach must still produce exactly one ended event")
        XCTAssertEqual(
            eventKinds(in: events).filter { $0 != .output },
            [.stopped, .ended],
            "the stop must be reported before the end it caused"
        )
        XCTAssertEqual(
            endings.first,
            .signalled(signal: SIGHUP),
            "detach did not end the stopped process group with SIGHUP"
        )
    }

    func testDroppingOwnerHangsUpAndReapsSpawnedProcessGroup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let pid = try await spawnThenReleaseOwner(cwd: directory)
        var needsCleanup = true
        defer {
            if needsCleanup { terminateAndReap(pid: pid) }
        }

        try await PTYTestChild.waitUntil(seconds: 3) {
            errno = 0
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
        needsCleanup = false
    }

    func testDroppingOwnerContinuesThenHangsUpStoppedProcessGroup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let pid = try await spawnStoppedThenReleaseOwner(cwd: directory)
        var needsCleanup = true
        defer {
            if needsCleanup { terminateAndReap(pid: pid) }
        }

        try await PTYTestChild.waitUntil(seconds: 3) {
            errno = 0
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
        needsCleanup = false
    }

    /// An external reaper — a test harness, a wrapper that waits on the whole group — can take
    /// the child's status before this actor's waiter sees it, leaving the waiter with `ECHILD`
    /// and no status to report. The stream must still end, and it must not invent a termination
    /// nobody observed. This drives the order that used to forget the lost status: it arrives
    /// while the master is still open, so nothing but persisted state can carry it to the end of
    /// file that follows. The opposite order is left to the production race — once the master is
    /// closed the child is hung up, so a synthetic version of it would race the real waiter.
    func testStreamFinishesWithoutTerminationWhenWaiterLosesBeforeMasterEnd() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: "exec /bin/sleep 30")
        )
        defer { PTYTestChild.terminateAndReap(process) }

        await process.waiterFinishedWithoutStatus()
        await process.readEnded()

        let events = try await collectToCompletion(process.events)
        XCTAssertEqual(
            terminations(in: events).count,
            0,
            "a lost status must not be reported as a termination"
        )
    }

    func testPaneExitCodeProjectsExitAndSignalForC4() {
        XCTAssertEqual(PTYTermination.exited(code: 7).paneExitCode, 7)
        XCTAssertEqual(
            PTYTermination.signalled(signal: SIGTERM).paneExitCode,
            128 + SIGTERM
        )
    }

    private func spawnThenReleaseOwner(cwd: URL) async throws -> pid_t {
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: cwd,
                script: "printf 'owner-ready\n'; exec /bin/sleep 30"
            )
        )
        _ = try await PTYTestChild.output(from: process.events, until: "owner-ready")
        return process.processIdentifier
    }

    private func spawnStoppedThenReleaseOwner(cwd: URL) async throws -> pid_t {
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: cwd,
                script: "kill -STOP $$; /bin/sleep 30"
            )
        )
        _ = try await collectThroughStop(process.events)
        return process.processIdentifier
    }

    private func terminateAndReap(pid: pid_t) {
        guard pid > 1 else { return }
        _ = Darwin.kill(-pid, SIGCONT)
        _ = Darwin.kill(-pid, SIGKILL)
        _ = Darwin.kill(pid, SIGCONT)
        _ = Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    private func collectToCompletion(
        _ events: AsyncStream<PTYEvent>
    ) async throws -> [PTYEvent] {
        try await PTYTestChild.withDeadline(seconds: 3) {
            var observed: [PTYEvent] = []
            for await event in events {
                observed.append(event)
            }
            return observed
        }
    }

    private func collectThroughStop(
        _ events: AsyncStream<PTYEvent>
    ) async throws -> [PTYEvent] {
        try await PTYTestChild.withDeadline(seconds: 3) {
            var observed: [PTYEvent] = []
            for await event in events {
                observed.append(event)
                if case .stopped = event {
                    return observed
                }
            }
            throw PTYTestChild.Failure.outputEnded
        }
    }

    private func terminations(in events: [PTYEvent]) -> [PTYTermination] {
        events.compactMap { event in
            guard case let .ended(termination) = event else { return nil }
            return termination
        }
    }

    private enum EventKind: Equatable {
        case output
        case stopped
        case ended
    }

    private func eventKinds(in events: [PTYEvent]) -> [EventKind] {
        events.map { event in
            switch event {
            case .output: .output
            case .stopped: .stopped
            case .ended: .ended
            }
        }
    }

    private func stoppedSignals(in events: [PTYEvent]) -> [Int32] {
        events.compactMap { event in
            guard case let .stopped(signal) = event else { return nil }
            return signal
        }
    }
}
