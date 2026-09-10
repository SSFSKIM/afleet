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
        /// The `SendMessage` call this record settled on, by its `tool_use` id. **A call belongs to
        /// one record**: a turn that relays two messages to one run produces two calls, and a
        /// record that took a call an older record had already settled on would report the older
        /// send's outcome for the newer one. Nil where no call named this run.
        var claimedCall: String?
        /// Whether the turn this record's prompt started has closed — the `result` attributed to
        /// this prompt uuid. It is what says the evidence is **complete**: until the turn closes the
        /// model may still call `SendMessage`, call it again after a refusal, or call it for a
        /// different run, and every one of those revises the arm.
        var turnClosed: Bool

        init(_ state: AgentRelayState, reply: String? = nil, claimedKey: String? = nil,
             claimedCall: String? = nil, turnClosed: Bool = false) {
            self.state = state; self.reply = reply; self.claimedKey = claimedKey
            self.claimedCall = claimedCall; self.turnClosed = turnClosed
        }

        /// Whether this conclusion is one no later frame can take back, and therefore one the
        /// registry keeps rather than re-deriving.
        ///
        /// **A terminal arm alone is not enough.** *Not delivered* mid-turn is provisional by
        /// design — the wrong-target arm is what is left while this run's own call has not arrived,
        /// and a refusal the model retries in the same turn becomes a relay — so the arm settles
        /// only once the turn has closed. *Delivered* settles on its own: the message is in the
        /// agent's transcript and a transcript is not un-written.
        var isSettled: Bool { state.isTerminal && (turnClosed || state == .delivered) }
    }

    /// Every record of one channel, advanced together.
    ///
    /// **Together, because delivery is correlated one-to-one.** Two relays of the same text to the
    /// same run are two messages and one forwarded frame is evidence for one of them; advancing each
    /// record in isolation would let a single frame deliver both. Records are advanced oldest first,
    /// so the earlier send claims the earlier frame.
    ///
    /// **`settled` is the conclusions the registry already holds**, and they are held rather than
    /// re-derived: the turn boundary a *Not delivered* was read from lives in the overlay, and a
    /// timeline rebuilt from the transcript files carries no overlay at all (§7.3), so a record
    /// re-derived after *Check again* would scan straight past its own turn into a later one and
    /// claim a later send's call. A settled record's own claims are taken first, so nothing that is
    /// re-derived can take a call or a delivery frame that already belongs to one.
    static func advance(_ records: [AgentRelayRecord], in timeline: ChannelTimeline,
                        settled: [AgentRelayRecord.ID: Outcome] = [:]) -> [AgentRelayRecord.ID: Outcome] {
        let items = timeline.items
        let ordered = records.sorted { $0.sentAt < $1.sentAt }
        /// What each record retried, for the lineage `supersedingSend` walks. Built once per pass:
        /// a *Retry* names the record it replaced, and a retry of a retry names that one.
        let retries = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.retryOf.map { (record.id, $0) }
        })
        var claimed: Set<String> = []
        var calls: Set<String> = []
        var outcomes: [AgentRelayRecord.ID: Outcome] = [:]
        for (position, record) in ordered.enumerated() {
            guard let held = settled[record.id] else { continue }
            let outcome = overtakenByDelivery(held, of: record, in: items, claiming: claimed,
                                              before: competingSend(with: record,
                                                                    among: ordered[ordered.index(after: position)...],
                                                                    in: items)) ?? held
            if let key = outcome.claimedKey { claimed.insert(key) }
            if let call = outcome.claimedCall { calls.insert(call) }
            outcomes[record.id] = outcome
        }
        for (position, record) in ordered.enumerated() where outcomes[record.id] == nil {
            // **What a younger send has already asked for.** A record must not settle on a call
            // that lies after a younger record's own prompt echo and carries the younger record's
            // message: that call is the younger send's, and the prompt echo is a transcript record,
            // so this holds on a timeline rebuilt from the files where the turn boundary does not.
            let younger = ordered[ordered.index(after: position)...]
            let contested = younger.compactMap { later in
                items.firstIndex { isPromptEcho($0, of: later) }
            }.min()
            let outcome = advance(record, in: timeline, claiming: claimed, callsClaimed: calls,
                                  contestedFrom: contested, contestedBy: younger.map(\.textDigest),
                                  // **A different bound, for a different question.** `contestedFrom`
                                  // above is every younger record, because a *call* is told apart by
                                  // the message it carries and the digests ride with it. A delivery
                                  // frame carries no such distinction — it is this record's text in
                                  // this record's run — so the bound for the delivery scan is the
                                  // narrow one below.
                                  deliveredBefore: supersedingSend(of: record, among: younger,
                                                                   in: items, retries: retries))
            if let key = outcome.claimedKey { claimed.insert(key) }
            if let call = outcome.claimedCall { calls.insert(call) }
            outcomes[record.id] = outcome
        }
        return outcomes
    }

    /// Where a younger send that could produce this record's delivery frame begins: the earliest
    /// prompt echo among the younger records with **the same target and the same text**, or nil
    /// where the channel holds no such send.
    ///
    /// **Asked by the settled pass, where the record has no claim of its own left.** The overtake
    /// this bounds applies only to a record that already concluded *Not delivered* — its call was
    /// refused, or the run stopped without taking the message — so a frame that a younger send of
    /// the same text could have produced is that send's. The unsettled pass asks the narrower
    /// question in `supersedingSend(of:among:in:retries:)`: there the record's own call went through
    /// and nothing has concluded that it failed, so the oldest-first rule still governs.
    ///
    /// A prompt echo is a transcript record, so this bound survives a rebuild.
    private static func competingSend(with record: AgentRelayRecord,
                                      among younger: ArraySlice<AgentRelayRecord>,
                                      in items: [TimelineItem]) -> Int? {
        younger
            .filter { $0.target == record.target && $0.textDigest == record.textDigest }
            .compactMap { later in items.firstIndex { isPromptEcho($0, of: later) } }
            .min()
    }

    /// The same question on the **unsettled** path, answered more narrowly.
    ///
    /// The delivery scan there is only ever reached by a record whose own `SendMessage` call went
    /// through — the refused arm returns before it — so this record's message is queued too, and
    /// which of two sends of one text a single frame belongs to is settled by
    /// `testOneForwardedFrameDeliversOneSendAndNotBoth`: the older one, because the queue delivers
    /// in order. Only a younger send with a **stronger claim than that** displaces it, and there are
    /// exactly two ways to know one has:
    ///
    /// - **The app already told the user this send failed.** *Retry* is offered on a *Not delivered*
    ///   arm and nowhere else, and the record it opens names the record it replaced — so a retry
    ///   descendant is the app's own statement that this record's message had not arrived when the
    ///   retry was sent. It holds while this record's turn is still open, which is where the
    ///   provisional fourth arm lives and where a user presses *Retry* soonest.
    /// - **The younger send is a whole turn later.** Oldest-first rests on both messages sitting in
    ///   one queue, which is the same-turn case the test above constructs. Once this record's turn
    ///   has closed and a later turn sent the text again, a frame arriving after that later prompt
    ///   is that send's — the older message would have been handed to the run rounds ago.
    ///
    /// The turn close is read only where a competing send exists at all, so the ordinary channel —
    /// which has never relayed one text twice — pays a filter over the records and no scan.
    ///
    /// **The frame in the gap belongs to neither send, and reads as the older one's failure.** A
    /// genuinely late delivery of the older message that lands after the younger send's prompt echo
    /// but before the younger send's own call is bounded away from the older record and is not yet
    /// the younger record's either, so the older row reads *Relayed*, or *Not delivered* with
    /// *Retry*, about a message that had in fact arrived. Which send such a frame belongs to is
    /// undecidable from the timeline, and this is the unreassuring direction of it: item 51 exists
    /// to end silent success, so a delivery reported late — or offered a retry the user may decline
    /// — is the arm to be wrong on. Accepted deliberately.
    private static func supersedingSend(of record: AgentRelayRecord,
                                        among younger: ArraySlice<AgentRelayRecord>,
                                        in items: [TimelineItem],
                                        retries: [AgentRelayRecord.ID: AgentRelayRecord.ID]) -> Int? {
        let competing = younger.filter { $0.target == record.target && $0.textDigest == record.textDigest }
        guard !competing.isEmpty else { return nil }
        // Read at most once, and only where the lineage did not already answer.
        var turnClose: Int?
        var readTurnClose = false
        var earliest: Int?
        for later in competing {
            guard let echo = items.firstIndex(where: { isPromptEcho($0, of: later) }) else { continue }
            var supersedes = isRetry(later, of: record, through: retries)
            if !supersedes {
                if !readTurnClose {
                    readTurnClose = true
                    turnClose = items.firstIndex {
                        if case .turnSummary(let turn) = $0 {
                            return turn.attribution == .prompted(uuid: record.promptUUID)
                        }
                        return false
                    }
                }
                supersedes = turnClose.map { echo > $0 } == true
            }
            if supersedes { earliest = min(earliest ?? echo, echo) }
        }
        return earliest
    }

    /// Whether `later` is the record that retried `record`, or a retry of one — the chain a *Retry*
    /// of a *Retry* leaves behind. Bounded by the number of records, and it cannot loop: a record
    /// names only a record that already existed when it was opened.
    private static func isRetry(_ later: AgentRelayRecord, of record: AgentRelayRecord,
                                through retries: [AgentRelayRecord.ID: AgentRelayRecord.ID]) -> Bool {
        var id = later.retryOf
        var hops = retries.count
        while let current = id, hops > 0 {
            if current == record.id { return true }
            id = retries[current]
            hops -= 1
        }
        return false
    }

    /// A settled *Not delivered* the message has since overtaken, or nil.
    ///
    /// **The one revision a settlement yields to.** The fourth arm concludes that a run stopped
    /// without taking the message, and the message can still turn up in that run's own transcript
    /// afterwards; a settlement that froze it would leave *Not delivered* and a *Retry* on a message
    /// that had arrived, and the retry would send it twice. It applies only to a record that settled
    /// on a **call of its own** and scans only after that call, and stops where a younger send of
    /// the same text to the same run begins, so it cannot take a delivery frame that belongs to some
    /// other send — which is the correlation the settlement exists to protect.
    ///
    /// **The record's own turn boundary is deliberately not a bound.** This arm is the one where the
    /// run took the message in a *later* round, so the frame it revises on lies after the `result`
    /// that closed the relay's turn; stopping there would leave *Not delivered* and a *Retry* on
    /// every message that arrived late, which is what this method exists to prevent
    /// (`testASettledNotDeliveredYieldsToTheMessageArriving` is that case).
    private static func overtakenByDelivery(_ held: Outcome, of record: AgentRelayRecord,
                                            in items: [TimelineItem], claiming claimed: Set<String>,
                                            before contested: Int? = nil) -> Outcome? {
        guard case .notDelivered = held.state, let call = held.claimedCall else { return nil }
        guard let index = items.firstIndex(where: {
            if case .toolCall(let made) = $0 { return made.toolUseID == call } else { return false }
        }) else { return nil }
        guard let key = delivery(of: record, in: items, after: index, claiming: claimed,
                                 before: contested) else { return nil }
        return Outcome(.delivered, reply: held.reply, claimedKey: key, claimedCall: call,
                       turnClosed: held.turnClosed)
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
                        claiming claimed: Set<String> = [],
                        callsClaimed calls: Set<String> = [],
                        contestedFrom contested: Int? = nil,
                        contestedBy youngerDigests: [String] = [],
                        deliveredBefore competing: Int? = nil) -> Outcome {
        let items = timeline.items
        guard let sent = items.firstIndex(where: { isPromptEcho($0, of: record) }) else {
            // The engine has not echoed the prompt yet. Nothing has happened that could be read as
            // either a relay or a refusal, and reporting one would be reporting a turn that has not
            // started.
            return Outcome(.pending)
        }

        var reply: String?
        /// Every call of this turn that named **this** run and that no older record has settled on,
        /// in the order the model wrote them.
        var ours: [Call] = []
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
                // The model's reply, for the arms item 51 says are shown with it: **the last thing
                // it said in the turn**, and not the last thing it said before its first tool call.
                // On the arms that need the reply the explanation comes *after* the call — the
                // model learns the resume was refused from the tool result and says so — and a
                // reading that stopped at the first call keeps the announcement ("I'll pass that
                // on") and drops the explanation, which is the sentence item 51 asks to be shown.
                let text = MessageText.text(of: message.blocks, fallback: "")
                if !text.isEmpty { reply = TextSanitiser.sanitise(text) }

            case .toolCall(let call) where call.name == "SendMessage":
                // **This run's own call wins over the order the calls arrived in, and one call
                // belongs to one record.** A model asked to relay two messages produces two calls;
                // reading "the first call naming this run" settles two sends on one call and
                // reports the first send's outcome for both. The wrong-target arm is what is left
                // when the turn carried a `SendMessage` and none of them named this run — and
                // because the state is re-derived from the whole timeline on every ask, a reading
                // taken between the two calls corrects itself the moment this run's own call
                // arrives.
                let verdict = verdict(of: call, for: record)
                if verdict == .wrongTarget { wrongTarget = true }
                else if !calls.contains(call.toolUseID) {
                    let claimedByAYounger = contested.map { index > $0 } == true
                        && youngerDigests.contains { carries($0, call) }
                    ours.append(Call(id: call.toolUseID, index: index, at: call.timestamp ?? .distantPast,
                                     verdict: verdict, carriesThisMessage: carries(record.textDigest, call),
                                     claimedByAYounger: claimedByAYounger))
                }

            case .turnSummary(let turn):
                // The turn this prompt started has closed. Later `SendMessage` calls belong to some
                // other prompt, and this record must not read them as its own.
                if turn.attribution == .prompted(uuid: record.promptUUID) { turnClosed = true }

            default:
                continue
            }
        }

        guard let ours = settling(among: ours) else {
            if wrongTarget {
                return Outcome(.notDelivered(.wrongTarget), reply: reply, turnClosed: turnClosed)
            }
            return Outcome(turnClosed ? .notDelivered(.noCall) : .pending, reply: reply, turnClosed: turnClosed)
        }
        switch ours.verdict {
        case .refused:
            return Outcome(.notDelivered(.refused), reply: reply, claimedCall: ours.id, turnClosed: turnClosed)
        case .running:
            return Outcome(.pending, reply: reply, claimedCall: ours.id, turnClosed: turnClosed)
        // Not stored above, and named here rather than defaulted so a fifth verdict cannot be
        // absorbed by an `default:` that means whatever the last author assumed.
        case .wrongTarget:
            return Outcome(.notDelivered(.wrongTarget), reply: reply, turnClosed: turnClosed)
        case .relayed: break
        }
        if let key = delivery(of: record, in: items, after: ours.index, claiming: claimed,
                              before: competing) {
            return Outcome(.delivered, reply: reply, claimedKey: key, claimedCall: ours.id,
                           turnClosed: turnClosed)
        }
        if stoppedBeforeNextRound(record.target, in: timeline, after: ours.at) {
            return Outcome(.notDelivered(.stoppedBeforeNextRound), reply: reply, claimedCall: ours.id,
                           turnClosed: turnClosed)
        }
        return Outcome(.relayed, reply: reply, claimedCall: ours.id, turnClosed: turnClosed)
    }

    /// One `SendMessage` call of the turn, as this record reads it.
    private struct Call {
        /// The call's `tool_use` id — the engine's own name for it, and not the `ItemID`, which
        /// carries the config home (§11). It is compared and claimed here and stated nowhere.
        let id: String
        let index: Int
        let at: Date
        let verdict: CallVerdict
        /// Whether the call's own `message` carries this record's text. The relay prompt asks for
        /// the message exactly as written, so the ordinary case answers yes; a model that
        /// paraphrased answers no and the call is still a candidate, because the alternative — no
        /// candidate at all — would report *no call* for a relay that happened.
        let carriesThisMessage: Bool
        /// The call lies after a younger record's own prompt echo and carries that record's message.
        /// It is that send's, and this record settles on it only if there is nothing else at all.
        let claimedByAYounger: Bool
    }

    /// Which of this turn's candidate calls this record settles on.
    ///
    /// **The message decides before the order does.** Two calls to one run in one turn are two
    /// different messages, and matching the call that carries *this* record's text is what stops
    /// the second send from reading the first send's result.
    ///
    /// **A call that went through outranks one that did not.** A model that was refused and called
    /// again in the same turn relayed the message; settling on the refusal because it came first
    /// would report *Not delivered* for text that arrived, and the delivery scan below would never
    /// be reached to contradict it.
    /// **A call a younger send has already asked for is not a candidate at all.** Two sends of one
    /// text to one run are told apart by the turn they were made in, and the turn boundary lives in
    /// the overlay — so on a timeline rebuilt from the transcript files the older send would take the
    /// younger one's call and report the younger send's outcome for both. The younger record's own
    /// prompt echo is a transcript record and is the boundary that survives.
    private static func settling(among calls: [Call]) -> Call? {
        let free = calls.filter { !$0.claimedByAYounger }
        let mine = free.filter(\.carriesThisMessage)
        let candidates = mine.isEmpty ? free : mine
        return candidates.first { $0.verdict == .relayed }
            ?? candidates.first { $0.verdict == .running }
            ?? candidates.first
    }

    /// Whether a call's own `message` carries the text this record sent, by the same digest the
    /// delivery scan uses. A call whose input does not decode, or that carries no message, answers
    /// false and is judged by its order alone.
    private static func carries(_ digest: String, _ call: ToolCallItem) -> Bool {
        guard case .sendMessage(let input) = call.input, let message = input.message else { return false }
        return AgentRelayDigest.matches(digest, in: message)
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
        // **The flag is not the whole refusal, and this is the arm that would get it wrong.**
        // `SendMessage` answers `{success, message}` and the engine serialises that object into one
        // text block of an ordinary `tool_result`. A *refused resume* — a run the user stopped, a
        // transcript that is gone, a worktree that went away — comes back `success: false` in a
        // result the engine never flags, because `is_error` is reserved for the tool's
        // validate-input refusals (an empty message, a malformed recipient). Reading only the flag
        // reports a message as relayed to an agent that will never take it: the silent failure item
        // 51 exists to make visible, in its quietest direction, because the surface is reassuring.
        if refusedInBody(call.result) { return .refused }
        // A call with no result yet is a call whose outcome is unknown, and the engine's success
        // string is what *Relayed* is concluded from. `.completed` is the builder's reading of the
        // `tool_result` having arrived.
        return call.status == .completed ? .relayed : .running
    }

    /// Whether the `tool_result`'s own body says the tool declined.
    ///
    /// Read as JSON out of the result's text, because that is the shape the engine writes and the
    /// only place this outcome is stated. A body that is not the tool's own object — a plain
    /// sentence, a shape a later release changes — answers nothing here rather than answering
    /// "refused": an unreadable body is not evidence of a refusal, and treating it as one would put
    /// *Not delivered* on a relay that went through.
    private static func refusedInBody(_ result: JSONValue?) -> Bool {
        guard let result else { return false }
        for text in resultTexts(of: result) {
            guard let data = text.data(using: .utf8),
                  let body = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let success = body["success"]?.boolValue else { continue }
            if !success { return true }
        }
        return false
    }

    /// The text of a `tool_result` body, whichever of its two shapes the engine wrote: a bare
    /// string, or the array of content blocks it uses when the tool returns an object.
    private static func resultTexts(of result: JSONValue) -> [String] {
        if let text = result.stringValue { return [text] }
        guard let blocks = result.arrayValue else { return [] }
        return blocks.compactMap { $0["text"]?.stringValue ?? $0.stringValue }
    }

    /// The delivery frame, or nil: an item **of the target run** after the relay whose text carries
    /// the message, that no earlier record has already claimed.
    ///
    /// Only the two kinds a forwarded message can arrive as — a user frame in the run's own stream,
    /// and a peer message, which is what a frame whose `origin.kind` is not `human` becomes. An
    /// assistant message of the run is the agent *replying*, and a reply quoting the message back is
    /// not the message arriving.
    ///
    /// `contested` is an index this record's delivery cannot lie at or after: the prompt echo of a
    /// younger send whose claim on a frame beats this record's. **The two callers compute it
    /// differently**, because their records are in different positions — the settled overtake passes
    /// `competingSend(with:among:in:)`, which is any younger send of the same text to the same run,
    /// and the unsettled scan passes `supersedingSend(of:among:in:retries:)`, which is the narrower
    /// set. The inline note in `advance(_:in:settled:)`'s unsettled loop says why they differ, and
    /// both helpers carry the reasoning. Nil where no such send exists, which is every relay that
    /// was never re-sent, and the scan then runs to the end of the items as it always has.
    private static func delivery(of record: AgentRelayRecord, in items: [TimelineItem],
                                 after relay: Int, claiming claimed: Set<String>,
                                 before contested: Int? = nil) -> String? {
        let end = min(contested ?? items.endIndex, items.endIndex)
        guard items.index(after: relay) < end else { return nil }
        for index in items.index(after: relay)..<end {
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
    ///
    /// **Its stated limitation (tracker 186).** `lastFrameAt` moves for *any* frame naming the task,
    /// a `task_progress` and a `background_tasks_changed` listing included, so a run that was already
    /// complete and already notified before the relay reads this arm the first time it appears in a
    /// later listing — reported *Not delivered* on the strength of a notification that is not new.
    /// The mirror publishes no instant for the notification and no count of them, and `endedAt` is
    /// stamped once and keeps its first value, so nothing this leaf can read tells a new
    /// notification from an old one. Closing it needs one field on `RegistryEntry` — `notifiedAt`,
    /// or a notification count — which is FleetKit's to publish and not this leaf's to invent. The
    /// arm stays as it is: it is right whenever the run's own frames moved after the relay, and the
    /// way it is wrong is the visible direction — a *Not delivered* with a *Retry* offered on a
    /// message that may still be queued, rather than a *Relayed* on one that will never arrive.
    ///
    /// **And the run's own node where the mirror has no row for it.** Only a live process fills the
    /// mirror, and the fold empties it when that process exits — so reading the mirror alone reports
    /// *Relayed* for ever about a message that will never arrive, the moment the process behind the
    /// relay is gone. The tree's node is the evidence that is left, and it is read narrowly: the run
    /// is terminal and its **end instant is after the relay**, which is the same reading by the same
    /// rule. A node the tree stamped before the relay, and a file-only channel's node, which carries
    /// no end instant at all, both answer no — so this adds no arm where the mirror had none.
    private static func stoppedBeforeNextRound(_ target: AgentRunID, in timeline: ChannelTimeline,
                                               after relay: Date) -> Bool {
        guard let entry = timeline.registry.entries[target] else {
            guard let node = timeline.agents?.node(target), node.status != .running,
                  let ended = node.endedAt else { return false }
            return ended > relay
        }
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
    /// The registry hands itself to the closure rather than being captured by it: a resend that
    /// held the registry would be a cycle through the very object that stores it, and the record a
    /// retry opens belongs to the registry the press came from.
    private var resends: [AgentRelayRecord.ID: @MainActor (AgentRelayRecord.ID, AgentRelayRegistry) async -> Void] = [:]

    /// The conclusions already reached, kept for the life of the app.
    ///
    /// **The one thing the derivation cannot re-derive.** The state is read from the timeline on
    /// every ask, and that is right while the evidence is still arriving — but the evidence a *Not
    /// delivered* is read from includes the turn's `result`, which lives in the ephemeral overlay
    /// and in no transcript record (§7.3). *Check again* rebuilds the workspace and the channel's
    /// timeline comes back from the files with no turn boundary in it, so a record that had already
    /// concluded would go back to *Pending* and then read the **next** send's `SendMessage` call as
    /// its own — two messages settled on one call, which is exactly the correlation item 51 asks
    /// for one-to-one. So a conclusion is kept, and re-derivation touches the unsettled records only.
    ///
    /// `@ObservationIgnored` because it is the derivation's own memory and not state a surface
    /// draws: the reading a row shows is published by `records` and by the timeline it is derived
    /// from, and a write here during a body evaluation must not invalidate that body.
    @ObservationIgnored private var settlements: [AgentRelayRecord.ID: AgentRelayMachine.Outcome] = [:]

    /// The records of each channel that hold no settlement yet — the publish gate, as a membership
    /// question rather than a scan.
    ///
    /// `observe(_:in:)` runs on every publish of every channel, so the gate itself must not grow
    /// with the channel's relay history: a record enters when it opens and leaves when its
    /// conclusion is stored, and a channel whose set is empty costs one dictionary read. Held beside
    /// `settlements` rather than derived from it for that reason, and `@ObservationIgnored` for the
    /// same reason.
    @ObservationIgnored private var unsettled: [ChannelKey: Set<AgentRelayRecord.ID>] = [:]

    /// Opens a record for a send that has already happened. Called after `sendPrompt` returned its
    /// uuid, never before: a record for a send the engine refused would be a message with a state and
    /// no message.
    @discardableResult
    func open(promptUUID: String, target: AgentRunID, textDigest: String, in channel: ChannelKey,
              at sentAt: Date = Date(), retryOf: AgentRelayRecord.ID? = nil,
              resend: (@MainActor (AgentRelayRecord.ID, AgentRelayRegistry) async -> Void)? = nil) -> AgentRelayRecord {
        let record = AgentRelayRecord(id: AgentRelayRecord.ID(raw: UUID()), promptUUID: promptUUID,
                                      target: target, textDigest: textDigest, sentAt: sentAt, retryOf: retryOf)
        records[channel, default: []].append(record)
        unsettled[channel, default: []].insert(record.id)
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
        let records = records(in: channel)
        derivations += 1
        let outcomes = AgentRelayMachine.advance(records, in: timeline, settled: settlements)
        for record in records {
            guard let outcome = outcomes[record.id], outcome.isSettled else { continue }
            settlements[record.id] = outcome
            unsettled[channel]?.remove(record.id)
        }
        return outcomes
    }

    /// The same pass, run because the channel **published** rather than because a surface asked, so
    /// that whatever settled is stored whether or not anything drew it.
    ///
    /// **Why the publish and not the ask.** A settlement is memory, and memory written only when a
    /// row or a node asks is memory a channel nobody is looking at never gets. The evidence a *Not
    /// delivered* is read from includes the turn's `result`, which is wire-only (§7.3): a relay
    /// whose turn closed while the reader was on another channel has nothing stored when *Check
    /// again* rebuilds the timeline from the files, and the record then reads *Pending* for good —
    /// or, worse, scans on past its own vanished turn boundary and takes a later turn's
    /// `SendMessage` call as its own. The timeline model keeps folding and keeps publishing for a
    /// channel that is not in view, which is exactly the case a reading cannot cover.
    ///
    /// **It answers nothing and draws nothing** (contract Y8): no item, no persisted store, and no
    /// change to what a row or a node shows while the evidence is still there. The only difference
    /// is that a conclusion reached with nobody looking is the conclusion a later reading gives.
    ///
    /// **The cost gate.** It returns before the pass for a channel with no records and for one whose
    /// every record has already settled — one dictionary read either way, over the set `unsettled`
    /// maintains — so the derivation runs only while a channel holds a relay still in flight: few,
    /// and for the length of a turn. Nothing else is compared: a publish
    /// happens *because* the fold changed, so a memo of the timeline's item count would skip almost
    /// no pass a streaming channel makes and would cost a comparison on every one of them. What is
    /// left of the shape is tracker 451.
    func observe(_ timeline: ChannelTimeline, in channel: ChannelKey) {
        guard let waiting = unsettled[channel], !waiting.isEmpty else { return }
        _ = outcomes(in: channel, of: timeline)
    }

    /// How many times the derivation has run: a reading, or a publish that passed the gate above.
    ///
    /// Counted for the reason `RetractionRegistry.decodes` is — the gate is invisible from the
    /// state, because the derivation is idempotent and a pass that was skipped changes nothing a
    /// surface can see, so the only way to assert it is the number of passes. `@ObservationIgnored`
    /// for `settlements`' reason: it is bookkeeping about work already done and nothing draws it.
    @ObservationIgnored private(set) var derivations = 0

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
        Task { [weak self] in
            guard let self else { return }
            await resend(id, self)
        }
    }
}
