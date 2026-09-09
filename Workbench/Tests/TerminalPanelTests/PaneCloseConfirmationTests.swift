import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The two buttons that change a pane's life. Closing a pane whose child is alive asks first, and
/// the hatch's question names what is waiting on it (spec Design §2; gate G3.3); restarting is a
/// shell pane's own button and reopens it in place (spec Design §6).
///
/// The confirmation is state on the session rather than an `NSAlert`, which is what lets a
/// headless test answer it. The children are real, because "declining leaves the pane running"
/// is a claim about a process.
@MainActor
final class PaneCloseConfirmationTests: XCTestCase {
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

    private func makeSession() throws -> (TerminalPanelSession, PaneTestContext.Fixture) {
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        let fixture = PaneTestContext.fixture(session: SessionID(), cwd: directory)
        let session = TerminalPanelSession(context: fixture.context)
        openSessions.append(session)
        return (session, fixture)
    }

    /// A child that sits idle and cannot outlive the test process.
    private func idleRequest(purpose: PanePurpose, cwd: URL) -> PaneRequest {
        PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", PaneTestChild.selfTerminating(after: 30, "while :; do sleep 1; done")],
            cwd: cwd,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: purpose
        )
    }

    private func runningChild(of pane: TerminalPane) throws -> PaneTestChild.ChildIdentity {
        guard case let .running(pid) = pane.state else {
            throw XCTSkip("state=\(pane.state)")
        }
        return try XCTUnwrap(PaneTestChild.identity(ofChild: pid), "the child was never running")
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: Group 4 — the question, and both answers

    func testClosingALivePaneRaisesTheQuestionInsteadOfClosingIt() async throws {
        let (session, _) = try makeSession()
        let pane = session.openShellPane()
        let child = try runningChild(of: pane)

        await session.requestClose(pane)

        let confirmation = try XCTUnwrap(session.pendingClose, "a live pane closed without asking")
        XCTAssertEqual(confirmation.paneID, ObjectIdentifier(pane), "the question names another pane")
        XCTAssertEqual(session.panes.count, 1, "panes=\(session.panes.count)")
        XCTAssertTrue(PaneTestChild.isRunning(child), "the child died while the question stood")
    }

    func testDecliningLeavesThePaneAndItsChildAlone() async throws {
        let (session, _) = try makeSession()
        let pane = session.openShellPane()
        let child = try runningChild(of: pane)
        await session.requestClose(pane)

        session.cancelPendingClose()
        await settle()

        XCTAssertNil(session.pendingClose, "the question is still standing after it was answered")
        XCTAssertTrue(session.panes.contains { $0 === pane }, "declining closed the pane anyway")
        XCTAssertTrue(PaneTestChild.isRunning(child), "declining killed the child")
    }

    func testConfirmingClosesTheHatchPaneAndReportsExactlyOneExit() async throws {
        let (session, fixture) = try makeSession()
        let request = idleRequest(purpose: .hatch(SessionID()), cwd: fixture.cwd)
        let pane = session.run(request)
        let child = try runningChild(of: pane)

        await session.requestClose(pane)
        let confirmation = try XCTUnwrap(session.pendingClose, "a live hatch pane closed without asking")
        // The hatch's question names what is waiting on it: X5 released this channel, and closing
        // the pane is what makes it owned again.
        XCTAssertTrue(confirmation.namesChannelReturn,
                      "the hatch's question does not name the channel's return")

        await session.confirmPendingClose()
        await settle()

        XCTAssertNil(session.pendingClose, "the question outlived its answer")
        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count)")
        XCTAssertFalse(PaneTestChild.isRunning(child), "confirming left the child alive")
        let recorded = await fixture.exits.recorded
        XCTAssertEqual(recorded.count, 1, "exits=\(recorded.count)")
        XCTAssertEqual(recorded.first?.request.id, request.id, "the exit echoed another request")
    }

    func testAShellPanesQuestionSaysOnlyThatAProcessIsRunning() async throws {
        let (session, _) = try makeSession()
        let pane = session.openShellPane()
        _ = try runningChild(of: pane)

        await session.requestClose(pane)

        let confirmation = try XCTUnwrap(session.pendingClose, "a live pane closed without asking")
        XCTAssertFalse(confirmation.namesChannelReturn,
                       "a shell pane's question claims a channel is waiting on it")
        XCTAssertNotEqual(confirmation.question, "", "the question is empty")
    }

    /// The other half of the *Restart pane* button the readout offers: a shell pane restarts in
    /// place, in the directory it was opened in, and stays the pane nobody requested.
    func testRestartingAShellPaneReplacesItInPlace() async throws {
        let (session, fixture) = try makeSession()
        session.openShellPane()
        let second = session.openShellPane(cwd: fixture.cwd)

        let restarted = await session.restart(second)
        let fresh = try XCTUnwrap(restarted, "the shell pane did not restart")

        XCTAssertEqual(session.panes.count, 2, "panes=\(session.panes.count)")
        XCTAssertTrue(session.panes.last === fresh, "the fresh pane took another slot")
        XCTAssertEqual(session.selectedIndex, 1, "selected=\(String(describing: session.selectedIndex))")
        XCTAssertEqual(fresh.spawn?.cwd, fixture.cwd, "the fresh pane lost the directory it ran in")
        XCTAssertTrue(fresh.request == nil, "a restarted shell pane carries a request")
    }

    /// A restart suspends while the pane it is replacing is torn down, and the user goes on using
    /// the panel through that suspension. The fresh pane takes the selection only if the pane it
    /// replaced still held it: a restart that assigned the selection unconditionally pulled the
    /// tab back off whatever the user had chosen in the meantime — and persisted that.
    func testARestartLeavesASelectionMadeWhileItWasSuspendedAlone() async throws {
        let (session, _) = try makeSession()
        let first = session.openShellPane()
        let second = session.openShellPane()
        XCTAssertEqual(session.selectedIndex, 1, "the pane being restarted did not begin selected")

        let restarting = Task { await session.restart(second) }
        await Task.yield()
        await Task.yield()
        session.select(0)
        let restarted = await restarting.value
        let fresh = try XCTUnwrap(restarted, "the shell pane did not restart")

        XCTAssertEqual(session.selectedIndex, 0,
                       "selected=\(String(describing: session.selectedIndex)) after a restart the user did not select")
        XCTAssertTrue(session.selectedPane === first, "the restart took the selection the user had moved")
        XCTAssertTrue(session.panes.last === fresh, "the fresh pane took another slot")
    }

    /// A close the user asks for while a restart is suspended in the pane's teardown wins, and the
    /// restart yields to it.
    ///
    /// The restart consulted the standing closes only on the way *in*, so a close begun inside its
    /// suspension was invisible to it: it dropped the old pane and put a fresh shell in the slot,
    /// and the close that resumed afterwards could no longer find a pane of its own to remove and
    /// returned. The user was told their pane had closed while the slot held a running child.
    func testARestartYieldsToACloseAskedForWhileItWasSuspended() async throws {
        let (session, _) = try makeSession()
        let pane = session.openShellPane()
        let child = try runningChild(of: pane)
        let gate = PaneTestGate()
        pane.heldTeardown = { await gate.hold() }

        let restarting = Task { await session.restart(pane) }
        await gate.awaitEntry()
        let closing = Task { await session.close(pane) }
        try await PaneTestChild.waitUntil(seconds: 10, "close-standing") { session.isClosing(pane) }
        // The interleaving, pinned rather than hoped for: the restart is still inside the teardown
        // at the moment the user's close is standing on the same pane.
        XCTAssertTrue(gate.isHolding, "the restart had already resumed before the close was asked for")

        gate.open()
        let restarted = await restarting.value
        await closing.value

        XCTAssertNil(restarted, "the restart opened a fresh shell in a slot the user had asked to empty")
        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count) once the user's close returned")
        XCTAssertFalse(PaneTestChild.isRunning(child), "the child of the closed pane is still running")
    }

    func testAPaneWhoseChildHasAlreadyEndedClosesWithoutAsking() async throws {
        let (session, fixture) = try makeSession()
        let pane = session.run(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            cwd: fixture.cwd,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .command
        ))
        try await PaneTestChild.waitUntil(seconds: 10, "pane-exit") {
            if case .exited = pane.state { return true }
            return false
        }

        await session.requestClose(pane)

        XCTAssertNil(session.pendingClose, "a pane with no live child asked before closing")
        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count)")
    }
}
