import Foundation
import FleetKit

/// The seam through which the composition root hands index results to whoever registers channels
/// (spec §2 step 9, §3).
///
/// The composition root drives it at three points and never at two: the restored snapshot, the
/// completed fresh build, and every watcher delta. A cold launch has no restored snapshot, so a
/// wiring that drove only the warm path would leave a first-ever launch with zero registered
/// supervisors — and `Fleet.events(of:)` returns nil for a key it was never told about, so the
/// symptom would be a sidebar of rows that never come alive.
///
/// `Sendable` beyond the brief's declaration: the composition root runs off the main actor and has
/// to carry the existential across that boundary to reach it. A `@MainActor` class is implicitly
/// `Sendable`, but `any WorkspaceCoordinating` is not unless the protocol says so.
@MainActor
protocol WorkspaceCoordinating: AnyObject, Sendable {
    func snapshotAvailable(_ snapshot: IndexSnapshot, origin: SnapshotOrigin) async
    func indexChanged(_ delta: IndexDelta) async
    /// Ends whatever the coordinator started. `AppModel.launch()` is re-entrant — *Check again* is
    /// the same call as the first launch — so the coordinator a previous launch built is stopped
    /// before a new one replaces it, rather than left with a live `updates` loop nothing reads.
    func stop()
}

extension WorkspaceCoordinating {
    func stop() {}
}

/// Which of the composition root's two snapshots this is.
///
/// The distinction is load-bearing and was not always here. A coordinator that inferred "restored"
/// from "the first snapshot I have seen" is right on a warm launch and wrong on a cold one, where
/// there is no persisted snapshot and the *fresh build* is the first thing to arrive — so a
/// first-ever launch painted every row as provisional and nothing ever cleared it, because the
/// second full snapshot that would have cleared it never comes on that path. The sequence knows
/// which is which; it says so rather than leaving it to be guessed.
enum SnapshotOrigin: Hashable, Sendable {
    /// `loadPersisted()`: last launch's index, painted at once so the window is not empty.
    case restored
    /// `build()`: this launch's own read of the config home.
    case built
}

/// The conformance that registers nothing. `FleetCoordinator` is the real one and is what
/// `AppModel.coordinatorFactory` now builds; this is kept for the tests that assert the composition
/// root drives the seam without asserting anything about what registration does with it.
@MainActor
final class NoopWorkspaceCoordinator: WorkspaceCoordinating {
    init() {}
    func snapshotAvailable(_ snapshot: IndexSnapshot, origin: SnapshotOrigin) async {}
    func indexChanged(_ delta: IndexDelta) async {}
}
