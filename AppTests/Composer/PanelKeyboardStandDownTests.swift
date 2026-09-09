import AppKit
import XCTest
@testable import Afleet

/// Tracker 350: the composer's Escape and Shift+Tab stand down while the panel holds the keyboard.
///
/// The defect these discriminate against is not a wrong answer inside the composer — it is a
/// binding that exists at all. A `.keyboardShortcut` is a command-table entry, and a command table
/// is consulted before the key event reaches the first responder, so a Terminal pane running a
/// full-screen TUI never saw Escape however correctly it handled it. Each test therefore points a
/// real window's keyboard at a real view and then asks the bar what it is offering.
///
/// **Headless, on a window built here.** Nothing is made key — an XCTest process cannot arrange
/// that — so the window is handed to `refresh(in:)`, which is the same call production makes with
/// `NSApp.keyWindow`. The AppKit hierarchy is built flat, one level under the content view, because
/// that is how SwiftUI lays representables out: measured on this machine, a marker installed as a
/// panel's `.background` is a *sibling* of the pane's surface and not its ancestor, which is why the
/// region carries a rect.
@MainActor
final class PanelKeyboardStandDownTests: XCTestCase {

    /// A view that can hold the keyboard and nothing else.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The main window's shape: a composer field on the left, a panel column on the right with a
    /// pane inside its rect, and the region over the column.
    private struct MainWindowRig {
        let window: NSWindow
        let field: FocusableView
        let pane: FocusableView
        let region: PanelKeyboardRegionView
    }

    private func makeMainWindow(_ focus: PanelKeyboardFocus) -> MainWindowRig {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let field = FocusableView(frame: NSRect(x: 20, y: 20, width: 300, height: 80))
        let region = PanelKeyboardRegionView()
        region.frame = NSRect(x: 480, y: 0, width: 320, height: 600)
        region.focus = focus
        let pane = FocusableView(frame: NSRect(x: 500, y: 40, width: 280, height: 500))
        content.addSubview(field)
        content.addSubview(region)
        content.addSubview(pane)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = content
        focus.register(region)
        return MainWindowRig(window: window, field: field, pane: pane, region: region)
    }

    func testPaneHoldingTheKeyboardTakesBothOrdinaryKeysFromTheComposer() {
        let focus = PanelKeyboardFocus()
        let rig = makeMainWindow(focus)

        XCTAssertTrue(rig.window.makeFirstResponder(rig.pane))
        focus.refresh(in: rig.window)

        XCTAssertTrue(focus.keyboardIsInPanel)
        let offered = ComposerShortcutBar.offered(keyboardIsInPanel: focus.keyboardIsInPanel)
        XCTAssertFalse(offered.contains(.interrupt),
                       "Escape must reach the pane's child, not interrupt the turn")
        XCTAssertFalse(offered.contains(.cyclePermissionMode),
                       "Shift+Tab must reach the pane's child, not cycle the permission mode")
        XCTAssertNil(ComposerShortcutBar.binding(.interrupt, offered: offered))
        XCTAssertNil(ComposerShortcutBar.binding(.cyclePermissionMode, offered: offered))
        // The panic stop is a Command chord no terminal child competes for, and it stays.
        XCTAssertTrue(offered.contains(.stopEverything))
        XCTAssertNotNil(ComposerShortcutBar.binding(.stopEverything, offered: offered))
    }

    func testComposerFieldHoldingTheKeyboardKeepsBothKeys() {
        let focus = PanelKeyboardFocus()
        let rig = makeMainWindow(focus)

        XCTAssertTrue(rig.window.makeFirstResponder(rig.field))
        focus.refresh(in: rig.window)

        XCTAssertFalse(focus.keyboardIsInPanel)
        let offered = ComposerShortcutBar.offered(keyboardIsInPanel: focus.keyboardIsInPanel)
        XCTAssertTrue(offered.contains(.interrupt))
        XCTAssertTrue(offered.contains(.cyclePermissionMode))
        XCTAssertNotNil(ComposerShortcutBar.binding(.interrupt, offered: offered))
        XCTAssertNotNil(ComposerShortcutBar.binding(.cyclePermissionMode, offered: offered))
    }

    func testFocusMovingBetweenFieldAndPaneFlipsWhatIsOffered() {
        let focus = PanelKeyboardFocus()
        let rig = makeMainWindow(focus)
        var seen: [Bool] = []

        for target in [rig.field, rig.pane, rig.field, rig.pane] as [NSView] {
            XCTAssertTrue(rig.window.makeFirstResponder(target))
            focus.refresh(in: rig.window)
            seen.append(focus.keyboardIsInPanel)
        }

        XCTAssertEqual(seen, [false, true, false, true])
        XCTAssertEqual(ComposerShortcutBar.offered(keyboardIsInPanel: seen[0]).count, 3)
        XCTAssertEqual(ComposerShortcutBar.offered(keyboardIsInPanel: seen[1]), [.stopEverything])
    }

    func testAPoppedOutPanelWindowCountsAsThePanelEvenWithNoViewFocused() {
        let focus = PanelKeyboardFocus()
        let main = makeMainWindow(focus)
        XCTAssertTrue(main.window.makeFirstResponder(main.field))
        focus.refresh(in: main.window)
        XCTAssertFalse(focus.keyboardIsInPanel)

        // The pop-out holds nothing but a panel, so its region spans the window.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let region = PanelKeyboardRegionView()
        region.spansWindow = true
        region.frame = content.bounds
        region.focus = focus
        content.addSubview(region)
        let poppedOut = NSWindow(contentRect: content.frame, styleMask: [.titled],
                                 backing: .buffered, defer: false)
        poppedOut.contentView = content
        focus.register(region)

        focus.refresh(in: poppedOut)
        XCTAssertTrue(focus.keyboardIsInPanel)
        XCTAssertEqual(ComposerShortcutBar.offered(keyboardIsInPanel: focus.keyboardIsInPanel),
                       [.stopEverything])

        // And the main window is still its own answer: the fact follows the key window.
        focus.refresh(in: main.window)
        XCTAssertFalse(focus.keyboardIsInPanel)
    }

    func testAWithdrawnRegionLeavesTheKeyboardOutsideThePanel() {
        let focus = PanelKeyboardFocus()
        let rig = makeMainWindow(focus)
        XCTAssertTrue(rig.window.makeFirstResponder(rig.pane))
        focus.refresh(in: rig.window)
        XCTAssertTrue(focus.keyboardIsInPanel)

        // The channel moved to Activity: the column is gone and nothing is a panel any more, even
        // though the view that held the keyboard is still in the window.
        focus.withdraw(rig.region)
        focus.refresh(in: rig.window)
        XCTAssertFalse(focus.keyboardIsInPanel)
        XCTAssertEqual(ComposerShortcutBar.offered(keyboardIsInPanel: focus.keyboardIsInPanel).count, 3)
    }

    func testNoWindowAndNoResponderAreBothOutsideThePanel() {
        let focus = PanelKeyboardFocus()
        let rig = makeMainWindow(focus)

        XCTAssertFalse(PanelKeyboardFocus.isInPanel(window: nil, regions: [rig.region]))
        // The window itself as first responder: nothing in it holds the keyboard.
        XCTAssertTrue(rig.window.makeFirstResponder(nil))
        XCTAssertFalse(PanelKeyboardFocus.isInPanel(window: rig.window, regions: [rig.region]))
    }
}
