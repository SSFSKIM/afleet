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
}
