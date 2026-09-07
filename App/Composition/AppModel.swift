import Foundation
import Observation
import FleetKit

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
    let shell: ShellModel

    /// The per-channel timeline owners (spec §8), one `ChannelTimelineModel` per channel.
    ///
    /// **One instance, app-scoped, and every consumer reads it from here** — `ChannelColumnView`
    /// draws the model this registry holds and the panel host's recent-URL feed reads that same
    /// model. A second registry constructed in either place would leave the Browser observing a
    /// timeline that ingestion never touches, and no unit test over either half alone could see it.
    ///
    /// It outlives a launch: `attach(to:)` rebinds it to the workspace the launch reached and
    /// releases every model built over the previous one.
    let timelines = ChannelTimelineRegistry()

    /// Contract X7's host (spec §7), the app's only conformance to `PanelHost`.
    ///
    /// **One instance, app-scoped**, for the same reason the registry above is: the panel column
    /// resolves its context from here, a popped-out window resolves the *same* context from here by
    /// key, and `FleetCoordinator` releases a removed channel's sessions here. A second host would
    /// hand a popped-out window a different session for the channel it is drawing, and the recent-URL
    /// feed in its context would watch a timeline nothing updates.
    let panels: PanelHostModel

    /// Activity, the badges and the notification router (spec §5, §6). Nil until a launch reaches a
    /// workspace, and rebuilt by each one — *Check again* is the same call as the first launch, and
    /// a second Activity following the first fleet's channels would notify twice.
    private(set) var activity: ActivityModel?

    /// What the last launch read out of the store. Read once because a notification decided behind
    /// an actor hop arrives after the thing it is about; Settings writing a change takes effect on
    /// the next launch, which is what the Developer section already says of every other preference.
    private var notificationPreferences = NotificationPreferences()

    /// The notification authorisation request the last launch started. Held rather than discarded:
    /// it outlives `startActivity` by design and a dropped task is a request nobody can account
    /// for. Nothing waits on it — see `ActivityLaunch`.
    private var authorisationRequest: Task<Bool, Never>?

    /// Shared by every window until launch and workspace binding have both completed.
    private var launchTask: Task<Void, Never>?

    /// `coordinatorFactory` defaults to nil rather than to a literal closure because the production
    /// coordinator has to be handed *this* model's panel host — a delta that removed a channel
    /// releases that channel's panel sessions — and a default argument cannot reach `self`.
    init(sequence: LaunchSequence = LaunchSequence(),
         coordinatorFactory: (@MainActor @Sendable (Workspace) -> any WorkspaceCoordinating)? = nil) {
        let panels = PanelHostModel()
        self.panels = panels
        self.shell = ShellModel(panels: panels)
        self.sequence = sequence
        self.coordinatorFactory = coordinatorFactory ?? { [timelines] workspace in
            FleetCoordinator(workspace: workspace, panels: panels, timelines: timelines)
        }
        // C5's one shipped tab, under `.thread`. C6 takes that id by `unregister(.thread)` and then
        // its own `register`; `register` refuses a duplicate, so the pair is the handover.
        //
        // Not `try?`. On a host constructed one line above this cannot throw, and the only way it
        // could is a future initialiser registering something first — in which case the placeholder
        // would vanish with no signal, and the tab C6 hands itself is the last thing that should
        // disappear quietly.
        do {
            try panels.register(PlaceholderTab())
            panels.select(.thread)
        } catch {
            assertionFailure("the placeholder is the first registration on a freshly built host")
        }
    }

    /// Binds the two app-scoped, workspace-dependent owners to the workspace a launch reached.
    ///
    /// One call rather than two at the call site, because the pair is a unit: the host reads the
    /// registry for every context's recent-URL feed, and a host bound to one workspace's registry
    /// while the registry was rebound to another is exactly the split the single instances exist to
    /// prevent. `lifecycle` is the seam pane exits leave through; production passes nil and gets
    /// `workspace.fleet`.
    func bindWorkspace(_ workspace: Workspace, lifecycle: (any LifecycleAPI)? = nil) {
        timelines.attach(to: workspace, lifecycle: lifecycle)
        panels.attach(to: workspace, timelines: timelines, lifecycle: lifecycle)
    }

    /// Runs the launch and routes on its outcome. Concurrent windows await the same task;
    /// they must not build independent stores, fleets or watcher pumps.
    /// Sequential retry is supported for *Check again* on setup/upgrade routes, where no
    /// workspace (and therefore no fleet or watcher) was constructed.
    func launch() async {
        if let launchTask {
            await launchTask.value
            return
        }
        // Main-actor isolation installs the task before another caller can enter. Only its
        // creator clears it, after binding and Activity setup, so joiners await the whole launch.
        let task = Task { await performLaunch() }
        launchTask = task
        await task.value
        launchTask = nil
    }

    private func performLaunch() async {
        route = .launching
        var configured = sequence
        let factory = coordinatorFactory
        configured.makeCoordinator = { [weak self] workspace in
            // If a caller explicitly replaces a workspace, retire its browser loop before
            // replacing the coordinator. This is not launch deduplication: the shared task
            // above prevents concurrent launches from creating abandoned workspace pumps.
            self?.coordinator?.stop()
            let coordinator = factory(workspace)
            self?.coordinator = coordinator
            return coordinator
        }
        route = await configured.run()
        settingsReadout = route.workspace.map(SettingsReadout.init(workspace:))
        // Before Activity, so a channel opened by the first paint already has a registry bound to
        // the workspace this launch reached rather than to the one it replaced.
        if let workspace = route.workspace { bindWorkspace(workspace) }
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
                                        isInView: { [shell] key in shell.isInView(key) },
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
        // Activity first, authorisation after and not awaited here — see `ActivityLaunch`.
        authorisationRequest = await ActivityLaunch.begin(model, requesting: poster)
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
