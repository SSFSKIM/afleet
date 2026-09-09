import AppKit
import Darwin
import FleetKit
import Foundation
import TerminalCore
@testable import TerminalPanel
import XCTest

/// What ends a pane. The last case is the one tracker 93 was left open for: a pane whose renderer
/// is wedged has a read loop suspended in `awaitFeedCapacity()`, and a close that waits for that
/// loop waits for ever unless the wait itself is cancellable.
@MainActor
final class PaneTeardownTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testCloseEndsTheChildAndTheReadLoopAndIsIdempotent() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = TerminalPane()
        window = PaneTestChild.window(around: pane.surface.view)
        try await PaneTestChild.awaitAttachment(of: pane.surface)
        let script = PaneTestChild.selfTerminating(after: 30, """
        printf 'afleet-pane-alive\\n'
        IFS= read -r hold
        """)
        pane.start(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            cwd: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .command
        ))
        guard case let .running(pid) = pane.state, let child = PaneTestChild.identity(ofChild: pid) else {
            XCTFail("state=\(pane.state) expected=running")
            return
        }
        try await PaneTestChild.waitUntil(seconds: 15, "child-alive") {
            pane.surface.renderedViewportText()?.contains("afleet-pane-alive") == true
        }

        await pane.close()

        XCTAssertFalse(PaneTestChild.isRunning(child), "child=still-running-after-close")
        XCTAssertFalse(pane.hasRunningReadLoop, "read-loop=still-running-after-close")

        // A second close is a no-op: there is no pty left to tear down and no loop left to cancel,
        // and a pane the panel closes twice is ordinary — the user closes it while it is exiting.
        let secondCloseReturned = await PaneTestChild.completes(withinSeconds: 10) {
            await pane.close()
        }
        XCTAssertTrue(secondCloseReturned, "second-close=did-not-return")
        XCTAssertFalse(pane.hasRunningReadLoop, "read-loop=restarted-by-second-close")
    }

    /// Tracker 93. The pane is deliberately **not** in a window, so the adapter's drain holds
    /// everything back — its own documented behaviour before a surface attaches — and the
    /// backlog crosses the cap while the child floods. The read loop is then suspended inside
    /// `awaitFeedCapacity()`, which is exactly the state a pane can be closed in.
    func testCloseCompletesWhileTheSurfaceBacklogIsFull() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = TerminalPane()
        pane.start(PaneRequest(
            executable: URL(filePath: "/usr/bin/yes"),
            arguments: ["afleet-pane-flood"],
            cwd: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .command
        ))
        guard case let .running(pid) = pane.state, let child = PaneTestChild.identity(ofChild: pid) else {
            XCTFail("state=\(pane.state) expected=running")
            return
        }
        try await PaneTestChild.waitUntil(seconds: 20, "backlog-at-cap") {
            pane.surface.outstandingFeedByteCount >= GhosttyTerminalSurface.feedBufferByteLimit
        }

        // Generous on purpose: this bound is a watchdog on the harness, and the only thing it
        // decides is that a wedged close is reported as a failure instead of hanging the suite.
        let closeReturned = await PaneTestChild.completes(withinSeconds: 20) {
            await pane.close()
        }

        XCTAssertTrue(closeReturned, "close=never-returned")
        XCTAssertFalse(pane.hasRunningReadLoop, "read-loop=still-running-after-close")
        XCTAssertFalse(PaneTestChild.isRunning(child), "child=still-running-after-close")
    }

    /// A pane that never attached and is then closed leaves nothing running behind it.
    ///
    /// The pane is deliberately **not** in a window, which is the discarded-pane shape: the
    /// adapter's drain holds the backlog back until a surface appears and re-asks every 10 ms,
    /// rescheduling a closure that captures itself — so the drain, the backend session and the
    /// backlog outlive a pane nobody will ever look at again, for the life of the process.
    ///
    /// Asserted on the adapter's own poll count rather than on a timer nothing can see: after the
    /// close it does not move again, across many times the poll interval.
    func testClosingANeverAttachedPaneLeavesNoRepeatingWorkScheduled() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = TerminalPane()
        pane.start(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'afleet-pane-unattached\\n'"],
            cwd: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .command
        ))
        try await PaneTestChild.waitUntil(seconds: 15, "drain-polling-for-attachment") {
            pane.surface.feedDrainAttachmentPollCount > 0
        }

        await pane.close()

        let polls = pane.surface.feedDrainAttachmentPollCount
        XCTAssertEqual(pane.surface.outstandingFeedByteCount, 0,
                       "backlog=\(pane.surface.outstandingFeedByteCount) bytes-after-close")
        // Twenty times the adapter's own attachment-poll interval.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pane.surface.feedDrainAttachmentPollCount, polls,
                       "drain-polls after-close=\(polls) later=\(pane.surface.feedDrainAttachmentPollCount)")
        XCTAssertEqual(pane.surface.outstandingFeedByteCount, 0,
                       "backlog=\(pane.surface.outstandingFeedByteCount) bytes-after-disposal")
    }

    /// Two closes of one pane, from two different paths, and both of them wait for the one
    /// teardown. The pane marks itself closed before it awaits anything, so a second caller used
    /// to walk straight back out through that guard while the child, the read loop and the
    /// surface were all still standing — and `TerminalPanelSession.tearDown()`, which calls
    /// `pane.close()` directly rather than through the session's own coalescing, is exactly that
    /// second caller. It then reported an exit for a pane that had not finished ending.
    func testASecondCloseFromAnotherPathReturnsOnlyAfterTheOneTeardownHasFinished() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = TerminalPane()
        pane.start(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", PaneTestChild.selfTerminating(after: 30, "sleep 30")],
            cwd: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .command
        ))
        guard case let .running(pid) = pane.state, let child = PaneTestChild.identity(ofChild: pid) else {
            XCTFail("state=\(pane.state) expected=running")
            return
        }

        // The first path closes and suspends inside the teardown; the second arrives while it is
        // there, which is the whole of the race.
        let first = Task { await pane.close() }
        await Task.yield()
        await pane.close()

        XCTAssertFalse(PaneTestChild.isRunning(child), "child=still-running-when-the-second-close-returned")
        XCTAssertFalse(pane.hasRunningReadLoop, "read-loop=still-running-when-the-second-close-returned")
        await first.value
    }
}
