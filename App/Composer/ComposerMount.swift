import SwiftUI
import AfleetCore
import PanelHostAPI
import FleetKit

/// One `ComposerModel` per channel, and the `ChannelSurfaceState` that model shares with the
/// channel header (spec §8.5, C6.2 *The shape: two models, one seam*).
///
/// The same shape as `ChannelTimelineRegistry`: built on first ask, retained across a channel
/// switch, keyed by `ChannelKey`. Retention is not an optimisation — the draft, and later the
/// attachments and the pending rewind, are what the user has typed and not yet sent, and a registry
/// that rebuilt the model on every return to a channel would throw them away.
///
/// **There is exactly one of these in the app**, `AppModel.composers`, bound by `bindWorkspace`
/// beside `timelines` and `panels`. Two registries would hand the header's actions (Task 8) a
/// different `ChannelSurfaceState` from the field those actions disable, which is the one thing the
/// seam exists to prevent — so this is an app-scoped instance and not a static. Task 2 shipped it as
/// `ComposerRegistry.shared` because its brief's fence stopped short of `App/Composition/`; the
/// leaf's fence does reach one registration line there, which is what this is.
@MainActor
final class ComposerRegistry {

    /// The lifecycle every model built here sends through. Nil until a launch reaches a workspace;
    /// production is that workspace's own fleet, and a test sets a double before the first
    /// `model(for:)`.
    var lifecycle: (any LifecycleAPI)?

    /// How a channel's `ChannelContext` is obtained — the one thing the composer needs from X7: the
    /// `LinkRouterCapability` the Browser route uses, and the cwd and `ResolvedEnvironment` the `!`
    /// escape runs in.
    ///
    /// Resolved here, where the model is built, rather than read from `@Environment` in the view.
    /// For the Browser route an absent context loses a URL; for `!` it would mean running a command
    /// in the wrong directory or not at all, and a shell escape that silently does nothing is worse
    /// than one that says it cannot run.
    ///
    /// **A closure and not the `PanelHostModel` itself, and that is load-bearing.** The mount is
    /// asserted by walking the view body with `Mirror`, and holding the host would put the whole
    /// panel graph — every channel's context, each one's captured lifecycle and link router — on
    /// that walk. Storing the host crashed `ComposerMountTests` outright: the walk ran away into the
    /// graph and took the bundle with it, and because `xcodebuild` retries a crashed bundle the
    /// suite then reported "Executed 0" rather than a failure. `Mirror` does not descend into a
    /// closure's captures, so this reference is where the walk stops. It is also the better
    /// layering: the registry depends on the *question*, not on X7's concrete host.
    var contextProvider: (@MainActor (ChannelKey, URL) -> ChannelContext?)?

    /// How the composer reaches the channel's `ChannelTimelineModel` — C6.1's, read only.
    ///
    /// The queue chip reads `Overlay.queue.queued` out of the timeline that model publishes, which
    /// is the channel's one fold (contract X4). A closure rather than the `ChannelTimelineRegistry`
    /// itself, for the same reason `contextProvider` is one: `ComposerMountTests` walks this view's
    /// body with `Mirror`, and a stored registry would put every open channel's ingestion on that
    /// walk. `Mirror` does not descend into a closure's captures.
    ///
    /// Nil leaves the chip empty rather than wrong — a composer with no timeline has nothing to
    /// read, and there is no second place to read a queue from.
    var timelineProvider: (@MainActor (ChannelKey) -> ChannelTimelineModel?)?

    /// Where each composer's `RefusalInterceptor` records a replaced drift refusal: FleetKit's own
    /// `fleet.log`, which is where C5's diagnostics already carry the drift count. Null until a launch
    /// reaches a workspace, so a composer built before one still counts and writes nowhere.
    var diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()

    private var models: [ChannelKey: ComposerModel] = [:]
    private var surfaces: [ChannelKey: ChannelSurfaceState] = [:]

    init() {}

    /// Binds the registry to the workspace a launch reached, releasing every model built over the
    /// previous one — the same contract `ChannelTimelineRegistry.attach(to:)` carries, for the same
    /// reason: *Check again* runs the whole launch again, and a composer still holding the previous
    /// fleet would send into a workspace nothing else refers to. Task 2 shipped this registry as a
    /// static with no rebind, which had exactly that defect; its worker flagged it.
    func attach(to workspace: Workspace, context: (@MainActor (ChannelKey, URL) -> ChannelContext?)? = nil,
                timeline: (@MainActor (ChannelKey) -> ChannelTimelineModel?)? = nil,
                lifecycle: (any LifecycleAPI)? = nil) {
        releaseAll()
        self.lifecycle = lifecycle ?? workspace.fleet
        self.diagnostics = workspace.diagnostics.fleet
        self.contextProvider = context
        self.timelineProvider = timeline
    }

    /// This channel's composer, built on first ask and retained afterwards.
    ///
    /// **Nil before a launch reaches a workspace**, because there is no X5 to send through yet and a
    /// field that accepted a message with nowhere to put it would lose it silently.
    ///
    /// The `ChannelSurfaceState` is created here and shared: the composer reads it and the header
    /// writes it, and two registries — or a surface built per view — would hand Task 8's header a
    /// different object from the field it is disabling, which is the one thing this seam exists to
    /// prevent.
    /// `cwd` is the channel's working directory, which the panel host needs to build the
    /// `ChannelContext` the Browser route and the `!` escape read. Resolved here, where the model is
    /// built, rather than in the view: for `!` an absent context means running a command in the
    /// wrong directory or not at all, and a shell escape that silently does nothing is worse than
    /// one that says it cannot run.
    func model(for key: ChannelKey, cwd: URL? = nil) -> ComposerModel? {
        if let existing = models[key] {
            // A row that gained a cwd after its composer was built — an archived channel since
            // registered — gets its context now rather than never.
            if existing.context == nil, let cwd { existing.context = contextProvider?(key, cwd) }
            followTimeline(existing)
            return existing
        }
        guard let lifecycle else { return nil }
        let surface = surfaces[key] ?? ChannelSurfaceState()
        surfaces[key] = surface
        let model = ComposerModel(key: key, lifecycle: lifecycle, surface: surface, diagnostics: diagnostics)
        if let cwd { model.context = contextProvider?(key, cwd) }
        followTimeline(model)
        models[key] = model
        return model
    }

    /// Points the composer's queue chip at the channel's timeline, if there is one to point at.
    ///
    /// Called on every `model(for:)` and not only on the first: `ChannelTimelineRegistry` builds a
    /// channel's model on first ask too, so a composer built before the column ever drew the channel
    /// would otherwise follow nothing for as long as it lived. `QueueChipModel.follow` is idempotent
    /// for the same model.
    private func followTimeline(_ model: ComposerModel) {
        guard let timelines = timelineProvider?(model.key) else { return }
        // The composer holds the same model the chip follows: *Edit* reads the rendered user
        // messages and the preceding assistant item out of it, and raises the honoured rewind's
        // host signal through it (`EditAndRewind`). Weakly, so the reference here is not a lifetime.
        model.timelines = timelines
        model.queue.follow(timelines)
    }

    /// This channel's shared surface state, whether or not a composer has been built. The header
    /// needs it before the field is first drawn.
    func surface(for key: ChannelKey) -> ChannelSurfaceState {
        if let existing = surfaces[key] { return existing }
        let surface = ChannelSurfaceState()
        surfaces[key] = surface
        return surface
    }

    /// Drops one channel's composer — the channel left the index. The surface goes with it: a
    /// header re-attaching to a released channel builds a fresh pair rather than writing into a
    /// state whose field is gone.
    func release(_ key: ChannelKey) {
        models.removeValue(forKey: key)?.stop()
        surfaces.removeValue(forKey: key)
    }

    /// The channels a composer has been built for; the count is what a report states.
    var openChannels: [ChannelKey] { Array(models.keys) }

    private func releaseAll() {
        for model in models.values { model.stop() }
        models = [:]
        surfaces = [:]
    }
}

/// The composer, mounted below the channel's list — one of C6.2's two call sites in
/// `ChannelColumnView` (spec *The fence*).
///
/// It takes the registry and the row's cwd rather than reading `@Environment(AppModel.self)`, and
/// resolves the model itself. The environment version was drawable only in a running app: the
/// reflection-based view test that is the only way this view is asserted sees an empty environment
/// and would find no composer, so the one place the mount could be wrong was the one place no test
/// could look.
struct ChannelComposerMount: View {

    let key: ChannelKey
    /// The channel's working directory, from the row the column already resolved. It is what the
    /// panel host needs to build the `ChannelContext` the composer's Browser route and `!` escape
    /// use, and it is nil only for a row that carries none — which is a row that is never registered.
    let cwd: URL?
    /// The app's one registry, handed down by the column. Not `@Environment`: the column already
    /// holds `AppModel`, and an environment read would make the mount undrawable in a test that
    /// walks the body by reflection, which is how this view is asserted at all.
    let composers: ComposerRegistry

    var body: some View {
        if let model = composers.model(for: key, cwd: cwd) {
            ComposerView(model: model)
        }
    }
}

/// The channel header's action menu — C6.2's other call site, mounted above the list.
///
/// It draws the three setting pickers, whose displayed values are engine readbacks (`SettingPickers`,
/// gate G7). C6.2 Task 8 fills the rest of it: the MCP popover, reload skills and plugins, rename,
/// fork, send to background and open in terminal, and moves the whole menu into `App/Header/`.
struct ChannelHeaderActionsSlot: View {

    let key: ChannelKey
    /// Task 8's actions write the surface state this registry holds for the channel; the slot takes
    /// it now so filling it changes this view and not the column.
    let composers: ComposerRegistry

    var body: some View {
        if let model = composers.model(for: key) {
            SettingPickersView(model: model.pickers)
        }
    }
}
