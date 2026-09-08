import AppKit
import Foundation
import GhosttyTerminal
import TerminalCore
import XCTest

@MainActor
private final class CollisionSurfaceStub: TerminalCore.TerminalSurface {
    let view = NSView()
    var onInput: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (TerminalSize) -> Void)?
    let terminalDescription = TerminalDescription(term: "stub-terminal")

    func feed(_ output: Data) {}
    func processDidExit(code: Int32) {}
    func setAppearance(_ appearance: TerminalAppearance) {}
}

final class NameCollisionTests: XCTestCase {
    @MainActor
    func testCoreProtocolAndDependencyClassCanBothBeNamedAndUsed() {
        let coreSurface: any TerminalCore.TerminalSurface = CollisionSurfaceStub()
        let dependencyType: GhosttyTerminal.TerminalSurface.Type =
            GhosttyTerminal.TerminalSurface.self

        XCTAssertTrue(coreSurface.view === coreSurface.view, "TerminalCore.TerminalSurface=absent")
        XCTAssertTrue(
            ObjectIdentifier(type(of: coreSurface)) != ObjectIdentifier(dependencyType),
            "GhosttyTerminal.TerminalSurface=absent"
        )
    }

    func testDefaultAppearanceFollowsSystemAndLeavesFontUnspecified() {
        let appearance = TerminalAppearance()

        XCTAssertTrue(appearance.themeName == nil, "system-theme-default=absent")
        XCTAssertTrue(appearance.fontName == nil, "system-font-default=absent")
        XCTAssertTrue(appearance.fontSize == nil, "system-font-size-default=absent")
    }
}
