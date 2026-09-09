import Foundation
import Observation
import ClaudeWire
import FleetKit

/// One *Send message*, as this leaf's own bookkeeping (root §8.8, item 51; child spec D2).
///
/// **It is not an item and never becomes one** (§7.3): no engine frame carries a delivery state —
/// it is afleet's reading of what the model did next — and this leaf adds no reducer. The record
/// holds only what the reading has to be *keyed* by and the lineage a retry leaves behind; the state
/// itself is derived from the timeline on every ask, so nothing here can drift from the frames.
struct AgentRelayRecord: Identifiable, Hashable, Sendable {

    struct ID: Hashable, Sendable { let raw: UUID }

    let id: ID

    /// The uuid `LifecycleAPI.sendPrompt` minted for the user frame, lowercased as the wire spells
    /// it. It is the join between this record and the timeline: the prompt echo carries it as
    /// `UserMessageItem.promptUUID`, and the `result` that closes the turn carries it as
    /// `TurnAttribution.prompted`. The host cannot mint it or read it from below X5, which is why
    /// `sendPrompt` answers it.
    let promptUUID: String

    /// The run the message was for.
    let target: AgentRunID

    /// The message, as the only form of it kept anywhere (§11). See `AgentRelayDigest`.
    let textDigest: String

    let sentAt: Date

    /// The record this one retried, or nil. A *Retry* opens a new record rather than mutating the
    /// failed one, so the history of a relay that failed survives the retry that replaced it.
    let retryOf: ID?
}

// MARK: - The machine

/// The pure half: what a record's state is, given the channel's timeline.
///
/// **Pure over `(record, ChannelTimeline)`** so every arm is testable without a view, a process or a
/// clock — which is what the gate needs, because five of the six arms are about *not* concluding
/// something and a surface cannot be asked what it declined to conclude.
///
/// **Derived on every ask rather than stepped.** A stepped machine would have to be fed each frame
/// exactly once and would hold a conclusion the frames could later contradict; a derivation cannot
/// disagree with the timeline it is read from, and re-deriving costs one pass over the items.
enum AgentRelayMachine {

    /// What one record's evidence adds up to.
    struct Outcome: Equatable, Sendable {
        var state: AgentRelayState
        /// The model's reply in the turn the relay was asked for, sanitised. Carried on every arm
        /// where the model spoke; a row draws it only where it explains something.
        var reply: String?
        /// The item this record concluded *Delivered* from, as its key string — never the `ItemID`,
        /// which carries the config home (§11). Nil on every other arm.
        var claimedKey: String?

        init(_ state: AgentRelayState, reply: String? = nil, claimedKey: String? = nil) {
            self.state = state; self.reply = reply; self.claimedKey = claimedKey
        }
    }

    /// Every record of one channel, advanced together.
    ///
    /// **Together, because delivery is correlated one-to-one.** Two relays of the same text to the
    /// same run are two messages and one forwarded frame is evidence for one of them; advancing each
    /// record in isolation would let a single frame deliver both. Records are advanced oldest first,
    /// so the earlier send claims the earlier frame.
    static func advance(_ records: [AgentRelayRecord], in timeline: ChannelTimeline) -> [AgentRelayRecord.ID: Outcome] {
        var claimed: Set<String> = []
        var outcomes: [AgentRelayRecord.ID: Outcome] = [:]
        for record in records.sorted(by: { $0.sentAt < $1.sentAt }) {
            let outcome = advance(record, in: timeline, claiming: claimed)
            if let key = outcome.claimedKey { claimed.insert(key) }
            outcomes[record.id] = outcome
        }
        return outcomes
    }

    /// One record, against the timeline and the delivery frames earlier records have already claimed.
    ///
    /// The evidence, arm by arm — this is the decision log's rule, spelled as code:
    ///
    /// - **Pending** holds until the wire shows a `SendMessage` `tool_use` naming *this* run followed
    ///   by a non-error `tool_result`. Until the prompt echo itself arrives there is nothing to read
    ///   the turn from, and pending is the honest answer.
    /// - **Relayed** is that call and that result, and nothing else. A `SendMessage` naming another
    ///   agent does not advance it — it settles `.wrongTarget`, because the model has answered the
    ///   request and answered it about someone else.
    /// - **Delivered** is the text in the **target run's own items**, after the relay. The same text
    ///   in the main stream is not delivery: the main stream is where the relay was asked for, so
    ///   concluding from it would conclude from the request.
    /// - **Not delivered** has its four arms, each from its own evidence: the turn's `result` with no
    ///   call in it; the call naming another run; an error `tool_result`; and the target's own
    ///   `task_notification` arriving after the relay with nothing of the target's carrying the text.
    static func advance(_ record: AgentRelayRecord, in timeline: ChannelTimeline,
                        claiming claimed: Set<String> = []) -> Outcome {
        let items = timeline.items
        guard let sent = items.firstIndex(where: { isPromptEcho($0, of: record) }) else {
            // The engine has not echoed the prompt yet. Nothing has happened that could be read as
            // either a relay or a refusal, and reporting one would be reporting a turn that has not
            // started.
            return Outcome(.pending)
        }

        var reply: String?
        var sawCall = false
        /// The first call of this turn that named **this** run, and what it says.
        var ours: (index: Int, at: Date, verdict: CallVerdict)?
        /// The model called `SendMessage` about some other agent and about nobody this record knows.
        var wrongTarget = false
        var turnClosed = false

        for index in items.index(after: sent)..<items.endIndex where !turnClosed {
            let item = items[index]
            // These arms are all about the **main** agent's turn. An item stamped with a run is that
            // run's, and reading one here is how the main stream and an agent's stream get confused.
            guard item.provenance.agentID == nil else { continue }
            switch item {
            case .assistantMessage(let message):
                // The model's reply, for the arms item 51 says are shown with it: the last thing it
                // said before it started calling tools, which is where it explains a refusal.
                if !sawCall {
                    let text = MessageText.text(of: message.blocks, fallback: "")
                    if !text.isEmpty { reply = TextSanitiser.sanitise(text) }
                }

            case .toolCall(let call) where call.name == "SendMessage":
                sawCall = true
                // **This run's own call wins over the order the calls arrived in.** A model asked to
                // relay to two agents in one turn produces two calls, and reading the first as this
                // record's would settle the wrong arm on whichever the model happened to write
                // first. The wrong-target arm is what is left when the turn carried a `SendMessage`
                // and none of them named this run — and because the state is re-derived from the
                // whole timeline on every ask, a reading taken between the two calls corrects itself
                // the moment this run's own call arrives.
                let verdict = verdict(of: call, for: record)
                if verdict == .wrongTarget { wrongTarget = true } else if ours == nil {
                    ours = (index, call.timestamp ?? .distantPast, verdict)
                }

            case .turnSummary(let turn):
                // The turn this prompt started has closed. Later `SendMessage` calls belong to some
                // other prompt, and this record must not read them as its own.
                if turn.attribution == .prompted(uuid: record.promptUUID) { turnClosed = true }

            default:
                continue
            }
        }

        guard let ours else {
            if wrongTarget { return Outcome(.notDelivered(.wrongTarget), reply: reply) }
            return Outcome(turnClosed ? .notDelivered(.noCall) : .pending, reply: reply)
        }
        switch ours.verdict {
        case .refused: return Outcome(.notDelivered(.refused), reply: reply)
        case .running: return Outcome(.pending, reply: reply)
        // Not stored above, and named here rather than defaulted so a fifth verdict cannot be
        // absorbed by an `default:` that means whatever the last author assumed.
        case .wrongTarget: return Outcome(.notDelivered(.wrongTarget), reply: reply)
        case .relayed: break
        }
        let relay = (index: ours.index, at: ours.at)
        if let key = delivery(of: record, in: items, after: relay.index, claiming: claimed) {
            return Outcome(.delivered, reply: reply, claimedKey: key)
        }
        if stoppedBeforeNextRound(record.target, in: timeline, after: relay.at) {
            return Outcome(.notDelivered(.stoppedBeforeNextRound), reply: reply)
        }
        return Outcome(.relayed, reply: reply)
    }

    // MARK: - The evidence, one reading at a time

    /// The echo of the prompt this record's send minted, on the **main** stream. A run's own items
    /// carry an agent id and a user message inside a run is not this send.
    private static func isPromptEcho(_ item: TimelineItem, of record: AgentRelayRecord) -> Bool {
        guard case .userMessage(let message) = item, message.provenance.agentID == nil else { return false }
        return !record.promptUUID.isEmpty && message.promptUUID == record.promptUUID
    }

    private enum CallVerdict: Equatable { case relayed, wrongTarget, refused, running }

    /// What one `SendMessage` call says about this record.
    ///
    /// **The target is read off the call's own input** — `SendMessageInput.to` — and never off the
    /// order the calls arrived in. A model relaying to two agents in one turn produces two calls, and
    /// a machine that advanced on "a `SendMessage` happened" would settle both records on whichever
    /// came first.
    ///
    /// An input that does not decode as a `SendMessage` input is `.wrongTarget` and not `.relayed`:
    /// the one thing this arm has to be sure of is that the call named *this* run, and a call whose
    /// target cannot be read has not been shown to.
    private static func verdict(of call: ToolCallItem, for record: AgentRelayRecord) -> CallVerdict {
        guard case .sendMessage(let input) = call.input, input.to == record.target else { return .wrongTarget }
        if call.isError == true || call.status == .failed || call.status == .denied { return .refused }
        // A call with no result yet is a call whose outcome is unknown, and the engine's success
        // string is what *Relayed* is concluded from. `.completed` is the builder's reading of the
        // `tool_result` having arrived.
        return call.status == .completed ? .relayed : .running
    }

    /// The delivery frame, or nil: an item **of the target run** after the relay whose text carries
    /// the message, that no earlier record has already claimed.
    ///
    /// Only the two kinds a forwarded message can arrive as — a user frame in the run's own stream,
    /// and a peer message, which is what a frame whose `origin.kind` is not `human` becomes. An
    /// assistant message of the run is the agent *replying*, and a reply quoting the message back is
    /// not the message arriving.
    private static func delivery(of record: AgentRelayRecord, in items: [TimelineItem],
                                 after relay: Int, claiming claimed: Set<String>) -> String? {
        for index in items.index(after: relay)..<items.endIndex {
            let item = items[index]
            guard item.provenance.agentID == record.target, !claimed.contains(item.id.key) else { continue }
            let text: String
            switch item {
            case .userMessage(let message): text = MessageText.text(of: message.blocks, fallback: message.text)
            case .peerMessage(let message): text = MessageText.text(of: message.blocks, fallback: message.text)
            default: continue
            }
            if AgentRelayDigest.matches(record.textDigest, in: text) { return item.id.key }
        }
        return nil
    }

    /// The fourth arm: the target's `task_notification` arrived after the relay and the run is
    /// terminal, with nothing of the run's own carrying the text.
    ///
    /// **Read off the registry mirror and not off the run tree's `endedAt`.** An agent run's
    /// notification produces no item at all — the reducer updates the tree and the mirror and makes
    /// no row — and the tree stamps `endedAt` only the first time, so a run that was already complete
    /// when the message was sent (which is the ordinary case: item 51 sends to a *completed* Explore
    /// run) carries a stamp from before the relay for ever. `RegistryEntry.notified` is the fact —
    /// the host has seen the notification that hands the result back — and `lastFrameAt` is when any
    /// frame naming this task last arrived, which is what places it after the relay.
    private static func stoppedBeforeNextRound(_ target: AgentRunID, in timeline: ChannelTimeline,
                                               after relay: Date) -> Bool {
        guard let entry = timeline.registry.entries[target] else { return false }
        return entry.notified && entry.status != .running && entry.lastFrameAt > relay
    }
}

// MARK: - The registry

/// Every *Send message* the app has made, by channel (child spec D2, contract Y8).
///
/// **App-scoped, for the reason the selection store is**: the record has to outlive the panel
/// session that made it — the main timeline's row draws the state, and that row is on the channel
/// column, which is not the Agents tab and does not go away when the tab does.
///
/// **It holds records and not states.** The state is derived from the channel's published timeline
/// on every ask, so what is stored is what the frames cannot say: which uuid was sent, what it was
/// for, and what a retry descended from.
@MainActor
@Observable
final class AgentRelayRegistry {

    /// One channel's records, oldest first.
    private(set) var records: [ChannelKey: [AgentRelayRecord]] = [:]

    /// How a record re-sends. **Held apart from the record and never inside it**: re-sending needs
    /// the message text, and the record is the thing reports, descriptions and assertions reach — so
    /// the text lives in a closure the send site captured, which nothing can print, encode or
    /// compare. `AgentRelayRecord` carries a digest and stays printable.
    /// It is handed the id of the record it is retrying, because that is the lineage the new record
    /// records and the send site cannot know it at the moment it captures the closure.
    private var resends: [AgentRelayRecord.ID: @MainActor (AgentRelayRecord.ID) async -> Void] = [:]

    /// Opens a record for a send that has already happened. Called after `sendPrompt` returned its
    /// uuid, never before: a record for a send the engine refused would be a message with a state and
    /// no message.
    @discardableResult
    func open(promptUUID: String, target: AgentRunID, textDigest: String, in channel: ChannelKey,
              at sentAt: Date = Date(), retryOf: AgentRelayRecord.ID? = nil,
              resend: (@MainActor (AgentRelayRecord.ID) async -> Void)? = nil) -> AgentRelayRecord {
        let record = AgentRelayRecord(id: AgentRelayRecord.ID(raw: UUID()), promptUUID: promptUUID,
                                      target: target, textDigest: textDigest, sentAt: sentAt, retryOf: retryOf)
        records[channel, default: []].append(record)
        resends[record.id] = resend
        return record
    }

    /// The records of one channel, oldest first.
    func records(in channel: ChannelKey) -> [AgentRelayRecord] { records[channel] ?? [] }

    /// The records for one run, oldest first — what a node draws.
    func records(of target: AgentRunID, in channel: ChannelKey) -> [AgentRelayRecord] {
        records(in: channel).filter { $0.target == target }
    }

    /// Every record of a channel with its state, derived from the timeline in one pass so that
    /// delivery stays correlated one-to-one.
    func outcomes(in channel: ChannelKey, of timeline: ChannelTimeline) -> [AgentRelayRecord.ID: AgentRelayMachine.Outcome] {
        AgentRelayMachine.advance(records(in: channel), in: timeline)
    }

    /// What the row for one sent message draws (contract Y8), or nil where this prompt sent no relay
    /// — which is every ordinary message in every channel, and is why the row draws nothing by
    /// default.
    func reading(forPrompt promptUUID: String, in channel: ChannelKey,
                 of timeline: ChannelTimeline) -> AgentRelayReading? {
        guard !promptUUID.isEmpty,
              let record = records(in: channel).first(where: { $0.promptUUID == promptUUID }) else { return nil }
        return reading(of: record, in: channel, of: timeline)
    }

    /// The same reading for a record already in hand — what a node draws, which knows its records by
    /// the run rather than by a uuid.
    func reading(of record: AgentRelayRecord, in channel: ChannelKey,
                 of timeline: ChannelTimeline) -> AgentRelayReading {
        let outcome = outcomes(in: channel, of: timeline)[record.id] ?? AgentRelayMachine.Outcome(.pending)
        var retry: (@MainActor () -> Void)?
        if outcome.state.offersRetry, resends[record.id] != nil {
            retry = { [weak self] in self?.retry(record.id) }
        }
        return AgentRelayReading(state: outcome.state, reply: outcome.reply, retry: retry)
    }

    /// *Retry*: re-send by the same path, which opens a **new** record naming this one as its
    /// lineage. Nothing about the failed record changes — a relay that failed is a thing that
    /// happened, and a retry that overwrote it would erase the only evidence the user has that it
    /// did.
    func retry(_ id: AgentRelayRecord.ID) {
        guard let resend = resends[id] else { return }
        Task { await resend(id) }
    }
}
