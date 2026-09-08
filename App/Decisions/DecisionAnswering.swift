import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// The one object a decision card's answer leaves by, held by both hosts (contract Y2, spec §8.4).
///
/// It performs `LifecycleAction.answer` through X5 and nothing else: the body it sends is whatever
/// `DecisionCard.answer(_:)` produced, so the timeline and Activity cannot answer one request two
/// different ways. A refusal renders through C5's `RowBanner`, and a successful answer tells the
/// host to forget the request, because the engine sends no frame back for one.
///
/// **The only state it holds is `inFlight`, a set of request ids.** That is bookkeeping about a
/// network call in progress — it disables the buttons between the click and `perform` returning, so
/// a double click cannot send twice. It holds no outcome and is not a second copy of
/// `DecisionItem.state`: a card's state is C3's, read from the item the host hands in.
@MainActor
@Observable
final class DecisionAnswering {

    /// What a host does with a successful answer: forget the request the pump is still holding —
    /// `ChannelEventPump.forget(_:)`, the seam C5 installed — and adopt the state `perform`
    /// returned. The default does neither, which is what a host with no pump wants.
    typealias Settled = @MainActor (RequestID, ChannelKey, ChannelState) -> Void

    private let lifecycle: any LifecycleAPI

    /// Assigned by the host after construction, because the host is what the closure captures.
    var settled: Settled = { _, _, _ in }

    /// The answers this object has sent and not yet had a reply to. Request ids, and nothing else.
    private(set) var inFlight: Set<RequestID> = []

    /// Why the last answer did not happen, or nil. Cleared by the next answer that does.
    private(set) var banner: RowBanner?

    init(lifecycle: any LifecycleAPI) {
        self.lifecycle = lifecycle
    }

    /// True while this request has an answer on the wire. The card disables its actions on it.
    func isAnswering(_ id: RequestID) -> Bool { inFlight.contains(id) }

    /// A card's action, on its way to the engine.
    ///
    /// Synchronous, and it claims the request id before it returns: the second of two clicks in one
    /// run loop turn finds the id already in flight and sends nothing. An action the mapping
    /// produces no answer for — the overage card's billing route — sends nothing and claims
    /// nothing.
    func send(_ action: DecisionAction, on card: DecisionCard, in channel: ChannelKey) {
        guard let answer = card.answer(action) else { return }
        let id = card.requestID
        guard inFlight.insert(id).inserted else { return }
        Task { await self.deliver(answer, to: id, in: channel) }
    }

    private func deliver(_ answer: InboundAnswer, to id: RequestID, in channel: ChannelKey) async {
        defer { inFlight.remove(id) }
        do {
            let state = try await lifecycle.perform(.answer(id, answer), on: channel)
            banner = nil
            settled(id, channel, state)
        } catch let error as LifecycleError {
            banner = RowBanner(error)
        } catch {
            banner = RowBanner(text: "The answer failed: \(type(of: error)).")
        }
    }
}
