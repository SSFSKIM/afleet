import Darwin
import Foundation
import Synchronization
@testable import TerminalCore
import XCTest

private final class PTYEventRecorder: Sendable {
    private let events = Mutex<[PTYEvent]>([])

    func append(_ event: PTYEvent) {
        events.withLock { $0.append(event) }
    }

    var snapshot: [PTYEvent] {
        events.withLock { $0 }
    }

    var output: Data {
        events.withLock { events in
            events.reduce(into: Data()) { bytes, event in
                guard case let .output(chunk) = event else { return }
                bytes.append(chunk)
            }
        }
    }

    var sawStop: Bool {
        events.withLock { events in
            events.contains { event in
                if case .stopped = event { return true }
                return false
            }
        }
    }
}

private actor WaiterDeliveryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class PTYTerminationTests: XCTestCase {
    private static let postStopObservationWindow = Duration.milliseconds(250)

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

    func testReportPolicyReportsStopWithoutEndingOrResumingChild() async throws {
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

        // Keep draining after the stop: returning at `.stopped` made every later `.ended`
        // invisible and let an accidental detach pass. The bounded window is long compared with
        // the local signal/waiter path while keeping a correct stopped child from hanging the test.
        let events = try await collectForWindowAfterStop(process.events)

        XCTAssertEqual(stoppedSignals(in: events), [SIGSTOP], "the stop event did not carry SIGSTOP")
        XCTAssertEqual(
            PTYTestChild.processState(pid: process.processIdentifier),
            Int8(SSTOP),
            "reporting a stop resumed the child instead of leaving it stopped"
        )
        XCTAssertEqual(
            terminations(in: events).count,
            0,
            "reporting a stop ended the child during the post-stop observation window"
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

    func testDetachEscalatesWhenStoppedChildIgnoresHangup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        var request = PTYTestChild.request(
            cwd: directory,
            script: "trap '' HUP; kill -STOP $$; exec /bin/sleep 30"
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
        XCTAssertEqual(endings.count, 1, "detach escalation did not produce one ended event")
        XCTAssertEqual(
            eventKinds(in: events).filter { $0 != .output },
            [.stopped, .ended],
            "detach escalation reported its end before its stop"
        )
        XCTAssertEqual(
            endings.first,
            .signalled(signal: SIGTERM),
            "detach did not escalate an ignored SIGHUP to SIGTERM"
        )
    }

    func testTeardownEscalatesIgnoredHangupAndWaitsForEnded() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "trap '' HUP; printf 'ready\\n'; exec /bin/sleep 30"
            )
        )
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(process) }
        }
        let (recorder, reader) = record(process.events)
        defer { reader.cancel() }
        try await waitForOutput("ready", in: recorder)

        await process.teardown()
        await reader.value
        let endings = terminations(in: recorder.snapshot)
        if !endings.isEmpty { needsCleanup = false }

        XCTAssertEqual(endings.count, 1, "teardown did not produce exactly one ended event")
        XCTAssertEqual(
            endings.first,
            .signalled(signal: SIGTERM),
            "teardown did not escalate an ignored SIGHUP to SIGTERM"
        )
    }

    func testTeardownEscalatesIgnoredHangupAndTermToKill() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "trap '' HUP TERM; printf 'ready\\n'; while :; do /bin/sleep 30; done"
            )
        )
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(process) }
        }
        let (recorder, reader) = record(process.events)
        defer { reader.cancel() }
        try await waitForOutput("ready", in: recorder)

        await process.teardown()
        await reader.value
        let endings = terminations(in: recorder.snapshot)
        if !endings.isEmpty { needsCleanup = false }

        XCTAssertEqual(endings.count, 1, "teardown kill escalation did not produce one ended event")
        XCTAssertEqual(
            endings.first,
            .signalled(signal: SIGKILL),
            "teardown did not escalate ignored SIGHUP and SIGTERM to SIGKILL"
        )
    }

    func testRetainedStreamDrainsEndedAfterTeardownOwnerRelease() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let completionMarker = directory.appending(path: "output-completed")
        let outputByteCount = PTYProcess.outputDeliveryByteLimit * 2
        var process: PTYProcess? = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: """
                /bin/stty raw -echo
                /usr/bin/head -c \(outputByteCount) /dev/zero
                /usr/bin/touch "$AFLEET_COMPLETION_MARKER"
                exec /bin/sleep 30
                """,
                environment: ["AFLEET_COMPLETION_MARKER": completionMarker.path]
            )
        )
        let childIdentity = try XCTUnwrap(
            PTYTestChild.identity(ofChild: process!.processIdentifier)
        )
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(childIdentity) }
        }
        let retainedEvents = process!.events

        try await PTYTestChild.waitUntil(seconds: 3) {
            FileManager.default.fileExists(atPath: completionMarker.path)
        }
        try await Task.sleep(for: .milliseconds(100))
        try await PTYTestChild.withDeadline(seconds: 3) { [process] in
            await process!.teardown()
        }
        needsCleanup = false
        process = nil

        let observed = try await collectToCompletion(retainedEvents)
        let outputByteTotal = observed.reduce(into: 0) { total, event in
            guard case let .output(bytes) = event else { return }
            total += bytes.count
        }
        XCTAssertEqual(
            outputByteTotal,
            outputByteCount,
            "releasing the torn-down owner discarded queued output"
        )
        XCTAssertEqual(
            terminations(in: observed).count,
            1,
            "releasing the torn-down owner discarded or duplicated its ended event"
        )
        XCTAssertEqual(eventKinds(in: observed).last, .ended, "ended overtook queued output")
    }

    func testCancellingEventConsumerDoesNotCloseLivePTY() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "/bin/stty raw -echo; printf 'ready'; exec /bin/cat"
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }
        let (recorder, reader) = record(process.events)
        try await waitForOutput("ready", in: recorder)

        reader.cancel()
        await reader.value
        try await process.write(Data("first-after-cancel".utf8))
        try await Task.sleep(for: .milliseconds(100))

        do {
            try await process.write(Data("second-after-cancel".utf8))
            try await process.resize(
                to: TerminalSize(rows: 25, columns: 81, pixelWidth: 648, pixelHeight: 500)
            )
        } catch {
            XCTFail("consumer cancellation closed the actor's live pty: \(error)")
        }

        await process.teardown()
    }

    func testDroppingOwnerBestEffortKillsHangupIgnoringProcessGroup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let childIdentity = try await spawnThenReleaseOwner(cwd: directory)
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(childIdentity) }
        }

        try await PTYTestChild.waitUntil(seconds: 3) {
            !PTYTestChild.stillNamesTheSameChild(childIdentity)
        }
        needsCleanup = false
    }

    func testDroppingOwnerBestEffortContinuesAndKillsStoppedProcessGroup() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let childIdentity = try await spawnStoppedThenReleaseOwner(cwd: directory)
        var needsCleanup = true
        defer {
            if needsCleanup { PTYTestChild.terminateAndReap(childIdentity) }
        }

        try await PTYTestChild.waitUntil(seconds: 3) {
            !PTYTestChild.stillNamesTheSameChild(childIdentity)
        }
        needsCleanup = false
    }

    /// This is the Global Constraints' non-executable substitute for the kernel race: macOS
    /// normally discards an unread stop when a terminal signal follows before `waitpid` runs.
    /// Drive two waiter deliveries instead. The first deliberately suspends; only a synchronous
    /// delivery gate can keep the second status from overtaking it.
    func testWaiterDeliversObservedStatusesInOrder() async throws {
        let gate = WaiterDeliveryGate()
        let trace = Mutex<[EventKind]>([])
        let finished = Mutex(false)
        let queue = DispatchQueue(label: "app.afleet.terminal-core.tests.waiter-order")

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        queue.async {
            PTYProcess.deliver {
                await gate.wait()
                trace.withLock { $0.append(.stopped) }
            }
            PTYProcess.deliver {
                trace.withLock { $0.append(.ended) }
                await gate.open()
            }
            finished.withLock { $0 = true }
        }

        try await PTYTestChild.waitUntil(seconds: 3) { finished.withLock { $0 } }
        XCTAssertEqual(trace.withLock { $0 }, [.stopped, .ended], "waiter statuses overtook each other")
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

    /// The owner-release tests keep only an identifier and clean up on timeout, while the actor's
    /// waiter goes on reaping without them. A pid the waiter has already reaped can be held by
    /// anything, so cleanup that names it by number alone can signal a stranger on the developer's
    /// own machine. This drives that case directly: an identity the helper can no longer prove,
    /// against a live process group of this test's own.
    func testOwnerReleaseCleanupRefusesAPidItCannotStillProveIsTheChild() throws {
        let bystander = try Self.spawnGroupLeader(sleepingFor: 30)
        defer { Self.killAndReap(bystander) }
        let identity = try XCTUnwrap(PTYTestChild.identity(ofChild: bystander))
        // The same number, a different process: what a caller holds after the reaper has taken the
        // status it was recorded for and the kernel has handed the number on.
        let stale = PTYTestChild.ChildIdentity(
            pid: identity.pid,
            startedAtSeconds: identity.startedAtSeconds - 1,
            startedAtMicroseconds: identity.startedAtMicroseconds
        )

        XCTAssertFalse(PTYTestChild.stillNamesTheSameChild(stale), "stale-identity=accepted")
        PTYTestChild.terminateAndReap(stale)
        usleep(250_000)

        XCTAssertTrue(PTYTestChild.isRunning(identity), "unrelated-process-group=signalled")
        // And the helper still does its job for the identity it can prove. It ends the child; it
        // does not reap it. This bystander has no production waiter behind it, so it stays a
        // zombie until this test's own `defer` takes the status — which is the point: cleanup
        // that reaped here would be taking a status that, for a pty child, belongs to the
        // waiter.
        PTYTestChild.terminateAndReap(identity)
        XCTAssertFalse(PTYTestChild.isRunning(identity), "proven-child=still-running")
    }

    /// A child of this test process in a process group of its own — the shape of a pty child, so
    /// the group signal the cleanup helper sends is the same syscall it would send there. Spawned
    /// with an empty environment: nothing of this process's, `CLAUDE*` included, reaches it.
    private static func spawnGroupLeader(sleepingFor seconds: Int) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw PTYTestChild.Failure.spawnRefused }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let path = "/bin/sleep"
        let spawned = path.withCString { executable in
            String(seconds).withCString { duration -> Int32 in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(executable), strdup(duration), nil,
                ]
                var environment: [UnsafeMutablePointer<CChar>?] = [nil]
                defer { argv.forEach { free($0) } }
                return posix_spawn(&pid, executable, nil, &attributes, &argv, &environment)
            }
        }
        guard spawned == 0 else { throw PTYTestChild.Failure.spawnRefused }
        return pid
    }

    private static func killAndReap(_ pid: pid_t) {
        _ = Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    private func spawnThenReleaseOwner(cwd: URL) async throws -> PTYTestChild.ChildIdentity {
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: cwd,
                script: "printf 'owner-ready\\n'; trap '' HUP; exec /bin/sleep 30"
            )
        )
        _ = try await PTYTestChild.output(from: process.events, until: "owner-ready")
        // Taken while the child is provably alive and ours, which is the only moment an identity
        // can be taken: the owner is released next and its waiter may reap at any time after.
        return try XCTUnwrap(PTYTestChild.identity(ofChild: process.processIdentifier))
    }

    private func spawnStoppedThenReleaseOwner(
        cwd: URL
    ) async throws -> PTYTestChild.ChildIdentity {
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: cwd,
                script: "trap '' HUP TERM; kill -STOP $$; exec /bin/sleep 30"
            )
        )
        _ = try await collectThroughStop(process.events)
        return try XCTUnwrap(PTYTestChild.identity(ofChild: process.processIdentifier))
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

    private func collectForWindowAfterStop(
        _ events: AsyncStream<PTYEvent>
    ) async throws -> [PTYEvent] {
        let recorder = PTYEventRecorder()
        return try await withThrowingTaskGroup(of: [PTYEvent].self) { group in
            group.addTask {
                for await event in events {
                    recorder.append(event)
                }
                return recorder.snapshot
            }
            group.addTask {
                try await PTYTestChild.waitUntil(seconds: 3) { recorder.sawStop }
                try await Task.sleep(for: Self.postStopObservationWindow)
                return recorder.snapshot
            }
            guard let first = try await group.next() else {
                throw PTYTestChild.Failure.outputEnded
            }
            group.cancelAll()
            return first
        }
    }

    /// A trace assertion, and deliberately so: pid recycling cannot be provoked from inside a
    /// test process. What is pinned instead is the gate every cleanup signal passes through — it
    /// must refuse once the child's status has been consumed, because from that moment `-pid`
    /// names whatever group next takes that number rather than this child's.
    func testCleanupSignalsAreRefusedOnceTheChildHasBeenReaped() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let living = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: PTYTestChild.selfTerminating(after: 30, "exec /bin/cat")
            )
        )
        let reaped = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: PTYTestChild.selfTerminating(after: 30, "exec /bin/cat")
            )
        )
        var livingNeedsCleanup = true
        defer {
            if livingNeedsCleanup { PTYTestChild.terminateAndReap(living) }
        }

        let livingDisposition = PTYTestChild.terminateAndReap(living)
        livingNeedsCleanup = false
        await reaped.teardown()
        let reapedDisposition = PTYTestChild.terminateAndReap(reaped)

        XCTAssertTrue(livingDisposition == .sent, "living-child-cleanup=refused")
        XCTAssertTrue(reapedDisposition == .notOwned, "reaped-child-cleanup=signalled")
    }

    /// The owner-release cleanup shares the reaper's gate. Its two signals are separated by a
    /// window in which the production waiter can reap — and a reaped pid, with the process group
    /// that shares its number, is reusable at once — so one proof cannot authorise both. The
    /// window cannot be arranged against the real scheduler, so the proof itself is what is
    /// driven here: it is invalidated between the signals, exactly as a reap would invalidate it.
    func testOwnerReleaseCleanupRefusesTheSecondSignalOnceTheProofIsGone() {
        let identity = PTYTestChild.ChildIdentity(
            pid: 424_242,
            startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456
        )
        let proofCallCount = Mutex(0)
        let signalsSent = Mutex<[Int32]>([])
        let watchCallCount = Mutex(0)

        PTYTestChild.terminateAndReap(
            identity,
            probes: PTYTestChild.ChildCleanupProbes(
                // Ours for the first signal, reaped by the production waiter before the second.
                stillNamesTheSameChild: { _ in
                    proofCallCount.withLock { count in
                        count += 1
                        return count == 1
                    }
                },
                signalProcessGroup: { _, signal in signalsSent.withLock { $0.append(signal) } },
                isRunning: { _ in
                    watchCallCount.withLock { $0 += 1 }
                    return false
                },
                settle: {}
            )
        )

        XCTAssertEqual(signalsSent.withLock { $0 }, [SIGCONT], "cleanup-signals=\(signalsSent.withLock { $0 })")
        XCTAssertEqual(proofCallCount.withLock { $0 }, 2, "cleanup-proofs=\(proofCallCount.withLock { $0 })")
        XCTAssertEqual(watchCallCount.withLock { $0 }, 0, "cleanup-watched-a-child-it-lost=\(watchCallCount.withLock { $0 })")
    }

    /// The same cleanup against a real child, with the production waiter alive. Releasing the
    /// owner without a teardown abandons the stream by design, so what is observable here is the
    /// child and the pid: the cleanup must end the child, and the pid must then go away — and it
    /// can only go away because the *production waiter* reaped it, since this cleanup never
    /// claims a status of its own.
    func testOwnerReleaseCleanupEndsTheChildAndLeavesTheReapToTheProductionWaiter() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        var process: PTYProcess? = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: PTYTestChild.selfTerminating(after: 30, "/bin/stty raw -echo; exec /bin/cat")
            )
        )
        let identity = try XCTUnwrap(PTYTestChild.identity(ofChild: process!.processIdentifier))
        process = nil

        PTYTestChild.terminateAndReap(identity)

        XCTAssertFalse(PTYTestChild.isRunning(identity), "owner-release-cleanup-child=alive")
        try await PTYTestChild.waitUntil(seconds: 5) {
            !PTYTestChild.stillNamesTheSameChild(identity)
        }
    }

    /// The deadline has to be one. `teardown` awaits its waiter's value without observing
    /// cancellation, and a throwing task group's scope waits for every child it cancelled, so a
    /// deadline built from one returned when the operation felt like it — the seconds in the call
    /// bounded nothing. What is asserted is the return, that the operation had not finished when
    /// it happened, and that the abandoned operation still reaches its own end.
    func testDeadlineReturnsWhileANonCancellableOperationIsStillRunning() async throws {
        let operationSeconds = 3.0
        let deadlineSeconds = 0.5
        let didFinish = Mutex(false)
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await PTYTestChild.withDeadline(seconds: deadlineSeconds) {
                // Cancellation-proof by construction: a continuation resumed off a queue that
                // knows nothing about tasks — the shape `teardown` has when it awaits its waiter.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + operationSeconds) {
                        didFinish.withLock { $0 = true }
                        continuation.resume()
                    }
                }
                return 0
            }
            XCTFail("deadline-elapsed=absent")
        } catch PTYTestChild.Failure.timedOut {
            // The deadline is what must be observed.
        }

        let elapsed = clock.now - startedAt
        XCTAssertLessThan(elapsed, .seconds(operationSeconds / 2), "deadline-return=\(elapsed)")
        XCTAssertFalse(didFinish.withLock { $0 }, "deadline-waited-for-the-operation")

        try await PTYTestChild.waitUntil(seconds: operationSeconds * 2) {
            didFinish.withLock { $0 }
        }
    }

    private func record(
        _ events: AsyncStream<PTYEvent>
    ) -> (PTYEventRecorder, Task<Void, Never>) {
        let recorder = PTYEventRecorder()
        let reader = Task {
            for await event in events {
                recorder.append(event)
            }
        }
        return (recorder, reader)
    }

    private func waitForOutput(_ marker: String, in recorder: PTYEventRecorder) async throws {
        let bytes = Data(marker.utf8)
        try await PTYTestChild.waitUntil(seconds: 3) {
            recorder.output.range(of: bytes) != nil
        }
    }

    private func terminations(in events: [PTYEvent]) -> [PTYTermination] {
        events.compactMap { event in
            guard case let .ended(termination) = event else { return nil }
            return termination
        }
    }

    private enum EventKind: Equatable, Sendable {
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
