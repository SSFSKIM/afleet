import Foundation
import Observation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Task 8: contract X7's host, its channel context and the placeholder tab (spec §7, gate G4).
///
/// Every scratch tree here is a `TempTree`, which refuses to build inside any config home, and
/// every identifier below is invented — a session is a hex-formatted index, a URL is under
/// `invented.example`, a working directory is `/invented/project`. No engine byte reaches a
/// committed file and no assertion compares one (§11).
///
/// Where an assertion would otherwise print a value carrying a config-home path, a session id or a
/// title, it is spelled as a boolean with a message this file wrote: `XCTAssertEqual` prints both
/// operands into the failure output, and that output is what a report quotes.
@MainActor
final class PanelHostTests: XCTestCase {

    /// R2: a protocol selection must invalidate the exact property the window renders.
    /// Reading host.selected alone would miss the original shell/host split entirely.
    func testProtocolSelectionUpdatesTheRenderedSelection() async throws {
        let app = AppModel()
        try app.panels.register(StubPanelTab(.files))
        let changed = expectation(description: "rendered selection invalidated")
        withObservationTracking {
            _ = app.shell.panelTab
        } onChange: {
            changed.fulfill()
        }
        let host: any PanelHost = app.panels
        host.select(.files)
        let result = await XCTWaiter.fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(result, .completed, "protocol selection did not invalidate the rendered tab")
        XCTAssertEqual(app.shell.panelTab, .files, "window still renders the old selection")

        // Tab-bar writes use the same owner, and a refused id cannot split the two views.
        app.shell.panelTab = .thread
        XCTAssertEqual(host.selected, .thread, "tab-bar selection did not reach the host")
        host.select(.github)
        XCTAssertEqual(app.shell.panelTab, .thread, "an unregistered tab moved the window")
        XCTAssertEqual(host.selected, .thread, "an unregistered tab moved the host")
    }

    /// R2: run must select the visible terminal, not just start a pane behind Thread.
    func testPaneRunUpdatesTheRenderedSelection() async throws {
        let app = AppModel()
        try app.panels.register(StubPanelTab(.terminal))
        let runner = RecordingPaneRunner()
        app.panels.registerPaneRunner(runner, for: .terminal)
        XCTAssertEqual(app.shell.panelTab, .thread, "test must begin on another tab")

        try await app.panels.run(PanelFixtures.paneRequest())

        let count = await runner.received.count
        XCTAssertEqual(count, 1, "the registered runner never received the pane")
        XCTAssertEqual(app.shell.panelTab, .terminal, "pane ran behind the old visible tab")
        XCTAssertEqual(app.panels.selected, .terminal, "run did not select its registered tab")
    }

    // MARK: - G4a: registration and order

    /// The canonical order is the tab set's, not the registration order.
    func testTabsPresentInCanonicalOrderWhateverTheRegistrationOrder() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.github))
        try host.register(StubPanelTab(.files))
        try host.register(StubPanelTab(.thread))

        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.thread, .files, .github],
                       "the host presented its three registered tabs out of canonical order")
    }

    /// A second registration of one id is refused rather than shadowing the first.
    func testASecondRegistrationOfOneIDThrows() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))

        XCTAssertThrowsError(try host.register(StubPanelTab(.files))) { error in
            XCTAssertEqual(error as? PanelHostError, .duplicateTab(.files),
                           "a duplicate registration threw the wrong error")
        }
        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.files],
                       "the refused registration changed what the host presents")
    }

    /// The handover C6 takes: `unregister(.thread)` and then its own `register`.
    ///
    /// Both halves matter. Without the refusal, a second registration would silently shadow the
    /// first; without the handover, the duplicate check would make the seven ids permanently
    /// first-come and C6 could never register Thread over C5's placeholder.
    func testUnregisterThenRegisterHandsTheIDOver() async throws {
        let host = PanelHostModel()
        try host.register(PlaceholderTab())
        let successor = StubPanelTab(.thread, title: "a later child's thread")

        XCTAssertThrowsError(try host.register(successor),
                             "registering over the placeholder without unregistering it succeeded")

        await host.unregister(.thread)
        try host.register(successor)

        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.thread],
                       "the successor is not the tab the host presents for .thread")
        XCTAssertEqual(host.title(for: .thread), "a later child's thread",
                       "the host reports the placeholder's title after the handover")
    }

    /// Unregistering a tab releases every session it held, and a re-registered tab gets fresh ones.
    func testUnregisterReleasesTheTabsSessions() async throws {
        let host = PanelHostModel()
        let counter = SessionCounter()
        try host.register(StubPanelTab(.thread, counter: counter))
        let channels = (0..<3).map { PanelFixtures.context(PanelFixtures.key($0)) }
        for context in channels { _ = host.session(for: .thread, context: context) }

        XCTAssertEqual(counter.created, 3, "the tab made \(counter.created) sessions for 3 channels")
        XCTAssertEqual(counter.released, 0, "\(counter.released) sessions were released before the unregister")
        XCTAssertEqual(host.liveSessionCount, 3, "the host holds \(host.liveSessionCount) sessions, not 3")

        await host.unregister(.thread)

        XCTAssertEqual(counter.released, 3,
                       "the unregister released \(counter.released) of the 3 sessions the tab held")
        XCTAssertEqual(host.liveSessionCount, 0, "the host still holds \(host.liveSessionCount) sessions")

        // The replacement gets its own sessions rather than the retired tab's. Identity cannot be
        // compared — the old objects are gone, which is the point — so the witness is the second
        // tab's own creation count.
        let second = SessionCounter()
        try host.register(StubPanelTab(.thread, counter: second))
        _ = host.session(for: .thread, context: channels[0])
        XCTAssertEqual(second.created, 1, "the re-registered tab made \(second.created) sessions, not 1")
        XCTAssertEqual(counter.created, 3, "the retired tab made \(counter.created) sessions after being dropped")
    }

    /// Unregistering a tab withdraws its link targets, even the most specific one.
    ///
    /// Specificity is the discriminating clause: a host that released the sessions and left the
    /// registry alone would still route a `.file` link into a tab that no longer exists, and every
    /// other test here would stay green.
    func testUnregisterWithdrawsTheTabsLinkTargets() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.thread))
        try host.register(StubPanelTab(.files))
        let recorder = LinkRecorder()
        await host.links.register(PanelFixtures.fileTarget(.thread, specificity: 10, into: recorder))
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 1, into: recorder))

        await host.links.open(PanelFixtures.fileLink, from: .currentPanel)
        XCTAssertEqual(recorder.tabs, [.thread], "the most specific target did not win the first open")

        await host.unregister(.thread)
        await host.links.open(PanelFixtures.fileLink, from: .currentPanel)

        XCTAssertEqual(recorder.tabs, [.thread, .files],
                       "after the unregister the link did not fall through to the next target")
        XCTAssertEqual(recorder.tabs.filter { $0 == .thread }.count, 1,
                       "the withdrawn tab received \(recorder.tabs.filter { $0 == .thread }.count) links, not 1")
        let remaining = await host.links.targetCount
        XCTAssertEqual(remaining, 1,
                       "the registry holds \(remaining) targets after one tab was withdrawn")
    }

    /// Cmd+1…7 is one-based over `available(for:)`, and an index outside it changes nothing.
    func testSelectIndexIsOneBasedOverAvailable() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))
        try host.register(StubPanelTab(.terminal))
        let context = PanelFixtures.context()

        host.selectIndex(3, in: context)
        XCTAssertNil(host.selected, "an out-of-range index selected a tab")

        host.selectIndex(1, in: context)
        XCTAssertEqual(host.selected, .files, "Cmd+1 did not select the first available tab")

        host.selectIndex(2, in: context)
        XCTAssertEqual(host.selected, .terminal, "Cmd+2 did not select the second available tab")

        host.selectIndex(3, in: context)
        XCTAssertEqual(host.selected, .terminal, "an out-of-range index moved the selection")
    }

    /// Cmd+N selects the Nth *registered and available* tab, along the path the app actually takes.
    ///
    /// **The path is the point.** `PanelHost.selectIndex(_:in:)` was correct and tested and had no
    /// production caller: the menu item called `ShellModel.selectPanelTab(at:)`, which indexed
    /// `PanelTabID.allCases`, so Cmd+N could name a tab the channel cannot show while the tested
    /// method that gets it right was never invoked. So this test presses the key the way the menu
    /// presses it and resolves it the way the column resolves it, and touches `selectIndex`
    /// only through them.
    ///
    /// **The channel is chosen so the two indexings disagree.** With `.files` and `.terminal`
    /// registered, index 2 over `allCases` is `.agents` — which this channel cannot show — and over
    /// `available(for:)` it is `.terminal`. A channel where all seven were available could not tell
    /// the two apart, and the test would pass against the wiring it exists to reject.
    func testCmdNSelectsTheNthAvailableTabAlongThePathTheAppTakes() async throws {
        let rig = try await PanelRig(channels: 1)
        let host = rig.host
        try host.register(StubPanelTab(.files))
        try host.register(StubPanelTab(.terminal))
        let context = try XCTUnwrap(host.context(for: rig.keys[0], cwd: PanelFixtures.cwd),
                                    "the host built no context")
        XCTAssertEqual(PanelTabID.allCases[1], .agents,
                       "index 2 over allCases is not a tab this channel lacks, so the test cannot discriminate")
        XCTAssertEqual(host.available(for: context), [.files, .terminal],
                       "the channel does not show the two tabs this test registered")

        rig.shell.selectPanelTab(at: 2)          // the menu item
        let chosen = PanelColumnView.resolvePendingPanelIndex(shell: rig.shell, host: host,
                                                              context: context)  // the panel column

        XCTAssertEqual(chosen, .terminal, "Cmd+2 named the wrong tab for this channel")
        XCTAssertEqual(rig.shell.panelTab, .terminal, "the window's selection is not the second available tab")
        XCTAssertEqual(host.selected, .terminal, "the host's selection is not the second available tab")

        // Inside `allCases`, past what this channel can show: nothing moves.
        rig.shell.selectPanelTab(at: 3)
        let none = PanelColumnView.resolvePendingPanelIndex(shell: rig.shell, host: host, context: context)
        XCTAssertNil(none, "an index past the available tabs named a tab")
        XCTAssertEqual(rig.shell.panelTab, .terminal, "an index past the available tabs moved the window")
        XCTAssertEqual(host.selected, .terminal, "an index past the available tabs moved the host")

        // And the menu's labels are drawn from the same list the index resolves against, so the
        // name beside Cmd+2 is the tab Cmd+2 selects.
        host.mainWindowShows(host.available(for: context))
        XCTAssertEqual(host.mainWindowTabs, [.files, .terminal],
                       "the menu would name a different list from the one Cmd+N indexes")
    }

    /// A tab that reports itself unavailable is absent for that channel and present for another.
    ///
    /// Both directions, so a tab that reported unavailable everywhere — or a host that ignored
    /// `isAvailable(in:)` — fails.
    func testAnUnavailableTabIsAbsentForThatChannelAndPresentForAnother() throws {
        let host = PanelHostModel()
        let welcome = PanelFixtures.key(0)
        try host.register(StubPanelTab(.files, availableIn: [welcome]))
        try host.register(StubPanelTab(.terminal))

        XCTAssertEqual(host.available(for: PanelFixtures.context(welcome)), [.files, .terminal],
                       "the tab is absent for the channel it reported itself available for")
        XCTAssertEqual(host.available(for: PanelFixtures.context(PanelFixtures.key(1))), [.terminal],
                       "the tab is present for a channel it reported itself unavailable for")
    }

    // MARK: - The session cache

    /// A session survives a channel switch, and two channels do not share one.
    ///
    /// Both clauses are needed: a host holding one global session would pass the first alone, and a
    /// host rebuilding on every switch would pass the second alone.
    func testTheSessionSurvivesAChannelSwitchAndIsPerChannel() throws {
        let host = PanelHostModel()
        let counter = SessionCounter()
        try host.register(StubPanelTab(.files, counter: counter))
        let a = PanelFixtures.context(PanelFixtures.key(0))
        let b = PanelFixtures.context(PanelFixtures.key(1))

        let first = host.session(for: .files, context: a)
        let other = host.session(for: .files, context: b)
        let again = host.session(for: .files, context: a)

        XCTAssertTrue(first === again, "the host rebuilt the channel's session on the way back")
        XCTAssertFalse(first === other, "two channels were handed one session")
        XCTAssertEqual(counter.created, 2, "the tab made \(counter.created) sessions for 2 channels")
        XCTAssertEqual(counter.released, 0, "\(counter.released) sessions were released across a switch")
    }

    /// The cache is bounded at sixteen channels, and the selected and popped-out channels are exempt.
    ///
    /// The last clause — an `.archived` origin evicts nothing — is the discriminating one, because
    /// evicting on `.archived` is the plausible wrong rule and would destroy state for nearly every
    /// channel. **It is a trace assertion and is stated as one**, per the plan's rule for a break
    /// that cannot be executed: no mutation of this code can make the clause fail, because nothing
    /// in `PanelHostModel` reads a `ChannelOrigin` at all — that absence *is* the property. What is
    /// asserted instead is the surface a wrong host would have had to hook: an archived
    /// `ChannelState` is published to the fleet and observed reaching the browser's own row, so the
    /// signal demonstrably arrived in the app, and the host's session count is unmoved on the other
    /// side of it.
    func testTheSessionCacheIsBoundedAndExemptsTheSelectedAndPoppedOutChannels() async throws {
        let host = PanelHostModel()
        let counter = SessionCounter()
        try host.register(StubPanelTab(.files, counter: counter))
        let total = 20
        let keys = (0..<total).map { PanelFixtures.key($0) }

        // The two exemptions, declared before anything is rendered so both are also the *least*
        // recently rendered channels by the end.
        host.focusChannel(keys[0])
        host.popOut(.files, channel: keys[1])

        // Only the two exempt sessions are held. Holding all twenty would keep every evicted one
        // alive and the release counter would read zero however well the eviction worked — the
        // instrument would be measuring the test's own retention rather than the cache's.
        var selectedSession: (any PanelTabSession)?
        var poppedSession: (any PanelTabSession)?
        var highWater = 0
        for (index, key) in keys.enumerated() {
            let session = host.session(for: .files, context: PanelFixtures.context(key))
            if index == 0 { selectedSession = session }
            if index == 1 { poppedSession = session }
            highWater = max(highWater, host.liveChannelCount)
        }

        XCTAssertEqual(highWater, PanelHostModel.channelCapacity,
                       "the cache reached \(highWater) channels against a bound of \(PanelHostModel.channelCapacity)")
        XCTAssertEqual(counter.created, total, "the tab made \(counter.created) sessions for \(total) channels")
        XCTAssertEqual(counter.released, total - PanelHostModel.channelCapacity,
                       "\(counter.released) sessions were released, not \(total - PanelHostModel.channelCapacity)")
        XCTAssertTrue(host.session(for: .files, context: PanelFixtures.context(keys[0])) === selectedSession,
                      "the selected channel's session was evicted although it was exempt")
        XCTAssertTrue(host.session(for: .files, context: PanelFixtures.context(keys[1])) === poppedSession,
                      "the popped-out channel's session was evicted although it was exempt")

        // The archived clause. An archived `ChannelState` is published to the fleet the browser
        // reads, and the wait is fulfilled by the row observing it — so the signal demonstrably
        // reached the app before the assertion below is made.
        let rig = try CoordinatorRig(host: host, sessions: keys.map(\.session))
        await rig.coordinator.snapshotAvailable(rig.snapshot, origin: .built)
        let releasedBefore = counter.released
        let liveBefore = host.liveChannelCount
        rig.lifecycle.emit(SidebarFixtures.state(keys[0], origin: .archived))
        await rig.browser.whenChanged { $0.row(keys[0].session)?.origin == .archived }

        XCTAssertEqual(counter.released, releasedBefore,
                       "an archived origin released \(counter.released - releasedBefore) session(s)")
        XCTAssertEqual(host.liveChannelCount, liveBefore,
                       "an archived origin left \(host.liveChannelCount) channels against \(liveBefore)")
    }

    /// A channel evicted under LRU pressure releases its context as well as its sessions.
    ///
    /// The bound is on sessions, but a context holds the channel's `TimelineRecentURLFeed` and that
    /// holds its `ChannelTimelineModel` — so a host that bounded the sessions at sixteen and kept
    /// every context would still accumulate one timeline model per channel browsed, which is the
    /// unbounded growth the bound exists to prevent, one indirection further out. The exempt
    /// channel is asserted in the same test, because a host that dropped every context on eviction
    /// pressure — including the selected channel's — would pass the first clause alone and blank
    /// the panel the user is looking at.
    func testAnEvictedChannelReleasesItsContextToo() async throws {
        let rig = try await PanelRig(channels: 1)
        let host = rig.host
        try host.register(StubPanelTab(.files))
        let total = PanelHostModel.channelCapacity + 4
        let keys = (0..<total).map { PanelFixtures.key($0) }
        host.focusChannel(keys[0])

        for key in keys {
            let context = try XCTUnwrap(host.context(for: key, cwd: PanelFixtures.cwd),
                                        "the host built no context for a channel")
            _ = host.session(for: .files, context: context)
        }

        XCTAssertEqual(host.liveChannelCount, PanelHostModel.channelCapacity,
                       "the cache holds \(host.liveChannelCount) channels against a bound of \(PanelHostModel.channelCapacity)")
        // keys[1] is the least recently rendered channel that is not exempt, so it is the first out.
        // A boolean, not `XCTAssertNil`, whose default message prints the operand — and a
        // `ChannelContext` prints its whole `ResolvedEnvironment`, including `HOME` and
        // `CLAUDE_CONFIG_DIR` under the scratch tree, which resolve inside the author's own
        // account (§11). Demonstrating this test failing is what showed it.
        XCTAssertTrue(host.context(for: keys[1]) == nil,
                      "an evicted channel kept the context that pins its timeline model")
        XCTAssertNotNil(host.context(for: keys[0]),
                        "the selected channel lost its context, so its panel would draw nothing")
    }

    /// A channel removed from the index releases its session at once, without LRU pressure.
    ///
    /// Driven through `FleetCoordinator.indexChanged(_:)`, the seam the composition root actually
    /// calls. Invoking the host directly would let this pass while production never evicted, which
    /// is a defect shape this plan has already produced once.
    func testAChannelRemovedFromTheIndexReleasesItsSessionAtOnce() async throws {
        let host = PanelHostModel()
        let counter = SessionCounter()
        try host.register(StubPanelTab(.files, counter: counter))
        let keys = (0..<2).map { PanelFixtures.key($0) }
        for key in keys { _ = host.session(for: .files, context: PanelFixtures.context(key)) }
        let rig = try CoordinatorRig(host: host, sessions: keys.map(\.session))

        XCTAssertEqual(host.liveChannelCount, 2, "the host holds \(host.liveChannelCount) channels, not 2")
        XCTAssertLessThan(host.liveChannelCount, PanelHostModel.channelCapacity,
                          "the bound was already reached, so an eviction would prove nothing")

        await rig.coordinator.indexChanged(IndexDelta(removed: [keys[0].session]))

        XCTAssertEqual(counter.released, 1,
                       "the removed channel released \(counter.released) session(s), not 1")
        XCTAssertEqual(host.liveChannelCount, 1,
                       "the host holds \(host.liveChannelCount) channels after one was removed, not 1")
    }

    /// A channel removed from the index releases the timeline model it was ingesting through.
    ///
    /// **Found by sweeping for the defect the review named**: `ChannelTimelineRegistry.release(_:)`
    /// existed, was tested, and no production path called it, so every channel ever opened kept its
    /// model — a `StreamIngestion`, an effects loop and a change-feed loop each — until a relaunch
    /// replaced the workspace. Driven through `FleetCoordinator.indexChanged(_:)`, the seam the
    /// composition root calls, for the same reason its sibling above is: a registry released only
    /// from a test leaves production holding everything.
    ///
    /// The floor is that the model was there to lose. The panel host's own release is asserted
    /// beside it, because the two owners of a removed channel have to let go together — the host's
    /// context holds the feed that reads this model, and either one left behind pins it.
    func testAChannelRemovedFromTheIndexReleasesItsTimelineModel() async throws {
        let rig = try await PanelRig(channels: 1)
        let key = rig.keys[0]
        _ = rig.timelines.model(for: key)
        XCTAssertEqual(rig.timelines.openChannels.count, 1,
                       "the registry holds \(rig.timelines.openChannels.count) models, not the 1 to be released")
        let host = rig.host
        try host.register(StubPanelTab(.files))
        let context = try XCTUnwrap(host.context(for: key, cwd: PanelFixtures.cwd),
                                    "the host built no context")
        _ = host.session(for: .files, context: context)

        let coordinator = FleetCoordinator(configHome: rig.workspace.configHome.root,
                                           registrar: RegistrarDouble(),
                                           index: StubIndex(persisted: nil,
                                                            built: LaunchFixtures.snapshot(configHome: rig.workspace.configHome.root,
                                                                                           ids: [key.session])),
                                           model: FleetBrowserModel(lifecycle: rig.lifecycle,
                                                                    configHome: rig.workspace.configHome.root),
                                           panels: host,
                                           timelines: rig.timelines)
        await coordinator.indexChanged(IndexDelta(removed: [key.session]))
        coordinator.stop()

        XCTAssertEqual(rig.timelines.openChannels.count, 0,
                       "the removed channel left \(rig.timelines.openChannels.count) timeline model(s) behind")
        XCTAssertEqual(host.liveChannelCount, 0,
                       "the removed channel left \(host.liveChannelCount) channel(s) in the panel host")
    }

    // MARK: - G4c: the popped-out window keeps its channel

    /// A popped-out tab keeps its channel while the main window moves to another.
    ///
    /// A scene that resolved from the current selection would pass every other test here and leave
    /// the parent's channel-retention guarantee checked only by a manual witness.
    func testAPoppedOutTabKeepsItsChannelWhenTheMainWindowSwitches() async throws {
        let rig = try await PanelRig(channels: 2)
        let host = rig.host
        try host.register(StubPanelTab(.files))
        let a = rig.keys[0]
        let b = rig.keys[1]
        _ = host.context(for: a, cwd: PanelFixtures.cwd)
        _ = host.context(for: b, cwd: PanelFixtures.cwd)
        host.focusChannel(a)
        host.popOut(.files, channel: a)

        // The main window moves on.
        rig.shell.select(b.session)
        host.focusChannel(b)

        let popped = try XCTUnwrap(host.poppedOut.first, "the pop-out was not recorded")
        let poppedContext = try XCTUnwrap(host.context(for: popped.channel),
                                          "the popped-out entry resolved no context")
        XCTAssertTrue(poppedContext.key == a, "the popped-out window followed the main window's channel")
        let main = PanelColumnView.channel(shell: rig.shell, browser: rig.browser)
        XCTAssertTrue(main?.key == b, "the main window did not move to the second channel")
        XCTAssertTrue(host.selectedChannel == b, "the host's selected channel did not follow the main window")
    }

    /// T5: track the scene's actual body dependencies, not a fresh dictionary read after
    /// release. The tab view retains its session, as real panels do. Only an invalidation
    /// permits a redraw, so a stale window cannot pass by querying the host directly.
    func testRemovedPopOutInvalidatesItsSceneAndReleasesTheRetainedSession() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let counter = SessionCounter()
        try app.panels.register(StubPanelTab(.files, counter: counter))
        let key = rig.keys[0]
        _ = app.panels.context(for: key, cwd: PanelFixtures.cwd)
        app.panels.popOut(.files, channel: key)
        let panel = PoppedOutPanel(tab: .files, channel: key)
        let scene = PoppedOutPanelScene(app: app, panel: panel)
        let coordinator = try XCTUnwrap(app.coordinatorFactory(rig.workspace) as? FleetCoordinator)
        defer { coordinator.stop() }

        // Removing another channel must not remove this panel, nor follow main-window focus.
        app.shell.select(rig.keys[1].session)
        await coordinator.indexChanged(IndexDelta(removed: [rig.keys[1].session]))
        let changed = expectation(description: "popped-out scene invalidated by channel release")
        var body = withObservationTracking { scene.body } onChange: { changed.fulfill() }
        XCTAssertTrue(ViewTree.values(of: PlaceholderColumn.self, in: body).isEmpty,
                      "the valid pop-out already showed the missing-channel placeholder")
        XCTAssertEqual(counter.created, 1, "the scene never built a tab session")
        XCTAssertEqual(counter.released, 0, "the valid scene did not retain its session")

        await coordinator.indexChanged(IndexDelta(removed: [key.session]))
        let result = await XCTWaiter.fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(result, .completed, "release did not invalidate the popped-out scene")
        if result == .completed { body = scene.body }
        XCTAssertEqual(ViewTree.values(of: PlaceholderColumn.self, in: body).count, 1,
                       "the window did not redraw its missing-channel placeholder")
        XCTAssertEqual(counter.released, 1, "the removed window body still retained its session")
        XCTAssertTrue(app.panels.context(for: key) == nil, "release kept a removed context")
    }

    // MARK: - G4b: the context's capabilities

    /// The context's store writes into `workbench` and reaches no other namespace.
    func testScopedStoreCannotReachAnotherNamespace() async throws {
        let rig = try await PanelRig(channels: 1)
        let context = try XCTUnwrap(rig.host.context(for: rig.keys[0], cwd: PanelFixtures.cwd),
                                    "the host built no context")
        let key = "panel.invented"

        try await context.store.write(7, key: key)

        let workbench = try await rig.workspace.store.read(Int.self, namespace: .workbench, key: key)
        XCTAssertEqual(workbench, 7, "the value did not read back under the workbench namespace")
        let afleet = try await rig.workspace.store.read(Int.self, namespace: .afleet, key: key)
        XCTAssertNil(afleet, "the panel's write reached the afleet namespace")
        let fleetKit = try await rig.workspace.store.read(Int.self, namespace: .fleetKit, key: key)
        XCTAssertNil(fleetKit, "the panel's write reached the fleetKit namespace")
        let keys = try await context.store.keys()
        XCTAssertTrue(keys.contains(key), "the scoped store lists \(keys.count) keys and not the one it wrote")
    }

    /// The feed answers exactly what `ChannelTimeline.recentURLs(limit:)` answers, over a non-empty
    /// list.
    ///
    /// The floor is what makes the comparison mean anything: two empty collections are equal, and a
    /// channel that failed to ingest would compare two of them.
    func testRecentURLFeedMatchesTheTimelineQuery() async throws {
        let rig = try await PanelRig(channels: 1, urlsPerChannel: 1)
        let key = rig.keys[0]
        let context = try XCTUnwrap(rig.host.context(for: key, cwd: PanelFixtures.cwd),
                                    "the host built no context")
        let model = rig.timelines.model(for: key)
        await model.open(rig.row(0))

        let expected = model.timeline.recentURLs(limit: 10)
        let actual = await context.recentURLs.current(limit: 10)

        XCTAssertFalse(expected.isEmpty, "the channel's timeline holds 0 URLs, so the comparison is empty")
        XCTAssertEqual(actual.map(\.url.absoluteString), expected.map(\.url.absoluteString),
                       "the feed and the timeline query disagree")
        XCTAssertTrue(actual == expected, "the feed's list differs from the timeline query's beyond the URLs")
    }

    /// A subscriber attached before the timeline gains a URL receives one containing it.
    ///
    /// Without this the Browser could hold a feed that never changes while `current(limit:)` still
    /// passes — publishing is the feed's whole purpose. Nothing polls: the wait is fulfilled by the
    /// delivery, and the timeout is a hang guard.
    func testRecentURLFeedPublishesWhenTheTimelineChanges() async throws {
        let rig = try await PanelRig(channels: 1, urlsPerChannel: 1)
        let key = rig.keys[0]
        let context = try XCTUnwrap(rig.host.context(for: key, cwd: PanelFixtures.cwd),
                                    "the host built no context")
        let model = rig.timelines.model(for: key)
        await model.open(rig.row(0))
        let before = await context.recentURLs.current(limit: 10)
        XCTAssertEqual(before.count, 1, "the channel opened with \(before.count) URLs, not 1")

        // Before the change, and before anything is written.
        let updates = context.recentURLs.updates
        let arrived = XCTestExpectation(description: "a published list holding the second URL")
        let seen = URLBox()
        let reader = Task {
            for await urls in updates where urls.contains(where: { $0.url == PanelFixtures.url(1) }) {
                seen.set(urls.map(\.url.absoluteString))
                arrived.fulfill()
                return
            }
        }

        try rig.appendURL(to: 0, index: 1)
        rig.watcher.emit([rig.paths[0]])

        let outcome = await XCTWaiter().fulfillment(of: [arrived], timeout: LaunchFixtures.hangGuard)
        reader.cancel()
        XCTAssertEqual(outcome, .completed, "the feed published nothing holding the new URL")
        XCTAssertEqual(seen.value.count, 2, "the published list held \(seen.value.count) URLs, not 2")
        XCTAssertTrue(seen.value.contains(PanelFixtures.url(1).absoluteString),
                      "the published list does not hold the URL the change added")
    }

    // MARK: - Link routing

    /// `.newWindow` pops the target's tab out *before* the target delivers.
    ///
    /// Asserted from one shared recorder, because a host that delivered first and popped out
    /// afterwards would show the file in the wrong window and no count-only assertion would see it.
    func testNewWindowPopsTheTargetTabOutBeforeDelivering() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))
        let channel = PanelFixtures.key(0)
        // The channel the main window has rendered. A pop-out is refused for one the host cannot
        // resolve, because the window it would present draws the missing-channel placeholder;
        // `context(for:cwd:)` records the working directory even on a host with no workspace.
        _ = host.context(for: channel, cwd: PanelFixtures.cwd)
        host.focusChannel(channel)
        let recorder = LinkRecorder()
        host.presentWindow = { _ in recorder.note("window") }
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 5, host: host,
                                                           into: recorder, note: "delivered"))

        await host.links.open(PanelFixtures.fileLink, from: .newWindow)

        XCTAssertEqual(recorder.notes, ["window", "delivered"],
                       "the pop-out and the delivery happened in the wrong order")
        XCTAssertEqual(host.poppedOut.count, 1,
                       "the host recorded \(host.poppedOut.count) pop-outs, not 1")
        XCTAssertEqual(host.poppedOut.first?.tab, .files, "the wrong tab was popped out")
        XCTAssertEqual(recorder.poppedOutAtDelivery, 1,
                       "\(recorder.poppedOutAtDelivery) pop-outs were recorded when the target ran, not 1")
    }

    /// A target that declines the pop-out receives `.newWindow` and gets no window.
    ///
    /// X7's `popsOutForNewWindow`, ruled at C7.6's gate (2026-09-09). The Browser answers
    /// `.newWindow` with the *system* browser, so a host that popped its tab out anyway would
    /// present two windows for one Cmd-click — an afleet one and Safari's. Both halves are in one
    /// test and asserted against the host's own pop-out registry, so "no pop-out happened" is a
    /// statement about the host rather than about which branch the source took: the declining
    /// target is delivered to and the default one still pops out, and the registry holds exactly
    /// the second.
    func testATargetThatDeclinesThePopOutDoesNotGetOneAndADefaultTargetStillDoes() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.browser))
        try host.register(StubPanelTab(.files))
        let channel = PanelFixtures.key(0)
        _ = host.context(for: channel, cwd: PanelFixtures.cwd)
        host.focusChannel(channel)
        let recorder = LinkRecorder()
        host.presentWindow = { _ in recorder.note("window") }
        await host.links.register(PanelFixtures.decliningURLTarget(.browser, specificity: 5,
                                                                   into: recorder, note: "browser"))
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 5, host: host,
                                                           into: recorder, note: "files"))

        await host.links.open(.url(PanelFixtures.url(1)), from: .newWindow)

        XCTAssertEqual(recorder.destinations, [.newWindow],
                       "the declining target received \(recorder.destinations) rather than .newWindow")
        XCTAssertEqual(recorder.notes, ["browser"],
                       "the recorded order was \(recorder.notes)")
        XCTAssertEqual(host.poppedOut.count, 0,
                       "the host recorded \(host.poppedOut.count) pop-outs for a target that declined one")

        await host.links.open(PanelFixtures.fileLink, from: .newWindow)

        XCTAssertEqual(host.poppedOut.map(\.tab), [.files],
                       "the host popped out \(host.poppedOut.map(\.tab)) rather than the default target's tab")
    }

    /// The handler receives the destination for both cases.
    ///
    /// A host that hard-coded `.currentPanel` would satisfy every other routing test and silently
    /// drop the distinction C7's binding W5 requires; destination-dependent delivery would then
    /// fail only at integration.
    func testTheHandlerReceivesTheDestinationForBothCases() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))
        host.focusChannel(PanelFixtures.key(0))
        let recorder = LinkRecorder()
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 5, into: recorder))

        await host.links.open(PanelFixtures.fileLink, from: .currentPanel)
        await host.links.open(PanelFixtures.fileLink, from: .newWindow)

        XCTAssertEqual(recorder.destinations, [.currentPanel, .newWindow],
                       "the handler did not receive both destinations in order")
        XCTAssertEqual(recorder.links.count, 2, "the handler ran \(recorder.links.count) times, not 2")
        XCTAssertTrue(recorder.links.allSatisfy { $0 == PanelFixtures.fileLink },
                      "the handler received a link the test did not open")
    }

    /// A `.url` nobody registered for reaches the external opener the host was built with.
    ///
    /// The opener is injected through `HostLinkRouter.init` rather than assigned afterwards,
    /// because the delegated router takes its fallbacks at construction; the production default
    /// opens a browser window and a test must not. The URL is invented (§11), and the assertion
    /// compares one string this file wrote.
    func testAnUnclaimedURLLinkReachesTheInjectedExternalOpener() async throws {
        let opened = URLBox()
        let router = HostLinkRouter(externalOpener: { url in opened.set(opened.value + [url.absoluteString]) })

        await router.open(.url(PanelFixtures.url(1)), from: .currentPanel)

        XCTAssertEqual(opened.value, [PanelFixtures.url(1).absoluteString],
                       "the unclaimed .url link did not reach the injected external opener")
    }

    /// The channel a `.newWindow` link pops its tab out for is the one the *action* came from.
    ///
    /// Routing suspends on the way to the registry, and the main actor is free while it does: the
    /// window can move to another channel, or leave every channel, inside that window. A host that
    /// read its current channel when the pop-out finally ran would open the target in a channel the
    /// user was not looking at when they clicked — or emit the no-channel diagnostic for a link that
    /// had a perfectly good channel. The focus change here lands after the routing task has entered
    /// the router and before the pop-out runs, which is an ordering rather than a timing: the
    /// yield's continuation is queued on the main actor ahead of anything the router queues later.
    func testANewWindowLinkPopsOutForTheChannelItOriginatedIn() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))
        let origin = PanelFixtures.key(0)
        let elsewhere = PanelFixtures.key(1)
        _ = host.context(for: origin, cwd: PanelFixtures.cwd)
        host.focusChannel(origin)
        let recorder = LinkRecorder()
        host.presentWindow = { _ in recorder.note("window") }
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 5, into: recorder))

        let routing = Task { await host.links.open(PanelFixtures.fileLink, from: .newWindow) }
        await Task.yield()
        host.focusChannel(elsewhere)
        await routing.value

        XCTAssertEqual(host.poppedOut.count, 1,
                       "the host recorded \(host.poppedOut.count) pop-outs, not 1")
        XCTAssertEqual(host.poppedOut.first?.channel, origin,
                       "the pop-out went to a channel the link did not originate in")
        XCTAssertEqual(recorder.notes, ["window"], "the recorded order was \(recorder.notes)")
    }

    /// `unregister` withdraws the tab's link targets **before** releasing anything the tab holds.
    ///
    /// X7 made the host member `async` so the withdrawal could be ordered, and the order that
    /// matters runs the other way too: a delivery already in flight is owed to a handler that has
    /// not finished, and the tab, its runners and its sessions are what that handler is reading.
    /// The handler here reports the tab's own title, which the host answers from the registration
    /// and falls back to the id's default for once the tab is gone, so a release that landed under
    /// the handler is visible rather than inferred.
    ///
    /// **A `LinkTarget` registered during the drain does not stop the release.** The registry keeps
    /// that target — it belongs to the epoch the withdrawal opened rather than to the one it
    /// withdrew, so the withdrawal comes back `superseded` — but a target changing hands is not a
    /// tab changing hands. Nothing here registered a *tab*, so the teardown still owns the tab, its
    /// pane runner and its sessions, and a host that read the registry's verdict as its own would
    /// keep them for a successor that does not exist (spec §3, 2026-09-08 final wave).
    func testUnregisterWithdrawsTheLinkTargetBeforeReleasingTheTabsState() async throws {
        let host = PanelHostModel()
        let title = "Invented Files Title"
        let counter = SessionCounter()
        try host.register(StubPanelTab(.files, title: title, counter: counter))
        host.focusChannel(PanelFixtures.key(0))
        _ = host.session(for: .files, context: PanelFixtures.context())
        let recorder = LinkRecorder()
        let gate = HandlerGate()
        await host.links.register(LinkTarget(tab: .files, specificity: 5,
                                             handles: { link in if case .file = link { true } else { false } },
                                             open: { _, _ in
                                                 recorder.note("start:\(host.title(for: .files))")
                                                 await gate.arrive()
                                                 recorder.note("end:\(host.title(for: .files))")
                                             }))

        let routing = Task { await host.links.open(PanelFixtures.fileLink, from: .currentPanel) }
        await gate.waitForArrival()
        let withdrawal = Task {
            await host.unregister(.files)
            recorder.note("unregistered")
        }
        for _ in 0..<50 { await Task.yield() }
        // The handover, driven while the withdrawal is still draining.
        await host.links.register(PanelFixtures.fileTarget(.files, specificity: 5, into: recorder,
                                                           note: "successor"))
        gate.open()
        await withdrawal.value
        await routing.value

        XCTAssertEqual(recorder.notes, ["start:\(title)", "end:\(title)", "unregistered"],
                       "the recorded order was \(recorder.notes)")
        XCTAssertNotEqual(host.title(for: .files), title,
                          "the teardown kept a tab no replacement had registered for")
        XCTAssertEqual(counter.released, 1,
                       "the teardown released \(counter.released) of the 1 session the tab held")
        XCTAssertEqual(host.liveSessionCount, 0,
                       "the host holds \(host.liveSessionCount) sessions after the teardown, not 0")

        // The target registered during the drain is still the registry's: withdrawal is by tab and
        // by epoch, and this one belongs to the epoch the withdrawal opened.
        await host.links.open(PanelFixtures.fileLink, from: .currentPanel)
        XCTAssertEqual(recorder.notes.last, "successor",
                       "the recorded order was \(recorder.notes)")
    }

    /// X7's concrete handover, driven with a link-target registration landing inside the drain:
    /// `await unregister(.thread)` and then `register` of the replacement, which **must succeed**.
    ///
    /// This is the shape C6 takes over C5's placeholder, and the only thing unusual about it here
    /// is that a panel registered a `LinkTarget` for the id while the withdrawal was draining. That
    /// makes the registry's verdict `superseded`, and a host that let the verdict decide whether it
    /// released its own state kept the placeholder — so the very next line, the handover's own
    /// `register`, threw `duplicateTab` and the child could never take the id. The registry answers
    /// for link targets; the tab is the host's (spec §3, 2026-09-08 final wave).
    func testTheHandoverSucceedsWhenALinkTargetRegistersDuringTheDrain() async throws {
        let host = PanelHostModel()
        let placeholder = SessionCounter()
        try host.register(StubPanelTab(.thread, title: "an invented placeholder", counter: placeholder))
        _ = host.session(for: .thread, context: PanelFixtures.context())
        let recorder = LinkRecorder()
        let gate = HandlerGate()
        await host.links.register(LinkTarget(tab: .thread, specificity: 5,
                                             handles: { link in if case .file = link { true } else { false } },
                                             open: { _, _ in
                                                 recorder.note("start")
                                                 await gate.arrive()
                                                 recorder.note("end")
                                             }))

        let routing = Task { await host.links.open(PanelFixtures.fileLink, from: .currentPanel) }
        await gate.waitForArrival()
        let withdrawal = Task {
            await host.unregister(.thread)
            recorder.note("unregistered")
        }
        for _ in 0..<50 { await Task.yield() }
        // A link target for the same id, registered while the withdrawal is still draining.
        await host.links.register(PanelFixtures.fileTarget(.thread, specificity: 5, into: recorder,
                                                           note: "target"))
        gate.open()
        await withdrawal.value
        await routing.value

        let successor = StubPanelTab(.thread, title: "a later child's thread")
        try host.register(successor)

        XCTAssertEqual(recorder.notes, ["start", "end", "unregistered"],
                       "the recorded order was \(recorder.notes)")
        XCTAssertEqual(host.title(for: .thread), "a later child's thread",
                       "the host reports another tab's title after the handover")
        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.thread],
                       "the successor is not the tab the host presents for .thread")
        XCTAssertEqual(placeholder.released, 1,
                       "the handover released \(placeholder.released) of the placeholder's 1 session")
    }

    /// The same handover with its two halves **overlapped**: the replacement registers while the
    /// withdrawal of the id it is taking is still draining.
    ///
    /// It succeeds rather than waits, because `PanelHost.register` is X7's synchronous member and
    /// waiting would mean making it `async`. What it may not do is succeed and leave the retired
    /// tab's sessions behind for the replacement to inherit, so the outgoing owner's release is
    /// ordered before the registration completes — and the withdrawal that resumes afterwards must
    /// release nothing, because the id is no longer the generation it began withdrawing.
    func testARegistrationDuringTheDrainTakesTheIDAndKeepsItsOwnState() async throws {
        let host = PanelHostModel()
        let outgoing = SessionCounter()
        try host.register(StubPanelTab(.thread, title: "an invented placeholder", counter: outgoing))
        _ = host.session(for: .thread, context: PanelFixtures.context())
        host.select(.thread)
        let recorder = LinkRecorder()
        let gate = HandlerGate()
        await host.links.register(LinkTarget(tab: .thread, specificity: 5,
                                             handles: { link in if case .file = link { true } else { false } },
                                             open: { _, _ in await gate.arrive() }))

        let routing = Task { await host.links.open(PanelFixtures.fileLink, from: .currentPanel) }
        await gate.waitForArrival()
        let withdrawal = Task {
            await host.unregister(.thread)
            recorder.note("unregistered")
        }
        for _ in 0..<50 { await Task.yield() }

        let replacement = SessionCounter()
        XCTAssertNoThrow(try host.register(StubPanelTab(.thread, title: "a later child's thread",
                                                        counter: replacement)),
                         "registering over an id whose owner is mid-withdrawal was refused")
        _ = host.session(for: .thread, context: PanelFixtures.context())
        XCTAssertEqual(outgoing.released, 1,
                       "the registration left \(1 - outgoing.released) of the retired tab's sessions behind")
        XCTAssertEqual(replacement.created, 1,
                       "the replacement made \(replacement.created) sessions, not 1")

        gate.open()
        await withdrawal.value
        await routing.value

        XCTAssertEqual(recorder.notes, ["unregistered"], "the recorded order was \(recorder.notes)")
        XCTAssertEqual(host.title(for: .thread), "a later child's thread",
                       "the withdrawal released a tab it no longer owned")
        XCTAssertEqual(replacement.released, 0,
                       "the withdrawal released \(replacement.released) of the replacement's sessions")
        XCTAssertEqual(host.liveSessionCount, 1,
                       "the host holds \(host.liveSessionCount) sessions after the overlapped handover, not 1")
    }

    /// A `.currentPanel` link is routed with **no preparation at all**, so a withdrawal has no
    /// suspension to land in.
    ///
    /// There is nothing to pop out for `.currentPanel`, but a `prepare` that returns immediately is
    /// not the same as no `prepare`: it is what makes the router suspend between resolving a target
    /// and delivering to it. A withdrawal arriving in that suspension — the host's own teardown
    /// path — then invalidates the resolution, and because a preparation was already counted for
    /// the withdrawn tab the router refuses the unrelated target that survived and falls back,
    /// though nothing irreversible ever happened. With no hook the resolution and the delivery are
    /// one step on the router's executor: the withdrawal queued behind this open waits for the
    /// delivery it finds in flight instead of pre-empting it.
    func testACurrentPanelLinkIsNotHeldOpenByAPreparation() async throws {
        let recorder = LinkRecorder()
        let messages = URLBox()

        // The interleaving is driven twenty times, because a router that *does* hop through a
        // no-op preparation only loses the target when the withdrawal wins that hop: one round is
        // a coin toss and twenty is a witness. With no preparation every round is the same round —
        // resolving and committing the delivery are one step on the router's executor, so the
        // withdrawal that follows waits for the delivery it finds in flight.
        for round in 0..<20 {
            let resolved = URLBox()
            let router = HostLinkRouter(diagnostic: { message in messages.set(messages.value + [message]) })
            await router.register(LinkTarget(tab: .files, specificity: 10,
                                             handles: { link in
                                                 guard case .file = link else { return false }
                                                 resolved.set(["resolved"])
                                                 return true
                                             },
                                             open: { _, _ in recorder.note("files") }))
            await router.register(PanelFixtures.fileTarget(.terminal, specificity: 1, into: recorder,
                                                           note: "terminal"))

            // The withdrawal is driven once the registry has *resolved*, which the target reports
            // from its own `handles`: an ordering rather than a timing.
            let routing = Task { await router.open(PanelFixtures.fileLink, from: .currentPanel) }
            for _ in 0..<1000 where resolved.value.isEmpty { await Task.yield() }
            await router.unregister(tab: .files)
            await routing.value

            XCTAssertEqual(recorder.notes.count, round + 1,
                           "round \(round) delivered \(recorder.notes.count - round) links, not 1")
        }

        XCTAssertEqual(Set(recorder.notes), ["files"],
                       "a resolved target lost its link to another target or to the fallback")
        XCTAssertEqual(messages.value.count, 0,
                       "the twenty rounds produced \(messages.value.count) diagnostics")
    }

    /// A pop-out is refused for a channel the host can no longer resolve.
    ///
    /// The channel is captured at entry, because it is a property of the action — but the window is
    /// presented in the present, and `releaseChannel(_:)` and `attach(to:…)` erase the very context
    /// a popped-out scene resolves through. A preparation that re-added the entry blindly would put
    /// a window on screen showing the missing-channel placeholder, which is what a link in flight
    /// across an index delta produces.
    func testAPopOutIsRefusedForAChannelTheHostCanNoLongerResolve() async throws {
        let rig = try await PanelRig(channels: 1)
        let host = rig.host
        try host.register(StubPanelTab(.files))
        let key = rig.keys[0]
        _ = host.context(for: key, cwd: PanelFixtures.cwd)
        host.focusChannel(key)
        let recorder = LinkRecorder()
        let messages = URLBox()
        let router = HostLinkRouter(diagnostic: { message in messages.set(messages.value + [message]) })
        router.host = host
        host.presentWindow = { _ in recorder.note("window") }
        await router.register(PanelFixtures.fileTarget(.files, specificity: 5, into: recorder,
                                                       note: "delivered"))

        // The channel leaves the index while the link is in flight: its context and its pop-outs
        // are erased, and the main window is pointed back at it before the preparation runs. The
        // sequence is straight-line rather than raced, because what the pop-out has to check is a
        // state and not an ordering — the timing above is only how the state is reached.
        host.releaseChannel(key)
        host.focusChannel(key)

        await router.open(PanelFixtures.fileLink, from: .newWindow)

        XCTAssertEqual(host.poppedOut.count, 0,
                       "the host recorded \(host.poppedOut.count) pop-outs for a channel it had released")
        XCTAssertEqual(recorder.notes, ["delivered"], "the recorded order was \(recorder.notes)")
        XCTAssertEqual(messages.value.count, 1,
                       "the refused pop-out produced \(messages.value.count) diagnostics, not 1")
    }

    // MARK: - G4d: the pane seam

    /// The request reaches the runner unchanged and the exit reaches the lifecycle with the same id.
    ///
    /// The `id` is the clause that matters: two requests with identical other fields are two
    /// requests, and C4 discards an exit whose id it is not waiting on.
    func testPaneRequestAndExitPassThroughUnchanged() async throws {
        let rig = try await PanelRig(channels: 1)
        let context = try XCTUnwrap(rig.host.context(for: rig.keys[0], cwd: PanelFixtures.cwd),
                                    "the host built no context")
        let runner = RecordingPaneRunner()
        await runner.bind(context.reportPaneExit)
        rig.host.registerPaneRunner(runner, for: .terminal)
        let request = PanelFixtures.paneRequest()

        try await rig.host.run(request)

        let received = await runner.received
        XCTAssertEqual(received.count, 1, "the runner received \(received.count) requests, not 1")
        XCTAssertTrue(received.first?.id == request.id, "the host handed the runner a different request id")
        XCTAssertTrue(received.first == request, "the host edited the request on its way to the runner")
        let exits = await rig.lifecycle.paneExits
        XCTAssertEqual(exits.count, 1, "the lifecycle received \(exits.count) pane exits, not 1")
        XCTAssertTrue(exits.first?.request.id == request.id,
                      "the exit reaching the lifecycle carries a different request id")
        XCTAssertTrue(exits.first?.request == request, "the exit's request is not the one that was run")
    }
    /// The tab reads the channel's identity, its working directory and X11's environment out of the
    /// context, and each is asserted.
    ///
    /// Gate G4b names these three beside the store and the feed, and until now they were *rendered*
    /// and never asserted — `PlaceholderTab` drew them, and nothing exercised the tab. The
    /// assertion goes through `PlaceholderReadout`, which is the value the view's four lines are
    /// formatted from, so what is asserted is what the window shows.
    ///
    /// The session id and the environment are spelled as booleans: `XCTAssertEqual` prints both
    /// operands, and the environment carries `HOME` and `CLAUDE_CONFIG_DIR` rooted in a scratch
    /// tree, which resolve under the author's own account (§11).
    func testTheTabReadsTheChannelsIdentityCwdAndEnvironment() async throws {
        let rig = try await PanelRig(channels: 1)
        let key = rig.keys[0]
        let tab = PlaceholderTab()
        try rig.host.register(tab)
        let context = try XCTUnwrap(rig.host.context(for: key, cwd: PanelFixtures.cwd),
                                    "the host built no context")

        let session = try XCTUnwrap(rig.host.session(for: .thread, context: context) as? PlaceholderTabSession,
                                    "the placeholder's session is not the type it makes")
        let readout = PlaceholderReadout(session: session, context: context)

        XCTAssertTrue(context.session == key.session, "the context names a different session from the channel")
        XCTAssertTrue(readout.session == key.session.description,
                      "the tab draws a different session from the one the context carries")
        XCTAssertEqual(readout.cwd, PanelFixtures.cwd.path, "the tab draws a different working directory")
        XCTAssertTrue(context.cwd == PanelFixtures.cwd, "the context carries a different working directory")
        XCTAssertTrue(context.environment == rig.workspace.environment,
                      "the context's environment is not the one the launch resolved")
        XCTAssertEqual(readout.environmentVariables, rig.workspace.environment.variables.count,
                       "the tab counts \(readout.environmentVariables) environment variables, not the resolved capture's")
        XCTAssertGreaterThan(readout.environmentVariables, 0,
                             "the resolved environment holds 0 variables, so the count proves nothing")
    }

    /// The host `FleetCoordinator` was handed is the host the app resolves its panels from.
    ///
    /// "One host" is the property five children inherit, and an assertion that compares a `let` to
    /// itself cannot fail. This one can: it takes the coordinator `AppModel`'s own factory builds,
    /// drives an index removal through it, and asserts the session released was one held by
    /// `app.panels` — the instance the panel column and the popped-out scene resolve from. A model
    /// that built the coordinator over a second host would release nothing here.
    func testTheAppResolvesOnePanelHost() async throws {
        let rig = try await PanelRig(channels: 1)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let counter = SessionCounter()
        try app.panels.register(StubPanelTab(.files, counter: counter))
        let key = rig.keys[0]
        _ = app.panels.session(for: .files, context: PanelFixtures.context(key))
        XCTAssertEqual(app.panels.liveChannelCount, 1,
                       "the host holds \(app.panels.liveChannelCount) channels, not 1")

        let coordinator = try XCTUnwrap(app.coordinatorFactory(rig.workspace) as? FleetCoordinator,
                                        "the app's factory did not build a FleetCoordinator")
        await coordinator.indexChanged(IndexDelta(removed: [key.session]))

        XCTAssertEqual(counter.released, 1,
                       "the coordinator the app builds released \(counter.released) sessions from app.panels, not 1")
        XCTAssertEqual(app.panels.liveChannelCount, 0,
                       "the host the app resolves from still holds \(app.panels.liveChannelCount) channels")
        coordinator.stop()
    }
}

// MARK: - Doubles

/// A one-shot gate a `@MainActor` link handler waits on, so a delivery can be held open while the
/// test drives the host's teardown against it. Continuation-based, so the interleaving is an
/// ordering rather than a timing.
@MainActor
private final class HandlerGate {
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var hasArrived = false

    func arrive() async {
        hasArrived = true
        let waiting = watchers
        watchers = []
        for watcher in waiting { watcher.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = arrivals
        arrivals = []
        for arrival in waiting { arrival.resume() }
    }
}


/// A tab whose availability, title and session accounting the test controls.
@MainActor
private final class StubPanelTab: PanelTab {
    let id: PanelTabID
    let title: String
    let systemImage: String
    /// Nil means available for every channel.
    private let availableIn: Set<ChannelKey>?
    private let counter: SessionCounter?

    init(_ id: PanelTabID, title: String? = nil, availableIn: Set<ChannelKey>? = nil,
         counter: SessionCounter? = nil) {
        self.id = id
        self.title = title ?? id.defaultTitle
        self.systemImage = id.defaultSystemImage
        self.availableIn = availableIn
        self.counter = counter
    }

    func isAvailable(in context: ChannelContext) -> Bool {
        availableIn.map { $0.contains(context.key) } ?? true
    }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        counter?.made()
        return CountedSession(counter: counter)
    }

    func makeView(session: any PanelTabSession, context: ChannelContext,
                  surface: PanelSurface) -> AnyView {
        AnyView(SessionHoldingPanel(session: session))
    }
}

/// A real panel's view retains its session; the regression must do the same.
private struct SessionHoldingPanel: View {
    let session: any PanelTabSession
    var body: some View { Text(verbatim: "a stub tab") }
}

/// A session that says when it is made and when it goes.
@MainActor
private final class CountedSession: PanelTabSession {
    private let counter: SessionCounter?
    init(counter: SessionCounter?) { self.counter = counter }
    deinit { counter?.wentAway() }
}

/// The creation and release counts a stateful tab's sessions report.
///
/// `@unchecked Sendable` is sound because both mutable fields are read and written only inside
/// `lock`, this instance's private `NSLock`. A `deinit` is not isolated to any actor, so the
/// counter cannot live on one.
private final class SessionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    private var releases = 0

    var created: Int { lock.lock(); defer { lock.unlock() }; return creations }
    var released: Int { lock.lock(); defer { lock.unlock() }; return releases }

    func made() { lock.lock(); creations += 1; lock.unlock() }
    func wentAway() { lock.lock(); releases += 1; lock.unlock() }
}

/// What a link target saw, in the order it saw it.
@MainActor
private final class LinkRecorder {
    private(set) var tabs: [PanelTabID] = []
    private(set) var links: [WorkspaceLink] = []
    private(set) var destinations: [LinkDestination] = []
    private(set) var notes: [String] = []
    /// How many pop-outs the host had recorded at the moment the target ran.
    private(set) var poppedOutAtDelivery = 0

    func note(_ text: String) { notes.append(text) }

    func delivered(tab: PanelTabID, link: WorkspaceLink, destination: LinkDestination,
                   poppedOut: Int, note: String?) {
        tabs.append(tab)
        links.append(link)
        destinations.append(destination)
        poppedOutAtDelivery = poppedOut
        if let note { notes.append(note) }
    }
}

/// A `PaneRunning` that records what it was given and reports an exit through the context.
private actor RecordingPaneRunner: PaneRunning {
    private(set) var received: [PaneRequest] = []
    private var report: (@Sendable (PaneExit) async -> Void)?

    func bind(_ report: @escaping @Sendable (PaneExit) async -> Void) { self.report = report }

    func run(_ request: PaneRequest) async {
        received.append(request)
        // The exit carries the request the runner was handed, unedited. Whether that is the request
        // the host was given is what the test asserts.
        await report?(PaneExit(request: request, code: 0, observedAt: Date()))
    }
}

/// A `[String]` box a detached reader writes and the test reads.
///
/// `@unchecked Sendable` is sound because the one mutable field is `stored`, read and written only
/// inside `lock`, this instance's private `NSLock`.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var value: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ next: [String]) { lock.lock(); stored = next; lock.unlock() }
}

// MARK: - Values

/// Every identifier these tests use. Invented throughout: a session is a hex-formatted index, a
/// config home is a fixed invented path, a URL is under `invented.example` (§11).
private enum PanelFixtures {

    static let configHome = URL(fileURLWithPath: "/invented/config-home")
    static let cwd = URL(fileURLWithPath: "/invented/project")

    /// A v4-shaped session id from an index, so twenty distinct channels read as twenty numbers.
    static func session(_ index: Int) -> SessionID {
        SessionID(String(format: "%08x-0000-4000-8000-%012x", index, index))!
    }

    static func key(_ index: Int, configHome: URL = PanelFixtures.configHome) -> ChannelKey {
        ChannelKey(configHome: configHome, session: session(index))
    }

    static func url(_ index: Int) -> URL {
        URL(string: "https://invented.example/page-\(index)")!
    }

    static let fileLink = WorkspaceLink.file(URL(fileURLWithPath: "/invented/project/file.swift"), line: nil)

    /// A context over stub capabilities, for the tests that are about the host and not about what
    /// the capabilities do.
    static func context(_ key: ChannelKey = PanelFixtures.key(0)) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: cwd,
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh", capturedAt: Date(), mode: .login),
                       store: NullScopedStore(),
                       links: NullLinkRouter(),
                       recentURLs: NullRecentURLFeed(),
                       reportPaneExit: { _ in })
    }

    /// A target for `.file` links, recording what it received.
    ///
    /// `host` is read *inside* the handler, so what the recorder stores is the number of pop-outs
    /// that existed at the moment of delivery — which is the ordering the `.newWindow` rule is
    /// about, and a constant here would make that assertion unable to fail.
    @MainActor
    static func fileTarget(_ tab: PanelTabID, specificity: Int, host: PanelHostModel? = nil,
                           into recorder: LinkRecorder, note: String? = nil) -> LinkTarget {
        LinkTarget(tab: tab, specificity: specificity,
                   handles: { link in if case .file = link { true } else { false } },
                   open: { link, destination in
                       recorder.delivered(tab: tab, link: link, destination: destination,
                                          poppedOut: host?.poppedOut.count ?? 0, note: note)
                   })
    }

    /// A target for `.url` links that declines the pop-out, the shape C7.6's Browser registers:
    /// its `.newWindow` is the *system* browser, so there is no afleet window for it to render in.
    @MainActor
    static func decliningURLTarget(_ tab: PanelTabID, specificity: Int,
                                   into recorder: LinkRecorder, note: String? = nil) -> LinkTarget {
        LinkTarget(tab: tab, specificity: specificity, popsOutForNewWindow: false,
                   handles: { link in if case .url = link { true } else { false } },
                   open: { link, destination in
                       recorder.delivered(tab: tab, link: link, destination: destination,
                                          poppedOut: 0, note: note)
                   })
    }

    static func paneRequest() -> PaneRequest {
        PaneRequest(executable: URL(fileURLWithPath: "/invented/bin/claude"),
                    arguments: ["--invented"],
                    cwd: cwd,
                    environment: ["PATH": "/usr/bin"],
                    purpose: .shell)
    }
}

/// Capabilities that answer and do nothing, for a context built to exercise the host.
private struct NullScopedStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

private struct NullLinkRouter: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

private struct NullRecentURLFeed: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}

// MARK: - Rigs

/// A coordinator and the browser behind it, wired to the host under test.
///
/// It exists so the two tests that need a production seam — an index delta, and an origin reaching
/// a row — drive the object the composition root drives rather than the host directly.
@MainActor
private struct CoordinatorRig {
    let coordinator: FleetCoordinator
    let browser: FleetBrowserModel
    let lifecycle: LifecycleDouble
    let snapshot: IndexSnapshot

    init(host: PanelHostModel, sessions: [SessionID]) throws {
        let home = PanelFixtures.configHome
        snapshot = LaunchFixtures.snapshot(configHome: home, ids: sessions)
        lifecycle = LifecycleDouble()
        browser = FleetBrowserModel(lifecycle: lifecycle, configHome: home)
        coordinator = FleetCoordinator(configHome: home,
                                       registrar: RegistrarDouble(),
                                       index: StubIndex(persisted: nil, built: snapshot),
                                       model: browser,
                                       panels: host)
    }
}

/// A workspace over a scratch config home, with the host and the timeline registry attached to it
/// exactly as `AppModel.bindWorkspace` attaches them.
///
/// Built by hand rather than through `LaunchSequence` because what is under test is the panel host,
/// and a launch would add a binary probe, a version gate and a sign-in gate, each of which can fail
/// for reasons that say nothing about §7.
@MainActor
private struct PanelRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let host: PanelHostModel
    let timelines: ChannelTimelineRegistry
    let browser: FleetBrowserModel
    let shell: ShellModel
    let watcher: StubWatcher
    let keys: [ChannelKey]
    let paths: [URL]

    /// `urlsPerChannel` transcripts carry that many assistant messages naming an invented URL each;
    /// zero writes the plain two-record transcript.
    init(channels: Int, urlsPerChannel: Int = 0) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let configHome = home.configHome

        var keys: [ChannelKey] = []
        var paths: [URL] = []
        for index in 0..<channels {
            let session = PanelFixtures.session(index)
            let url: URL
            if urlsPerChannel > 0 {
                url = try PanelRig.transcriptWithURLs(in: home.root, slug: "invented-\(index)",
                                                      session: session, urls: urlsPerChannel)
            } else {
                url = try LaunchFixtures.transcript(in: home.root, slug: "invented-\(index)", session: session)
            }
            keys.append(ChannelKey(configHome: configHome.root, session: session))
            paths.append(url)
        }
        self.keys = keys
        self.paths = paths

        let index = TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)

        timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        host = PanelHostModel()
        shell = ShellModel(panels: host)
        host.attach(to: workspace, timelines: timelines, lifecycle: lifecycle)
        browser = FleetBrowserModel(lifecycle: lifecycle, configHome: configHome.root)
        browser.paint(LaunchFixtures.snapshot(configHome: configHome.root, ids: keys.map(\.session)),
                      listing: nil, origin: .built)
    }

    /// The row the channel column would hand the timeline model.
    func row(_ index: Int) -> ChannelRow {
        ChannelRow(key: keys[index],
                   title: "an invented channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: PanelFixtures.cwd,
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: nil)
    }

    /// Appends one assistant message naming `PanelFixtures.url(index)`, and moves the leaf onto it.
    ///
    /// The leaf has to move: `RecordReducer` projects the chain the closing `last-prompt` names, so
    /// a record appended past the named leaf applies cleanly and appears in no projection.
    func appendURL(to channel: Int, index: Int) throws {
        let handle = try FileHandle(forWritingTo: paths[channel])
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(PanelRig.assistantWithURL(session: keys[channel].session,
                                                                    index: index).utf8))
    }

    /// One user record and `count` assistant records, each naming its own invented URL, with the
    /// leaf on the last of them.
    private static func transcriptWithURLs(in configHome: URL, slug: String, session: SessionID,
                                           urls count: Int) throws -> URL {
        let directory = configHome.appending(path: "projects/\(slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var body = #"{"type":"user","sessionId":"\#(session)","uuid":"\#(uuid(0))","parentUuid":null,"isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"invented prompt"}}"# + "\n"
        for index in 0..<count { body += assistantWithURL(session: session, index: index) }
        let file = directory.appending(path: "\(session).jsonl")
        try Data(body.utf8).write(to: file)
        return file
    }

    /// An assistant record naming one invented URL, followed by the `last-prompt` that makes it the
    /// projected leaf. Its parent is the record before it, so the chain stays one branch.
    private static func assistantWithURL(session: SessionID, index: Int) -> String {
        let me = uuid(index + 1)
        let parent = uuid(index)
        let text = "invented reply naming \(PanelFixtures.url(index).absoluteString)"
        let record = #"{"type":"assistant","sessionId":"\#(session)","uuid":"\#(me)","parentUuid":"\#(parent)","isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:0\#(index + 1).000Z","message":{"id":"msg_invented\#(index)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        let leaf = #"{"type":"last-prompt","sessionId":"\#(session)","leafUuid":"\#(me)","lastPrompt":"invented prompt"}"# + "\n"
        return record + leaf
    }

    private static func uuid(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012x", index)
    }
}
