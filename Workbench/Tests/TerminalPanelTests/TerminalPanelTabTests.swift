import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The tab X7's host renders: its identity, the session it vends, and the one thing a session
/// cannot do for itself — reading its W6 document on the first render and never again
/// (spec Design §1, §7; gate G4.2).
@MainActor
final class TerminalPanelTabTests: XCTestCase {
    private var directories: [URL] = []
    private var openSessions: [TerminalPanelSession] = []

    override func tearDown() async throws {
        for session in openSessions {
            for pane in session.panes { await session.close(pane) }
        }
        openSessions = []
        for directory in directories { PaneTestChild.remove(directory) }
        directories = []
        try await super.tearDown()
    }

    private func makeFixture() throws -> PaneTestContext.Fixture {
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        return PaneTestContext.fixture(session: SessionID(), cwd: directory)
    }

    /// Also the assertion that `makeSession` vends a `TerminalPanelSession` at all: every test
    /// below reaches its session through here.
    private func hold(_ session: any PanelTabSession) throws -> TerminalPanelSession {
        let session = try XCTUnwrap(session as? TerminalPanelSession,
                                    "the tab vended a session of another type")
        openSessions.append(session)
        return session
    }

    // MARK: Group 1 — the tab

    func testTheTabIsTheTerminalTabAndTakesItsWordsFromTheIdItRegistersUnder() {
        let tab = TerminalPanelTab(registry: TerminalSessionRegistry())

        XCTAssertEqual(tab.id, .terminal, "the tab did not register under .terminal")
        // From the id's own defaults: a second spelling of a panel's name is a name that drifts.
        XCTAssertEqual(tab.title, PanelTabID.terminal.defaultTitle, "the tab spells its own title")
        XCTAssertEqual(tab.systemImage, PanelTabID.terminal.defaultSystemImage,
                       "the tab spells its own symbol")
    }

    func testTheTabIsAvailableForEveryChannel() throws {
        let tab = TerminalPanelTab(registry: TerminalSessionRegistry())
        let fixture = try makeFixture()

        XCTAssertTrue(tab.isAvailable(in: fixture.context),
                      "a channel was refused a terminal")
    }

    func testAskingTwiceForOneChannelYieldsTheSameSessionAsTheRunnerHolds() throws {
        let registry = TerminalSessionRegistry()
        let tab = TerminalPanelTab(registry: registry)
        let fixture = try makeFixture()

        let first = try hold(tab.makeSession(for: fixture.context))
        let second = tab.makeSession(for: fixture.context)

        // The same object, because the runner reaches the channel's panes through the registry
        // and a second session would report an exit for panes the first one is holding.
        XCTAssertTrue(first === (second as? TerminalPanelSession),
                      "the tab made a second session for one channel")
        XCTAssertTrue(first === registry.session(for: fixture.context),
                      "the tab's session is not the registry's")
    }

    func testTheFirstRenderRestoresTheChannelsDocumentAndARerenderDoesNot() async throws {
        let fixture = try makeFixture()
        let tab = TerminalPanelTab(registry: TerminalSessionRegistry())
        try await fixture.store.write(
            TerminalPanelState(
                panes: [PersistedPane(cwd: fixture.cwd.path), PersistedPane(cwd: fixture.cwd.path)],
                selected: 1
            ),
            key: TerminalPanelState.storeKey(for: fixture.key)
        )
        let session = try hold(tab.makeSession(for: fixture.context))

        _ = tab.makeView(session: session, context: fixture.context, surface: .panel)
        await session.settleRestore()

        // Two panes and not zero: removing the restore call from the tab leaves the document
        // unread, which is the gap T3 left and this test closes.
        XCTAssertEqual(session.panes.count, 2, "panes=\(session.panes.count)")

        _ = tab.makeView(session: session, context: fixture.context, surface: .panel)
        await session.settleRestore()

        // Two and not four: a re-render is not a second restore.
        XCTAssertEqual(session.panes.count, 2, "panes=\(session.panes.count)")
    }

    func testAChannelWithNoDocumentRendersOneShellPane() async throws {
        let fixture = try makeFixture()
        let tab = TerminalPanelTab(registry: TerminalSessionRegistry())
        let session = try hold(tab.makeSession(for: fixture.context))

        _ = tab.makeView(session: session, context: fixture.context, surface: .panel)
        await session.settleRestore()

        XCTAssertEqual(session.panes.count, 1, "panes=\(session.panes.count)")
        XCTAssertTrue(session.panes.first?.request == nil,
                      "the restored pane carries a request it was never given")
    }
}
