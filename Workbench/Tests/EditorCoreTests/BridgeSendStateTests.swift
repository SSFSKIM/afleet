import XCTest

@testable import EditorCore

/// What `MonacoEditorView` owes the bridge the moment it says `ready`.
///
/// A reload — a navigation, a crashed web content process, the S3 harness re-running a route —
/// builds a **fresh** Monaco instance, whose theme is Monaco's own default `vs`. Everything the
/// host had told the previous instance is gone, so anything the view is still holding on the
/// host's behalf has to be said again.
final class BridgeSendStateTests: XCTestCase {

    /// The first `ready` of a view the host has not themed follows the system appearance.
    func testTheFirstReadyFollowsTheSystemAppearance() {
        var state = BridgeSendState()

        XCTAssertEqual(state.ready(defaultTheme: "vs-dark"), [.setTheme(name: "vs-dark")])
    }

    /// The defect: only "the host has set a theme" survived a reload, not *which* theme. The
    /// fresh instance is `vs`, the view sends nothing because it believes the host owns the
    /// theme, and a dark editor comes back light.
    func testAnExplicitThemeIsSentAgainAfterAReload() {
        var state = BridgeSendState()
        _ = state.ready(defaultTheme: "vs")
        _ = state.send(.setTheme(name: "hc-black"))

        state.loading()

        XCTAssertEqual(state.ready(defaultTheme: "vs"), [.setTheme(name: "hc-black")],
                       "the reload left the host's theme on the previous Monaco instance")
    }

    /// The other half of the same state: a view the host never themed keeps following the
    /// appearance across a reload, rather than latching onto whatever it sent first.
    func testAViewTheHostNeverThemedStillFollowsTheAppearanceAfterAReload() {
        var state = BridgeSendState()
        _ = state.ready(defaultTheme: "vs")

        state.loading()

        XCTAssertEqual(state.ready(defaultTheme: "vs-dark"), [.setTheme(name: "vs-dark")])
        XCTAssertEqual(state.appearanceChanged(defaultTheme: "vs"), .setTheme(name: "vs"),
                       "the view stopped following the appearance without the host asking")
    }

    /// A theme the host sent before `ready` is already in the queue, so the replay must not add
    /// a second one: `ready` releases each command once.
    func testAThemeQueuedBeforeReadyIsSentOnce() {
        var state = BridgeSendState()
        XCTAssertNil(state.send(.setTheme(name: "vs-dark")), "a command before ready was not queued")

        XCTAssertEqual(state.ready(defaultTheme: "vs"), [.setTheme(name: "vs-dark")])
    }

    /// Once the host owns the theme, the system appearance no longer moves it — before or after
    /// a reload.
    func testAnExplicitThemeSilencesTheAppearanceAcrossAReload() {
        var state = BridgeSendState()
        _ = state.ready(defaultTheme: "vs")
        _ = state.send(.setTheme(name: "hc-black"))
        state.loading()
        _ = state.ready(defaultTheme: "vs")

        XCTAssertNil(state.appearanceChanged(defaultTheme: "vs-dark"))
    }

    /// Commands sent while the bridge is not live are released in order behind the theme.
    func testQueuedCommandsAreReleasedInOrderBehindTheTheme() {
        var state = BridgeSendState()
        XCTAssertNil(state.send(.open(path: "notes/one.txt", language: "plaintext", text: "a\n", line: nil)))
        XCTAssertNil(state.send(.gotoLine(line: 4, column: nil)))

        XCTAssertEqual(
            state.ready(defaultTheme: "vs"),
            [
                .setTheme(name: "vs"),
                .open(path: "notes/one.txt", language: "plaintext", text: "a\n", line: nil),
                .gotoLine(line: 4, column: nil),
            ])
        XCTAssertEqual(state.send(.save), .save, "a command after ready was queued instead of sent")
    }
}
