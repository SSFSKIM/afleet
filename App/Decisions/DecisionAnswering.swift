import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// The app's one reservation set for decision answers, and the one place a settled answer is
/// announced (contract Y2, spec §8.4).
///
/// **Why it is not per host.** Every surface that can answer a request builds its own
/// `DecisionAnswering`: Activity's row, the Thread tab, the timeline's card. A request id is
/// answerable exactly once — the supervisor drops the pending entry with the first answer and
/// refuses the second — so an in-flight set held per host disables the buttons of the host that
/// clicked and leaves the same request live on every other surface. The two clicks then both reach
/// the wire and the second comes back `decisionGone`, which is an error about afleet's own
/// bookkeeping dressed as an error about the engine.
///
/// **And why the settle notification lives here too.** The engine sends no frame back for an answer,
/// so a host holding the request's payload — `ChannelEventPump.requests` — learns it is closed only
/// by being told, and *any* surface's answer closes it. One announcement point means the host that
/// holds the payload hears about an answer it did not make, which is the case that leaked before.
/// `@Observable` because the cards disable on it: the in-flight set moved out of the answering
/// object, and a view that observed the old property has to observe this one instead.
@MainActor
@Observable
final class DecisionReservations {

    /// What a host does with a successful answer: forget the request its pump is still holding —
    /// `ChannelEventPump.forget(_:)`, the seam C5 installed — and adopt the state `perform`
    /// returned.
    typealias Settled = @MainActor (RequestID, ChannelKey, ChannelState) -> Void

    /// The answers on the wire, from every host at once. Request ids, and nothing else: this is
    /// bookkeeping about a network call in progress and never a copy of `DecisionItem.state`.
    private(set) var inFlight: Set<RequestID> = []

    /// Keyed by the host, so a model rebuilt over the same set replaces its own registration rather
    /// than adding a second one.
    private var observers: [ObjectIdentifier: Settled] = [:]

    init() {}

    func isAnswering(_ id: RequestID) -> Bool { inFlight.contains(id) }

    /// Takes the one slot this request has, or refuses because some surface already has it.
    func claim(_ id: RequestID) -> Bool { inFlight.insert(id).inserted }

    func release(_ id: RequestID) { inFlight.remove(id) }

    /// Registers a host to hear about every answer that succeeded, whoever sent it.
    func observe(_ host: AnyObject, _ settled: @escaping Settled) {
        observers[ObjectIdentifier(host)] = settled
    }

    /// Announces an answer the engine accepted.
    func settled(_ id: RequestID, in channel: ChannelKey, as state: ChannelState) {
        for observer in observers.values { observer(id, channel, state) }
    }
}

/// The one object a decision card's answer leaves by, held by both hosts (contract Y2, spec §8.4).
///
/// It performs `LifecycleAction.answer` through X5 and nothing else: the body it sends is whatever
/// `DecisionCard.answer(_:)` produced, so the timeline and Activity cannot answer one request two
/// different ways. A refusal renders through C5's `RowBanner`, and a successful answer tells the
/// host to forget the request, because the engine sends no frame back for one.
///
/// **It holds no state of its own.** The in-flight ids live in `DecisionReservations`, which every
/// host shares, because the request they reserve is answerable once and not once per surface. This
/// object holds no outcome and no copy of `DecisionItem.state`: a card's state is C3's, read from
/// the item the host hands in.
@MainActor
@Observable
final class DecisionAnswering {

    /// Where a successful answer's host signal goes (spec D2, contract X4).
    ///
    /// The engine sends **no frame back for an answer**, so the only thing that can move the item
    /// out of `.pending` is the host saying it answered: `HostSignal.decisionAnswered(id, outcome)`
    /// through `ChannelTimelineModel.signal(_:)`, which forwards to the channel's one
    /// `StreamIngestion` and the `WireReducer` inside it. That is why the card keeps no decision
    /// state of its own — it renders `DecisionItem.state`, which C3's reducer wrote.
    ///
    /// A closure rather than a reference to the timeline model, because this object is built by
    /// three hosts and only one of them owns a channel's fold: Activity's row and the Thread tab
    /// answer requests for channels whose `ChannelTimelineModel` they do not hold. The host that
    /// holds one assigns this; a host that does not leaves the default, which raises nowhere and is
    /// the right behaviour for a surface with no fold to tell.
    ///
    /// **No production host assigns it yet.** The assignment belongs to the channel column's
    /// per-row capability carrier — C6.1's `TimelineRenderContext`, which is not on `main` — and
    /// reaching the timeline registry from here by another route would be the second capability
    /// path the C6 cut exists to prevent.
    typealias Raising = @MainActor (ChannelKey, HostSignal) async -> Void

    private let lifecycle: any LifecycleAPI

    /// The shared set, and the shared announcement. Handed in rather than made here: a host that
    /// makes its own is a host whose answers nobody else hears about.
    let reservations: DecisionReservations

    /// See `Raising`. Assigned by a host that owns the channel's `ChannelTimelineModel`.
    var raise: Raising = { _, _ in }

    /// Every answer on the wire, from any host. Read by the cards, which disable on it.
    var inFlight: Set<RequestID> { reservations.inFlight }

    /// Why the last answer did not happen, or nil. Cleared by the next answer that does.
    private(set) var banner: RowBanner?

    init(lifecycle: any LifecycleAPI, reservations: DecisionReservations = DecisionReservations()) {
        self.lifecycle = lifecycle
        self.reservations = reservations
    }

    /// True while this request has an answer on the wire — sent from **any** surface, which is what
    /// makes the second of two hosts refuse rather than send a duplicate. The card disables on it.
    func isAnswering(_ id: RequestID) -> Bool { reservations.isAnswering(id) }

    /// A card's action, on its way to the engine.
    ///
    /// Synchronous, and it claims the request id before it returns: the second of two clicks in one
    /// run loop turn finds the id already in flight and sends nothing. An action the mapping
    /// produces no answer for — the overage card's billing route — sends nothing and claims
    /// nothing.
    /// `onSuccess` runs on the same branch as the raise: after `perform` returned, and never after
    /// one that threw. It is for the consequences an answer has on this side of the wire that
    /// cannot be undone — the refusal dialog's retraction is the one this child has — so that a
    /// refused answer leaves the surface exactly as it found it.
    func send(_ action: DecisionAction, on card: DecisionCard, in channel: ChannelKey,
              onSuccess: (@MainActor () -> Void)? = nil) {
        guard let answer = card.answer(action) else { return }
        let id = card.requestID
        guard reservations.claim(id) else { return }
        let outcome = Self.outcome(of: answer, for: card.kind)
        Task { await self.deliver(answer, to: id, in: channel, as: outcome, then: onSuccess) }
    }

    /// How a decision ended, from the answer that ended it and the kind of card it was.
    ///
    /// The behaviour on the wire settles most of it: an allow is `.allowed`, a deny is `.denied`
    /// with the message the user typed, a cancelled dialog is `.cancelled`. The kind settles the
    /// rest, and has to: a question's reply and a plan's approval are both `{behavior: "allow"}` on
    /// the wire, and reading either as *allowed* would put the word for a permission grant on a
    /// card that granted no permission. `DecisionOutcome.label` is what the item's state carries,
    /// so this is the word the timeline shows.
    static func outcome(of answer: InboundAnswer, for kind: DecisionItem.Kind) -> DecisionOutcome {
        switch answer {
        case .permission(.allow):
            switch kind {
            case .permission: return .allowed
            case .plan: return .answered(summary: "plan approved")
            default: return .answered(summary: "answered")
            }
        case .permission(.deny(let message, _, _)):
            // An empty message is no message. `DecisionOutcome.denied` spells that as nil rather
            // than as an empty string, so a reader cannot tell them apart and does not have to.
            return .denied(message: message.isEmpty ? nil : message)
        case .dialog(.completed(let result)):
            // The dialog results are the engine's own words — `retry_fallback`, `consent`, … —
            // and the outcome carries whichever one was sent rather than a word of afleet's.
            if case .string(let spelling) = result { return .answered(summary: spelling) }
            return .answered(summary: "answered")
        case .dialog(.cancelled):
            return .cancelled
        case .elicitation(.accept):
            return .answered(summary: "accepted")
        case .elicitation(.decline):
            return .answered(summary: "declined")
        case .elicitation(.cancel):
            return .cancelled
        case .hookContinue, .mcpResponse, .error:
            // Not answers this child's mapping produces: a hook continuation and an MCP response
            // are the inbound policy's, and `.error` is the binary's. Kept total rather than
            // trapped, because a settled request is settled whoever settled it.
            return .answered(summary: "answered")
        }
    }

    private func deliver(_ answer: InboundAnswer, to id: RequestID, in channel: ChannelKey,
                         as outcome: DecisionOutcome, then onSuccess: (@MainActor () -> Void)? = nil) async {
        defer { reservations.release(id) }
        do {
            let state = try await lifecycle.perform(.answer(id, answer), on: channel)
            banner = nil
            // **On success only.** A `perform` that threw leaves the decision `.pending`, which is
            // the truth: the engine was never told. Raising outside this branch would mark a failed
            // answer as answered, and the card would go quiet on a request still waiting.
            await raise(channel, .decisionAnswered(id, outcome: outcome))
            onSuccess?()
            reservations.settled(id, in: channel, as: state)
        } catch let error as LifecycleError {
            banner = RowBanner(error)
        } catch {
            banner = RowBanner(text: "The answer failed: \(type(of: error)).")
        }
    }
}
