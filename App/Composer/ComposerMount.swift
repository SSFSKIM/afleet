import SwiftUI
import AfleetCore
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
    func attach(to workspace: Workspace, lifecycle: (any LifecycleAPI)? = nil) {
        releaseAll()
        self.lifecycle = lifecycle ?? workspace.fleet
        self.diagnostics = workspace.diagnostics.fleet
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
    func model(for key: ChannelKey) -> ComposerModel? {
        if let existing = models[key] { return existing }
        guard let lifecycle else { return nil }
        let surface = surfaces[key] ?? ChannelSurfaceState()
        surfaces[key] = surface
        let model = ComposerModel(key: key, lifecycle: lifecycle, surface: surface, diagnostics: diagnostics)
        models[key] = model
        return model
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
/// It resolves everything itself, rather than taking the model as an argument, because the fence
/// allows two added lines in that file and nothing else: a parameter would mean threading the
/// registry through `ChannelColumnView` and the private column view it builds, which is four more
/// edits to a file C5 owns.
struct ChannelComposerMount: View {

    let key: ChannelKey
    /// The app's one registry, handed down by the column. Not `@Environment`: the column already
    /// holds `AppModel`, and an environment read would make the mount undrawable in a test that
    /// walks the body by reflection, which is how this view is asserted at all.
    let composers: ComposerRegistry

    var body: some View {
        if let model = composers.model(for: key) {
            ComposerView(model: model)
        }
    }
}

/// The channel header's action menu — C6.2's other call site, mounted above the list.
///
/// // C6.2 Task 8 replaces this. It fills with the MCP popover, reload skills and plugins, rename,
/// fork, send to background, open in terminal, and the permission-mode, model and effort pickers
/// whose displayed values are engine readbacks. The slot exists now so the mount point merges
/// before `App/Header/` does; today it draws nothing and reaches no lifecycle, so a column that
/// mounts it is the column C5 shipped.
struct ChannelHeaderActionsSlot: View {

    let key: ChannelKey
    /// Task 8's actions write the surface state this registry holds for the channel; the slot takes
    /// it now so filling it changes this view and not the column.
    let composers: ComposerRegistry

    var body: some View {
        EmptyView()
    }
}
