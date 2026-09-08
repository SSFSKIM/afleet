import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// §7.5's side-question thread: question and answer pairs, tool-free, and **no record in the main
/// transcript** (item 10).
///
/// *Ask on the side* is `side_question`, a control request — `LifecycleAPI.send(AnyControlRequest,
/// on:)` and never `perform(.send)`. That is the whole of item 10's negative: a control request
/// produces no user record, so the transcript the channel column draws gains nothing, while a
/// composer line would have added one.
///
/// **The history accumulates here.** The engine reads `history` as `{question, response,
/// fallback_notice?}` objects in ask order and omits the key entirely when there is none
/// (`ClaudeWire/Sources/WireFrames/OutboundRequests.swift`, and the engine's own
/// `askSideQuestion` at `cli.pretty.js:289480` in 2.1.263, which spreads `history` only when it is
/// non-empty). X10's `/btw` builds a `SideQuestion` **without** history, so this accumulating
/// variant is additive rather than a second route.
///
/// The reply is `{response, synthetic, refusalFallback?: {originalModel, fallbackModel, content}}`
/// (`cli.pretty.js:289481`, `:297978`), and `null` where the engine had nothing to answer with. A
/// question the engine did not answer stays in the thread as an unanswered pair and **stays out of
/// the history**: a history element without a response is not a shape the engine reads.
@MainActor
@Observable
final class SideQuestionThread {

    /// One ask and what came back. `fallbackNotice` is the engine's own sentence about answering on
    /// a fallback model, carried into the next ask's history as `fallback_notice`.
    struct Exchange: Hashable, Sendable {
        var question: String
        var response: String?
        var fallbackNotice: String?
    }

    /// What the thread was opened on, as the header draws it — the message's own opening words, not
    /// an id and not a path (§11).
    let anchorText: String

    private(set) var exchanges: [Exchange] = []

    /// An ask is on the wire. The field disables on it, so one question is asked once.
    private(set) var isAsking = false

    /// Why the last ask did not land, or nil.
    private(set) var banner: RowBanner?

    init(anchorText: String) {
        self.anchorText = anchorText
    }

    /// The `history` the next ask carries: every answered exchange, in ask order. Empty until one
    /// has been answered, and `SideQuestion` omits the key entirely for an empty one.
    var history: [JSONValue] {
        exchanges.compactMap { exchange in
            guard let response = exchange.response else { return nil }
            var object: [String: JSONValue] = ["question": .string(exchange.question),
                                               "response": .string(response)]
            if let notice = exchange.fallbackNotice { object["fallback_notice"] = .string(notice) }
            return .object(object)
        }
    }

    /// Takes the in-flight slot for a question, or refuses because one ask is already on the wire or
    /// because there is nothing to ask. The claimed question comes back trimmed.
    ///
    /// **Synchronous, and separate from the ask itself**, for the reason
    /// `DecisionAnswering.send(_:on:in:)` claims its request id before it returns: the caller holds
    /// the only copy of what the user typed, and a refusal it learns about from inside a `Task` is a
    /// refusal it learns about after it has already cleared the field. A claim it can read on the
    /// spot is what lets the second question survive the first one being in flight.
    func claim(_ question: String) -> String? {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAsking else { return nil }
        isAsking = true
        return asked
    }

    /// One ask, on the side, once `claim(_:)` has taken the slot. Y5:
    /// `send(AnyControlRequest(SideQuestion(...)))` and nothing else. The claim is given back here.
    func deliver(_ asked: String, through lifecycle: any LifecycleAPI, on channel: ChannelKey) async {
        defer { isAsking = false }
        let request = AnyControlRequest(SideQuestion(question: asked, history: history))
        do {
            let reply = try await lifecycle.send(request, on: channel)
            banner = nil
            exchanges.append(Exchange(question: asked,
                                      response: reply["response"]?.stringValue,
                                      fallbackNotice: reply["refusalFallback"]?["content"]?.stringValue))
        } catch {
            banner = TaskCardModel.banner(for: error)
            exchanges.append(Exchange(question: asked, response: nil, fallbackNotice: nil))
        }
    }
}
