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
/// **The history accumulates here** — the asking itself lands with the next deliverable. The engine reads `history` as `{question, response,
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
}
