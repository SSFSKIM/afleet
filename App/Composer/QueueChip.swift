import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// One queued message, as the chip shows it.
///
/// `id` is the engine's command uuid — an engine-assigned identifier, never a path, a title or a
/// session (§11). `label` is the text of the timeline's `userMessage` whose `promptUUID` is that
/// uuid, and **nil is a row, not an absence**: a queued message the user cannot see is worse than
/// one without a label.
struct QueueChipRow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String?
}

/// The queue chip (spec §8.5, C6.2 *The queue chip*): the messages this channel has queued behind a
/// running turn, in arrival order, each cancellable.
///
/// **It reads; it does not derive.** Every row comes out of `Overlay.queue.queued` in the
/// `ChannelTimeline` the channel's `ChannelTimelineModel` publishes — the one-read view of durable,
/// overlay and preview that C3's host-signal corrective landed. There is no second fold and no
/// projection of the wire on this side: the ingestion holds the channel's only reducer and nothing
/// in the app folds the wire (contract X4 as amended). This type owns exactly two things the fold
/// does not: which timeline it is following, and the one control request that cancels a row.
///
/// **No optimistic removal.** A row leaves when the next `command_lifecycle` says the id left the
/// queue and at no other moment. A cancel the engine declines would otherwise vanish a message that
/// is still going to run — which is the failure the user cannot recover from, because the words are
/// gone from the chip while the turn that will speak them is still coming.
@MainActor
@Observable
final class QueueChipModel {

    let key: ChannelKey

    /// What the chip draws, in the engine's arrival order. Empty whenever the queue is.
    private(set) var rows: [QueueChipRow] = []

    /// Why a cancel could not be sent, in this leaf's own words. It is set **only** when the X5 call
    /// itself failed; a `{cancelled: false}` answer is not a failure and clears it (see `cancel`).
    private(set) var cancelFailure: String?

    /// X5, and the only way this file reaches the engine (contract Y5).
    @ObservationIgnored private let lifecycle: any LifecycleAPI

    /// The channel's timeline owner — C6.1's, read only. The chip goes through it rather than
    /// through `StreamIngestion`: that actor is the model's, one channel has one of them, and a
    /// second reader of the ingestion would be a second lifetime to get wrong.
    @ObservationIgnored private weak var timelines: ChannelTimelineModel?
    @ObservationIgnored private var follower: Task<Void, Never>?

    init(key: ChannelKey, lifecycle: any LifecycleAPI) {
        self.key = key
        self.lifecycle = lifecycle
    }

    deinit { follower?.cancel() }

    // MARK: - Following the fold

    /// Follows one channel's timeline: the current value now, and every applied timeline after it.
    ///
    /// `timelineUpdates` is published from the model's `effects` loop, which republishes on any
    /// `Effect.changes` — durable, overlay or preview since C3's corrective — so a `command_lifecycle`
    /// that moves nothing else still reaches this chip. Idempotent for the same model; a second call
    /// with a different one replaces the subscription rather than adding to it.
    ///
    /// **Identity alone is not the guard, because a stopped chip still holds the model it followed.**
    /// `stop()` cancels the follower and leaves `timelines` set — `cancel` refreshes from it — so a
    /// chip that returned early on identity would never subscribe again after the channel went off
    /// screen and came back, and would draw a queue frozen at the moment the view disappeared.
    func follow(_ model: ChannelTimelineModel) {
        guard timelines !== model || follower == nil else { return }
        follower?.cancel()
        timelines = model
        refresh(model.timeline)
        follower = Task { @MainActor [weak self] in
            for await timeline in model.timelineUpdates {
                guard let self, !Task.isCancelled else { return }
                self.refresh(timeline)
            }
        }
    }

    func stop() {
        follower?.cancel()
        follower = nil
    }

    /// Re-reads the chip from a timeline. The **whole** of the chip's state comes from here.
    ///
    /// `queued` is taken as it is: its order is the engine's arrival order, `QueueState.apply` drops
    /// an id from it on `started` and on every terminal state, and nothing here re-orders, filters or
    /// remembers. A `started` id is therefore never a row, so it is never offered for cancellation as
    /// *queued* — which it no longer is.
    private func refresh(_ timeline: ChannelTimeline) {
        var labels: [String: String] = [:]
        for item in timeline.items {
            guard case .userMessage(let message) = item else { continue }
            labels[message.promptUUID] = message.text
        }
        rows = timeline.overlay.queue.queued.map { QueueChipRow(id: $0, label: labels[$0]) }
    }

    /// Re-reads from the timeline this chip is following. Used after a cancel is answered.
    private func refreshFromOverlay() {
        guard let timelines else { return }
        refresh(timelines.timeline)
    }

    // MARK: - Cancel

    /// Cancels one queued message: exactly one `cancel_async_message` naming that uuid, through X5.
    ///
    /// The raw `AnyControlRequest` form is correct here and is this leaf's only use of it: ClaudeWire
    /// types no spec for this subtype, so there is no C2 statement of the subtype and its keys to
    /// render, and spelling it here is not a second opinion about a shape C2 owns. Tracker 142 records
    /// it so C2 can type it at the next typings pass. The key is snake_case, as the engine declares it.
    ///
    /// **`{cancelled: false}` is not a failure.** The engine's own schema says `false` means the
    /// message was not in the queue — it already started. That is the queue's `{backgrounded: false}`
    /// (§8.4): the chip refreshes from the overlay and the row disappears when the fold says it did,
    /// with **no banner**, because nothing went wrong and there is nothing for the user to do.
    ///
    /// Nothing is removed here on either answer. See the type's note on optimistic removal.
    ///
    /// **`{cancelled: true}` raises `HostSignal.promptCancelled`**, and only that answer does. The fold holds every
    /// uuid the host sent in `outstandingPrompts` and spends the oldest on the next `result`; a cancelled message
    /// produces no result, so an uncancelled entry would be spent on some other prompt's turn and the timeline
    /// would name the wrong message as its cause. `false` means the message was not in the queue — it may be
    /// running already — so its prompt is still owed a turn and nothing is retired.
    func cancel(_ id: String) async {
        cancelFailure = nil
        let request = AnyControlRequest(subtype: "cancel_async_message",
                                        payload: .object(["message_uuid": .string(id)]))
        do {
            let answer = try await lifecycle.send(request, on: key)
            if answer["cancelled"]?.boolValue == true {
                await timelines?.signal(.promptCancelled(uuid: id))
            }
            refreshFromOverlay()
        } catch let error as LifecycleError {
            // This leaf's own words about afleet's own refusal, not the engine's, so X10's
            // render-the-table rule does not reach it. The blocker is named; nothing else is.
            if case .notEligible(let blocker) = error {
                cancelFailure = "The message was not cancelled — \(ComposerModel.name(of: blocker)); it is still queued."
            } else {
                cancelFailure = "The message was not cancelled; it is still queued."
            }
        } catch {
            cancelFailure = "The message was not cancelled; it is still queued."
        }
    }
}
