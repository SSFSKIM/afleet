import Foundation
import Observation

/// The one state machine over the four routes, and the only thing the window observes.
///
/// It owns no launch logic of its own: `launch()` runs `LaunchSequence` and stores what it
/// returned. That division is what lets *Check again* on the setup and upgrade screens be the same
/// call as the first launch, and what lets the whole sequence be tested without a window.
@MainActor
@Observable
final class AppModel {
    private(set) var route: AppRoute = .launching

    /// The sequence, with its seams. Production values by default; a test replaces the ones it
    /// cares about.
    var sequence: LaunchSequence

    /// The registrar that turns each listed entry into a `Fleet.register(_:cwd:recent:)` and owns
    /// the fleet browser's model. A seam rather than a direct construction because the cold-launch
    /// test replaces the thing that records registrations without replacing the sequence that drives
    /// it.
    var coordinatorFactory: @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating

    /// The coordinator the last successful launch built, kept so the app can reach it.
    private(set) var coordinator: (any WorkspaceCoordinating)?

    /// The fleet browser's model, when the last launch reached a workspace. The window's sidebar
    /// reads it; Tasks 5, 6, 8 and 9 all arrive here.
    var browser: FleetBrowserModel? { (coordinator as? FleetCoordinator)?.model }

    /// Settings' readout over the workspace the last launch reached, built once so the scene does
    /// not make a new one on every body evaluation.
    private(set) var settingsReadout: SettingsReadout?

    init(sequence: LaunchSequence = LaunchSequence(),
         coordinatorFactory: @escaping @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating = { FleetCoordinator(workspace: $0) }) {
        self.sequence = sequence
        self.coordinatorFactory = coordinatorFactory
    }

    /// Runs the launch and routes on its outcome. Re-entrant by design: *Check again* calls it
    /// again, and it starts nothing that would have to be torn down first, because every route
    /// that offers *Check again* is one where no store, no fleet and no watcher was constructed.
    func launch() async {
        route = .launching
        var configured = sequence
        let factory = coordinatorFactory
        configured.makeCoordinator = { [weak self] workspace in
            // *Check again* runs the whole sequence again, so a previous launch's coordinator is
            // stopped before this one replaces it. Leaving it alive would leave a second `updates`
            // loop reading the same stream into a model nothing draws.
            self?.coordinator?.stop()
            let coordinator = factory(workspace)
            self?.coordinator = coordinator
            return coordinator
        }
        route = await configured.run()
        settingsReadout = route.workspace.map(SettingsReadout.init(workspace:))
    }
}
