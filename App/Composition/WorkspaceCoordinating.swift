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
    func snapshotAvailable(_ snapshot: IndexSnapshot) async
    func indexChanged(_ delta: IndexDelta) async
}

/// The conformance that registers nothing. `FleetCoordinator` is the real one and is what
/// `AppModel.coordinatorFactory` now builds; this is kept for the tests that assert the composition
/// root drives the seam without asserting anything about what registration does with it.
@MainActor
final class NoopWorkspaceCoordinator: WorkspaceCoordinating {
    init() {}
    func snapshotAvailable(_ snapshot: IndexSnapshot) async {}
    func indexChanged(_ delta: IndexDelta) async {}
}
