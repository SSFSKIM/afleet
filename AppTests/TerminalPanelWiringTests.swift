import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.4 T5: the app-side glue that puts the Terminal tab into the running app (child spec Design
/// §9; gates G1, G2, G3.1, G4.3).
///
/// Every identifier here is invented — a session is a hex-formatted index, a job short is a coined
/// word, a working directory is under the test's own temporary tree. No engine byte reaches a
/// committed file and no assertion compares one (§11). Where an assertion would otherwise print a
/// config-home path or a session id it is spelled as a count or a boolean with a message this file
/// wrote, because `XCTAssertEqual` prints both operands and that output is what a report quotes
/// (§6.3).
@MainActor
final class TerminalPanelWiringTests: XCTestCase {

    // MARK: - Group 1: registration

    /// C5 registered a placeholder and left `.terminal` to this leaf, and its own note asked for
    /// exactly this assertion: the tab is available for a channel, and a pane request finds a
    /// runner rather than `noPaneRunner`.
    func testTheTerminalTabAndItsPaneRunnerAreRegisteredAfterBinding() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let context = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd),
                                    "the bound host could not build a context for its own channel")

        XCTAssertTrue(rig.app.panels.available(for: context).contains(.terminal),
                      "the Terminal tab is not registered on a bound app")

        do {
            try await rig.app.panels.run(WiringFixtures.request(purpose: .shell, cwd: rig.cwd),
                                         for: rig.key)
        } catch PanelHostError.noPaneRunner {
            XCTFail("no pane runner is registered for the Terminal tab")
        } catch {
            XCTFail("the pane request did not reach a runner: \(type(of: error))")
        }
    }

    // MARK: - Group 2: the sidebar's *Attach*

    /// The finding C5 left behind: *Attach* asked X5 for a request and then parked it, so no pane
    /// ever opened. It now travels to `PanelHost.run(_:for:)` **unchanged, `id` included** — a
    /// re-minted id is the one mutation C4 cannot see, because it discards an exit for an id it is
    /// not waiting on and says nothing — and into the channel the row names.
    ///
    /// **Nothing seeds the host's context here.** A background job's channel is a channel no
    /// window has shown; seeding one was the test standing in for a step the app does not take,
    /// and every one of these assertions passed over a path that could not run in the app.
    /// **The row brings its channel into view, and does it before the pane runs** (ruled
    /// 2026-09-09; tracker 384).
    ///
    /// The host selects the Terminal *tab*, but the panel column derives its *channel* from
    /// `shell.focus`, so before this the pane opened where nobody was looking and item 15's
    /// "*Attach* shows its screen" was not what happened. The reading is taken **inside** the
    /// runner, at the moment the request arrives, because the claim is an ordering: a focus read
    /// after the call cannot tell a selection that came first from one that came later. Dropping
    /// `shell.select` fails this and nothing else.
    func testAttachSelectsTheRowsChannelBeforeThePaneRuns() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(11)
        let job = WiringFixtures.job("jshow", session: session, cwd: rig.cwd)
        rig.paintRows([(session, rig.cwd)])
        await rig.lifecycle.stagePane(.success(WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)))
        await runner.observeFocus { [shell = rig.shell] in shell.focus }
        XCTAssertNotEqual(rig.shell.focus, .channel(session), "the test must begin somewhere else")

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        let focus = await runner.focusAtRun
        XCTAssertEqual(focus, [.channel(session)],
                       "the window was not already on the row's channel when its pane ran")
        XCTAssertEqual(rig.shell.focus, .channel(session), "the row did not leave its channel in view")
    }

    /// The row-first branch, over a rig whose fleet really holds a row for the job's session: the
    /// pane goes to that channel and the directory it is made resolvable with is the **row's**.
    func testAttachRunsTheRequestItWasGivenInTheChannelTheRowNames() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(7)
        let job = WiringFixtures.job("jattach", session: session)
        rig.paintRows([(session, rig.cwd)])
        let staged = WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(staged))

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        let received = await runner.received
        XCTAssertEqual(received, [staged], "Attach did not reach the pane runner with the request X5 answered")
        let channels = await runner.channels
        XCTAssertEqual(channels.count, 1, "Attach placed its pane in no channel, or in more than one")
        XCTAssertEqual(channels.first?.session, session, "the pane was placed in a channel the row did not name")
        let attached = await rig.lifecycle.attachedJobs
        XCTAssertEqual(attached, [job.short], "Attach did not go through LifecycleAPI.attach")
        XCTAssertNil(rig.browser.jobBanners[job.short.rawValue], "a successful Attach left a banner")
    }

    /// X5 refusing is not a reason to move the window. The selection used to happen before the
    /// request was asked for, so a refused *Attach* left the main window standing in a channel
    /// where nothing had opened and nothing was going to — the user sent somewhere else to read a
    /// banner on the row they had just clicked.
    func testAnX5RefusalLeavesTheWindowWhereItWas() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(12)
        let job = WiringFixtures.job("jrefuse", session: session)
        rig.paintRows([(session, rig.cwd)])
        await rig.lifecycle.stagePane(.failure(.notOwned))
        let before = rig.shell.focus

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        XCTAssertEqual(rig.shell.focus, before, "a refused Attach moved the window anyway")
        XCTAssertNotNil(rig.browser.jobBanners[job.short.rawValue], "the row refused without saying so")
        let received = await runner.received
        XCTAssertEqual(received.count, 0, "a refused Attach opened a pane")
    }

    /// And a channel with no row is not somewhere the window can go. The panel column resolves the
    /// channel it draws through `FleetBrowserModel.row`, so selecting a session the browser has no
    /// row for leaves the column on its pick-a-channel placeholder — the pane invisible again,
    /// which is the failure the selection was added to close.
    func testAChannelWithNoRowIsNotSelected() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(13)
        let job = WiringFixtures.job("jnorow", session: session, cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)))
        _ = rig.app.panels.context(for: rig.key, cwd: rig.cwd)
        rig.app.panels.focusChannel(rig.key)
        let before = rig.shell.focus

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        XCTAssertEqual(rig.shell.focus, before, "the window moved to a channel with no row to draw")
        let received = await runner.received
        XCTAssertEqual(received.count, 1, "the pane did not open")
    }

    // MARK: - Group 3: *Logs*

    /// §9.5 and §17 C7 both name *Logs* as a pane, and it is the same verb as *Attach* over a
    /// different X5 request — and, like *Attach*, over a channel nothing has rendered.
    func testLogsGoesThroughTheLifecycleAndThenTheHost() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(9)
        let job = WiringFixtures.job("jlogs", session: session)
        rig.paintRows([(session, rig.cwd)])
        let staged = WiringFixtures.request(purpose: .logs(job.short), cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(staged))

        await SidebarView.openJobPane(job, verb: .logs, browser: rig.browser, shell: rig.shell)

        let logged = await rig.lifecycle.loggedJobs
        XCTAssertEqual(logged, [job.short], "Logs did not go through LifecycleAPI.logs")
        let attached = await rig.lifecycle.attachedJobs
        XCTAssertEqual(attached, [], "Logs went through the Attach verb")
        let received = await runner.received
        XCTAssertEqual(received, [staged], "Logs did not reach the pane runner with the request X5 answered")
    }

    // MARK: - Group 4: a row that can name no channel

    /// An exec job has no session, so with no channel in view there is nothing to name — and a
    /// refusal is the row's banner, never an error reaching a channel (§10). Nothing is asked of
    /// X5 either: a `claude attach` run for a pane that can never be placed is a child spawned for
    /// nobody.
    func testAJobWithNoSessionAndNoChannelInViewRefusesAndRunsNothing() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let job = WiringFixtures.job("jexec", session: nil)
        rig.app.panels.focusChannel(nil)

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        XCTAssertNotNil(rig.browser.jobBanners[job.short.rawValue], "the row refused without saying so")
        let attached = await rig.lifecycle.attachedJobs
        XCTAssertEqual(attached, [], "a job that can name no channel still asked X5 for a pane")
        let received = await runner.received
        XCTAssertEqual(received.count, 0, "a job that can name no channel still opened a pane")
    }

    /// The other half of the same rule: an exec job's pane falls back to the channel the window is
    /// showing, which is the caller's to name and not the host's to guess.
    func testAJobWithNoSessionFallsBackToTheChannelInView() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let job = WiringFixtures.job("jexec2", session: nil)
        let staged = WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(staged))
        _ = rig.app.panels.context(for: rig.key, cwd: rig.cwd)
        rig.app.panels.focusChannel(rig.key)

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        let channels = await runner.channels
        XCTAssertEqual(channels, [rig.key], "the exec job's pane did not land in the channel in view")
        XCTAssertNil(rig.browser.jobBanners[job.short.rawValue], "a placed pane left a refusal on the row")
    }

    /// And the refusal is unchanged where there is genuinely no directory to name: a channel whose
    /// row carries no working directory, and which nothing has rendered, cannot be made resolvable,
    /// so the host refuses and the row says so.
    func testAJobWhoseChannelHasNoDirectoryAnywhereStillRefusesOnTheRow() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(11)
        let job = WiringFixtures.job("jnocwd", session: session)
        rig.paintRows([(session, nil)])
        let staged = WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(staged))

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        XCTAssertNotNil(rig.browser.jobBanners[job.short.rawValue], "the host refused without saying so")
        let received = await runner.received
        XCTAssertEqual(received.count, 0, "a pane opened in a channel the host could not resolve")
    }

    /// A job whose session has left the index has no row, so it has no channel of its own to be
    /// placed in either — and seeding the host from the **job's** directory recorded that directory
    /// as the channel's own, so every later Cmd+Shift+T shell in it opened in the job's tree and W6
    /// wrote that down. A job's channel is the one its row names; with no row the pane goes where
    /// the window is looking, which is the fallback an exec job already takes.
    func testAJobWithNoRowOpensInTheChannelInViewAndRecordsNoCWDForItsOwn() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let runner = rig.replaceTerminalRunner()
        let session = WiringFixtures.session(14)
        let job = WiringFixtures.job("jgone", session: session, cwd: rig.cwd)
        await rig.lifecycle.stagePane(.success(WiringFixtures.request(purpose: .attach(job.short), cwd: rig.cwd)))
        _ = rig.app.panels.context(for: rig.key, cwd: rig.cwd)
        rig.app.panels.focusChannel(rig.key)

        await SidebarView.openJobPane(job, verb: .attach, browser: rig.browser, shell: rig.shell)

        // Sessions rather than whole keys: XCTAssertEqual prints both operands and a `ChannelKey`
        // carries a config home path (§6.3).
        let channels = await runner.channels
        XCTAssertEqual(channels.map(\.session), [rig.key.session],
                       "the pane did not land in the channel the window is showing")
        XCTAssertFalse(rig.app.panels.canResolveChannel(ChannelKey(configHome: rig.configHome, session: session)),
                       "the job's own directory was recorded as its channel's")
    }

    // MARK: - Group 5: Cmd+Shift+T

    /// §8.7's shortcut, asserted through the function the menu item calls — the precedent
    /// `PanelColumnView.resolvePendingPanelIndex` set, so the shortcut is testable without a window.
    func testTheTerminalShortcutOpensAShellPaneInTheFocusedChannel() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let context = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd))
        rig.app.panels.focusChannel(rig.key)
        XCTAssertEqual(rig.app.panels.selected, .thread, "the test must begin on another tab")

        AfleetApp.openTerminalPane(host: rig.app.panels)

        XCTAssertEqual(rig.app.panels.selected, .terminal, "the shortcut did not select the Terminal tab")
        let session = try XCTUnwrap(rig.app.panels.session(for: .terminal, context: context) as? TerminalPanelSession,
                                    "the host did not vend the Terminal tab's own session")
        XCTAssertEqual(session.panes.count, 1, "the shortcut opened no shell pane in the focused channel")
    }

    /// With no focused channel there is nothing to open a pane in, and a key combination is not an
    /// assertion: nothing moves.
    func testTheTerminalShortcutWithNoFocusedChannelChangesNothing() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let context = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd))
        rig.app.panels.focusChannel(nil)

        AfleetApp.openTerminalPane(host: rig.app.panels)

        XCTAssertEqual(rig.app.panels.selected, .thread, "an unfocused shortcut moved the selection")
        let session = try XCTUnwrap(rig.app.panels.session(for: .terminal, context: context) as? TerminalPanelSession)
        XCTAssertEqual(session.panes.count, 0, "an unfocused shortcut opened a pane anyway")
    }

    // MARK: - Group 6: end to end through the registered tab

    /// The whole seam, with no double in it: a `.hatch` request run through `PanelHost.run(_:for:)`
    /// reaches the registered runner, the registry hands it the very session the registered tab
    /// vends, and a pane exists there. A registry per owner would leave this session empty while a
    /// pane lived in another one, which is the failure no unit test of either half can see.
    ///
    /// The request's executable does not exist, so the pane's child never starts. That is the
    /// panel's own `.failed` arm and not this test's subject: what is asserted is that the pane is
    /// here, holding the request it was made from. Where its exit then travels is T6's.
    func testAHatchRequestReachesTheRegisteredTabsOwnSession() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let context = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd))
        let request = WiringFixtures.request(purpose: .hatch(rig.key.session), cwd: rig.cwd)

        try await rig.app.panels.run(request, for: rig.key)

        let session = try XCTUnwrap(rig.app.panels.session(for: .terminal, context: context) as? TerminalPanelSession,
                                    "the host did not vend the Terminal tab's own session")
        XCTAssertEqual(session.panes.count, 1, "the request never reached the registered tab's session")
        // A boolean rather than an equality, because `XCTAssertEqual` prints both operands and a
        // `PaneRequest` carries a working directory (§6.3).
        XCTAssertTrue(session.panes.first?.request == request, "the pane holds a request the host did not run")
    }

    // MARK: - Group 7: a rebind

    /// `bindWorkspace` rebuilds the host's world — its contexts and its sessions go with the
    /// workspace that built them — and the Terminal registry has to go the same way. A session
    /// kept across the rebind holds the previous workspace's store and its `reportPaneExit`, so
    /// its panes write to a store nobody reads and report exits to a lifecycle nobody is listening
    /// to, and nothing can reach those children to close them.
    func testRebindingTheWorkspaceReleasesTheTerminalSessionsAndTheirPanes() async throws {
        let rig = try await WiringRig()
        defer { rig.stop() }
        let context = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd),
                                    "the bound host could not build a context for its own channel")
        let before = try XCTUnwrap(rig.app.panels.session(for: .terminal, context: context) as? TerminalPanelSession,
                                   "the host did not vend the Terminal tab's own session")
        before.openShellPane()
        XCTAssertEqual(before.panes.count, 1, "panes=\(before.panes.count)")

        rig.app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        await rig.app.terminalSessions.settleRelease()

        XCTAssertEqual(before.panes.count, 0, "panes=\(before.panes.count)")
        let rebound = try XCTUnwrap(rig.app.panels.context(for: rig.key, cwd: rig.cwd),
                                    "the rebound host could not build a context for its own channel")
        let after = rig.app.panels.session(for: .terminal, context: rebound) as? TerminalPanelSession
        XCTAssertFalse(after === before, "a rebind handed back the previous workspace's session")
    }
}

// MARK: - Values

/// Every identifier these tests use, invented throughout (§11).
private enum WiringFixtures {

    /// A v4-shaped session id from an index, so distinct channels read as distinct numbers.
    static func session(_ index: Int) -> SessionID {
        SessionID(String(format: "%08x-0000-4000-8000-%012x", index, index))!
    }

    /// A pane request whose executable does not exist: what is under test is where the request
    /// travels, never what a child prints.
    static func request(purpose: PanePurpose, cwd: URL) -> PaneRequest {
        PaneRequest(executable: URL(fileURLWithPath: "/invented/bin/claude"),
                    arguments: ["--invented"],
                    cwd: cwd,
                    environment: ["PATH": "/usr/bin"],
                    purpose: purpose)
    }

    /// A background job. `session` nil is the exec job, which has no session at all — the case the
    /// channel-naming rule exists for.
    static func job(_ short: String, session: SessionID?, cwd: URL? = nil) -> JobEntry {
        JobEntry(short: JobShort(rawValue: short), state: "working", kind: "bg",
                 sessionID: session, cwd: cwd, name: nil)
    }
}

/// A `PaneRunning` standing in for the registered one, recording the request and the channel it was
/// run in. Nothing here spawns: what these groups assert is the journey, and a real child would add
/// a process to every assertion about where a request went.
private actor WiringPaneRunner: PaneRunning {
    private(set) var received: [PaneRequest] = []
    private(set) var channels: [ChannelKey] = []
    /// What the window was showing **at the moment the request reached the runner**, when a test
    /// installs the probe. It is read here rather than after the call because the claim under test
    /// is an ordering — the channel is selected *before* the pane runs — and a reading taken
    /// afterwards cannot tell "selected first" from "selected eventually".
    private(set) var focusAtRun: [ShellModel.Focus] = []
    private var probe: (@MainActor @Sendable () -> ShellModel.Focus)?

    func observeFocus(_ probe: @escaping @MainActor @Sendable () -> ShellModel.Focus) {
        self.probe = probe
    }

    func run(_ request: PaneRequest, in context: ChannelContext) async {
        received.append(request)
        channels.append(context.key)
        if let probe { focusAtRun.append(await MainActor.run { probe() }) }
    }
}

// MARK: - Rig

/// An `AppModel` bound to a workspace over a scratch config home, exactly as a launch binds one.
///
/// Built by hand rather than through `LaunchSequence` because what is under test is the glue, and a
/// launch would add a binary probe, a version gate and a sign-in gate, each of which can fail for
/// reasons that say nothing about §9.
///
/// The environment's shell is `/usr/bin/true`, so a shell pane this suite opens spawns a child that
/// exits at once: these tests are about where a pane is placed, not about what a terminal shows.
@MainActor
private struct WiringRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let app: AppModel
    /// Kept so a test can bind it a second time, which is what *Check again* and a second launch
    /// do to a model that is already bound.
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    /// The sidebar's model, over the same config home and the same lifecycle the app is bound to —
    /// which is what `FleetCoordinator` builds in production.
    let browser: FleetBrowserModel
    let configHome: URL
    let key: ChannelKey
    let cwd: URL
    /// The sidebar acts through the shell — it is what selects a channel — and the shell reads the
    /// same host the app holds, exactly as `RootView` builds the pair.
    let shell: ShellModel

    /// Paints listed rows for the sessions named, because a job's channel is resolved through the
    /// row that names it and a rig built by hand has an empty fleet. One call per test: the paint
    /// replaces the snapshot rather than adding to it, exactly as a fresh index build does.
    func paintRows(_ rows: [(session: SessionID, cwd: URL?)]) {
        let moment = Date()
        var entries: [SessionID: IndexEntry] = [:]
        for row in rows {
            entries[row.session] = SidebarFixtures.entry(row.session, configHome: configHome,
                                                         cwd: row.cwd?.path, mtime: moment)
        }
        browser.apply(IndexSnapshot(configHome: configHome, builtAt: moment, entries: entries))
    }

    /// Takes `.terminal`'s pane runner for a recording one, for the groups that assert where a
    /// request travelled rather than what the panel did with it.
    func replaceTerminalRunner() -> WiringPaneRunner {
        let runner = WiringPaneRunner()
        app.panels.registerPaneRunner(runner, for: .terminal)
        return runner
    }

    func stop() { browser.stopUpdates() }

    init() async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let configHome = home.configHome
        self.configHome = configHome.root
        cwd = temp.root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        key = ChannelKey(configHome: configHome.root, session: WiringFixtures.session(0))

        let index = TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        var environment = LaunchFixtures.environment(home: temp.root, configHome: home.root)
        environment = ResolvedEnvironment(variables: environment.variables,
                                          shell: "/usr/bin/true",
                                          capturedAt: environment.capturedAt,
                                          mode: environment.mode)
        workspace = Workspace(configHome: configHome,
                              environment: environment,
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)

        lifecycle = LifecycleDouble()
        app = AppModel()
        shell = ShellModel(panels: app.panels)
        app.bindWorkspace(workspace, lifecycle: lifecycle)
        browser = FleetBrowserModel(lifecycle: lifecycle, configHome: configHome.root)
    }
}
