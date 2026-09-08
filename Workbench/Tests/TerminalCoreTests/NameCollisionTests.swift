import AppKit
import Foundation
import GhosttyTerminal
import TerminalCore
import XCTest

final class NameCollisionTests: XCTestCase {
    /// `TerminalCore` and `GhosttyTerminal` both ship a type called `TerminalSurface`, and the
    /// adapter is the one place where the two names meet. What has to hold is not that the names
    /// differ — the compiler settles that — but that the *shipped* adapter is unambiguously the
    /// core protocol's conformer and not the dependency's type.
    ///
    /// The subject is bound as `AnyObject` on purpose: through that binding the casts are runtime
    /// questions, so an adapter that stopped conforming, or a `TerminalSurface` that resolved to
    /// the dependency, fails here instead of merely changing what compiles.
    @MainActor
    func testShippedAdapterIsTheCoreProtocolAndNotTheDependencyType() {
        let shipped: AnyObject = GhosttyTerminalSurface()

        XCTAssertTrue(
            shipped is any TerminalCore.TerminalSurface,
            "shipped-adapter-core-conformance=absent"
        )
        XCTAssertFalse(
            shipped is GhosttyTerminal.TerminalSurface,
            "shipped-adapter=dependency-type"
        )

        guard let surface = shipped as? any TerminalCore.TerminalSurface,
              let adapter = shipped as? GhosttyTerminalSurface
        else {
            XCTFail("shipped-adapter-core-conformance=absent")
            return
        }
        // Dispatch through the existential has to reach the shipped adapter's own storage, which
        // is what makes the conformance load-bearing rather than merely declared.
        surface.onInput = { _ in }
        XCTAssertTrue(adapter.onInput != nil, "core-protocol-witness=not-the-shipped-adapter")
        XCTAssertTrue(surface.view === adapter.view, "core-protocol-view=not-the-shipped-view")
    }

    func testDefaultAppearanceFollowsSystemAndLeavesFontUnspecified() {
        let appearance = TerminalAppearance()

        XCTAssertTrue(appearance.themeName == nil, "system-theme-default=absent")
        XCTAssertTrue(appearance.fontName == nil, "system-font-default=absent")
        XCTAssertTrue(appearance.fontSize == nil, "system-font-size-default=absent")
    }
}
