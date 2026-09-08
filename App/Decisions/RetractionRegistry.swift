import Foundation
import Observation
import ClaudeWire
import FleetKit

/// The messages a settled refusal dialog took back, per channel (spec D11, §8.4).
///
/// `refusal_fallback_prompt` names `retractedMessageUuids` — messages the engine already streamed
/// and which stop being true the moment the dialog is resolved. Removing them is **not** reduction:
/// §7.3's differential invariant forbids this unit adding a reducer, so this is a render-time
/// filter and nothing else. The channel's list calls `retains(_:)` and draws what it answers true
/// for; C3's items are untouched.
///
/// **Nothing enters on receipt.** There is deliberately no entry point for a dialog that has merely
/// been drawn: the one way a uuid gets in is `resolved(_:in:)`, which the card calls after an answer
/// has left the host and which the channel calls for a `control_cancel_request` that retired the
/// dialog (§8.4 counts that as a resolution). A registry that evicted on receipt would delete the
/// partial answer while the user was still deciding whether to keep it.
@MainActor
@Observable
final class RetractionRegistry {

    /// The retracted uuids of every resolved refusal dialog, keyed by the channel that raised it.
    /// A channel with no resolved dialog has no entry and retains everything.
    private(set) var retracted: [ChannelKey: Set<String>] = [:]

    init() {}

    /// A refusal dialog has been settled: its messages go.
    ///
    /// Called at a resolution and nowhere else — an answer the card sent, or a
    /// `control_cancel_request` that retired the dialog. A card of any other kind, and a refusal
    /// dialog whose payload retracts nothing, add nothing.
    func resolved(_ card: DecisionCard, in channel: ChannelKey) {
        guard let refusal = card.refusalFallback else { return }
        let uuids = refusal.retractedMessageUUIDs
        guard !uuids.isEmpty else { return }
        retracted[channel, default: []].formUnion(uuids)
    }

    /// Whether the channel's list should still draw this item.
    ///
    /// Pure, so the list can call it while it lays out. The channel is read from the item's own
    /// stream rather than passed in, because an item already names the session and the config home
    /// it belongs to and a second parameter could disagree with them.
    ///
    /// The match is `WireReducer`'s own rule for "the record that produced this item": the item's
    /// key, and an assistant message's `recordUUIDs`, because one assistant item can be built from
    /// several streamed records and only one of them need be retracted.
    func retains(_ item: TimelineItem) -> Bool {
        let stream = item.id.stream
        let uuids = retracted[ChannelKey(configHome: stream.configHome, session: stream.sessionID)] ?? []
        guard !uuids.isEmpty else { return true }
        if uuids.contains(item.id.key) { return false }
        if case .assistantMessage(let message) = item, message.recordUUIDs.contains(where: uuids.contains) {
            return false
        }
        return true
    }
}
