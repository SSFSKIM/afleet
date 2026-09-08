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

    // MARK: - The navigation a message belongs to

    /// What the view is told, or `nil` when the message was dropped.
    private func delivered(
        _ arrival: BridgeSendState.Arrival
    ) -> (event: EditorEvent, drained: [EditorCommand])? {
        if case let .deliver(event, drained) = arrival { return (event, drained) }
        return nil
    }

    private func body(_ fields: [String: Any], generation: Int) -> [String: Any] {
        fields.merging(["generation": generation]) { _, new in new }
    }

    /// A page the view has navigated away from is not gone the moment `load()` returns: its
    /// scripts keep running until WebKit tears the document down, and anything it posted before
    /// that is still on its way. A `ready` from it marks the *new* page ready and drains the
    /// queue into a document that never received it; a `saveRequested` from it offers the host a
    /// buffer belonging to a file the view has stopped showing, which is a stale write.
    func testMessagesFromThePreviousNavigationAreDropped() {
        var state = BridgeSendState()
        state.loading()
        let outgoing = state.generation
        _ = state.ready(defaultTheme: "vs")
        state.loading()
        XCTAssertNil(state.send(.open(path: "notes/one.txt", language: "plaintext", text: "a\n", line: nil)),
                     "the reload did not put the bridge back in its not-ready state")

        XCTAssertNil(delivered(state.receive(body(["type": "ready"], generation: outgoing),
                                             defaultTheme: "vs")),
                     "a ready from the outgoing page marked the new navigation ready")
        XCTAssertNil(delivered(state.receive(body(["type": "saveRequested",
                                                   "path": "notes/one.txt", "text": "a\n"],
                                                  generation: outgoing),
                                             defaultTheme: "vs")),
                     "a saveRequested from the outgoing page was offered to the host for writing")
        XCTAssertNil(state.send(.gotoLine(line: 2, column: nil)),
                     "the outgoing page's ready drained the queue into the new navigation")
    }

    /// The other half: the page now on screen is heard, and its `ready` releases the queue the
    /// stale one was refused.
    func testTheCurrentNavigationIsHeardAndDrainsTheQueue() {
        var state = BridgeSendState()
        state.loading()
        _ = state.send(.open(path: "notes/one.txt", language: "plaintext", text: "a\n", line: nil))

        let arrival = delivered(state.receive(body(["type": "ready"], generation: state.generation),
                                              defaultTheme: "vs"))
        XCTAssertEqual(arrival?.event, .ready)
        XCTAssertEqual(arrival?.drained,
                       [.setTheme(name: "vs"),
                        .open(path: "notes/one.txt", language: "plaintext", text: "a\n", line: nil)])
    }

    /// A message with no generation at all belongs to no navigation this view started, so it is
    /// dropped rather than trusted — the stamp is what attribution rests on.
    func testAnUnstampedMessageIsDropped() {
        var state = BridgeSendState()
        state.loading()

        XCTAssertNil(delivered(state.receive(["type": "ready"], defaultTheme: "vs")),
                     "an unstamped message was attributed to the current navigation")
    }

    /// An undecodable body is still reported, and still names only its `type`.
    func testAnUndecodableBodyFromTheCurrentNavigationIsReported() {
        var state = BridgeSendState()
        state.loading()

        XCTAssertEqual(state.receive(body(["type": "dirty", "path": "notes/one.txt"],
                                          generation: state.generation), defaultTheme: "vs"),
                       .undecodable(type: "dirty"))
    }
}
