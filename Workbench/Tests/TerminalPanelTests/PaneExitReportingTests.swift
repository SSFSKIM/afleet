import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The one obligation a session owes X5: exactly one `PaneExit` per X5-originated pane, echoing
/// the request it was given, and none at all for a pane the panel made itself (spec Design §6;
/// gate G2.1). The children are real, because the mapping under test is the live one.
@MainActor
final class PaneExitReportingTests: XCTestCase {
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

    /// Fulfilled by the exit it waits for; the deadline is a watchdog on the harness and decides
    /// no assertion.
    private func exits(
        from recorder: PaneTestContext.ExitRecorder,
        reaching count: Int
    ) async -> [PaneExit] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let recorded = await recorder.recorded
            if recorded.count >= count { return recorded }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await recorder.recorded
    }

    /// Gives a report that should never come every chance to arrive before it is called absent.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    func testAnX5OriginatedPanesExitIsReportedOnceWithTheRequestEchoed() async throws {
        let (session, fixture) = try makeSession()
        let request = PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            cwd: fixture.cwd,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .hatch(SessionID())
        )

        session.run(request)

        let recorded = await exits(from: fixture.exits, reaching: 1)
        XCTAssertEqual(recorded.count, 1, "exits=\(recorded.count)")
        // By value, `id` included: C4 discards an exit whose id it is not waiting on, silently,
        // so a re-minted id is not a visible failure anywhere but here.
        XCTAssertEqual(recorded.first?.request, request, "the request was not echoed unchanged")
        XCTAssertEqual(recorded.first?.code, 3, "the child's own status was not reported")

        if let pane = session.panes.first { await session.close(pane) }
        await settle()
        let afterClose = await fixture.exits.recorded
        XCTAssertEqual(afterClose.count, 1, "closing an already-exited pane reported a second exit")
    }

    func testAShellPanesExitIsReportedToNobody() async throws {
        let (session, fixture) = try makeSession()
        let pane = session.openShellPane()

        await session.close(pane)
        await settle()

        let recorded = await fixture.exits.recorded
        XCTAssertEqual(recorded.count, 0, "a pane nobody requested reported an exit")
    }

    func testAFailedSpawnIsReportedWithTheUnexecutableCode() async throws {
        let (session, fixture) = try makeSession()
        let request = PaneRequest(
            executable: URL(filePath: "/invented/bin/never-executable"),
            arguments: [],
            cwd: fixture.cwd,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .hatch(SessionID())
        )

        session.run(request)

        guard case .failed = session.panes.first?.state else {
            return XCTFail("state=\(String(describing: session.panes.first?.state))")
        }
        let recorded = await exits(from: fixture.exits, reaching: 1)
        XCTAssertEqual(recorded.count, 1, "exits=\(recorded.count)")
        XCTAssertEqual(recorded.first?.request, request, "the request was not echoed unchanged")
        XCTAssertEqual(recorded.first?.code, PaneSpawn.unexecutableExitCode,
                       "a spawn that never executed was not reported as 127")
    }
}
