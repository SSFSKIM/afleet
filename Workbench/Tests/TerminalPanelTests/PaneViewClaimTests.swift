import Foundation
@testable import TerminalPanel
import XCTest

/// One pane, one window: the claimant stack that decides which mounted host holds a pane's
/// `NSView` and which one says the pane is showing elsewhere (spec Design §8; gate G4.3).
///
/// The claim is model state precisely so this can be asserted without two windows.
@MainActor
final class PaneViewClaimTests: XCTestCase {

    // MARK: Group 2 — the claim

    func testTheNewestClaimantHoldsTheViewAndTheOlderOneReportsItselfUnclaimed() {
        let claim = PaneViewClaim()

        let main = claim.register()
        XCTAssertTrue(claim.holds(main), "the only claimant does not hold the view")

        let poppedOut = claim.register()
        XCTAssertTrue(claim.holds(poppedOut), "the newest claimant does not hold the view")
        XCTAssertFalse(claim.holds(main), "two hosts hold one NSView at once")
    }

    func testWithdrawingTheHolderReturnsTheClaimToTheOneBelowIt() {
        let claim = PaneViewClaim()
        let main = claim.register()
        let poppedOut = claim.register()

        claim.withdraw(poppedOut)

        // A stack and not a token: with a token there is nobody to hand the pane back to, and the
        // main window says "showing in another window" about a window that has closed.
        XCTAssertTrue(claim.holds(main), "the claim did not return to the surviving host")
        XCTAssertFalse(claim.holds(poppedOut), "a withdrawn claimant still holds the view")
    }

    func testWithdrawingOutOfOrderLeavesTheRightSurvivorHolding() {
        let claim = PaneViewClaim()
        let old = claim.register()
        let new = claim.register()

        // SwiftUI may make the new host's view before it dismantles the old one's, so the
        // withdrawal that arrives is the *lower* claimant's. It removes itself where it sits and
        // never pops the top.
        claim.withdraw(old)

        XCTAssertTrue(claim.holds(new), "an out-of-order withdrawal took the claim from the holder")
        XCTAssertFalse(claim.holds(old), "a withdrawn claimant still holds the view")
    }

    func testAClaimantThatNeverHeldTheViewWithdrawingChangesNothing() {
        let claim = PaneViewClaim()
        let holder = claim.register()
        let stranger = claim.register()
        claim.withdraw(stranger)

        claim.withdraw(stranger)

        XCTAssertTrue(claim.holds(holder), "a repeated withdrawal moved the claim")
        XCTAssertEqual(claim.claimantCount, 1, "claimants=\(claim.claimantCount)")
    }

    func testWithdrawingEveryClaimantLeavesNobodyHolding() {
        let claim = PaneViewClaim()
        let first = claim.register()
        let second = claim.register()

        claim.withdraw(second)
        claim.withdraw(first)

        XCTAssertFalse(claim.holds(first), "an unmounted host still holds the view")
        XCTAssertEqual(claim.claimantCount, 0, "claimants=\(claim.claimantCount)")
    }

    // MARK: Group 2b — the claim a mounted host holds, and the pane it holds it against

    /// A host whose pane parameter changes withdraws from the pane it **registered with**.
    ///
    /// SwiftUI reuses a host's `@State` for the next value of its parameters, so a holder that
    /// remembered only its `Claimant` would withdraw against whichever pane it was looking at
    /// last — leaving a claim behind on a stack that now has nobody to hand the view back to.
    func testAHostWhosePaneChangesWithdrawsFromThePaneItRegisteredWith() {
        let holder = PaneClaimHolder()
        let first = TerminalPane()
        let second = TerminalPane()
        holder.register(for: first)

        holder.register(for: second)

        XCTAssertEqual(first.viewClaim.claimantCount, 0,
                       "the first pane kept \(first.viewClaim.claimantCount) claimant(s) after the host moved on")
        XCTAssertEqual(second.viewClaim.claimantCount, 1,
                       "the second pane has \(second.viewClaim.claimantCount) claimants, not 1")
        XCTAssertTrue(holder.holdsView(of: second), "the host does not draw the pane it just registered for")
        XCTAssertFalse(holder.holdsView(of: first), "the host still claims to draw the pane it left")
    }

    /// Switching the selection between two panes: each pane's claim is held by the host that is
    /// showing it, and neither host draws the placeholder.
    ///
    /// This is what the selected pane's subtree identity produces — a selection change tears the
    /// host down and builds a new one rather than reusing the previous pane's state, whose claim
    /// belongs to a stack the pane on screen knows nothing about.
    func testSwitchingTheSelectionLeavesEachPaneHeldByTheHostShowingIt() {
        let first = TerminalPane()
        let second = TerminalPane()

        let showingFirst = PaneClaimHolder()
        showingFirst.register(for: first)
        // The selection moves: the identity changes, so this is a *new* host, not the one above.
        let showingSecond = PaneClaimHolder()
        showingSecond.register(for: second)

        XCTAssertTrue(showingSecond.holdsView(of: second),
                      "the pane the user selected renders the placeholder instead of its surface")
        XCTAssertTrue(showingFirst.holdsView(of: first),
                      "the pane left behind lost its claim to a host drawing another pane")
    }

    /// The placeholder is for a pane genuinely displayed elsewhere, and for nothing else: a second
    /// host over the *same* pane — the pop-out — takes the view, and the first says so.
    func testThePlaceholderAppearsOnlyForAPaneShowingInAnotherHost() {
        let pane = TerminalPane()
        let mainWindow = PaneClaimHolder()
        mainWindow.register(for: pane)
        XCTAssertTrue(mainWindow.holdsView(of: pane), "the only host does not draw the pane")

        let poppedOut = PaneClaimHolder()
        poppedOut.register(for: pane)

        XCTAssertTrue(poppedOut.holdsView(of: pane), "the newest host over one pane does not draw it")
        XCTAssertFalse(mainWindow.holdsView(of: pane), "two hosts draw one NSView at once")

        poppedOut.withdraw()
        XCTAssertTrue(mainWindow.holdsView(of: pane), "the claim did not return when the pop-out closed")
    }

    /// A withdrawal names the pane the registration named, and a repeated one changes nothing.
    func testWithdrawingReleasesThePaneTheHostRegisteredWithAndIsIdempotent() {
        let holder = PaneClaimHolder()
        let pane = TerminalPane()
        holder.register(for: pane)

        holder.withdraw()
        holder.withdraw()

        XCTAssertEqual(pane.viewClaim.claimantCount, 0,
                       "the pane kept \(pane.viewClaim.claimantCount) claimant(s) after its host went away")
        XCTAssertFalse(holder.holdsView(of: pane), "an unmounted host still draws the pane")
    }
}
