import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
import Workbench
@testable import Afleet

/// Tracker 240 closed at the app's two consumers: a delivery lands in the channel the **action**
/// was raised for, whichever channel the window has moved to since.
///
/// `HostLinkRouter` already captures that channel at entry and publishes it as `LinkOrigin.channel`
/// for the whole routed call — the Browser's pull-request target reads it — and these are the two
/// consumers that were still resolving through the host's *present* focus instead. Both suites that
/// came before this one assert the old mitigation's good case, where the window has not moved; what
/// discriminates is the case the mitigation was always wrong for, so each test here stages the move
/// inside the routed call.
///
/// Every identifier is invented and every tree is built under the process's temporary directory by
/// `PanelRig`; no assertion names a path or a session id (§6.3, §11).
@MainActor
final class LinkChannelOriginTests: XCTestCase {

    /// A `.file` raised in A, delivered while the main window is on B, opens in A.
    ///
    /// The move is staged from `didCaptureOrigin`, the barrier `HostLinkRouter` publishes for
    /// exactly this: it fires once the origin has been captured and before anything reads it,
    /// which is the window in which the main window is free to move. Yielding and hoping would be
    /// asserting the scheduler's habits rather than the rule (§17.7).
    func testACurrentPanelFileDeliveryOpensInTheChannelTheActionWasRaisedIn() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let file = try rig.temp.file("raised/notes.swift", "let a = 1\n")
        let raised = try XCTUnwrap(app.panels.context(for: rig.keys[0],
                                                      cwd: try rig.temp.directory("raised")))
        let movedTo = try XCTUnwrap(app.panels.context(for: rig.keys[1],
                                                       cwd: try rig.temp.directory("moved")))
        app.panels.focusChannel(rig.keys[0])
        try await waitUntilRegistered(app)

        let panels = app.panels
        let elsewhere = rig.keys[1]
        app.panels.links.didCaptureOrigin = { @Sendable in
            await MainActor.run { panels.focusChannel(elsewhere) }
        }
        await app.panels.links.open(.file(file, line: nil), from: .currentPanel)

        let raisedSession = try XCTUnwrap(app.panels.session(for: .files, context: raised)
                                            as? FilesPanelSession)
        let movedSession = try XCTUnwrap(app.panels.session(for: .files, context: movedTo)
                                            as? FilesPanelSession)
        XCTAssertEqual(raisedSession.openFiles.count, 1,
                       "the delivery left the channel the link was raised in")
        XCTAssertEqual(movedSession.openFiles.count, 0,
                       "the delivery followed the window rather than the action")
    }

    /// The same for `.newWindow`, and this is tracker 370's crossing: `lastPopOut` is one slot, so
    /// a second pop-out prepared while the first delivery is still in flight claims both.
    ///
    /// The second pop-out is staged from `presentWindow`, which runs inside the router's `prepare`
    /// — between resolving the target and delivering to it — and is therefore the one place a
    /// second preparation can be made to overlap the first without asserting on scheduling. The
    /// guard on the channel is what stops the staged pop-out re-entering this closure.
    func testANewWindowFileDeliveryKeepsItsOwnChannelWhenASecondPopOutOverlapsIt() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let file = try rig.temp.file("raised/notes.swift", "let a = 1\n")
        let raised = try XCTUnwrap(app.panels.context(for: rig.keys[0],
                                                      cwd: try rig.temp.directory("raised")))
        let movedTo = try XCTUnwrap(app.panels.context(for: rig.keys[1],
                                                       cwd: try rig.temp.directory("moved")))
        app.panels.focusChannel(rig.keys[0])
        try await waitUntilRegistered(app)

        let panels = app.panels
        let own = rig.keys[0]
        let other = rig.keys[1]
        app.panels.presentWindow = { panel in
            guard panel.channel == own else { return }
            panels.popOut(.files, channel: other)
            panels.focusChannel(other)
        }
        await app.panels.links.open(.file(file, line: nil), from: .newWindow)

        let raisedSession = try XCTUnwrap(app.panels.session(for: .files, context: raised)
                                            as? FilesPanelSession)
        let movedSession = try XCTUnwrap(app.panels.session(for: .files, context: movedTo)
                                            as? FilesPanelSession)
        XCTAssertEqual(raisedSession.openFiles.count, 1,
                       "the delivery left the channel its own window was popped out for")
        XCTAssertEqual(movedSession.openFiles.count, 0,
                       "an overlapping pop-out claimed another link's delivery")
    }

    /// The Source Control panel's `.commit`, from A's popped-out panel, with the same crossing
    /// staged: the notice lands in A.
    ///
    /// Neither channel is in a repository, so what the delivery is owed is a notice rather than a
    /// selection — which is what proves which channel it reached without this test knowing anything
    /// about a repository, exactly as C7.7's own suite does it.
    func testANewWindowCommitDeliveryKeepsItsOwnChannelWhenASecondPopOutOverlapsIt() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let raised = try XCTUnwrap(app.panels.context(for: rig.keys[0],
                                                      cwd: try rig.temp.directory("raised")))
        let movedTo = try XCTUnwrap(app.panels.context(for: rig.keys[1],
                                                       cwd: try rig.temp.directory("moved")))
        app.panels.focusChannel(rig.keys[0])
        try await waitUntilRegistered(app)

        let panels = app.panels
        let own = rig.keys[0]
        let other = rig.keys[1]
        app.panels.presentWindow = { panel in
            guard panel.channel == own else { return }
            panels.popOut(.sourceControl, channel: other)
            panels.focusChannel(other)
        }
        await app.panels.links.open(.commit(Self.hash), from: .newWindow)

        let raisedSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: raised)
                                            as? SourceControlModel)
        let movedSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: movedTo)
                                            as? SourceControlModel)
        XCTAssertNotNil(raisedSession.deliveryNotice,
                        "the commit left the channel its own window was popped out for")
        XCTAssertNil(movedSession.deliveryNotice,
                     "an overlapping pop-out claimed the commit's delivery")
    }

    /// The fallback the origin does not take away: a link opened outside a routed action — no
    /// origin at all — is still the main window's, which is what a delivery raised from the menu
    /// bar or from a test harness has.
    func testADeliveryWithNoOriginStillAnswersWithTheMainWindowsChannel() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let shown = try XCTUnwrap(app.panels.context(for: rig.keys[1],
                                                     cwd: try rig.temp.directory("shown")))
        let shownSession = try XCTUnwrap(app.panels.session(for: .files, context: shown)
                                            as? FilesPanelSession)
        app.panels.focusChannel(rig.keys[1])

        XCTAssertNil(LinkOrigin.channel, "a test is not inside a routed action")
        XCTAssertTrue(app.filesSession(for: .currentPanel) === shownSession,
                      "a delivery with no origin did not fall back to the main window's channel")
    }

    /// An invented forty-hex commit id. Never a hash from any repository (§11).
    private static let hash = String(repeating: "ab", count: 20)

    /// The registrations are spawned from `AppModel.init`, so a bounded wait is what a test has.
    /// A count, never a target (§11).
    private func waitUntilRegistered(_ app: AppModel,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            if await app.panels.links.targetCount == 3 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the tabs registered in the initialiser never registered their link targets",
                file: file, line: line)
    }
}
