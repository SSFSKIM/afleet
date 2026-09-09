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
/// been drawn: a uuid gets in only once its dialog has stopped being pending. A registry that
/// evicted on receipt would delete the partial answer while the user was still deciding whether to
/// keep it.
///
/// **The writer is the published overlay, not a view.** `observe(_:in:)` runs at every publish over
/// the state C3's fold holds, so every resolution §8.4 names feeds it: an answer this host sent, an
/// answer another surface sent, and a `control_cancel_request` that retired the dialog — which
/// nobody pressed and which no card's callback can see. The card's own callback stays for the frame
/// in which it answers, before the next publish has landed.
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

    /// Every refusal dialog this channel's fold now holds in a **resolved** state, resolved here.
    ///
    /// Called at every publish. §8.4 evicts "on resolution, whatever the choice, or when a
    /// `control_cancel_request` retires the dialog", and the three states below are exactly those:
    /// `.answered` is a choice somebody made, `.cancelled` is the binary retiring the request, and
    /// `.policyAnswered` is afleet's own inbound policy settling it.
    ///
    /// **`.inert` is not among them, and that is the point.** A process that dies rewrites every
    /// pending decision to `.inert`, so a reading of "not pending" would take the messages back for
    /// a dialog nobody answered and nothing cancelled — and this registry is the channel's, not the
    /// process's, so they would stay hidden through the respawn with nothing left to un-hide them.
    /// The other producer of `.inert` is a dialog kind afleet never declared, which carries no
    /// refusal payload and retracts nothing anyway.
    ///
    /// **Each dialog is read once.** This runs on the thirty-hertz publish path, and building a
    /// `DecisionCard` encodes and re-decodes the whole request payload — so a scan of every settled
    /// dialog per publish would grow the per-publish cost with the channel's whole dialog history,
    /// which §8.3 forbids. The kind is checked against `DecisionItem.title`, which *is* the
    /// `dialog_kind` for a dialog, so a dialog of another kind costs a string compare; and an id
    /// already read is skipped, so the decode happens once per dialog for the channel's life. The
    /// set holds request ids and grows with the number of dialogs a session raises, which is a
    /// number of user prompts and not a rate.
    func observe(_ overlay: Overlay, in channel: ChannelKey) {
        for decision in overlay.decisions.values
        where decision.kind == .dialog
            && decision.title == Self.refusalDialogKind
            && Self.isResolved(decision.state)
            && !observed.contains(decision.requestID) {
            observed.insert(decision.requestID)
            decodes += 1
            resolved(DecisionCard(decision), in: channel)
        }
    }

    /// The `dialog_kind` a refusal-fallback ask carries — `DecisionItem.title` for a dialog.
    static let refusalDialogKind = "refusal_fallback_prompt"

    /// §8.4's resolutions, and nothing else. See `observe(_:in:)` for why `.inert` is excluded.
    private static func isResolved(_ state: DecisionItem.State) -> Bool {
        switch state {
        case .answered, .cancelled, .policyAnswered: true
        case .pending, .inert: false
        }
    }

    /// The dialogs `observe(_:in:)` has already read, so each is decoded once however many times it
    /// is published.
    ///
    /// `@ObservationIgnored` on both this and the count below: they are bookkeeping about work
    /// already done, and nothing draws them. Left observable, a publish that decoded a dialog would
    /// invalidate every view reading the registry a second time, on top of the invalidation
    /// `retracted` already carries.
    @ObservationIgnored private var observed: Set<RequestID> = []

    /// How many dialogs `observe(_:in:)` has decoded. Counted for the reason the table's reloads
    /// are: a cost nothing can count is a cost nothing can hold.
    @ObservationIgnored private(set) var decodes = 0

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
