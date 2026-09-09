import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.4 T6: gate **G2.1**, the headless half — a pane's exit reaching C4 through the whole real
/// path (child spec Acceptance G2, Design §2, §3 and §6).
///
/// Nothing between the request and the lifecycle is a double. A real `PaneRequest` goes into the
/// real `PanelHostModel.run(_:for:)`, which resolves the channel's real `ChannelContext` and hands
/// it to the real `TerminalPaneRunner`; the real `TerminalPanelSession` opens a real `TerminalPane`
/// over a real pty and a real child; and what the child's exit reaches is `LifecycleDouble`, the
/// one double in the journey, standing where C4 stands. T2 already proved the host-to-runner hop
/// with a recording runner, so a second recording runner here would prove nothing new.
///
/// Every identifier is invented — a session is a hex-formatted index, a working directory is
/// inside this test's own temporary tree, a child's environment is two names this file wrote
/// (§11). No engine byte reaches a committed file. Where an assertion would otherwise print a
/// `PaneRequest` or a child environment it is spelled as a boolean or a count with a message this
/// file wrote, because `XCTAssertEqual` prints both operands and that output is what a report
/// quotes (§6.3).
///
/// The children are `/bin/sh` and `/usr/bin/true`, never `claude`: what is under test is the
/// journey of an exit, and a status is a status whoever produced it.
@MainActor
final class TerminalPanelJourneyTests: XCTestCase {

    // MARK: - Group 1: the hatch's exit reaches C4 exactly once, unchanged

    /// A `.hatch` request whose child exits 3: one `PaneExit`, carrying the request that was run
    /// with its `id` intact, and carrying 3.
    ///
    /// The `id` clause is the one that cannot fail loudly in production. C4 matches an exit by
    /// `request.id` across its supervisors and records anything else as a `.staleExit`, silently —
    /// so a panel that re-minted the id would leave a hatched channel released for ever and say
    /// nothing. The mutation that proves this test discriminating is exactly that re-mint.
    func testAHatchExitReachesTheLifecycleOnceWithItsRequestUnchanged() async throws {
        let rig = try await JourneyRig()
        let context = try rig.resolve(0)
        let request = JourneyFixtures.request(purpose: .hatch(context.session),
                                              cwd: rig.cwd,
                                              arguments: ["-c", "exit 3"])

        try await rig.host.run(request, for: context.key)

        let exits = await rig.settledExits { rig.session(0)?.panes.first?.state.hasEnded == true }
        XCTAssertEqual(exits.count, 1, "the lifecycle received \(exits.count) pane exits, not 1")
        XCTAssertTrue(exits.first?.request.id == request.id,
                      "the exit reaching the lifecycle carries a re-minted request id")
        XCTAssertTrue(exits.first?.request == request,
                      "the exit's request is not the one that was run")
        XCTAssertEqual(exits.first?.code, 3, "the child's own status did not reach the lifecycle")
    }

    // MARK: - Group 2: a shell pane reports nothing

    /// A pane the panel made itself is nobody's request, so there is no request to echo and no one
    /// waiting on it. Reporting it would put a `.staleExit` in C4's log for every closed shell,
    /// which is a record of a mistake nobody made (spec Design §6, Decision Log).
    ///
    /// The rig's shell is `/usr/bin/true`, so the shell pane's child exits at once and the thing
    /// this waits for is that exit, not a duration.
    func testAShellPanesExitReachesTheLifecycleNever() async throws {
        let rig = try await JourneyRig(shellPath: "/usr/bin/true")
        let context = try rig.resolve(0)
        let session = try XCTUnwrap(rig.host.session(for: .terminal, context: context) as? TerminalPanelSession,
                                    "the host did not vend the Terminal tab's own session")

        let pane = session.openShellPane()

        let exits = await rig.settledExits { pane.state.hasEnded }
        XCTAssertTrue(pane.state.hasEnded, "the shell pane's child never ended, so nothing was proved")
        XCTAssertNil(pane.request, "a pane the panel opened itself is carrying a request")
        XCTAssertEqual(exits.count, 0, "a shell pane reported \(exits.count) exit(s) through X5")
    }

    // MARK: - Group 3: a failed spawn reports 127

    /// The arm that stops a hatch whose pane never started from leaving its channel released for
    /// ever (spec Design §2, Decision Log).
    ///
    /// Three clauses, and each is load-bearing: the pane lands `.failed` rather than disappearing;
    /// nothing throws back to the caller, because §10 forbids a pty failure reaching the channel as
    /// an error; and exactly one `PaneExit` arrives, carrying the code the panel synthesises
    /// because there was no child to observe one from.
    func testAPaneWhoseSpawnFailsStillReports127() async throws {
        let rig = try await JourneyRig()
        let context = try rig.resolve(0)
        let missing = rig.cwd.appending(path: "no-such-executable")
        let request = JourneyFixtures.request(purpose: .hatch(context.session),
                                              cwd: rig.cwd,
                                              arguments: [],
                                              executable: missing)

        do {
            try await rig.host.run(request, for: context.key)
        } catch {
            XCTFail("a pane whose spawn failed threw \(type(of: error)) back to the caller")
        }

        let pane = try XCTUnwrap(rig.session(0)?.panes.first, "the failed request opened no pane")
        guard case .failed = pane.state else {
            return XCTFail("a pane whose executable does not exist did not land in .failed")
        }
        let exits = await rig.settledExits { true }
        XCTAssertEqual(exits.count, 1, "a failed spawn reported \(exits.count) exits, not 1")
        XCTAssertTrue(exits.first?.request.id == request.id,
                      "the synthesised exit carries a request id the caller never ran")
        XCTAssertEqual(exits.first?.code, PaneSpawn.unexecutableExitCode,
                       "a failed spawn did not report the unexecutable status")
    }

    // MARK: - Group 4: a signalled child is an event, not a number

    /// A child that kills itself with SIGTERM produces an exit report at all.
    ///
    /// What is pinned is the *event*. The spec accepts that `PaneExit` cannot tell `.signalled(15)`
    /// from `.exited(143)` — X5's re-adoption keys on the event and not on the number — so the
    /// failure this guards against is a panel that treats a signalled child as no termination and
    /// reports nothing, which is the same stuck channel as an unreported failed spawn.
    func testASignalledChildStillProducesAnExitReport() async throws {
        let rig = try await JourneyRig()
        let context = try rig.resolve(0)
        let request = JourneyFixtures.request(purpose: .hatch(context.session),
                                              cwd: rig.cwd,
                                              arguments: ["-c", "kill -TERM $$"])

        try await rig.host.run(request, for: context.key)

        let exits = await rig.settledExits { rig.session(0)?.panes.first?.state.hasEnded == true }
        XCTAssertEqual(exits.count, 1, "a signalled child reported \(exits.count) exits, not 1")
        XCTAssertEqual(exits.first?.code, 128 + SIGTERM,
                       "a signalled child's exit did not carry 128 plus its signal")
    }

    // MARK: - Group 5: the exit belongs to the channel the caller named

    /// G2.1's clause about *where*. Two channels the host can resolve, the window focused on the
    /// second, the request run **for the first**: the pane is in the first channel's session, the
    /// second's is empty, and the exit reaches the lifecycle.
    ///
    /// T2 asserted the context the host handed over. This asserts the pane and the exit that
    /// follow it, which is the part a recording runner cannot see: a host that resolved the channel
    /// from its own focus would open the pane in a channel X5 never released, and C4 would wait on
    /// an exit from a pane that is running somewhere else.
    func testThePaneAndItsExitBelongToTheNamedChannelAndNotTheFocusedOne() async throws {
        let rig = try await JourneyRig(channels: 2)
        let named = try rig.resolve(0)
        let focused = try rig.resolve(1)
        rig.host.focusChannel(focused.key)
        let request = JourneyFixtures.request(purpose: .hatch(named.session),
                                              cwd: rig.cwd,
                                              arguments: ["-c", "exit 3"])

        try await rig.host.run(request, for: named.key)

        XCTAssertEqual(rig.session(0)?.panes.count, 1, "the named channel's session holds no pane")
        XCTAssertEqual(rig.session(1)?.panes.count, 0, "the focused channel took the named channel's pane")
        XCTAssertTrue(rig.session(0)?.panes.first?.request == request,
                      "the pane in the named channel holds a request the caller did not run")
        let exits = await rig.settledExits { rig.session(0)?.panes.first?.state.hasEnded == true }
        XCTAssertEqual(exits.count, 1, "the named channel's pane reported \(exits.count) exits, not 1")
        XCTAssertTrue(exits.first?.request.id == request.id,
                      "the exit that reached the lifecycle is not the named channel's pane's")
    }
}

// MARK: - Values

/// Every identifier this suite hands a child, invented throughout (§11).
private enum JourneyFixtures {

    /// The child's whole environment: two names this file wrote, and nothing of the test process's
    /// own. X11 says the request's environment *is* the child's, so a crafted one here is also what
    /// makes the pane's pass-through observable at all.
    static let environment = ["PATH": "/usr/bin:/bin", "AFLEET_INVENTED_PANE": "journey"]

    /// A pane request over `/bin/sh` unless the caller names another executable. The purposes here
    /// are all `.hatch`, because the hatch is the request whose exit an actual channel is waiting
    /// on; `PaneSpawn`'s per-purpose mapping is C7.4's T1 and not this suite's.
    static func request(purpose: PanePurpose,
                        cwd: URL,
                        arguments: [String],
                        executable: URL = URL(fileURLWithPath: "/bin/sh")) -> PaneRequest {
        PaneRequest(executable: executable,
                    arguments: arguments,
                    cwd: cwd,
                    environment: environment,
                    purpose: purpose)
    }
}

private extension PaneState {
    /// Whether this pane will produce no further termination: its child ended, or never started.
    var hasEnded: Bool {
        switch self {
        case .exited, .failed: true
        case .starting, .running, .stopped: false
        }
    }
}

// MARK: - Rig

/// `PanelRig` with C7.4's own tab and pane runner registered over one registry, exactly as
/// `AppModel.bindWorkspace` registers them, plus a working directory that exists on disk because a
/// child is spawned into it.
///
/// One registry for both, and never one each: the tab and the runner have to vend the same
/// `TerminalPanelSession` or a pane would live in one session while the other is asked whether it
/// holds one.
@MainActor
private struct JourneyRig {

    /// How long the harness will wait for an event before giving up. It bounds the harness and
    /// decides no assertion: every assertion in this file reads the state after the wait, so a
    /// watchdog that fires produces the ordinary failure of an unmet expectation rather than a
    /// verdict of its own.
    static let watchdog: Duration = .seconds(20)

    /// How long between polls, and how many agreeing observations count as "the reports landed".
    private static let pollInterval: Duration = .milliseconds(5)
    private static let agreementsForSettled = 4

    let panels: PanelRig
    let registry: TerminalSessionRegistry
    /// A directory that exists: a pty spawn into a directory that does not is a failed spawn, which
    /// is group 3's subject and nobody else's.
    let cwd: URL

    var host: PanelHostModel { panels.host }
    var lifecycle: LifecycleDouble { panels.lifecycle }

    init(channels: Int = 1, shellPath: String = "/bin/zsh") async throws {
        panels = try await PanelRig(channels: channels, shellPath: shellPath)
        registry = TerminalSessionRegistry()
        try panels.host.register(TerminalPanelTab(registry: registry))
        panels.host.registerPaneRunner(TerminalPaneRunner(registry: registry), for: .terminal)
        cwd = try panels.temp.directory("pane-cwd")
    }

    /// The channel's context, resolved through the host as every production caller resolves one.
    @discardableResult
    func resolve(_ index: Int) throws -> ChannelContext {
        try XCTUnwrap(panels.host.context(for: panels.keys[index], cwd: cwd),
                      "the host built no context for one of its own channels")
    }

    /// The Terminal session the host vends for that channel — the same object the runner was
    /// handed, because both go through the one registry. `nil` for a channel the host can resolve
    /// no context for, which every caller here has already ruled out by resolving one.
    func session(_ index: Int) -> TerminalPanelSession? {
        guard let context = panels.host.context(for: panels.keys[index]) else { return nil }
        return panels.host.session(for: .terminal, context: context) as? TerminalPanelSession
    }

    /// Waits for `event`, then for the lifecycle's exit log to stop changing, and answers the log.
    ///
    /// Both halves are fulfilled by what they wait for and neither is a fixed sleep: the first
    /// returns on the turn the event holds, the second on the turn the count has agreed with
    /// itself often enough to say the reports for this pane have landed. That second half is not
    /// decoration — `TerminalPanelSession.report` hands each exit to an unstructured `Task`, so a
    /// suite that counted the instant the first arrived could not see a second and "exactly one"
    /// would be unfalsifiable. `Self.watchdog` bounds both and decides nothing: on a timeout this
    /// answers the log as it stands and the caller's own assertion is what fails.
    func settledExits(after event: @MainActor () async -> Bool) async -> [PaneExit] {
        let deadline = ContinuousClock.now + Self.watchdog
        while ContinuousClock.now < deadline {
            if await event() { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
        var last = -1
        var agreements = 0
        while ContinuousClock.now < deadline {
            let count = await lifecycle.paneExits.count
            if count == last {
                agreements += 1
                if agreements >= Self.agreementsForSettled { break }
            } else {
                last = count
                agreements = 0
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return await lifecycle.paneExits
    }
}
