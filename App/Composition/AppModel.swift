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

    /// What the window is looking at (spec §6).
    ///
    /// It is owned here rather than by the scene because Activity's notifications have to know
    /// which channel is in view whether or not the Activity view is on screen, and the model that
    /// decides them is built beside this one. `AfleetApp` reads it; the menu items move it.
    let shell = ShellModel()

    /// Activity, the badges and the notification router (spec §5, §6). Nil until a launch reaches a
    /// workspace, and rebuilt by each one — *Check again* is the same call as the first launch, and
    /// a second Activity following the first fleet's channels would notify twice.
    private(set) var activity: ActivityModel?

    /// What the last launch read out of the store. Read once because a notification decided behind
    /// an actor hop arrives after the thing it is about; Settings writing a change takes effect on
    /// the next launch, which is what the Developer section already says of every other preference.
    private var notificationPreferences = NotificationPreferences()

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
        await startActivity()
    }

    /// Builds Activity over the workspace the launch reached, and starts it.
    ///
    /// The order matters: the poster's in-app fallback presents into the model, and the router
    /// posts through the poster, so the model is constructed first and the two are given a weak
    /// reference back to it. Nothing here retains a cycle — `ActivityModel` owns the router, the
    /// router owns the poster, and the poster reaches the model only through a closure that holds
    /// it weakly.
    private func startActivity() async {
        activity?.stop()
        activity = nil
        guard let workspace = route.workspace, let browser else { return }
        notificationPreferences = await AfleetSettingsStore.read(from: workspace.store).notifications

        // A box, because the poster needs the model and the model needs the router that needs the
        // poster. One of the three edges has to be late, and this is the one with nothing to lose:
        // a notification raised before the model exists has no surface to be raised on.
        let sink = ActivitySink()
        let poster = SystemOrInAppPoster { [sink] notification in sink.present(notification) }
        let router = NotificationRouter(poster: poster,
                                        lifecycle: workspace.fleet,
                                        isInView: { [shell] key in shell.focus.session == key.session },
                                        preferences: { [weak self] in
                                            self?.notificationPreferences ?? NotificationPreferences()
                                        })
        let model = ActivityModel(lifecycle: workspace.fleet,
                                  configHome: workspace.configHome.root,
                                  shell: shell,
                                  router: router,
                                  store: workspace.store)
        sink.model = model
        activity = model
        model.attach(to: browser)
        await poster.requestAuthorisation()
        await model.start()
    }
}

/// The late edge of Activity's three-way construction: the poster's in-app fallback presents
/// through this, and the model is set into it once it exists. Weak, so the box never keeps a
/// superseded launch's Activity alive.
@MainActor
final class ActivitySink {
    weak var model: ActivityModel?
    func present(_ notification: AfleetNotification) { model?.present(notification) }
}
