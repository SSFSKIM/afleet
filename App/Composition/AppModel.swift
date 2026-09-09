import Foundation
import Observation
import SwiftUI
import FleetKit
import Workbench

/// The one state machine over the four routes, and the only thing the window observes.
///
/// It owns no launch logic of its own: `launch()` runs `LaunchSequence` and stores what it
/// returned. That division is what lets *Check again* on the setup and upgrade screens be the same
/// call as the first launch, and what lets the whole sequence be tested without a window.
@MainActor
@Observable
final class AppModel: FilesTabHost {
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

    /// The one set of in-flight decision reservations, and the one place a settled answer is
    /// announced (contract Y2).
    ///
    /// **One instance, app-scoped**, for a reason the registry above shares: a request the engine is
    /// waiting on is answerable exactly once, and the surfaces that can answer it — Activity's row,
    /// the Thread tab, the timeline's card — each hold their own `DecisionAnswering`. A set per host
    /// disables only the host that clicked, so two of them reach the wire and the second is refused;
    /// and the host holding the request's payload never hears about an answer another surface sent.
    let decisions = DecisionReservations()

    /// Contract X7's host (spec §7), the app's only conformance to `PanelHost`.
    ///
    /// **One instance, app-scoped**, for the same reason the registry above is: the panel column
    /// resolves its context from here, a popped-out window resolves the *same* context from here by
    /// key, and `FleetCoordinator` releases a removed channel's sessions here. A second host would
    /// hand a popped-out window a different session for the channel it is drawing, and the recent-URL
    /// feed in its context would watch a timeline nothing updates.
    let panels: PanelHostModel

    /// C7.4's map from a channel to its Terminal panes.
    ///
    /// **One instance, and it is the whole point of the property.** The registered tab and the
    /// registered pane runner are two objects, and each of them asks this for a channel's session:
    /// a registry per owner would leave the host rendering one session while a `PaneRequest` placed
    /// its pane in another, so the pane would exist and no window would ever draw it. It is held
    /// here rather than inside either owner because neither of them can be the one that owns it.
    let terminalSessions = TerminalSessionRegistry()
    /// C7.6's Browser tab, and through it the one window-wide `BrowserModel` (spec §9.4, Q5).
    ///
    /// **One instance, app-scoped**, like the three owners above it: the tab set is shared across
    /// channels and across the main and popped-out windows, and a second `BrowserTab` would be a
    /// second set of web views for the same pages.
    let browserTab: BrowserTab

    /// Where the Browser's tab-set document goes. Bound to the workspace a launch reached, because
    /// the tab is registered before any launch has run.
    private let browserStore: DeferredWorkbenchStore

    /// Q15's inspection policy, mirrored out of the settings document by each launch.
    private let webInspector: WebInspectorSwitch

    /// Whether the Browser's two link targets are in the registry. `launch()` runs again on *Check
    /// again*, and a second pass that registered them again would leave two indistinguishable
    /// targets per link kind, tying on specificity.
    private var browserLinkTargetsRegistered = false

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

    /// Which run each channel's Agents pane has open (C6.4, child spec D5).
    ///
    /// **One instance, app-scoped**, for the reason `decisions` above it is: contract Y4's
    /// `show(run:in:)` is synchronous and the tab's per-channel session is built lazily by the host
    /// on first render, so a chip clicked before the tab was ever opened has nothing to write to. A
    /// store per surface would drop exactly those navigations.
    let agentSelection = AgentSelectionStore()

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
    /// Contract Y1's registry, and the reason it is a parameter.
    ///
    /// `RowRegistry.register(kind:builder:)` traps on a second claim of a kind — two leaves owning
    /// one row kind is a breach of the cut's fence, and the trap is what lets four worktrees build
    /// one target. `AppModel.init` is where C6.1's eleven claims go, so on `RowRegistry.shared` the
    /// second `AppModel` a process builds would die. Production builds one model and claims once on
    /// the shared registry; a test gives each model its own; a genuine double claim still traps.
    /// **Do not make `register` idempotent instead** — the trap is the contract.
    init(registry: RowRegistry = .shared,
         sequence: LaunchSequence = LaunchSequence(),
         coordinatorFactory: (@MainActor @Sendable (Workspace) -> any WorkspaceCoordinating)? = nil) {
        let panels = PanelHostModel()
        self.panels = panels
        self.shell = ShellModel(panels: panels)
        self.sequence = sequence
        let browserStore = DeferredWorkbenchStore()
        let webInspector = WebInspectorSwitch()
        self.browserStore = browserStore
        self.webInspector = webInspector
        self.browserTab = BrowserWiring.makeTab(store: browserStore, inspector: webInspector)
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
        // **Superseded 2026-09-09 (C6.1 Task 8).** This was two claims: eleven kinds here and the
        // remaining two — `decision` and `sentFile` — on `RowRegistry.shared` below, behind a
        // once-per-process flag, because the leaf that owned those rows could not reach the per-row
        // capability carrier. Contract Y7's mount closed that, so all thirteen are claimed in this
        // one call and the once-per-process guard moved with them.
        TimelineRowKinds.register(on: registry)
        //
        // C7.4's Terminal leaf takes `.terminal` here and registers its pane runner for the same
        // id, both over `terminalSessions` — see that property for why the two share one registry.
        // Registration is what makes `PanelHost.run(_:for:)` reach a runner at all; without it
        // every X5 pane request answers `noPaneRunner` and no gate can run.
        // C7.5's Files tab under `.files`, which nothing holds, so it is a plain registration and
        // not a handover (C7.5 Design §10). Asserted for the same reason: a shipped tab that
        // vanished from the tab bar with no signal is the thing this must not do quietly.
        //
        // Its two link targets are registered **with the tab**, not with its first session: the
        // host builds a session lazily, for rendering, so a `.file` or `.diff` link raised before
        // anyone has looked at Files would otherwise resolve to nothing (C7.5 Design §9).
        // Spawned, because registration is a hop onto the link registry's actor and this is not.
        let files = FilesTab(host: self)
        do {
            try panels.register(PlaceholderTab())
            try panels.register(TerminalPanelTab(registry: terminalSessions))
            panels.registerPaneRunner(TerminalPaneRunner(registry: terminalSessions), for: .terminal)
            panels.select(.thread)
            try panels.register(files)
        } catch {
            assertionFailure("the shipped tabs are the first registrations on a freshly built host")
        }
        Task { await files.registerLinkTargets(through: panels.links) }
        // C7.6's Browser tab, under `.browser`, registered once (Q4). Not `try?` for the reason
        // above it: nothing else can hold `.browser` on a host built two lines ago, and a Browser
        // that vanished silently would leave every `.url` link falling through to W5's fallback and
        // opening in the system browser with no sign that a panel was meant to have it.
        //
        // **The tab is registered here and its two link targets are not**, which is the one place
        // this milestone had to choose. `PanelHost.register` is X7's synchronous member and
        // `LinkRouterCapability.register` is `async` — the registry is an actor — so the pair
        // cannot both happen in an initialiser. A detached `Task` would leave the window of exactly
        // the shape the targets exist to close: a link arriving before its target reaches W5's
        // fallback and leaves the app. So target registration is awaited at the top of
        // `performLaunch` instead, which is strictly earlier than the first link that can exist:
        // a `WorkspaceLink` is opened through a `ChannelContext`, and no context exists until
        // `bindWorkspace`, later in that same call.
        do {
            try panels.register(browserTab)
        } catch {
            assertionFailure("the Browser is registered on a freshly built host and nothing else holds .browser")
        }
    }

    /// Registers the Browser's `.url` and `.pullRequest` targets on the app's one link registry
    /// (Q4, D41), once for the life of the process.
    func registerBrowserLinkTargets() async {
        guard !browserLinkTargetsRegistered else { return }
        browserLinkTargetsRegistered = true
        for target in BrowserWiring.makeLinkTargets(model: browserTab.model, panels: panels) {
            await panels.links.register(target)
        }
    }

    // MARK: - The Files panel's link deliveries (C7.5 spec Design §9)

    /// What a delivered `.file` or `.diff` opens in: the Files session for the channel the
    /// delivery belongs to, built if this is that channel's first visit.
    ///
    /// **It creates where `filesSaveTarget` refuses to**, and the difference is what asked. A menu
    /// item computing its own enabled state must not bring a panel into being; a link the user
    /// clicked is an instruction to open something now, and the channel it belongs to may never
    /// have shown Files.
    ///
    /// **The channel is the host's, not the render path's.** `PanelColumnView` draws only the
    /// selected tab, so moving channels with Thread up renders no Files view, and a pop-out draws
    /// one for a channel of its own; resolving through the last render would send the delivery to
    /// whichever channel was drawn last. This is the Y-side of tracker 240's mitigation, and it is
    /// still only a mitigation — a link on behalf of a channel that is not on screen cannot say so
    /// until X7 carries the originating channel.
    func filesSession(for destination: LinkDestination) -> FilesPanelSession? {
        guard let key = channel(for: destination),
              let context = panels.context(for: key) else { return nil }
        return panels.session(for: .files, context: context) as? FilesPanelSession
    }

    /// Which channel a delivery belongs to.
    ///
    /// `.currentPanel` is the channel the main window is showing. `.newWindow` is the channel the
    /// host popped a window out for immediately before this delivery — `HostLinkRouter` captured
    /// it when the action was taken, precisely because the window may have moved on since, and
    /// reading the selection here would undo that capture: the file would open in the channel the
    /// window is on now while the window that was just opened renders the one the link came from.
    /// A pop-out that has been closed since names nothing, and the current channel answers instead.
    private func channel(for destination: LinkDestination) -> ChannelKey? {
        guard destination == .newWindow,
              let window = panels.lastPopOut, window.tab == .files,
              panels.poppedOut.contains(window) else { return panels.selectedChannel }
        return window.channel
    }

    /// Brings Files forward, so a routed file does not open in a panel nobody can see.
    func selectFilesTab() { panels.select(.files) }

    // MARK: - The Files panel's save (C7.5 spec Design §7)

    /// The session Cmd+S reaches: the Files panel's, for the channel the **key window** is
    /// showing — a popped-out Files window's own channel, or the main window's while Files is the
    /// tab it has selected.
    ///
    /// **It resolves a session rather than creating one.** `session(for:context:)` builds one for
    /// any context handed to it, and a menu item computing its own enabled state must not bring a
    /// panel into being as a side effect. The guards below are what prevent it: `selected == .files`
    /// means the panel column is already rendering Files for `selectedChannel` and membership of
    /// `poppedOut` means a window is rendering it for its own channel, so in both cases the host
    /// already holds that session — and a channel the host has never rendered has no context to
    /// ask with.
    func filesSaveTarget(inFocused window: PoppedOutPanel?) -> FilesPanelSession? {
        guard let key = saveChannel(inFocused: window),
              let context = panels.context(for: key) else { return nil }
        return panels.session(for: .files, context: context) as? FilesPanelSession
    }

    /// Whose Files panel Cmd+S is aimed at.
    ///
    /// A popped-out window keeps a channel of its own and never touches the main window's
    /// selection, so a menu item resolved from that selection alone saves whichever channel the
    /// main window happens to show while the user is typing into a window in front of them — or
    /// offers nothing at all. The key window decides: a popped-out Files panel names its own
    /// channel, any other pop-out names none, and the main window's rule below is what answers
    /// when it is the key window.
    ///
    /// A window closed since is not a target: `poppedOut` is the membership its own scene reads,
    /// and one that has left it draws the missing-channel placeholder.
    private func saveChannel(inFocused window: PoppedOutPanel?) -> ChannelKey? {
        guard let window else {
            guard panels.selected == .files else { return nil }
            return panels.selectedChannel
        }
        guard window.tab == .files, panels.poppedOut.contains(window) else { return nil }
        return window.channel
    }

    /// Whether the *Save* item has anything to do. The panel's own header button is disabled on
    /// the same fact, so the key and the button agree.
    func canSaveFiles(inFocused window: PoppedOutPanel?) -> Bool {
        filesSaveTarget(inFocused: window)?.selected?.isDirty ?? false
    }

    /// Cmd+S. W4's editor vocabulary is closed, so Monaco cannot report the key press: the host
    /// sends `save` and writes the `saveRequested` that comes back (C7.5 Design §7).
    func saveFilesPanel(inFocused window: PoppedOutPanel?) {
        filesSaveTarget(inFocused: window)?.save()
    }

    /// Binds the two app-scoped, workspace-dependent owners to the workspace a launch reached.
    ///
    /// One call rather than two at the call site, because the pair is a unit: the host reads the
    /// registry for every context's recent-URL feed, and a host bound to one workspace's registry
    /// while the registry was rebound to another is exactly the split the single instances exist to
    /// prevent. `lifecycle` is the seam pane exits leave through; production passes nil and gets
    /// `workspace.fleet`.
    func bindWorkspace(_ workspace: Workspace, lifecycle: (any LifecycleAPI)? = nil) {
        // The Terminal registry goes the same way as the host's sessions and contexts, and for the
        // same reason: a session kept across the rebind holds the previous workspace's store and
        // its `reportPaneExit`, so its panes would write where nothing reads and report exits to a
        // lifecycle nobody is listening to. Releasing it also ends those panes, which is the only
        // moment anything can — after this line nothing holds them.
        //
        // A channel *removed* from the fleet wants the same treatment and does not get it here:
        // `FleetCoordinator.release` would have to reach this registry, and that seam is filed as
        // tech debt rather than opened in a fix wave.
        terminalSessions.release()
        // The Browser's tab-set document (W6's `browser` key in the `workbench` namespace). It is
        // bound here rather than at construction because the tab is registered before any launch
        // has run, and this is the call that also builds the first `ChannelContext`.
        browserStore.bind(workspace.store)
        timelines.attach(to: workspace, lifecycle: lifecycle)
        panels.attach(to: workspace, timelines: timelines, lifecycle: lifecycle)
        composers.attach(to: workspace,
                         context: { [panels] key, cwd in panels.context(for: key, cwd: cwd) },
                         timeline: { [timelines] key in timelines.model(for: key) },
                         paneRunner: { [panels] request, channel in try await panels.run(request, for: channel) },
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
        // Before anything else, and before any `ChannelContext` exists: a link opened with no
        // Browser target registered falls through to W5's fallback and leaves the app.
        await registerBrowserLinkTargets()
        route = .launching
        launchStore = nil
        canResetBinaryOverride = false
        settingsRecoveryError = nil
        var configured = sequence
        configured.settingsLoaded = { [weak self] store, settings in
            self?.launchStore = store
            self?.canResetBinaryOverride = settings.developer.binaryPathOverride != nil
            // Q15: mirrored for the panel's web-view factory, which reads it synchronously at every
            // `makeWebView` and cannot await the store. Release builds ask it; Debug builds are
            // inspectable regardless and never do.
            self?.webInspector.isOn = settings.developer.webInspector
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
                                              fold: ChannelFold(timelines: timelines),
                                              reservations: decisions))
            } catch {
                assertionFailure("the handover unregistered .thread before registering over it")
            }
            if wasShowingThread { panels.select(.thread) }
            // C6.4's Agents tab under `.agents` (contract Y3, and this leaf's `[parent-impact]`).
            // **A plain registration, not a handover**: `PlaceholderTab` claims `.thread` alone and
            // nothing else registers `.agents`, so there is nothing to unregister first. Here
            // rather than on `init`'s registration line for Y3's second reason — the tab's own
            // later actions are X5 requests, and the lifecycle exists nowhere earlier.
            //
            // The registry reaches it as a closure and not as a reference: a panel holding the
            // app's one `ChannelTimelineRegistry` is the duplicate-capability path the C6 cut
            // exists to prevent, and X7 hands panels capabilities rather than the host.
            //
            // **Once for the process, like the Browser's targets.** `launch()` runs again on
            // *Check again*, and a plain second `register` would trap on the duplicate. Keeping the
            // first registration is right rather than merely safe: everything this tab holds is
            // app-scoped and outlives a launch — the registry closure reads whichever workspace
            // `bindWorkspace` last attached, and the selection store is the same one either way.
            if !panels.isRegistered(.agents) {
                // The lifecycle is the tab's third app-scoped object, and it is Y3's second reason
                // for registering here at all: §8.8's node actions are X5 requests — `stop_task`,
                // `background_tasks`, `.stopEverything`, `.backgroundAll` — and there is no fleet to
                // send them by anywhere earlier.
                let agents = AgentsTab(timelines: { [timelines] key in timelines.model(for: key).timeline },
                                       selection: agentSelection,
                                       lifecycle: workspace.fleet)
                do {
                    try panels.register(agents)
                } catch {
                    assertionFailure("the Agents tab is registered on a host where nothing holds .agents")
                }
                // Contract Y4, installed: the `Agent` chip's seam, which has been
                // `NoAgentNavigation` since C6.1 landed it. It focuses the run's channel, selects
                // this tab and writes the run into the app-scoped store the session reads when the
                // host builds it — the shell and the host through closures, never references.
                agentNavigation = AgentNavigator(selection: agentSelection,
                                                 focusChannel: { [shell] key in shell.select(key.session) },
                                                 selectTab: { [panels] in panels.select(.agents) })
                // Its `/agents` command target (child spec D15, tracker 207), registered **with the
                // tab** and awaited — a session is built lazily for rendering, so a link raised
                // before anyone opened the tab must still resolve. It cannot go beside the
                // Browser's at the top of this call: the tab does not exist until the lifecycle
                // does, a few lines above. Awaiting here is still strictly before the first link
                // that can be raised, because nothing this launch reached is on screen until
                // `route` is published below.
                for target in agents.linkTargets(through: { [panels] in panels.select(.agents) }) {
                    await panels.links.register(target)
                }
            }
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
                                  store: workspace.store,
                                  reservations: decisions)
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
