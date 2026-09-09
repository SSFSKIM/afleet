import AppKit
import Foundation
import TerminalCore
@testable import TerminalPanel
import XCTest

/// One pane, one window: the claimant stack that decides which mounted host holds a pane's
/// `NSView` and which one says the pane is showing elsewhere (spec Design §8; gate G4.3).
///
/// The claim is model state precisely so this can be asserted without two windows.
@MainActor
final class PaneViewClaimTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

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

    // MARK: Group 2c — the AppKit container under the claim

    /// The claim decides which host is *eligible* to render a pane; it says nothing about where
    /// the surface's `NSView` is attached. A representable that handed SwiftUI the surface's view
    /// itself gave two hosts one object, so when their lifetimes overlap the outgoing host's
    /// teardown removes the view the incoming host has already taken, and `updateNSView` — which
    /// is handed that same shared view — has nothing to repair it with.
    ///
    /// Each representable takes a container of its own; the surface's view moves into the newest
    /// one, and a container only ever removes a view it is still holding.
    func testEachRepresentableTakesItsOwnContainerAndTheOutgoingOneLeavesTheIncomingAlone() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface)

        let outgoing = representable.makeContainer()
        let incoming = representable.makeContainer()

        XCTAssertFalse(outgoing === incoming, "two hosts were handed one AppKit view")
        XCTAssertTrue(surface.view.superview === incoming, "the newest host does not hold the surface")

        // The overlap: SwiftUI dismantles the outgoing host after the incoming one is made.
        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === incoming,
                      "the outgoing host's teardown removed the view the incoming host holds")
    }

    /// A pane the user just asked for is a pane they mean to type into. The claim moves and the
    /// view is attached, but nothing was made first responder — so the keystrokes went on reaching
    /// whatever held the focus before, the composer, and the new pane sat there looking ready.
    ///
    /// The host that takes the surface is the one that asks for the focus, because it is the only
    /// thing that knows the view has just moved to it.
    func testAHostThatTakesTheSurfaceTakesTheKeyboardWithIt() {
        let surface = GhosttyTerminalSurface()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        // Stands for whatever held the focus when the pane was asked for; in the app it is the
        // composer, which this target may not import.
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let container = PaneSurfaceContainer(frame: NSRect(x: 0, y: 100, width: 600, height: 400))
        root.addSubview(elsewhere)
        root.addSubview(container)
        window = PaneTestChild.window(around: root)
        window?.makeFirstResponder(elsewhere)
        XCTAssertTrue(window?.firstResponder === elsewhere, "the test did not begin with the focus elsewhere")

        container.adopt(surface.view)

        let responder = window?.firstResponder as? NSView
        XCTAssertFalse(responder === elsewhere, "the keyboard stayed where it was when the pane opened")
        XCTAssertTrue(responder === surface.view || responder?.isDescendant(of: surface.view) == true,
                      "the host that took the surface did not make it first responder")
    }

    /// The same request from a container that is not in a window yet, which is every container
    /// SwiftUI makes: it still owes the focus, and pays it when the window arrives.
    func testAHostAdoptingBeforeItHasAWindowStillTakesTheKeyboardWhenOneArrives() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface)

        let container = representable.makeContainer()
        XCTAssertTrue(container.owesSurfaceFocus, "a host that took the surface did not ask for the focus")

        window = PaneTestChild.window(around: container)

        XCTAssertFalse(container.owesSurfaceFocus, "the focus request was never paid once a window existed")
        XCTAssertEqual(container.focusHandoffCount, 1, "handoffs=\(container.focusHandoffCount)")
    }

    /// The reversed ordering, which the repair arm alone does not cover: the surviving host is
    /// laid out **before** the outgoing one is dismantled.
    ///
    /// `updateNSView` only adopts a surface nobody holds, so a survivor that updates while the
    /// outgoing container still has the view does nothing — and the outgoing container then takes
    /// the view out with nobody left to notice, leaving the pane blank until some later update
    /// that may never come. Relinquishing hands the view on instead of merely dropping it.
    func testAnOutgoingContainerHandsTheSurfaceToTheHostThatStillStands() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface)
        let surviving = representable.makeContainer()
        let outgoing = representable.makeContainer()

        // The survivor is laid out first, while the outgoing container is still the one holding
        // the view: it is not eligible to take it, and it does not.
        surviving.adoptIfUnheld(surface.view)
        XCTAssertTrue(surface.view.superview === outgoing, "the newest host does not hold the surface")

        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === surviving,
                      "the outgoing host left the pane attached to nothing")
    }

    /// The hand-off is not the user asking for this pane. A pop-out closing while the user is
    /// typing in the composer moves the surface back to the main window's host, and a host that
    /// asked for the keyboard on the way in would send the next keystrokes into a live client.
    ///
    /// Only the adoption that answers a request for the pane takes the focus; this one takes the
    /// view and leaves the keyboard exactly where the user put it.
    func testAHandOffToASurvivingHostLeavesTheKeyboardWhereItWas() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        // Stands for whatever the user is typing in; in the app it is the composer, which this
        // target may not import.
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let surviving = representable.makeContainer()
        let outgoing = representable.makeContainer()
        root.addSubview(elsewhere)
        root.addSubview(surviving)
        root.addSubview(outgoing)
        window = PaneTestChild.window(around: root)
        window?.makeFirstResponder(elsewhere)
        XCTAssertTrue(window?.firstResponder === elsewhere, "the test did not begin with the focus elsewhere")

        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === surviving, "the hand-off did not reach the surviving host")
        XCTAssertTrue(window?.firstResponder === elsewhere,
                      "the hand-off took the keyboard out of what the user was typing in")
        XCTAssertEqual(surviving.focusHandoffCount, 0, "handoffs=\(surviving.focusHandoffCount)")
    }

    /// And the repair arm is not a request either: a host putting back a view nobody holds is
    /// answering a layout, not a person.
    func testARepairingHostTakesTheSurfaceAndNotTheKeyboard() {
        let surface = GhosttyTerminalSurface()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let container = PaneSurfaceContainer(frame: NSRect(x: 0, y: 100, width: 600, height: 400))
        root.addSubview(elsewhere)
        root.addSubview(container)
        window = PaneTestChild.window(around: root)
        window?.makeFirstResponder(elsewhere)
        XCTAssertTrue(window?.firstResponder === elsewhere, "the test did not begin with the focus elsewhere")

        container.adoptIfUnheld(surface.view)

        XCTAssertTrue(surface.view.superview === container, "the repair arm did not take the unheld view")
        XCTAssertTrue(window?.firstResponder === elsewhere,
                      "a host repairing an unheld view took the keyboard with it")
        XCTAssertEqual(container.focusHandoffCount, 0, "handoffs=\(container.focusHandoffCount)")
    }

    /// A container that has lost the surface to a newer host removes nothing when it goes away,
    /// and a host mounted while nobody holds the view takes it back.
    func testAContainerRemovesOnlyAViewItStillHoldsAndRepairsAnUnheldOne() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface)
        let container = representable.makeContainer()

        container.relinquish(surface.view)
        XCTAssertNil(surface.view.superview, "the container that held the view did not release it")

        let repaired = PaneSurfaceContainer()
        repaired.adoptIfUnheld(surface.view)
        XCTAssertTrue(surface.view.superview === repaired, "no host took an unheld surface view")

        // And a host laid out again never pulls the view out of the one that has it now.
        container.adoptIfUnheld(surface.view)
        XCTAssertTrue(surface.view.superview === repaired, "a re-laid-out host stole the surface back")
    }
}
