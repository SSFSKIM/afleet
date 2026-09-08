// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import Foundation
import Observation

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
