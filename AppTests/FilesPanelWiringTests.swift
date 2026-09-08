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
        XCTAssertEqual(app.panels.available(for: PanelFixtures.context()), [.thread, .files],
                       "the channel does not offer exactly the two shipped tabs")
        XCTAssertTrue(app.panels.session(for: .files, context: PanelFixtures.context())
                        is FilesPanelSession,
                      "the host built something other than the Files panel's session")
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

        XCTAssertNil(app.filesSaveTarget, "the window is on no channel and Files is not selected")
        app.panels.focusChannel(key)
        XCTAssertNil(app.filesSaveTarget, "another tab's selection offered the Files save target")
        app.panels.select(.files)
        XCTAssertTrue(app.filesSaveTarget === session,
                      "Cmd+S did not reach the session the window is showing")

        XCTAssertFalse(app.canSaveFiles, "Save is enabled with no dirty buffer")
        await session.openFile(at: file, line: nil)
        let surface = StubEditorSurface()
        session.attach(surface)
        surface.onEvent?(.dirty(path: try XCTUnwrap(session.selected).path, isDirty: true))
        XCTAssertTrue(app.canSaveFiles, "Save is disabled over a dirty buffer")

        app.panels.focusChannel(rig.keys[1])
        XCTAssertNil(app.filesSaveTarget, "a channel the host never rendered produced a save target")
        XCTAssertEqual(app.panels.liveSessionCount, 1,
                       "resolving the save target created a session")
    }
}

/// The editor seam, recording nothing: the only event this file delivers is the dirty flag, and
/// what the session sends back is asserted in the package's own tests.
@MainActor
private final class StubEditorSurface: EditorSurface {
    var onEvent: (@MainActor @Sendable (EditorEvent) -> Void)?
    func send(_ command: EditorCommand) {}
}
