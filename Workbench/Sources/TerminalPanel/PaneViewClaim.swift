// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import Foundation
import Observation
import PanelHostAPI

/// Which mounted host holds a pane's `NSView`, when the host retains one session per (tab,
/// channel) and hands it to every renderer of that pair — after a pop-out, two (spec Design §8).
///
/// An `NSView` lives in one view hierarchy at a time, so a representable that simply returned the
/// surface's view would move it to whichever window laid out last and blank the other, silently.
/// The rule instead: a **claimant stack**, whose top holds the view. A host that does not hold it
/// draws a plain statement that the pane is showing in another window. The pane's process, its
/// read loop and its buffer are untouched — only the view moves.
///
/// A stack and not a single token, because a token loses the pane for good: the pop-out takes it,
/// the main window's host stays mounted showing the statement, and when the pop-out closes there
/// is nobody to hand the claim back to. Withdrawal is identity-checked and never pops the top,
/// because SwiftUI may run the new host's `makeNSView` before the old host's `dismantleNSView`.
///
/// It is model state so gate G4.3 can be witnessed without two windows.
@MainActor
@Observable
public final class PaneViewClaim {

    /// A mounted host's place in the stack. Opaque and value-typed: what a holder needs is a name
    /// for itself that survives being handed through a SwiftUI coordinator.
    public struct Claimant: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private var claimants: [Claimant] = []

    public init() {}

    /// The claimant currently holding the view, or `nil` while no host is mounted.
    public var holder: Claimant? { claimants.last }

    /// How many hosts are mounted. Diagnostic: it exists so "the stack emptied" is an assertion
    /// rather than a recollection.
    public var claimantCount: Int { claimants.count }

    /// Registers a newly mounted host, which becomes the holder.
    public func register() -> Claimant {
        let claimant = Claimant(id: UUID())
        claimants.append(claimant)
        return claimant
    }

    /// Removes this host wherever it sits, which is the whole of the ordering story: an
    /// out-of-order withdrawal takes the claim from nobody, and a repeated one changes nothing.
    public func withdraw(_ claimant: Claimant) {
        claimants.removeAll { $0 == claimant }
    }

    public func holds(_ claimant: Claimant) -> Bool {
        claimants.last == claimant
    }
}

/// Whether the first host that mounts over a pane is owed the keyboard — and it is owed **once**.
///
/// Taking the focus is a property of *why a container exists*, which is the one thing a container
/// cannot see. A pane a person asked for — the shell pane they opened, the request they ran, the
/// restart they pressed — is a pane they mean to type into, so the first container mounted over it
/// takes the keyboard. Every container after that exists for a reason of the window system's own.
///
/// The debt is the **pane's**, because a claim outlives containers and a container does not outlive
/// a pop-out. While a popped-out window holds the claim the main host draws the statement and drops
/// its container, so when the pop-out closes what SwiftUI builds is a *new* main-window
/// representable: there is no surviving container to recognise, and a rule written about one let
/// that new host take the focus out of the composer the user was typing in.
@MainActor
public final class PaneFocusDebt {

    private var isOwed: Bool

    private init(isOwed: Bool) { self.isOwed = isOwed }

    /// A pane that exists because a person asked for it.
    public static func owedOnce() -> PaneFocusDebt { PaneFocusDebt(isOwed: true) }

    /// A pane nobody is owed the keyboard for.
    public static func settled() -> PaneFocusDebt { PaneFocusDebt(isOwed: false) }

    /// Whether the debt still stands. Diagnostic: it exists so "the first host took it and the
    /// next one did not" is an assertion rather than a recollection.
    public var isStanding: Bool { isOwed }

    /// Takes the debt if it stands, and leaves it settled either way.
    ///
    /// The surface is what says whether this mount is itself a person asking. It is asked here
    /// rather than at the call site because "which mounts mean *type here now*" is one rule and
    /// belongs in one place.
    public func claim(mountedIn surface: PanelSurface) -> Bool {
        // A popped-out window issues the debt it is about to pay. Asking for one *is* asking for
        // this pane: what the person asked for is a window whose whole content is it. Which is a
        // different thing from the claim merely coming back when that window closes — the main
        // window's host is rebuilt there by nobody's request, and takes nothing.
        //
        // Issued here and nowhere else, so it is one debt per mounted host: a re-render updates a
        // container and never makes one, and a pop-out opened again is a new host and a new asking.
        if case .poppedOutWindow = surface { isOwed = true }
        defer { isOwed = false }
        return isOwed
    }
}
