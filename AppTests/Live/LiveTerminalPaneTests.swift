import AppKit
import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.4 T7: gate **G2.2**, the live half of item 15's attach arm — a real background job, the real
/// `claude attach` client in a real pane, and the exit the detach byte causes reaching C4's seam
/// (child spec Acceptance G2.2).
///
/// **Zero model turns, and that is the design rather than a saving.** Both verbs this suite runs
/// are promptless: `claude --bg --resume <id>`, through X5's *Send to background*, and
/// `claude attach <short>`, through X5's `attach`. Nothing here sends a prompt, and nothing here
/// reads `AFLEET_LIVE_CLI_TURNS`. A prompted turn is refused by this account's organisation policy
/// anyway, which `LiveComposerTests` already recorded; this suite does not spend one confirming it.
///
/// **What is real and what is not.** The request is the engine-facing one C4 composes — it comes
/// from `LifecycleAPI.attach` on the fleet the launch built, and is never assembled here. The
/// client, the pty, the window and the exit are all real. The one double is `LifecycleDouble`,
/// standing where C4 stands, because the exit's *arrival* is the thing under test and a real fleet
/// consumes it silently: `Fleet.paneExited` discards an exit whose id it is not waiting on and says
/// nothing. Real request, real client, real pty, real exit, observed report.
///
/// **The verdict is taken before teardown.** Closing the pane hangs its child up, and the `.ended`
/// that produces is indistinguishable from the one the byte caused; C7.1's S1 needed the same care
/// and this suite inherits it, together with S1's `--hold` control — the same leg with no byte
/// written, which is what stops a client that ended anyway from making the byte look causal.
///
/// **Nothing here writes under a config home** (X9). The scratch home is read through
/// `ScratchLiveGate`; the only processes that write into it are the `claude` children afleet
/// spawns. afleet's own write roots are under a `TempTree`. The only processes this suite ends are
/// its own pane's child and the job it started itself, and the job is ended through X5's `stop`
/// verb rather than by a signal of this suite's own (§7.8).
///
/// **No engine byte reaches this file** (§11). The one string a leg matches in the grid is the
/// job's own working directory, read back from the request at run time; nothing captured is
/// written down, and no assertion message carries a path or an environment (§6.3).
@MainActor
final class LiveTerminalPaneTests: XCTestCase {

    /// How long a leg watches for an end after the moment the byte would have been written. Both
    /// legs use the same window, because the control's whole claim is that nothing ended inside it.
    /// S1 measured the end at about half a second, so ten is a watchdog and not a threshold.
    private static let observationWindow: Duration = .seconds(10)

    /// The budgets the harness is bounded by. Each is fulfilled by the event it waits for; none
    /// decides an assertion.
    private static let readyBudget: Duration = .seconds(90)
    private static let paintBudget: Duration = .seconds(60)
    private static let attachmentBudget: Duration = .seconds(20)
    private static let reportBudget: Duration = .seconds(10)

    /// How few rows of the grid still count as "the client painted nothing". S1's own number.
    private static let paintedRowFloor = 3

    // MARK: - The leg

    /// Item 15's attach half, end to end: the job, the request, the pane, the client's screen, the
    /// byte, the exit, and the exit's arrival at the lifecycle with its request echoed unchanged.
    func testCtrlZEndsAnAttachPaneAndTheExitReachesTheLifecycle() async throws {
        try await runAttachLeg(sendsCtrlZ: true, channelIndex: 0)
    }

    /// S1's `--hold`, and it is not optional: the same leg with no byte written must show **no**
    /// end inside the same window. Without it a client that ended of its own accord would make the
    /// byte look causal when it was not.
    func testTheSameLegWithoutTheByteSeesNoEnd() async throws {
        try await runAttachLeg(sendsCtrlZ: false, channelIndex: 1)
    }

    // MARK: - The rig

    private func runAttachLeg(sendsCtrlZ: Bool, channelIndex: Int) async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let directory = try ScratchLiveGate.trustedDirectory()

        // 1. The app, launched over the scratch home exactly as it launches over any other. The
        //    fleet it builds is the real one, and it is the only thing that composes a request.
        let tree = try TempTree()
        let environment = try await Self.appEnvironment(configHome: home)
        var sequence = LaunchSequence(storeRoot: try tree.directory("store"),
                                      diagnosticsRoot: try tree.directory("logs"),
                                      resolveEnvironment: { environment })
        let box = ModelBox()
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }
        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the launch did not reach a workspace over the scratch home")
        let coordinator = try XCTUnwrap(box.value, "the launch built no coordinator")
        await coordinator.model.whenChanged { !$0.isProvisional && $0.allRows.count > 0 }

        // 2. A channel of the corpus, recorded in the directory the scratch home already trusts —
        //    the engine resolves a transcript by its project directory, so a resumed child has to
        //    start there. Ordered by session so the two legs take two different channels whatever
        //    order XCTest runs them in, and neither leg can be looking at the other's job.
        let canonical = CanonicalPath.string(directory)
        let candidates = coordinator.model.allRows
            .filter { row in
                guard let cwd = row.cwd, row.offersOwnedActions else { return false }
                return CanonicalPath.string(cwd) == canonical
            }
            .map(\.key)
            .sorted { $0.session.description < $1.session.description }
        guard channelIndex < candidates.count else {
            await Self.stopApp(workspace: workspace, coordinator: coordinator)
            throw XCTSkip("""
                the scratch config home lists fewer than \(channelIndex + 1) ownable transcript(s) \
                recorded in a trusted directory, so this leg has no channel to background
                """)
        }
        let key = candidates[channelIndex]

        // 3. The job, at zero turns, by the real item-15 route: an unprompted owned channel — C5's
        //    G1e's spawn — handed to X5's `sendToBackground`, which is `claude --bg --resume <id>`.
        _ = try await workspace.fleet.perform(.open, on: key)
        let ready = await Self.poll(upTo: Self.readyBudget) { () -> Bool? in
            let origin = await workspace.fleet.state(of: key)?.origin
            return origin == .owned(.ready) ? true : nil
        }
        guard ready == true else {
            await Self.stopApp(workspace: workspace, coordinator: coordinator)
            throw XCTSkip("the channel did not reach ready under the scratch home, so there is nothing to background")
        }
        _ = try await workspace.fleet.perform(.sendToBackground, on: key)
        let roster = await workspace.fleet.jobs()
        guard let job = roster.first(where: { $0.sessionID == key.session }) else {
            await Self.stopApp(workspace: workspace, coordinator: coordinator)
            return XCTFail("the roster names no job for the channel this leg backgrounded")
        }

        // 4. The request C4 composes for `claude attach <short>`, taken from the real fleet and
        //    never built here.
        let request = try await workspace.fleet.attach(job.short)

        // From here the job exists, so every exit path stops it. `defer` cannot await, so the
        // failure is carried by hand rather than thrown through the cleanup.
        var failure: Error?
        do {
            try await observe(request: request, key: key, workspace: workspace, sendsCtrlZ: sendsCtrlZ)
        } catch {
            failure = error
        }
        // X5's own job verb — `claude stop <short>` — and only the job this leg started (§7.8).
        do {
            try await workspace.fleet.performJob(.stop, job.short)
        } catch {
            XCTFail("the job this leg started could not be stopped through X5's stop verb")
        }
        await Self.stopApp(workspace: workspace, coordinator: coordinator)
        if let failure { throw failure }
    }

    /// The pane, the client's screen, the byte and the verdict — everything between the request and
    /// the report.
    private func observe(request: PaneRequest, key: ChannelKey, workspace: Workspace,
                         sendsCtrlZ: Bool) async throws {
        // The panel host over the real workspace, with the lifecycle seam recorded. The request is
        // the fleet's; only the consumer of the exit is a double.
        let lifecycle = LifecycleDouble()
        let timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        let host = PanelHostModel()
        host.attach(to: workspace, timelines: timelines, lifecycle: lifecycle)
        let registry = TerminalSessionRegistry()
        try host.register(TerminalPanelTab(registry: registry))
        host.registerPaneRunner(TerminalPaneRunner(registry: registry), for: .terminal)
        let context = try XCTUnwrap(host.context(for: key, cwd: request.cwd),
                                    "the host built no context for the channel the job holds")

        try await host.run(request, for: key)
        let session = try XCTUnwrap(host.session(for: .terminal, context: context) as? TerminalPanelSession,
                                    "the host did not vend the Terminal tab's own session")
        let pane = try XCTUnwrap(session.panes.first, "the attach request opened no pane")

        // A real window, because a headless pane renders nothing: the adapter withholds every byte
        // until a surface attaches, and `renderedViewportText()` answers nil until then.
        let surfaceHost = Self.hostWindow(around: pane.surface.view)
        defer { surfaceHost.orderOut(nil) }
        let attached = await Self.poll(upTo: Self.attachmentBudget) { () -> Bool? in
            pane.surface.renderedViewportText() != nil ? true : nil
        }
        XCTAssertTrue(attached == true, "the pane's surface never attached, so the grid could not be read at all")

        // The client's own screen. What is matched is the job's working directory, which the attach
        // client paints in its header and which is read back off the request at run time — nothing
        // captured is written down here (§11). The row count is the same floor S1 used.
        let marker = CanonicalPath.string(request.cwd)
        let painted = await Self.poll(upTo: Self.paintBudget) { () -> Int? in
            let text = pane.surface.renderedViewportText()
            guard text?.contains(marker) == true else { return nil }
            return Self.nonBlankRowCount(text)
        }
        let rows = painted ?? Self.nonBlankRowCount(pane.surface.renderedViewportText())
        XCTAssertNotNil(painted,
                        "the attach client's own screen never named the job's working directory in the pane's "
                        + "grid; \(rows) non-blank row(s) were painted")
        XCTAssertGreaterThanOrEqual(rows, Self.paintedRowFloor,
                                    "the pane's grid carries \(rows) non-blank row(s), which is no screen")
        // The floor under both legs: a pane whose child never started, or had already gone, would
        // let the control pass on nothing at all.
        guard case .running = pane.state else {
            return XCTFail("the pane holds no running child at the moment the byte would be written")
        }

        // Ctrl+Z, as the byte a tty carries for it, written into the pane's own ingress — the same
        // path a keystroke in the surface takes.
        let clock = ContinuousClock()
        let sentAt = clock.now
        if sendsCtrlZ {
            let ingress = try XCTUnwrap(pane.surface.onInput, "the pane wired no ingress for the surface's input")
            ingress(Data([0x1A]))
        }
        // The verdict, taken here and not after teardown: closing the pane hangs its child up, and
        // the end that produces reaches the same observer.
        let ended = await Self.poll(upTo: Self.observationWindow) { () -> (PTYTermination, Duration)? in
            guard case let .exited(termination) = pane.state else { return nil }
            return (termination, sentAt.duration(to: clock.now))
        }

        if sendsCtrlZ {
            let observed = try XCTUnwrap(ended, "the pane observed no end inside the window after the byte")
            XCTAssertEqual(observed.0.paneExitCode, 0, "the attach client's end was not a clean zero")

            // The exit reaches the lifecycle, carrying the request that was run with its id intact.
            // The id is the clause that cannot fail loudly in production: C4 matches an exit by
            // `request.id` and records anything else as a stale exit, silently.
            let exits = await Self.poll(upTo: Self.reportBudget) { () -> [PaneExit]? in
                let recorded = await lifecycle.paneExits
                return recorded.isEmpty ? nil : recorded
            } ?? []
            XCTAssertEqual(exits.count, 1, "the lifecycle received \(exits.count) pane exit(s), not 1")
            XCTAssertTrue(exits.first?.request.id == request.id,
                          "the exit reaching the lifecycle carries a re-minted request id")
            XCTAssertTrue(exits.first?.request == request,
                          "the exit's request is not the one the fleet composed")
            XCTAssertEqual(exits.first?.code, 0, "the client's own status did not reach the lifecycle")
            print("""
            G2.2 the byte
              screen ....................... \(rows) non-blank row(s)
              end .......................... exit code \(observed.0.paneExitCode) \
            after \(Self.milliseconds(observed.1)) ms
              lifecycle .................... \(exits.count) exit(s), request echoed
              model turns .................. 0
            """)
        } else {
            XCTAssertNil(ended,
                         "the attach client ended inside the window with no byte written, so no end in the other "
                         + "leg can be called the byte's")
            XCTAssertTrue(pane.hasLiveChild, "the control's client is gone, so it controls for nothing")
            let exits = await lifecycle.paneExits
            XCTAssertEqual(exits.count, 0, "the control reported \(exits.count) exit(s) with no byte written")
            print("""
            G2.2 the control
              screen ....................... \(rows) non-blank row(s)
              end .......................... none inside \(Self.milliseconds(Self.observationWindow)) ms
              lifecycle .................... 0 exit(s)
              model turns .................. 0
            """)
        }

        // This leg's own pane, ended by this leg. Nothing else on the machine is touched.
        await session.close(pane)
    }

    // MARK: - Helpers

    /// The login shell's environment with `CLAUDE_CONFIG_DIR` pointed at the scratch home.
    private static func appEnvironment(configHome: URL) async throws -> ResolvedEnvironment {
        let resolved = await LaunchSequence.resolveLoginShellEnvironment()
        var variables = resolved.variables
        variables["CLAUDE_CONFIG_DIR"] = configHome.path(percentEncoded: false)
        return ResolvedEnvironment(variables: variables, shell: resolved.shell,
                                   capturedAt: resolved.capturedAt, mode: resolved.mode)
    }

    private static func stopApp(workspace: Workspace, coordinator: FleetCoordinator) async {
        await workspace.fleet.shutdown()
        coordinator.stop()
    }

    /// A real `NSWindow` the pane's view lays out in. Ordered back rather than made key: what the
    /// leg needs is layout, not focus.
    ///
    /// Named `hostWindow` rather than `window` because `Tools/c5/check-app-wiring.py` keys on bare
    /// names, and the bare one is an `App/` declaration this suite does not exercise.
    private static func hostWindow(around view: NSView) -> NSWindow {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
                            styleMask: [.titled, .resizable],
                            backing: .buffered,
                            defer: false)
        host.contentView = view
        host.orderBack(nil)
        return host
    }

    private static func nonBlankRowCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    /// Polls `body` every 20 ms until it answers or `deadline` passes. The interval is short
    /// because the leg reports how long the byte took to be answered, and S1 measured that in
    /// hundreds of milliseconds.
    private static func poll<T>(upTo deadline: Duration, _ body: @MainActor () async -> T?) async -> T? {
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < deadline {
            if let value = await body() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await body()
    }

    /// The coordinator the launch built. A single-owner box; every access is on the main actor.
    private final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }
}
