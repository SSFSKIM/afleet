import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The channel's pane stack: what a shell pane runs, how the selection moves, and that two
/// channels' stacks are two stacks (spec Design §6, §7; gate G4.1).
@MainActor
final class TerminalPanelSessionTests: XCTestCase {
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

    private func makeSession(cwd: URL? = nil) throws -> (TerminalPanelSession, PaneTestContext.Fixture) {
        let directory = try cwd ?? PaneTestChild.temporaryDirectory()
        if cwd == nil { directories.append(directory) }
        let fixture = PaneTestContext.fixture(session: SessionID(), cwd: directory)
        let session = TerminalPanelSession(context: fixture.context)
        openSessions.append(session)
        return (session, fixture)
    }

    // MARK: Group 1 — what a shell pane runs

    func testShellPaneRunsTheContextsShellInteractivelyInTheChannelsDirectory() throws {
        let (session, fixture) = try makeSession()

        let pane = session.openShellPane()

        let spawn = try XCTUnwrap(pane.spawn, "the shell pane never launched")
        XCTAssertEqual(spawn.executable, URL(fileURLWithPath: fixture.context.environment.shell),
                       "the shell pane did not run ResolvedEnvironment.shell")
        // `-i` and not `-l`: X11's capture already *is* the login shell's environment, so a login
        // shell would prepend PATH a second time and break item 23's equality.
        XCTAssertEqual(spawn.arguments, ["-i"], "the shell pane's argument vector is not [-i]")
        XCTAssertEqual(spawn.cwd, fixture.cwd, "the shell pane did not start in ChannelContext.cwd")
        // §6.3: by name, never a dumped environment.
        XCTAssertEqual(Set(spawn.environment.keys),
                       Set(fixture.context.environment.variables.keys),
                       "the shell pane's environment is not the context's by name")
        // §6.3 again: the comparison is total but the message names only what moved, because
        // `XCTAssertEqual` would print both dictionaries and that is the one thing an environment
        // assertion may never do.
        let variables = fixture.context.environment.variables
        let rewritten: [String] = variables.keys.filter { spawn.environment[$0] != variables[$0] }.sorted()
        XCTAssertTrue(spawn.environment == variables, "rewritten=\(rewritten.joined(separator: ","))")
        XCTAssertTrue(pane.request == nil, "a shell pane carries a PaneRequest it was never given")
    }

    func testASecondShellPaneIsAppendedAndSelected() throws {
        let (session, _) = try makeSession()

        let first = session.openShellPane()
        XCTAssertEqual(session.selectedIndex, 0, "the first pane was not selected")
        let second = session.openShellPane()

        XCTAssertEqual(session.panes.count, 2, "the second pane replaced the first")
        XCTAssertTrue(session.panes.first === first, "the first pane moved")
        XCTAssertEqual(session.selectedIndex, 1, "the second pane was not selected")
        XCTAssertTrue(session.selectedPane === second, "selectedPane is not the pane just opened")
    }

    func testClosingTheSelectedPaneSelectsANeighbourAndClosingTheLastLeavesNone() async throws {
        let (session, _) = try makeSession()
        let first = session.openShellPane()
        let second = session.openShellPane()

        await session.close(second)

        XCTAssertEqual(session.panes.count, 1, "the closed pane was not dropped")
        XCTAssertEqual(session.selectedIndex, 0, "the selection did not move to a neighbour")
        XCTAssertTrue(session.selectedPane === first, "the neighbour selected is not the surviving pane")

        await session.close(first)

        XCTAssertTrue(session.panes.isEmpty, "closing the last pane left panes behind")
        XCTAssertNil(session.selectedIndex, "closing the last pane left a selection")
        XCTAssertNil(session.selectedPane, "closing the last pane left a selected pane")
    }

    // MARK: Group 4 — two closes of one pane

    /// A close suspends while the pane tears its child down, and the panel can be re-entered
    /// there: a double-click on the close button, or the view's close arriving while the
    /// confirmation's is in flight, both put two `close(_:)` calls on one pane inside each other.
    /// The second must be the no-op the first's work already made it, and not a second mutation
    /// over an index the first is still holding — which removes a neighbour, reports a second exit
    /// for a request C4 has already been told about, or leaves the array shorter than the index it
    /// is about to remove from.
    func testTwoConcurrentClosesOfOnePaneMoveTheStackOnceAndReportOneExit() async throws {
        let (session, fixture) = try makeSession()
        let neighbour = session.openShellPane()
        let target = session.run(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", PaneTestChild.selfTerminating(after: 30, "sleep 30")],
            cwd: fixture.cwd,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .logs(JobShort(rawValue: "jtwice"))
        ))
        XCTAssertEqual(session.panes.count, 2, "the pane the closes are about was never opened")

        async let first: Void = session.close(target)
        async let second: Void = session.close(target)
        _ = await (first, second)

        XCTAssertEqual(session.panes.count, 1, "panes=\(session.panes.count)")
        XCTAssertTrue(session.panes.first === neighbour, "the second close removed the neighbour")
        XCTAssertEqual(session.selectedIndex, 0, "the selection does not name the surviving pane")

        // Both closes have returned, so every report either has been made or never will be; the
        // wait gives a second one every chance to arrive before it is called absent.
        try? await Task.sleep(for: .milliseconds(300))
        let reported = await fixture.exits.recorded
        XCTAssertEqual(reported.count, 1, "exits=\(reported.count)")
    }

    // MARK: Group 5 — G4.1: two channels, two stacks, and a child that survives the switch

    func testTwoChannelsNeverSeeEachOthersPanesAndAChildSurvivesTheSwitch() async throws {
        let (jade, _) = try makeSession()
        let (slate, _) = try makeSession()

        let jadePane = jade.openShellPane()
        _ = slate.openShellPane()
        _ = slate.openShellPane()

        XCTAssertEqual(jade.panes.count, 1, "one channel's stack grew with the other's panes")
        XCTAssertEqual(slate.panes.count, 2, "the second channel's stack is not its own")
        for pane in slate.panes {
            XCTAssertFalse(jade.panes.contains { $0 === pane }, "a pane is in two channels' stacks")
        }

        guard case let .running(pid) = jadePane.state else {
            return XCTFail("jade-pane=\(jadePane.state)")
        }
        let identity = try XCTUnwrap(PaneTestChild.identity(ofChild: pid), "the child was never seen")

        // The switch away and back is the host handing a different session to the renderer and
        // then this one again; the session object is what carries the pane across it.
        _ = slate.selectedPane
        _ = jade.selectedPane

        XCTAssertTrue(PaneTestChild.isRunning(identity), "the channel's child did not survive the switch")
        XCTAssertTrue(jade.panes.first === jadePane, "the pane did not survive the switch")
    }
}
