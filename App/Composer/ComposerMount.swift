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
/// **There is one of these in the app.** `AppModel` owns `ChannelTimelineRegistry` and
/// `PanelHostModel` exactly so that every consumer reads the same instance, and this belongs beside
/// them — but C6.2's fence does not reach `App/Composition/`, so the single instance lives here
/// instead and the architect moves it at merge. Two registries would hand the header's actions
/// (Task 8) a different `ChannelSurfaceState` from the field those actions disable, which is the
/// one thing the seam exists to prevent.
@MainActor
final class ComposerRegistry {

    static let shared = ComposerRegistry()

    private var models: [ChannelKey: ComposerModel] = [:]
    private var surfaces: [ChannelKey: ChannelSurfaceState] = [:]

    init() {}

    /// This channel's composer, built on first ask over the lifecycle the app has bound.
    ///
    /// **Nil before a launch reaches a workspace**, because there is no X5 to send through yet and a
    /// field that accepted a message with nowhere to put it would lose it silently. Once built, the
    /// model is answered whatever is passed afterwards: the lifecycle is the workspace's for the
    /// life of that workspace, and re-reading it per body evaluation would be a second opinion about
    /// which fleet this channel belongs to.
    func model(for key: ChannelKey, lifecycle: (any LifecycleAPI)?) -> ComposerModel? {
        if let existing = models[key] { return existing }
        guard let lifecycle else { return nil }
        let surface = surfaces[key] ?? ChannelSurfaceState()
        surfaces[key] = surface
        let model = ComposerModel(key: key, lifecycle: lifecycle, surface: surface)
        models[key] = model
        return model
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

    /// Optional on purpose. The mount is reached from a view hierarchy that installs `AppModel` in
    /// the environment, and from a test that does not; the non-optional form traps in the second.
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        if let model = ComposerRegistry.shared.model(for: key, lifecycle: app?.timelines.lifecycle) {
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

    var body: some View {
        EmptyView()
    }
}
