import Foundation
import SwiftUI

/// What became of one *Send message* (root §8.8, acceptance item 51).
///
/// **The action is not a delivery, and each of its four ways of failing silently is a case here.**
/// afleet composes an ordinary main-session prompt asking the main agent to relay the message to a
/// run by id; there is no host-initiated resume or messaging control in the protocol at all (parity
/// §18.25), so this relay is the only path and every step of it is the model's choice. The model may
/// not call `SendMessage`; it may call it naming a different agent; the call may come back an error,
/// which is what a refused resume looks like (parity §18.25.4, §18.26.2); and the target may stop
/// before its next tool round. The engine's own success string only says the message is *queued for
/// the agent's next tool round* (parity §18.26.2) — so even a clean call is not delivery.
///
/// **Four named reasons and never a generic one.** A fifth way to fail would have to be named to be
/// folded in here, which is the whole point: a `.notDelivered(.other)` case is how the next silent
/// arm gets hidden behind a sentence that is already on screen.
enum AgentRelayState: Hashable, Sendable {

    /// Sent, and the wire has not yet shown the main agent calling `SendMessage` for this target.
    case pending

    /// A `SendMessage` `tool_use` naming **this** run came back without an error. The engine has
    /// queued the message; nothing has yet shown the agent receiving it.
    case relayed

    /// The message text is in the **agent's own** transcript, correlated one-to-one with this send.
    /// Text in the main stream is not delivery — the main stream is where the relay was *asked for*.
    case delivered

    case notDelivered(Reason)

    /// The four arms, as acceptance item 51 enumerates them.
    enum Reason: String, Hashable, Sendable, CaseIterable {
        /// The turn closed — a `result` attributed to this prompt — with no `SendMessage` call in it.
        case noCall
        /// The model called `SendMessage`, naming another agent. The message went somewhere else, or
        /// nowhere; either way it did not go here.
        case wrongTarget
        /// The `tool_result` was an error. A refused resume is this arm.
        case refused
        /// The target's `task_notification` arrived after the relay and no round of the target's own
        /// carried the text.
        case stoppedBeforeNextRound
    }

    /// Whether this reading is one the user can act on with *Retry*.
    var offersRetry: Bool {
        if case .notDelivered = self { return true }
        return false
    }

    /// The sentence a row draws. afleet's own copy — the engine wrote none of this, because the
    /// engine has no opinion about whether a relay it never made was supposed to happen (X10's rule
    /// is about the engine's tables, and this is not one).
    ///
    /// It names no run, no task id and no message text (§11): what the reader needs is which of the
    /// four things happened, and the node the message was for is already the thing they clicked.
    var sentence: String {
        switch self {
        case .pending: "Pending — Claude has been asked to relay this to the agent."
        case .relayed: "Relayed — queued for the agent's next tool round."
        case .delivered: "Delivered — the message is in the agent's own transcript."
        case .notDelivered(.noCall): "Not delivered — the turn ended with no SendMessage call."
        case .notDelivered(.wrongTarget): "Not delivered — the SendMessage call named a different agent."
        case .notDelivered(.refused): "Not delivered — the SendMessage call came back an error."
        case .notDelivered(.stoppedBeforeNextRound): "Not delivered — the agent stopped before its next tool round."
        }
    }
}

// MARK: - The text, as a digest

/// The sent text, as the only form of it this leaf keeps: a digest (child spec's relay design, §11).
///
/// **Why a digest and not the text.** The message is the user's words and reaches a report the
/// moment anything holds it — a failure message, a diagnostic, a description, an `XCTAssertEqual`
/// that printed both operands. What the delivery arm actually needs is an *equality test* against
/// what the agent's transcript now holds, and a digest answers that without the value ever existing
/// in a printable field.
///
/// **The tolerance is deliberate and bounded.** The engine forwards a relayed message into the
/// agent's stream as a frame of its own, and nothing in the bundle promises the forwarded body is
/// byte-identical to what the model passed as `SendMessage.message` — a wrapper line is exactly the
/// kind of thing the harness adds. So a candidate matches when the digest of the whole normalised
/// text matches, or when the digest of any one of its paragraphs or lines does. That accepts a
/// prefix or suffix the harness added and still refuses a transcript that merely *mentions* the
/// agent: nothing shorter than a whole line of the original can match.
enum AgentRelayDigest {

    /// The digest of one text: two independent 64-bit rolling hashes, hex.
    ///
    /// **Not a cryptographic hash, deliberately.** The one thing this value does is answer "is this
    /// the same text", within one process, against a candidate the same engine produced — it is never
    /// inverted, never stored, never sent and never compared against an adversary's input. A
    /// cryptographic digest would cost the app a framework import the import policy does not allow
    /// for a question 128 independent bits already answer.
    static func of(_ text: String) -> String {
        var fnv: UInt64 = 0xcbf2_9ce4_8422_2325
        var djb: UInt64 = 5381
        for byte in Array(normalise(text).utf8) {
            fnv = (fnv ^ UInt64(byte)) &* 0x1000_0000_01b3
            djb = (djb &* 33) &+ UInt64(byte)
        }
        return String(format: "%016lx%016lx", fnv, djb)
    }

    /// Whether `text` carries the message this digest was taken of, whole, as a paragraph, or as a
    /// line. An empty digest matches nothing: a message with no text is not a message.
    static func matches(_ digest: String, in text: String) -> Bool {
        guard !digest.isEmpty, !normalise(text).isEmpty else { return false }
        if of(text) == digest { return true }
        for segment in segments(of: text) where of(segment) == digest { return true }
        return false
    }

    /// The paragraphs and the lines of a candidate, each normalised by the same rule the digest uses.
    /// Bounded by `segmentLimit`, because a candidate is a whole transcript frame and an unbounded
    /// split would let one very long frame cost more than the scan that found it.
    private static func segments(of text: String) -> [String] {
        var found: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            found.append(paragraph)
            for line in paragraph.split(separator: "\n", omittingEmptySubsequences: true) {
                found.append(String(line))
            }
            if found.count >= segmentLimit { break }
        }
        return Array(found.prefix(segmentLimit)).filter { !normalise($0).isEmpty }
    }

    static let segmentLimit = 512

    /// Leading and trailing whitespace off, and nothing else. Case is kept and interior spacing is
    /// kept: two messages differing in either are two different messages, and a delivery concluded
    /// from a near-match would be the premature conclusion the arms exist to catch.
    private static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - What a surface is told

/// One relay, as a surface draws it (contract Y8).
///
/// Not `Equatable` and deliberately so: it carries the *Retry* action, which is a closure, and the
/// alternative — an id a surface would hand back to the registry — is a second identifier for a row
/// to hold and get wrong. Nothing keys anything off this value; it is built per body evaluation from
/// the record and the timeline, both of which observation already tracks.
///
/// It carries **no message text and no run id** (§11). The state, the model's own reply where the
/// arm is a refusal, and whether *Retry* is offered are the whole of what a row draws.
struct AgentRelayReading {

    let state: AgentRelayState

    /// What the model said in the turn the relay was asked for, where the arm is one the model
    /// explained — sanitised at the boundary that read it off the wire. Item 51 asks for it by name:
    /// "shown with the model's reply and a *Retry*".
    let reply: String?

    /// *Retry* re-sends and opens a **new** record. Nil where the state is not one to retry from.
    let retry: (@MainActor () -> Void)?
}

/// The delivery state, drawn (contract Y8, item 51).
///
/// One small view in this leaf's own directory rather than a block of layout inside C6.1's message
/// row: the contract's row-side edit is one decoration, and a decoration that grew a body would be
/// this leaf writing C6.1's file rather than calling into it.
struct AgentRelayNote: View {

    /// **The drawn strings are stored, not computed inside `body`.** `Mirror` does not evaluate a
    /// body, so a sentence produced there is one no test can be told the row draws — and what these
    /// four states are *for* is being visible. It is the same rule the tree's rows follow.
    let sentence: String
    let reply: String?
    let retry: (@MainActor () -> Void)?
    let isNotDelivered: Bool

    init(reading: AgentRelayReading) {
        sentence = reading.state.sentence
        reply = reading.reply
        retry = reading.retry
        if case .notDelivered = reading.state { isNotDelivered = true } else { isNotDelivered = false }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(sentence)
                .font(.caption2)
                .foregroundStyle(isNotDelivered ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            if let reply, !reply.isEmpty {
                Text(reply)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }
}
