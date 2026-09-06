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

/// Task 3's conformance, so the app builds and the composition root has something to drive.
/// **Task 4 ships the real one** — the registrar that turns each listed entry into a
/// `Fleet.register(_:cwd:recent:)` — and wires it into `AppModel.coordinatorFactory`.
@MainActor
final class NoopWorkspaceCoordinator: WorkspaceCoordinating {
    init() {}
    func snapshotAvailable(_ snapshot: IndexSnapshot) async {}
    func indexChanged(_ delta: IndexDelta) async {}
}
