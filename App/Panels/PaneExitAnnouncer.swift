import Foundation
import FleetKit

/// When a pane afleet asked for has ended, for the one surface that has to act **after** the pane
/// rather than after the request (§14 item 47, tracker 314).
///
/// **Why this exists at all.** `PanelHost.run(_:for:)` returns when the pane *starts* — it hands the
/// request to the registered runner, which spawns and returns — and the exit travels back later,
/// through the context's `reportPaneExit` into `LifecycleAPI.paneExited`. Everything about a hatch
/// is fine with that: X5 owns the re-adoption and the channel comes back on its own. §6.11's trust
/// review is the one case where an *app* surface owes something to the exit: trust is granted in the
/// engine's own dialog inside that pane, nothing afleet holds changes when it is, and the verdict
/// can only be re-read from the global config document afterwards. Re-reading when `run` returns
/// reads it before the user has answered the dialog.
///
/// **It is the exit report and not a timer, and not a second source of truth.** The announcement is
/// teed off the very closure that already carries the exit to X5, after X5 has been told, so there
/// is one path and this is a listener on it. Nothing polls and nothing waits on a duration.
///
/// A caller declares the id it cares about *before* the pane runs, because a spawn that never
/// executes is reported at once — the panel synthesises exit code 127 — and a wait armed afterwards
/// would have missed it. Only declared ids are remembered and a satisfied wait forgets its own, so
/// what this holds is bounded by the panes in flight rather than by the panes that have ever run —
/// which is why a second announcement of an id already waited for does nothing, and is how a test
/// can see the bound without this type growing an accessor for it.
actor PaneExitAnnouncer {

    private var expected: Set<UUID> = []
    private var ended: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init() {}

    /// Declares that `id`'s exit will be waited for. Called before the pane is run.
    func expect(_ id: UUID) {
        expected.insert(id)
    }

    /// One exit, after X5 has been told about it. An id nobody declared is dropped.
    func announce(_ exit: PaneExit) {
        let id = exit.request.id
        guard expected.contains(id) else { return }
        ended.insert(id)
        for continuation in waiters.removeValue(forKey: id) ?? [] { continuation.resume() }
    }

    /// Returns when `id`'s pane has ended — at once if it already has.
    ///
    /// Returns at once for an id nobody declared as well, which is the safe direction: a caller
    /// whose `expect` never ran would otherwise wait for ever on a pane whose exit this object was
    /// never told to keep.
    func whenExited(_ id: UUID) async {
        guard expected.contains(id) else { return }
        if ended.remove(id) != nil {
            expected.remove(id)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
        expected.remove(id)
        ended.remove(id)
    }
}
