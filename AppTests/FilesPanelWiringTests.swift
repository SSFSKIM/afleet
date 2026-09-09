import Foundation
import XCTest
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.5 T8: the two lines this leaf adds to the app — the tab's registration (spec Design §10)
/// and Cmd+S's target (Design §7, Parent revision 1).
///
/// Every identifier is invented and every tree is built under the process's temporary directory
/// by `PanelRig`; no assertion names a path or carries a buffer (§6.3, §11).
@MainActor
final class FilesPanelWiringTests: XCTestCase {

    /// Design §10: `AppModel.init` registers `FilesTab` beside C5's placeholder, so a freshly
    /// built model can show Files on any channel with nothing else having run first.
    func testTheAppRegistersTheFilesTabAndBuildsItsSession() throws {
        let app = AppModel()

        XCTAssertTrue(app.panels.isRegistered(.files), "the app model does not hold the Files tab")
        XCTAssertEqual(app.panels.title(for: .files), PanelTabID.files.defaultTitle,
                       "the registered tab is not named by its own title")
        XCTAssertEqual(app.panels.available(for: PanelFixtures.context()), [.thread, .files, .browser],
                       "the channel does not offer exactly the shipped tabs")
        XCTAssertTrue(app.panels.session(for: .files, context: PanelFixtures.context())
                        is FilesPanelSession,
                      "the host built something other than the Files panel's session")
    }

    /// Design §9: the tab's two link targets exist from the moment the tab is registered, not from
    /// the first time somebody looks at Files. The host builds a session lazily, for rendering, so
    /// a registration that waited for one would leave every `.file` and `.diff` link raised before
    /// the first visit resolving to nothing.
    func testTheFilesLinkTargetsAreRegisteredBeforeThePanelIsEverDisplayed() async throws {
        let app = AppModel()

        try await waitUntilRegistered(app)
        XCTAssertEqual(app.panels.liveSessionCount, 0,
                       "registering the targets brought a session into being")
    }

    /// Design §9's mitigation of tracker 240, as the app runs it: the delivery goes to the channel
    /// the **host** is showing, resolved through the host's own session lookup at the moment of
    /// delivery — not to whichever session a view rendered last. And a `.currentPanel` delivery
    /// brings Files forward, so a routed file does not open behind the tab that is up.
    func testADeliveredFileLinkOpensInTheShownChannelAndBringsFilesForward() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let left = try rig.temp.directory("left")
        let shown = try rig.temp.directory("shown")
        let file = try rig.temp.file("shown/notes.swift", "let a = 1\n")
        let leftContext = try XCTUnwrap(app.panels.context(for: rig.keys[0], cwd: left))
        let shownContext = try XCTUnwrap(app.panels.context(for: rig.keys[1], cwd: shown))
        // The window drew Files for the first channel, then moved to the second with Thread up.
        _ = app.panels.view(for: .files, context: leftContext, surface: .panel)
        app.panels.focusChannel(rig.keys[1])
        app.panels.select(.thread)
        try await waitUntilRegistered(app)

        await app.panels.links.open(.file(file, line: nil), from: .currentPanel)

        let shownSession = try XCTUnwrap(app.panels.session(for: .files, context: shownContext)
                                            as? FilesPanelSession)
        let leftSession = try XCTUnwrap(app.panels.session(for: .files, context: leftContext)
                                            as? FilesPanelSession)
        XCTAssertEqual(shownSession.openFiles.count, 1,
                       "the link did not reach the channel the window is showing")
        XCTAssertEqual(leftSession.openFiles.count, 0,
                       "the link followed the last render rather than the window")
        XCTAssertEqual(app.panels.selected, .files,
                       "a delivered link opened into a tab nobody could see")
    }

    /// The registration is spawned from `AppModel.init`, so a bounded wait is what a test has.
    /// A count, never a target (§11).
    private func waitUntilRegistered(_ app: AppModel,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            if await app.panels.links.targetCount == 2 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the Files tab's two link targets never registered", file: file, line: line)
    }

    /// Design §7: Cmd+S reaches the Files session of the channel the main window is showing, is
    /// offered only when Files is the selected tab, and is enabled only over a dirty buffer.
    ///
    /// The last two assertions are the side-effect clause: a channel the host has never rendered
    /// has no context, so computing whether the menu item is enabled cannot bring a session into
    /// being for it.
    func testTheSaveCommandTargetsTheFilesSessionTheMainWindowIsShowing() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let project = try rig.temp.directory("project")
        let file = try rig.temp.file("project/notes.swift", "let a = 1\n")
        let key = rig.keys[0]
        let context = try XCTUnwrap(app.panels.context(for: key, cwd: project))
        let session = try XCTUnwrap(app.panels.session(for: .files, context: context)
                                        as? FilesPanelSession)

        XCTAssertNil(app.filesSaveTarget(inFocused: nil), "the window is on no channel and Files is not selected")
        app.panels.focusChannel(key)
        XCTAssertNil(app.filesSaveTarget(inFocused: nil), "another tab's selection offered the Files save target")
        app.panels.select(.files)
        XCTAssertTrue(app.filesSaveTarget(inFocused: nil) === session,
                      "Cmd+S did not reach the session the window is showing")

        XCTAssertFalse(app.canSaveFiles(inFocused: nil), "Save is enabled with no dirty buffer")
        await session.openFile(at: file, line: nil)
        let surface = StubEditorSurface()
        session.attach(surface)
        surface.onEvent?(.dirty(path: try XCTUnwrap(session.selected).path, isDirty: true))
        XCTAssertTrue(app.canSaveFiles(inFocused: nil), "Save is disabled over a dirty buffer")

        app.panels.focusChannel(rig.keys[1])
        XCTAssertNil(app.filesSaveTarget(inFocused: nil), "a channel the host never rendered produced a save target")
        XCTAssertEqual(app.panels.liveSessionCount, 1,
                       "resolving the save target created a session")
    }

    /// Tracker 243: Cmd+S resolves against the **key window**, and a popped-out Files panel keeps a
    /// channel of its own. Resolving it from the main window's selection alone makes a focused
    /// pop-out save another channel, or offers nothing at all while a dirty buffer is on screen in
    /// front of the user.
    func testTheSaveCommandResolvesAgainstTheFocusedWindowRatherThanTheMainSelection() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let poppedTree = try rig.temp.directory("popped")
        let mainTree = try rig.temp.directory("main")
        let file = try rig.temp.file("popped/notes.swift", "let a = 1\n")
        let popped = try XCTUnwrap(app.panels.context(for: rig.keys[0], cwd: poppedTree))
        let shown = try XCTUnwrap(app.panels.context(for: rig.keys[1], cwd: mainTree))
        let poppedSession = try XCTUnwrap(app.panels.session(for: .files, context: popped)
                                            as? FilesPanelSession)
        let shownSession = try XCTUnwrap(app.panels.session(for: .files, context: shown)
                                            as? FilesPanelSession)
        app.panels.popOut(.files, channel: rig.keys[0])
        app.panels.focusChannel(rig.keys[1])
        app.panels.select(.files)
        let window = PoppedOutPanel(tab: .files, channel: rig.keys[0])

        XCTAssertTrue(app.filesSaveTarget(inFocused: window) === poppedSession,
                      "Cmd+S in a popped-out window reached another window's channel")
        XCTAssertTrue(app.filesSaveTarget(inFocused: nil) === shownSession,
                      "with the main window key, Cmd+S left the channel it is showing")
        XCTAssertNil(app.filesSaveTarget(inFocused: PoppedOutPanel(tab: .thread, channel: rig.keys[0])),
                     "a pop-out that is not the Files panel offered the Files save target")

        // Enablement follows the same window: the dirty buffer is the pop-out's, and the main
        // window's channel has none.
        await poppedSession.openFile(at: file, line: nil)
        let surface = StubEditorSurface()
        poppedSession.attach(surface)
        surface.onEvent?(.dirty(path: try XCTUnwrap(poppedSession.selected).path, isDirty: true))
        XCTAssertTrue(app.canSaveFiles(inFocused: window),
                      "Save was disabled over the dirty buffer in the key window")
        XCTAssertFalse(app.canSaveFiles(inFocused: nil),
                       "Save was enabled from another window's dirty buffer")

        app.panels.closePopOut(window)
        XCTAssertNil(app.filesSaveTarget(inFocused: window),
                     "a window that is closed still offered a save target")
    }

    /// Design §9's other half of tracker 240's mitigation: a `.newWindow` delivery belongs to the
    /// channel its own window was popped out for.
    ///
    /// The router captures that channel when the action is taken, precisely because routing
    /// suspends twice before the handler runs and the main actor is free throughout. Presenting
    /// the window is where the window is free to move, so the move is staged from there: the
    /// pop-out for the first channel happens, the selection leaves for the second, and the file
    /// must still land in the channel whose window was opened for it.
    func testANewWindowDeliveryOpensInTheChannelItsWindowWasPoppedOutFor() async throws {
        let rig = try await PanelRig(channels: 2)
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let file = try rig.temp.file("popped/notes.swift", "let a = 1\n")
        let popped = try XCTUnwrap(app.panels.context(for: rig.keys[0],
                                                      cwd: try rig.temp.directory("popped")))
        let moved = try XCTUnwrap(app.panels.context(for: rig.keys[1],
                                                     cwd: try rig.temp.directory("moved")))
        let poppedSession = try XCTUnwrap(app.panels.session(for: .files, context: popped)
                                            as? FilesPanelSession)
        let movedSession = try XCTUnwrap(app.panels.session(for: .files, context: moved)
                                            as? FilesPanelSession)
        app.panels.focusChannel(rig.keys[0])
        app.panels.presentWindow = { [weak app] _ in app?.panels.focusChannel(rig.keys[1]) }
        try await waitUntilRegistered(app)

        await app.panels.links.open(.file(file, line: nil), from: .newWindow)

        XCTAssertEqual(poppedSession.openFiles.count, 1,
                       "the link did not reach the channel its own window was popped out for")
        XCTAssertEqual(movedSession.openFiles.count, 0,
                       "the link followed the channel the window had moved on to")
        XCTAssertEqual(app.panels.selected, .thread,
                       "a link that asked for its own window moved the main panel's selection")
    }
}

/// The editor seam, recording nothing: the only event this file delivers is the dirty flag, and
/// what the session sends back is asserted in the package's own tests.
@MainActor
private final class StubEditorSurface: EditorSurface {
    var onEvent: (@MainActor @Sendable (EditorEvent) -> Void)?
    func send(_ command: EditorCommand) {}
}
