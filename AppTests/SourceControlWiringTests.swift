import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.7 T8: the lines this leaf adds to the app — the two tabs' registration (spec Design §2,
/// §11), the one `.commit` target (Design §7) and `AppModel`'s `SourceControlTabHost` conformance.
///
/// Every identifier is invented and every tree is built under the process's temporary directory by
/// `PanelRig`; no assertion names a path, a repository or a buffer (§6.3, §11).
@MainActor
final class SourceControlWiringTests: XCTestCase {

    /// Design §2 and §11: `AppModel.init` registers both tabs beside the four already shipped, so
    /// a freshly built model offers them on every channel — including one whose folder is in no
    /// repository, which is what the availability rule is for — and the host can build a session
    /// and a view for each without anything else having run first.
    func testTheAppRegistersBothTabsAndBuildsASessionAndViewForEach() throws {
        let app = AppModel(registry: RowRegistry())
        let context = PanelFixtures.context()

        XCTAssertTrue(app.panels.isRegistered(.sourceControl), "the app model does not hold the Source Control tab")
        XCTAssertTrue(app.panels.isRegistered(.github), "the app model does not hold the GitHub tab")
        XCTAssertEqual(app.panels.title(for: .sourceControl), PanelTabID.sourceControl.defaultTitle,
                       "the registered Source Control tab is not named by its own title")
        XCTAssertEqual(app.panels.title(for: .github), PanelTabID.github.defaultTitle,
                       "the registered GitHub tab is not named by its own title")
        XCTAssertEqual(app.panels.available(for: context),
                       [.thread, .files, .sourceControl, .terminal, .browser, .github],
                       "the channel does not offer exactly the shipped tabs, in canonical order")

        XCTAssertTrue(app.panels.session(for: .sourceControl, context: context) is SourceControlModel,
                      "the host built something other than the Source Control panel's session")
        XCTAssertTrue(app.panels.session(for: .github, context: context) is GitHubModel,
                      "the host built something other than the GitHub panel's session")

        // A view, not just a session: `makeView` is what the panel column calls, and a tab
        // registered without one would leave an empty column that no session assertion notices.
        // `ViewTree` is what can look inside the `AnyView` X7 hands back.
        let scm = app.panels.view(for: .sourceControl, context: context, surface: .panel)
        let github = app.panels.view(for: .github, context: context, surface: .panel)
        XCTAssertFalse(ViewTree.values(of: SourceControlPanelView.self, in: scm).isEmpty,
                       "the host built no Source Control view for the channel")
        XCTAssertFalse(ViewTree.values(of: GitHubPanelView.self, in: github).isEmpty,
                       "the host built no GitHub view for the channel")
    }

    /// Design §7: the `.commit` target exists from the moment the tab is registered — the host
    /// builds a session lazily, for rendering, so a target that waited for the first visit would
    /// leave every `.commit` link raised before it falling through to W5's fallback — and there is
    /// exactly **one** of it. One registration is the whole of tracker 240's mitigation: a second
    /// would tie on specificity and canonical tab order, which is all `LinkRouter.mostSpecific`
    /// compares, and the router would then pick between two channels arbitrarily.
    ///
    /// The count is asserted as a **delta** over the Files pair, because both are spawned from
    /// `AppModel.init` and a fixed number would be a race between two children. A count, never a
    /// target (§11).
    func testTheCommitTargetIsRegisteredOnceBeforeThePanelIsEverDisplayed() async throws {
        let app = AppModel(registry: RowRegistry())

        try await waitForInitTargets(app)
        XCTAssertEqual(app.panels.liveSessionCount, 0,
                       "registering the target brought a session into being")

        // Settled: nothing else lands after the two initialiser tasks, so the third target is the
        // Source Control tab's one and only.
        try await Task.sleep(for: .milliseconds(200))
        let settled = await app.panels.links.targetCount
        XCTAssertEqual(settled, 3,
                       "the app registered \(settled) targets before a launch, not the Files pair plus one .commit")
    }

    /// Design §7's mitigation as the app runs it: a `.commit` delivered `.currentPanel` reaches the
    /// Source Control session of the channel the **window is showing**, resolved through the host
    /// at the moment of delivery rather than through whichever session a view rendered last — and
    /// it brings the tab forward, so a selected commit is not selected behind the tab that is up.
    ///
    /// The channel is in no repository, so the answer the delivery is owed is a notice rather than
    /// a selection; that is the point. §7 is binding that a delivery is never a silent no-op, and a
    /// notice raised in exactly one of two sessions is what proves which channel the link reached
    /// without this test knowing anything about a repository.
    func testADeliveredCommitLinkReachesTheShownChannelAndBringsTheTabForward() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let drawn = try XCTUnwrap(app.panels.context(for: rig.keys[0], cwd: try rig.temp.directory("drawn")))
        let shown = try XCTUnwrap(app.panels.context(for: rig.keys[1], cwd: try rig.temp.directory("shown")))
        // The window drew Source Control for the first channel, then moved to the second with
        // Thread up — the shape an anchor bound in `makeView` would get wrong.
        _ = app.panels.view(for: .sourceControl, context: drawn, surface: .panel)
        app.panels.focusChannel(rig.keys[1])
        app.panels.select(.thread)
        try await waitForInitTargets(app)

        await app.panels.links.open(.commit(Self.hash), from: .currentPanel)

        let shownSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: shown)
                                            as? SourceControlModel)
        let drawnSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: drawn)
                                            as? SourceControlModel)
        XCTAssertNotNil(shownSession.deliveryNotice,
                        "the delivery did not reach the channel the window is showing")
        XCTAssertNil(drawnSession.deliveryNotice,
                     "the delivery followed the last render rather than the window")
        XCTAssertEqual(app.panels.selected, .sourceControl,
                       "a delivered commit was selected in a tab nobody could see")
    }

    /// Design §7's other half, and the reason the destination goes with the question: a
    /// `.newWindow` delivery belongs to the channel its **own** window was popped out for.
    ///
    /// Asserted on `sourceControlSession(for:)` directly, per destination, because that is the
    /// conformance the target calls and the thing C7.5's `filesSession(for:)` established. The
    /// window is popped out for the first channel and the selection then leaves for the second:
    /// `.newWindow` must still name the first, `.currentPanel` the second.
    func testTheHostAnswersASourceControlSessionPerDestination() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel(registry: RowRegistry())
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let popped = try XCTUnwrap(app.panels.context(for: rig.keys[0], cwd: try rig.temp.directory("popped")))
        let moved = try XCTUnwrap(app.panels.context(for: rig.keys[1], cwd: try rig.temp.directory("moved")))
        let poppedSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: popped)
                                            as? SourceControlModel)
        let movedSession = try XCTUnwrap(app.panels.session(for: .sourceControl, context: moved)
                                            as? SourceControlModel)
        app.panels.popOut(.sourceControl, channel: rig.keys[0])
        app.panels.focusChannel(rig.keys[1])

        XCTAssertTrue(app.sourceControlSession(for: .newWindow) === poppedSession,
                      "a .newWindow delivery left the channel its own window was popped out for")
        XCTAssertTrue(app.sourceControlSession(for: .currentPanel) === movedSession,
                      "a .currentPanel delivery did not reach the channel the window is showing")

        // A window closed since names nothing, and the current channel answers instead — the same
        // rule Files takes, and what stops a delivery resurrecting a window that is gone.
        app.panels.closePopOut(PoppedOutPanel(tab: .sourceControl, channel: rig.keys[0]))
        XCTAssertTrue(app.sourceControlSession(for: .newWindow) === movedSession,
                      "a closed pop-out still claimed the delivery")

        // And a pop-out that is another tab's is not this delivery's capture: `lastPopOut` is one
        // slot over every tab, so accepting it would send a commit to whichever channel Files was
        // last opened for.
        app.panels.popOut(.files, channel: rig.keys[0])
        XCTAssertTrue(app.sourceControlSession(for: .newWindow) === movedSession,
                      "a Files pop-out claimed a Source Control delivery")
    }

    /// An invented forty-character hash. It names no commit in any repository, which is what makes
    /// the notice above the deterministic answer (§11).
    private static let hash = "0123456789abcdef0123456789abcdef01234567"

    /// The initialiser spawns the Files pair and the Source Control target, so a bounded wait is
    /// what a test has. A count, never a target (§11).
    private func waitForInitTargets(_ app: AppModel,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            if await app.panels.links.targetCount >= 3 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the tabs registered in the initialiser never registered their link targets",
                file: file, line: line)
    }
}
