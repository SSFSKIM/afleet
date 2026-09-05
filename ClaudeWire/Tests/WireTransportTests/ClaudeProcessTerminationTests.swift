import XCTest
import AfleetCore
import WireFrames
import WireMCP
import WireDiagnostics
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
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "ignore_sigterm", diagnostics: sink)
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
        // The whole escalation trace, as a sequence rather than a membership check. SIGKILL re-establishes
        // liveness immediately before it signals, so a recheck that got the sense wrong would put
        // `no_live_child_to_signal` here instead of `SIGKILL` and the child would outlive `terminate()`.
        XCTAssertEqual(sink.terminateSteps, ["end_session", "stdin_closed", "SIGTERM", "SIGKILL"])
        let statuses = await probe.value
        XCTAssertTrue(statuses.contains(.terminating))
        // never .exited before the real exit: every .exited sample must come after all .terminating samples
        if let lastTerminating = statuses.lastIndex(of: .terminating), let firstExited = statuses.firstIndex(where: { if case .exited = $0 { return true }; return false }) {
            XCTAssertGreaterThan(firstExited, lastTerminating)
        }
    }
    /// Fix 1. On a constructed-but-never-spawned actor, `terminate()` used to fall through the escalation to
    /// `Process.terminate()` on an unlaunched process — an uncatchable `NSInvalidArgumentException` — and then
    /// to `kill(0, SIGKILL)`, which signals every process in afleet's own process group.
    ///
    /// The load-bearing assertion is that **no signal leaves**, not that nothing crashed. `terminate()` records
    /// `terminateEscalated(step:)` immediately before each signalling call and nowhere else, so the absence of
    /// the `SIGTERM` and `SIGKILL` steps says the signalling code was never entered — which is a claim the
    /// pre-fix code fails, because it records `SIGTERM` and then calls `Process.terminate()`. Asserting the
    /// SIGKILL itself is not possible from inside the victim: `kill(0, SIGKILL)` would take this test process
    /// with it, so a suite that survives is the only report you would ever get. That is why the step trace,
    /// not a crash check, is what this pins.
    func testTerminateBeforeSpawnNeitherWaitsNorSignals() async throws {
        let h = try Harness()
        let sink = RecordingDiagnostics()
        let p = h.make(scenario: "", diagnostics: sink)     // constructed; `spawn()` is never called
        let t0 = ContinuousClock.now
        await p.terminate()
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(1), "no escalation timer may run for a child that never existed")
        await p.terminate()                                 // idempotent
        let steps = sink.entries.filter { $0.contains("\"event\":\"terminate_escalated\"") }
        XCTAssertFalse(steps.contains { $0.contains("\"step\":\"SIGTERM\"") }, "a signal was sent with no child: \(steps)")
        XCTAssertFalse(steps.contains { $0.contains("\"step\":\"SIGKILL\"") }, "a signal was sent with no child: \(steps)")
        XCTAssertEqual(steps.filter { $0.contains("\"step\":\"never_launched\"") }.count, 1, "steps: \(steps)")
        XCTAssertFalse(steps.contains { $0.contains("\"step\":\"stdin_closed\"") }, "there is no stdin to close: \(steps)")
        // And the pid the pre-fix code would have signalled is in fact 0, the whole process group.
        let pid = await p.childProcessIdentifier
        XCTAssertEqual(pid, 0, "an unlaunched Process reports pid 0; kill(0, ...) is group-wide")
        let status = await p.status
        guard case .exited(.code(let code, let tail)) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(code, -1); XCTAssertEqual(tail, "terminated before launch")
        do { _ = try await p.spawn(); XCTFail("spawn accepted after terminate") }
        catch let e as WireError { if case .notInRunningState = e {} else { XCTFail("\(e)") } }
        _ = await h.expect({ if case .exited = $0 { return true }; return false }, "the stream still publishes an exit")
    }
    /// Fix 4. Exit observation must not be hostage to consumer liveness. Nothing iterates `events` here and the
    /// channel holds four elements, so the `.exited` push cannot complete — and yet `terminate()` must still
    /// return on the real exit rather than time out and escalate to signalling a pid Foundation has reaped.
    /// Pre-fix this took roughly forty seconds: 5 s to the SIGTERM step, 5 s more, then the 30 s final wait.
    func testExitObservationDoesNotDependOnAConsumerDraining() async throws {
        let h = try Harness()
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = "flood:100,exit:0"
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []),
                              diagnostics: NullDiagnostics(), capture: nil, eventBufferCapacity: 4)
        _ = try await p.spawn()
        let t0 = ContinuousClock.now
        await p.terminate()
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(3), "a stalled consumer must not push exit observation into the escalation")
        let status = await p.status
        guard case .exited(.code(0, _)) = status else { return XCTFail("\(status)") }
    }
    /// Fix A. EOF is not guaranteed by the child's death: it needs *every* holder of the write end to close
    /// it, and a grandchild that inherited the descriptor at fork keeps it open. The stand-in constructs
    /// exactly that — it starts a `/bin/sleep` that inherits stdout and stderr, then exits — so the readers
    /// never finish. The terminal event must be published anyway; an unbounded wait here would mean no
    /// `.exited`, no `finish()`, and a channel FleetKit never releases.
    func testExitIsPublishedWhenAGrandchildHoldsTheDescriptorOpen() async throws {
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "leak_stdout,exit:0", diagnostics: sink)
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr("GRANDCHILD HOLDS STDOUT", _) = $0 { return true }; return false }, "the grandchild was started")
        guard case .exited(let s, _)? = await h.expect({ if case .exited = $0 { return true }; return false },
                                                       "the terminal exit must be published though no EOF ever arrives",
                                                       within: .seconds(12)) else { return }
        XCTAssertTrue(s.isClean)
        XCTAssertTrue(sink.entries.contains { $0.contains("\"what\":\"reader_drain_deadline_exceeded\"") },
                      "publication should have gone ahead on the deadline, not on EOF: \(sink.entries.suffix(4))")
        await p.terminate()
    }
    /// Group 1a. `terminate()` awaited the `end_session` write and the stdin close before arming any timeout.
    /// `StdinWriter` serialises writes on one queue, so an earlier write parked on a pipe the child has stopped
    /// reading holds that queue and the `end_session` write behind it never returns — and the escalation that
    /// exists to guarantee the child dies is never reached at all.
    ///
    /// The failure mode is a hang, so the assertion is a deadline: pre-fix this test does not fail on a value,
    /// it fails by `completes(within:)` running out at twenty-five seconds. Post-fix the escalation costs about
    /// ten (five graceful, five to SIGTERM, then SIGKILL), and the child dies of SIGKILL because the stand-in
    /// ignores SIGTERM.
    ///
    /// The step trace is asserted as the whole sequence rather than as a membership check: it is the record of
    /// what was actually signalled, and it must show the graceful phase *timing out* and the escalation
    /// continuing past it.
    func testAStuckStdinWriteCannotPreventSIGTERMAndSIGKILL() async throws {
        let h = try Harness(); let sink = RecordingDiagnostics()
        let p = h.make(scenario: "deaf_stdin,ignore_sigterm,stay_alive", diagnostics: sink)
        _ = try await p.spawn()
        _ = await h.expect({ if case .stderr("DEAF", _) = $0 { return true }; return false }, "the child stopped reading stdin")
        // 512 KB against a 64 KB pipe buffer, so the writer's queue is parked inside this one write and every
        // later write is behind it. The send never returns; that is the premise, not a defect.
        let stuck = Task { try await p.send(raw: .object(["type": .string("user"), "filler": .string(String(repeating: "x", count: 512 * 1024))])) }
        try await Task.sleep(for: .milliseconds(500))

        let outcome = await completes(within: .seconds(25)) { await p.terminate() }
        stuck.cancel()
        guard let reported = outcome else {
            kill(await p.childProcessIdentifier, SIGKILL)      // the escalation never ran; do not leak the child
            return XCTFail("terminate() never returned: a blocked stdin write prevented SIGTERM and SIGKILL")
        }
        XCTAssertEqual(sink.terminateSteps, ["graceful_phase_deadline_exceeded", "SIGTERM", "SIGKILL"])
        guard case .signal(SIGKILL, _)? = reported else { return XCTFail("terminate reported \(String(describing: reported))") }
        guard case .exited(.signal(let sig, _), _)? = await h.expect({ if case .exited = $0 { return true }; return false }, "exited by SIGKILL") else { return }
        XCTAssertEqual(sig, SIGKILL)
    }
    /// Group 1b, end to end. Nothing iterates `events`, the channel holds four elements and the child floods
    /// it, so the terminal `.exited` is pushed onto a channel that is full and has no consumer. It used to be
    /// pushed with an ordinary suspending push, which parked `processDidExit` forever: no terminal event, no
    /// `finish()`, and a stream FleetKit never sees end.
    ///
    /// The observable is `bufferedEventCount` crossing the capacity, and it has to be: a consumer that arrives
    /// to *look* at the stream is a consumer that drains it, which frees the slots and lets even the parked
    /// pre-fix push through. So the claim is checked while nothing has consumed anything — the terminal element
    /// is the only one exempt from capacity, so a fifth element in a four-element channel is the exit itself.
    /// Only afterwards does a consumer appear, to confirm the element is the exit and that it is last.
    func testTheTerminalExitIsPublishedOnAFullChannelNobodyIsDraining() async throws {
        let h = try Harness()
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = "flood:100,exit:0"
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []),
                              diagnostics: NullDiagnostics(), capture: nil, eventBufferCapacity: 4)
        _ = try await p.spawn()
        // The child exits on its own. `status` flips at the top of `processDidExit`, before publication, so
        // this waits for the child to be gone without waiting for the event that says so.
        guard await completes(within: .seconds(15), { () -> Bool in
            while true {
                if case .exited = await p.status { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }) == true else { return XCTFail("the child never exited") }
        guard await completes(within: .seconds(10), { () -> Bool in
            while true {
                if await p.bufferedEventCount > 4 { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }) == true else {
            return XCTFail("the terminal exit was never enqueued: it is parked on a full channel with no consumer")
        }
        // Only now does a consumer appear.
        guard let events = await completes(within: .seconds(20), { () -> [WireEvent] in
            var all: [WireEvent] = []
            for await ev in p.events { all.append(ev) }
            return all
        }) else { return XCTFail("the event stream never ended: the terminal exit is parked on a full channel") }
        guard case .exited(let s, _)? = events.last else {
            return XCTFail("the last event was \(String(describing: events.last)), not the exit")
        }
        XCTAssertTrue(s.isClean)
        XCTAssertEqual(events.filter { if case .exited = $0 { return true }; return false }.count, 1,
                       "exactly one terminal event, and it is last")
    }
    /// Group 1c. `terminate()` returned `Void`, so a caller could not tell an observed exit from an escalation
    /// that ran out with the child still alive and `status` still `.terminating`. The outcome is now the return
    /// value, and it is the same exit the actor recorded.
    func testTerminateReportsTheExitItObserved() async throws {
        let h = try Harness(); let p = h.make(scenario: "")
        _ = try await p.spawn()
        guard let observed = await p.terminate() else { return XCTFail("no exit reported for a child that exited cleanly") }
        XCTAssertTrue(observed.isClean)
        let status = await p.status
        XCTAssertEqual(status, .exited(observed), "the reported exit must be the one the actor recorded")
        let again = await p.terminate()
        XCTAssertEqual(again, observed, "an idempotent second call reports the same exit")
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
