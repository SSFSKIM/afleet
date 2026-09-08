import Foundation
import Observation
import SwiftUI
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
    @ObservationIgnored private var launchStore: (any StateStore)?
    private(set) var canResetBinaryOverride = false
    private(set) var settingsRecoveryError: String?

    /// Uses only the app store that already passed the launch overlap guard. No engine call,
    /// no workspace prerequisite, and no unrelated preference is reset.
    func resetBinaryOverrideAndRetry() async {
        guard let store = launchStore, canResetBinaryOverride else { return }
        canResetBinaryOverride = false
        settingsRecoveryError = nil
        var settings = await AfleetSettingsStore.read(from: store)
        settings.developer.binaryPathOverride = nil
        do {
            try await AfleetSettingsStore.write(settings, to: store)
        } catch {
            canResetBinaryOverride = true
            settingsRecoveryError = "Could not reset the binary override: \(LaunchSequence.shape(of: error))."
            return
        }
        await launch()
    }

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

    /// The per-channel composers (spec §8.5), one `ComposerModel` and one shared
    /// `ChannelSurfaceState` per channel.
    ///
    /// **One instance, app-scoped**, for the reason the two above are: the channel column draws the
    /// field from here and C6.2's header actions write the surface state from here, and a second
    /// registry would disable a field that is not the one on screen.
    let composers = ComposerRegistry()

    /// Contract Y4's seam: where an `Agent` chip in the timeline navigates to.
    ///
    /// A settable property with a default rather than a construction, the shape `HostLinkRouter`
    /// takes on `PanelHostModel`: one instance, app-scoped, reachable from every surface that needs
    /// it. `NoAgentNavigation` is installed here and does nothing; C6.4 replaces it with the
    /// implementation that selects the Agents tab and its node, and nothing else about the chip's
    /// call site changes when it does.
    var agentNavigation: any AgentNavigating = NoAgentNavigation()

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
        self.coordinatorFactory = coordinatorFactory ?? { [timelines, composers] workspace in
            FleetCoordinator(workspace: workspace, panels: panels, timelines: timelines, composers: composers)
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
        // Contract Y1: this child's two kinds, claimed on the app's one registry. Here rather than
        // in `performLaunch` because registration is synchronous and needs nothing a launch
        // produces — unlike the `.thread` handover above, whose `unregister` is `async` and whose
        // tab cannot answer a card without a lifecycle.
        //
        // **Once per process.** `RowRegistry.register(kind:)` traps on a second claim, which is the
        // contract working: two leaves owning one kind is a breach of the C6 cut. A second
        // `AppModel` is not that — every test that launches builds one — so the claim is guarded by
        // this flag and the trap is left to say the one thing it exists to say.
        if !AppModel.hasClaimedRowKinds {
            AppModel.hasClaimedRowKinds = true
            RowRegistry.shared.register(kind: .decision) { AnyView(DecisionRowView(row: $0)) }
            RowRegistry.shared.register(kind: .sentFile) { AnyView(SentFileRowView(row: $0)) }
        }
    }

    /// Whether this process has already claimed Y1's two kinds. `@MainActor` on the type isolates
    /// it, so the check and the claim cannot interleave.
    private static var hasClaimedRowKinds = false

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
        composers.attach(to: workspace,
                         context: { [panels] key, cwd in panels.context(for: key, cwd: cwd) },
                         timeline: { [timelines] key in timelines.model(for: key) },
                         paneRunner: { [panels] request in try await panels.run(request) },
                         lifecycle: lifecycle)
        // *Fork from here* opens a sibling channel and the window has to move to it, which is C5's own selection
        // path and not a second one. Set after `attach`, which releases the models of the previous workspace.
        composers.selectChannel = { [shell] key in shell.select(key.session) }
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
        launchStore = nil
        canResetBinaryOverride = false
        settingsRecoveryError = nil
        var configured = sequence
        configured.settingsLoaded = { [weak self] store, settings in
            self?.launchStore = store
            self?.canResetBinaryOverride = settings.developer.binaryPathOverride != nil
        }
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
        let reached = await configured.run()
        settingsReadout = reached.workspace.map(SettingsReadout.init(workspace:))
        // Before Activity, so a channel opened by the first paint already has a registry bound to
        // the workspace this launch reached rather than to the one it replaced.
        if let workspace = reached.workspace {
            bindWorkspace(workspace)
            // Contract Y3: `.thread` passes from C5's placeholder to C6.3's Thread tab. Here rather
            // than on `init`'s registration line for two reasons with one answer: `unregister` is
            // `async` — it awaits the link-target withdrawal, so a withdrawal cannot land after the
            // replacement's registration and delete the *new* tab's target — and an initialiser
            // cannot await; and this is the first moment a lifecycle exists, without which the tab
            // can neither answer a card nor post a reply. `unregister` drops the selection when it
            // held it, so the selection is re-taken.
            let wasShowingThread = panels.selected == .thread
            await panels.unregister(.thread)
            do {
                // The tab is handed the app's one timeline registry, through two closures and not
                // as a reference: a decision answered from the Thread tab has to raise
                // `HostSignal.decisionAnswered` on the channel's fold — the engine sends no frame
                // back for an answer, so nothing else moves the item out of `.pending` — and the
                // open thread has to read the item's state from that same fold. This is the one
                // construction site where the app-scoped registry and a lifecycle both exist.
                try panels.register(ThreadTab(lifecycle: workspace.fleet,
                                              fold: ChannelFold(timelines: timelines)))
            } catch {
                assertionFailure("the handover unregistered .thread before registering over it")
            }
            if wasShowingThread { panels.select(.thread) }
        }
        await startActivity(over: reached)
        // **Last.** Publishing the route is what puts the actionable surfaces on screen — the
        // sidebar's Background section and its *Adopt*, every row's action menu — and supervisor
        // events are not replayed. An action taken before Activity's hooks are installed emits its
        // request to nobody: the card loses the payload that would have let it be answered, and a
        // surfaced hook callback can be left with nothing to answer it. Nothing between the
        // sequence returning and this line reaches the user, so the cost is a few more frames of
        // the launch screen and the gain is that no window is ever actionable ahead of Activity.
        route = reached
    }

    /// Builds Activity over the workspace the launch reached, and starts it.
    ///
    /// The order matters: the poster's in-app fallback presents into the model, and the router
    /// posts through the poster, so the model is constructed first and the two are given a weak
    /// reference back to it. Nothing here retains a cycle — `ActivityModel` owns the router, the
    /// router owns the poster, and the poster reaches the model only through a closure that holds
    /// it weakly.
    private func startActivity(over route: AppRoute) async {
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
        // Contract X4 and spec D2: a card answered from Activity raises `decisionAnswered` on the
        // channel's own fold. Activity holds no timeline model — it answers for channels the user
        // has never opened — so it is given the app's one registry as a provider, the shape the
        // composer registry receives its seams in.
        model.timeline = { [timelines] key in timelines.model(for: key) }
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
