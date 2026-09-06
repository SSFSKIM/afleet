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

    /// **Task 4 replaces this** with the registrar that turns each listed entry into a
    /// `Fleet.register(_:cwd:recent:)`. Task 3's default registers nothing, which is why the
    /// coordinator seam is declared here and filled there rather than left to fall between them.
    var coordinatorFactory: @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating

    /// The coordinator the last successful launch built, kept so the app can reach it.
    private(set) var coordinator: (any WorkspaceCoordinating)?

    init(sequence: LaunchSequence = LaunchSequence(),
         coordinatorFactory: @escaping @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating = { _ in NoopWorkspaceCoordinator() }) {
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
            let coordinator = factory(workspace)
            self?.coordinator = coordinator
            return coordinator
        }
        route = await configured.run()
    }
}
