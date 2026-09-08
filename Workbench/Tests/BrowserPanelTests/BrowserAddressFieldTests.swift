import Foundation
import XCTest
@testable import BrowserPanel

/// The address field's two rules (fix wave B, B4 and B5). Every URL is invented (§11).
@MainActor
final class BrowserAddressFieldTests: XCTestCase {

    private static let page = URL(string: "https://invented.example/one")!
    private static let other = URL(string: "https://invented.example/two")!

    // MARK: A draft the page must not take away

    func testAPageThatMovesWhileTheUserIsTypingLeavesTheDraftAlone() {
        var field = BrowserAddressField()
        field.appeared(showing: Self.page)

        field.edited(to: "invented.example/what-the-user-wants")
        field.pageChanged(to: Self.other)

        XCTAssertEqual(field.text, "invented.example/what-the-user-wants",
                       "a background navigation overwrote the address being typed")
    }

    func testThePageFollowsTheFieldAgainOnceTheDraftIsSubmitted() {
        var field = BrowserAddressField()
        field.edited(to: "invented.example/what-the-user-wants")

        field.submitted()
        field.pageChanged(to: Self.other)

        XCTAssertEqual(field.text, Self.other.absoluteString,
                       "the field stopped following the page after a submission")
    }

    func testThePageFollowsTheFieldAgainOnceFocusLeaves() {
        var field = BrowserAddressField()
        field.edited(to: "half an address")

        field.focusEnded()
        field.pageChanged(to: Self.other)

        XCTAssertEqual(field.text, Self.other.absoluteString)
    }

    /// The ordinary case, and the one that makes the guard discriminate: a page that moves while
    /// nobody is typing is what the field is for.
    func testAPageThatMovesWithNoDraftTakesTheField() {
        var field = BrowserAddressField()
        field.appeared(showing: Self.page)

        field.pageChanged(to: Self.other)

        XCTAssertEqual(field.text, Self.other.absoluteString)
    }

    /// A web view between pages reports no URL, which is not an address to show.
    func testAPageWithNoURLDoesNotBlankTheField() {
        var field = BrowserAddressField()
        field.appeared(showing: Self.page)

        field.pageChanged(to: nil)

        XCTAssertEqual(field.text, Self.page.absoluteString)
    }

    // MARK: A field drawn over a page that is already there

    /// B5: the host gives every (tab, channel) pair its own SwiftUI identity, so switching channels
    /// rebuilds this state while the shared page stays exactly where it was. Nothing changes, so a
    /// field that waited for a change would open blank over a page on screen.
    func testAFieldDrawnOverASettledPageOpensOnItsAddress() {
        var field = BrowserAddressField()

        field.appeared(showing: Self.page)

        XCTAssertEqual(field.text, Self.page.absoluteString,
                       "the address bar opened blank over a page that is on screen")
    }

    func testAFieldDrawnWithNoPageOpensEmpty() {
        var field = BrowserAddressField()

        field.appeared(showing: nil)

        XCTAssertEqual(field.text, "")
    }

    /// A redraw is not a reason to lose what is being typed — a channel switch can happen under a
    /// draft as easily as a navigation can.
    func testARedrawDoesNotTakeADraftAway() {
        var field = BrowserAddressField()
        field.edited(to: "invented.example/mid-thought")

        field.appeared(showing: Self.page)

        XCTAssertEqual(field.text, "invented.example/mid-thought")
    }

    // MARK: The selection

    func testSelectingAnotherTabTakesTheFieldToThatTabsAddress() {
        var field = BrowserAddressField()
        field.edited(to: "a draft for the tab being left")

        field.tabChanged(to: Self.other)

        XCTAssertEqual(field.text, Self.other.absoluteString)
        XCTAssertFalse(field.isEditing, "the draft survived the tab it belonged to")
    }

    func testSelectingATabWithNoPageEmptiesTheField() {
        var field = BrowserAddressField()
        field.appeared(showing: Self.page)

        field.tabChanged(to: nil)

        XCTAssertEqual(field.text, "")
    }
}
