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
}
