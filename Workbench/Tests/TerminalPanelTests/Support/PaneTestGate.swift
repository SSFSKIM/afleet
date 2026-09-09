import Foundation

/// A suspension a test can stand an entire interleaving inside.
///
/// `Task.yield()` is a scheduling hint and not a rendezvous: a test that yields twice and hopes
/// the work it is racing is still suspended passes just as happily on the run where that work
/// finished first — which is how a witness comes to pass against the very defect it exists to
/// pin. A gate is the opposite: whoever enters it stops there until the test opens it, and
/// ``awaitEntry()`` returns only once someone is genuinely inside.
///
/// The pattern is the store stub's held read, moved to where a pane's teardown suspends.
@MainActor
final class PaneTestGate {

    /// Whether someone is suspended inside the gate right now. It is what lets a test assert
    /// "the restart had not resumed yet" rather than recollect it.
    private(set) var isHolding = false

    private var isOpen = false
    private var held: CheckedContinuation<Void, Never>?
    private var entry: CheckedContinuation<Void, Never>?

    /// Called from inside the work being held. Returns at once once the gate has been opened, so
    /// a second pass through it is not a second suspension.
    func hold() async {
        guard !isOpen else { return }
        isHolding = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            held = continuation
        }
        isHolding = false
    }

    /// Returns once something is suspended in the gate.
    func awaitEntry() async {
        guard !isHolding else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entry = continuation
        }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}
