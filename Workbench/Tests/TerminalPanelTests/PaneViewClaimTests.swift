import AppKit
import FleetKit
import Foundation
import PanelHostAPI
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
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)

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
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)

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
    ///
    /// Both hosts are in a window, because that is what makes the survivor one: a container in no
    /// window is not somewhere the pane can be seen, and the hand-off passes over it.
    func testAnOutgoingContainerHandsTheSurfaceToTheHostThatStillStands() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let surviving = representable.makeContainer()
        let outgoing = representable.makeContainer()
        root.addSubview(surviving)
        root.addSubview(outgoing)
        window = PaneTestChild.window(around: root)

        // The survivor is laid out first, while the outgoing container is still the one holding
        // the view: it is not eligible to take it, and it does not.
        surviving.adoptIfUnheld(surface.view)
        XCTAssertTrue(surface.view.superview === outgoing, "the newest host does not hold the surface")

        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === surviving,
                      "the outgoing host left the pane attached to nothing")
    }

    /// The debt is discharged by the grant and not by the attempt. A window can refuse to move the
    /// keyboard — the responder holding it declines to resign, which is an editor with a sheet up
    /// or a field mid-validation — and `makeFirstResponder` says so in its answer. Clearing the
    /// debt before reading that answer left the pane with no keyboard and nothing left owing, so
    /// neither the next layout nor the window arriving ever tried again.
    func testAFocusRequestTheWindowRefusesIsStillOwedAndPaidByTheNextAttempt() {
        let surface = GhosttyTerminalSurface()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let stubborn = StubbornResponder(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let container = PaneSurfaceContainer(frame: NSRect(x: 0, y: 100, width: 600, height: 400))
        root.addSubview(stubborn)
        root.addSubview(container)
        window = PaneTestChild.window(around: root)
        window?.makeFirstResponder(stubborn)
        XCTAssertTrue(window?.firstResponder === stubborn, "the test did not begin with the focus held")

        container.adopt(surface.view)

        XCTAssertTrue(window?.firstResponder === stubborn, "the window moved a focus it was refusing")
        XCTAssertTrue(container.owesSurfaceFocus, "a refused focus request was written off as paid")
        XCTAssertEqual(container.focusHandoffCount, 0, "handoffs=\(container.focusHandoffCount)")

        // The responder lets go, and the container is put into a window again — the next attempt.
        stubborn.yields = true
        container.removeFromSuperview()
        root.addSubview(container)

        XCTAssertFalse(container.owesSurfaceFocus, "the debt outlived the attempt that paid it")
        XCTAssertEqual(container.focusHandoffCount, 1, "handoffs=\(container.focusHandoffCount)")
        let responder = window?.firstResponder as? NSView
        XCTAssertTrue(responder === surface.view || responder?.isDescendant(of: surface.view) == true,
                      "the pane never got the keyboard the window had refused it")
    }

    /// And a window that refuses once and then never moves.
    ///
    /// `viewDidMoveToWindow` was the only thing that asked again, so a container already sitting in
    /// its window — which is every container after the first layout pass — never retried, and
    /// `adoptIfUnheld` returns at once because the surface is still attached to it. The debt stood
    /// for ever in a window nothing moved it out of, and the pane never got the keyboard.
    ///
    /// The container here stays exactly where it is; what comes round is an ordinary layout pass.
    func testARefusedFocusRequestIsRetriedByTheNextLayoutWithoutMovingWindows() throws {
        let surface = GhosttyTerminalSurface()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let stubborn = StubbornResponder(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let container = PaneSurfaceContainer(frame: NSRect(x: 0, y: 100, width: 600, height: 400))
        root.addSubview(stubborn)
        root.addSubview(container)
        window = PaneTestChild.window(around: root)
        window?.makeFirstResponder(stubborn)
        XCTAssertTrue(window?.firstResponder === stubborn, "the test did not begin with the focus held")

        container.adopt(surface.view)
        XCTAssertTrue(container.owesSurfaceFocus, "a refused focus request was written off as paid")
        let stationary = try XCTUnwrap(container.window, "the container was in no window to be refused by")

        // The responder lets go, and the pane is laid out again — a resize, a divider dragged, a
        // status bar appearing under it. Nothing puts the container into a window: it is in one.
        stubborn.yields = true
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.window === stationary, "the container left the window that refused it")
        XCTAssertFalse(container.owesSurfaceFocus, "the debt outlived the layout that paid it")
        XCTAssertEqual(container.focusHandoffCount, 1, "handoffs=\(container.focusHandoffCount)")
        let responder = window?.firstResponder as? NSView
        XCTAssertTrue(responder === surface.view || responder?.isDescendant(of: surface.view) == true,
                      "the pane never got the keyboard the window had refused it")
    }

    /// Which of two standing hosts the view goes to is the newest, which is what the top of a
    /// claimant stack means — and it is a fact about registration order, not about which container
    /// happened to be made first. Asserted in the order the existing hand-off test does not cover:
    /// two hosts still standing, and the older of them must not take it.
    func testTheHandOffGoesToTheNewestHostThatStillStands() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let older = representable.makeContainer()
        let newer = representable.makeContainer()
        let outgoing = representable.makeContainer()
        root.addSubview(older)
        root.addSubview(newer)
        root.addSubview(outgoing)
        window = PaneTestChild.window(around: root)

        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === newer, "the hand-off passed over the newest standing host")
    }

    /// A host that lost the surface to a newer one and was then dismantled is gone, and the stack
    /// has to know it. Its own teardown removes nothing — the view is not its to remove — so a
    /// forget that sat below that guard left it standing in the list for ever, and the next
    /// hand-off chose it: SwiftUI had already taken its view apart, so the window that really was
    /// drawing the pane drew nothing at all.
    func testAHostDismantledEarlierIsNotHandedTheSurface() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let surviving = representable.makeContainer()
        let dismantled = representable.makeContainer()
        let outgoing = representable.makeContainer()
        root.addSubview(surviving)
        root.addSubview(dismantled)
        root.addSubview(outgoing)
        window = PaneTestChild.window(around: root)

        // The middle host goes away while the newest one holds the view: it removes nothing,
        // correctly, and that is the whole of what it does.
        dismantled.relinquish(surface.view)
        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === surviving,
                      "the surface was handed to a host that had already been dismantled")
    }

    /// And a host in no window is not somewhere a pane can be seen. SwiftUI may release a container
    /// without dismantling it, and a hand-off to one leaves the pane attached to a view hierarchy
    /// nothing draws while the window that is still showing the tab shows an empty pane.
    func testAHostInNoWindowIsNotHandedTheSurface() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        let surviving = representable.makeContainer()
        // Registered over the same surface and never put in a window — the newest entry in the
        // stack, and the one place the view must not go.
        let windowless = representable.makeContainer()
        let outgoing = representable.makeContainer()
        root.addSubview(surviving)
        root.addSubview(outgoing)
        window = PaneTestChild.window(around: root)
        XCTAssertNil(windowless.window, "the test did not begin with a host outside every window")

        outgoing.relinquish(surface.view)

        XCTAssertTrue(surface.view.superview === surviving,
                      "the surface was handed to a host that is in no window")
    }

    /// The whole pop-out transition, and who is owed the keyboard at each step of it.
    ///
    /// Popping the tab out **is** a person asking for this pane: they asked for a window whose whole
    /// content is it. So the first container mounted for a popped-out surface takes the keyboard,
    /// once. The main window's host rebuilt when that window closes takes nothing, because a claim
    /// coming back is the window system and not a person. And popping out again is a fresh asking.
    ///
    /// Walked through the real claim path — every host here registers, mounts and is taken apart the
    /// way SwiftUI does it — rather than by hand-mounting containers.
    func testEachPopOutTakesTheKeyboardAndTheClaimComingBackNever() throws {
        let pane = TerminalPane()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        // Stands for whatever the user is typing in; in the app it is the composer, which this
        // target may not import.
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        root.addSubview(composer)
        window = PaneTestChild.window(around: root)

        // Opened in the main window: the pane the user asked for takes the keyboard. They then go
        // back to typing in the composer.
        let mainHost = mount(pane, drawnIn: .panel, under: root)
        XCTAssertEqual(mainHost.container.focusHandoffCount, 1, "the pane the user opened never took the keyboard")
        window?.makeFirstResponder(composer)

        // Popped out. The main host loses the claim and draws the statement, which is SwiftUI
        // dropping its container; the pop-out's container is the one the user asked for.
        let firstPopOut = mount(pane, drawnIn: Self.poppedOutWindow, under: root)
        dropContainer(of: mainHost)
        XCTAssertFalse(mainHost.holder.holdsView(of: pane), "the main window still claims to draw a popped-out pane")
        XCTAssertEqual(firstPopOut.container.focusHandoffCount, 1,
                       "popping the tab out did not take the keyboard: handoffs=\(firstPopOut.container.focusHandoffCount)")
        // And the debt it issued is the one it paid. A debt left standing would be taken by
        // whichever host mounted next — which is the main window's, when this window closes.
        XCTAssertFalse(pane.focusDebt.isStanding, "the pop-out left a debt standing for the next host")

        // The user goes back to the composer, and then closes the pop-out. The claim returns to the
        // main host, and SwiftUI builds it the container it no longer had.
        window?.makeFirstResponder(composer)
        unmount(firstPopOut)
        XCTAssertTrue(mainHost.holder.holdsView(of: pane), "the claim did not return when the pop-out closed")
        let returned = mainHost.representable.makeContainer()
        root.addSubview(returned)
        XCTAssertTrue(window?.firstResponder === composer,
                      "a claim returning from a closed pop-out took the composer's keyboard")
        XCTAssertEqual(returned.focusHandoffCount, 0, "handoffs=\(returned.focusHandoffCount)")

        // And popping out a second time is a person asking a second time.
        let secondPopOut = mount(pane, drawnIn: Self.poppedOutWindow, under: root)
        XCTAssertEqual(secondPopOut.container.focusHandoffCount, 1,
                       "a second pop-out did not take the keyboard: handoffs=\(secondPopOut.container.focusHandoffCount)")
        let responder = window?.firstResponder as? NSView
        XCTAssertTrue(responder === pane.surface.view || responder?.isDescendant(of: pane.surface.view) == true,
                      "the pane the user popped out again never got the keyboard")
    }

    /// A pane returning from a closed pop-out owes the user nothing.
    ///
    /// The previous rule protected a surviving *container*, and after a pop-out there is none: while
    /// the popped-out window held the claim the main host drew the statement and dropped its
    /// container, so what SwiftUI builds when the pop-out closes is a **new** main-window
    /// representable — and its `makeContainer()` is the focus-taking adoption. The user was typing
    /// in the composer and the next keystroke went into a live client.
    ///
    /// Walked through the real claim path rather than two containers by hand: the main host
    /// registers, the pop-out registers over it, the pop-out withdraws, and the claim returns.
    func testAPaneReturningFromAClosedPopOutDoesNotTakeTheComposersKeyboard() throws {
        let pane = TerminalPane()
        let surface = pane.surface
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        // Stands for whatever the user is typing in; in the app it is the composer, which this
        // target may not import.
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        root.addSubview(composer)
        window = PaneTestChild.window(around: root)

        // The user opens the pane. The main window's host registers a claim and mounts a container,
        // and that container is the one the pane owes the keyboard to.
        let mainHost = PaneClaimHolder()
        mainHost.register(for: pane)
        let mainRepresentable = PaneSurfaceView(surface: surface, focus: pane.focusDebt, drawnIn: .panel)
        let opened = mainRepresentable.makeContainer()
        root.addSubview(opened)
        XCTAssertEqual(opened.focusHandoffCount, 1, "the pane the user opened never took the keyboard")

        // The tab is popped out: the pop-out's host takes the claim, so the main host draws the
        // statement instead — which is SwiftUI dismantling its container.
        let poppedOutHost = PaneClaimHolder()
        poppedOutHost.register(for: pane)
        XCTAssertFalse(mainHost.holdsView(of: pane), "the main window still claims to draw a popped-out pane")
        let poppedOutRepresentable = PaneSurfaceView(surface: surface, focus: pane.focusDebt,
                                                     drawnIn: Self.poppedOutWindow)
        let poppedOut = poppedOutRepresentable.makeContainer()
        root.addSubview(poppedOut)
        PaneSurfaceView.dismantleNSView(opened, coordinator: mainRepresentable.makeCoordinator())
        opened.removeFromSuperview()

        // And the user goes back to the composer while the pop-out is up.
        window?.makeFirstResponder(composer)
        XCTAssertTrue(window?.firstResponder === composer,
                      "the test did not reach the pop-out with the focus in the composer")

        // The pop-out closes. Its host withdraws, its container is dismantled, the claim comes back
        // to the main host — and SwiftUI builds that host a container it never had.
        poppedOutHost.withdraw()
        PaneSurfaceView.dismantleNSView(poppedOut, coordinator: poppedOutRepresentable.makeCoordinator())
        poppedOut.removeFromSuperview()
        XCTAssertTrue(mainHost.holdsView(of: pane), "the claim did not return when the pop-out closed")
        let returned = mainRepresentable.makeContainer()
        root.addSubview(returned)

        XCTAssertTrue(surface.view.superview === returned,
                      "the returning pane was not attached to the main window's new host")
        XCTAssertTrue(window?.firstResponder === composer,
                      "a pane returning from a closed pop-out took the composer's keyboard")
        XCTAssertEqual(returned.focusHandoffCount, 0, "handoffs=\(returned.focusHandoffCount)")
    }

    /// The hand-off is not the user asking for this pane. A pop-out closing while the user is
    /// typing in the composer moves the surface back to the main window's host, and a host that
    /// asked for the keyboard on the way in would send the next keystrokes into a live client.
    ///
    /// Only the adoption that answers a request for the pane takes the focus; this one takes the
    /// view and leaves the keyboard exactly where the user put it.
    func testAHandOffToASurvivingHostLeavesTheKeyboardWhereItWas() {
        let surface = GhosttyTerminalSurface()
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
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
        let representable = PaneSurfaceView(surface: surface, focus: .owedOnce(), drawnIn: .panel)
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

    // MARK: One mounted host

    /// A window the user popped this tab out into. Every identifier in it is invented (§11).
    private static let poppedOutWindow = PanelSurface.poppedOutWindow(
        tab: .terminal,
        channel: ChannelKey(
            configHome: PaneTestContext.configHome,
            session: SessionID(uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        )
    )

    /// Everything one mounted host is: the claim it registered, the representable SwiftUI built for
    /// it, and the container that representable made.
    private struct MountedHost {
        let holder: PaneClaimHolder
        let representable: PaneSurfaceView
        let container: PaneSurfaceContainer
    }

    /// A host appearing: it registers a claim, and its representable makes the container that goes
    /// into the window. The order is SwiftUI's.
    private func mount(_ pane: TerminalPane, drawnIn: PanelSurface, under root: NSView) -> MountedHost {
        let holder = PaneClaimHolder()
        holder.register(for: pane)
        let representable = PaneSurfaceView(surface: pane.surface, focus: pane.focusDebt, drawnIn: drawnIn)
        let container = representable.makeContainer()
        root.addSubview(container)
        return MountedHost(holder: holder, representable: representable, container: container)
    }

    /// A host that is still mounted but no longer holds the claim: it draws the statement instead,
    /// so its container is dismantled and its claim stays where it is.
    private func dropContainer(of host: MountedHost) {
        PaneSurfaceView.dismantleNSView(host.container, coordinator: host.representable.makeCoordinator())
        host.container.removeFromSuperview()
    }

    /// A host going away entirely — the popped-out window closing.
    private func unmount(_ host: MountedHost) {
        host.holder.withdraw()
        dropContainer(of: host)
    }
}

/// A responder that keeps the keyboard until it is told to let go. `makeFirstResponder` answers
/// false while it holds, which is a window refusing a request rather than granting it — the one
/// thing a container cannot learn any other way.
private final class StubbornResponder: NSView {
    var yields = false

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool { yields }
}
