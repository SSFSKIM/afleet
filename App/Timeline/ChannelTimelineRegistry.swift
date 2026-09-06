import Foundation
import Observation
import AfleetCore
import FleetKit

/// The per-channel timeline owner: one `ChannelTimelineModel` per channel, retained for the life of
/// the workspace (spec §8).
///
/// **There is exactly one of these in the app**, `AppModel.timelines`, and every consumer reaches
/// its model through it — the channel column draws one, and the panel host's recent-URL feed reads
/// the same one. Constructing a second registry anywhere would hand the Browser a feed watching a
/// model that ingestion never touches, which is a defect no unit test over either half can see.
///
/// **A model is retained across a channel switch** because ingestion is expensive to restart and
/// because the panel host's per-(tab, channel) session cache and C7's panes both assume a channel's
/// state survives switching away and back.
@MainActor
@Observable
final class ChannelTimelineRegistry {

    /// The workspace the models are built over. Nil until a launch reaches one.
    private(set) var workspace: Workspace?

    /// The events seam handed to every model. Production is the workspace's own fleet; a test
    /// replaces it with a `LifecycleAPI` double before opening a channel.
    @ObservationIgnored var lifecycle: (any LifecycleAPI)?

    /// The change-feed seam handed to every model. Nil is the workspace's own feed; a test replaces
    /// it with a double that can suspend inside `subscribe()`, which is the only place the
    /// subscribe-before-read ordering is observable. Set before the channel's first `model(for:)`.
    @ObservationIgnored var changeFeed: ChannelTimelineModel.ChangeFeedSubscribing?

    @ObservationIgnored private var models: [ChannelKey: ChannelTimelineModel] = [:]

    init() {}

    /// Binds the registry to the workspace a launch reached, releasing every model built over the
    /// previous one. *Check again* runs the whole launch again, and a model still driving the old
    /// workspace's ingestion would keep reading a store and a fleet nothing else refers to.
    func attach(to workspace: Workspace, lifecycle: (any LifecycleAPI)? = nil,
                changeFeed: ChannelTimelineModel.ChangeFeedSubscribing? = nil) {
        releaseAll()
        self.workspace = workspace
        self.lifecycle = lifecycle ?? workspace.fleet
        self.changeFeed = changeFeed
    }

    /// This channel's model, built on first ask and retained afterwards.
    func model(for key: ChannelKey) -> ChannelTimelineModel {
        if let existing = models[key] { return existing }
        let model = ChannelTimelineModel(key: key, workspace: workspace, lifecycle: lifecycle,
                                         changeFeed: changeFeed)
        models[key] = model
        return model
    }

    /// The channels a model has been built for. The count is what a report states; the keys are
    /// what the panel host's release path needs.
    var openChannels: [ChannelKey] { Array(models.keys) }

    /// Drops one channel's model — the channel left the index.
    func release(_ key: ChannelKey) {
        models.removeValue(forKey: key)?.close()
    }

    private func releaseAll() {
        for model in models.values { model.close() }
        models = [:]
    }
}
