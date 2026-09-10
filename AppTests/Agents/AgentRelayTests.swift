import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.4 Task 7, gate G4's headless half: item 51's *Pending → Relayed → Delivered* path and its four
/// *Not delivered* arms, over decoded frame sequences.
///
/// **Every arm asserts the evidence the state was concluded from, and never that a surface changed.**
/// A message showing *Delivered* is not delivery concluded from the agent's transcript: the
/// discriminating half of each arm is the near miss — a `SendMessage` naming another agent, the same
/// text in the main stream, a turn that has not closed — and a machine that settles too early or
/// ignores the target id passes every "it eventually says delivered" assertion there is.
///
/// **The frames are decoded, not assembled.** Each one is written as JSON and put through
/// `FrameDecoder` and `WireReducer` — C3's own reducer, the one a live channel runs — so what the
/// machine reads is the projection production would have produced. Every identifier is invented and
/// no fixture byte is quoted (§11); the fixture replay is Task 8's.
///
/// Nothing here prints a message text, a task id, a prompt uuid or a path: an assertion over a value
/// that reaches one is a boolean with a written message.
@MainActor
final class AgentRelayTests: XCTestCase {

    // MARK: - Pending → Relayed

    /// **G4: *Relayed* is settled by the target's own call, and by nothing else.**
    ///
    /// Three readings over one growing timeline: before any call it is *Pending*; a `SendMessage`
    /// still running is *Pending*; the same call with a non-error result is *Relayed*. The `to` of
    /// the call is the target's id, read off the call's own input.
    func testPendingBecomesRelayedOnlyOnTheTargetsOwnCall() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()

        XCTAssertTrue(wire.state(of: record) == .pending,
                      "a send with no SendMessage call on the wire settled something other than pending")

        wire.sendMessageCall(to: RelayWire.target)
        XCTAssertTrue(wire.state(of: record) == .pending,
                      "a SendMessage call with no result yet was read as relayed")

        wire.toolResult(isError: false)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "the target's own SendMessage call and a non-error result did not settle relayed")
    }

    /// **G4, the discriminating half: a `SendMessage` naming a different agent does not advance.**
    ///
    /// It settles `.notDelivered(.wrongTarget)` — the model answered the request, and answered it
    /// about someone else. A machine that advanced on "a SendMessage happened" reads this as
    /// *Relayed* and then waits for a delivery that cannot come.
    func testASendMessageNamingAnotherAgentSettlesWrongTargetAndDoesNotAdvance() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()

        wire.sendMessageCall(to: RelayWire.otherAgent)
        wire.toolResult(isError: false)

        XCTAssertTrue(wire.state(of: record) == .notDelivered(.wrongTarget),
                      "a SendMessage naming a different agent did not settle the wrong-target arm")
    }

    /// A turn that relays to two agents settles each record on **its own** call, whichever the model
    /// wrote first.
    ///
    /// Without it, a user who messages two runs in the same turn is told one of them went to the
    /// wrong agent — and the arm they are shown is a real arm, so nothing about the surface looks
    /// wrong.
    func testATurnRelayingToTwoAgentsSettlesThisRecordOnItsOwnCall() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()

        wire.sendMessageCall(to: RelayWire.otherAgent)
        wire.toolResult(isError: false)
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.wrongTarget),
                      "a turn whose only SendMessage named another agent did not settle the wrong-target arm")

        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.toolResult(id: RelayWire.secondSendCall, isError: false)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "this run's own call in the same turn did not take precedence over another's")
    }

    // MARK: - Relayed → Delivered

    /// **G4: *Delivered* is the text in the target run's own items, and nothing else.**
    ///
    /// The near miss is the whole point: the same text forwarded on the **main** stream does not
    /// advance it, because the main stream is where the relay was asked for. Both halves run over one
    /// timeline, in that order, so a machine that scanned every item passes the first and fails here.
    func testRelayedBecomesDeliveredOnlyOnTheTextInTheAgentsTranscript() {
        var wire = RelayWire()
        wire.open()
        wire.openOther()
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)

        wire.mainStreamMessage(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "the message text appearing in the main stream was read as delivery")

        // The two negative controls, and they are the whole discrimination. A machine that accepted
        // **any** frame of the target run passes on the first; one that accepted the record's own
        // text **wherever** it landed passes on the second. Both are near misses a live channel
        // produces: an agent goes on working after the relay, and a turn relays to two runs.
        wire.forwarded(RelayWire.secondMessage)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "a frame of the target run that carries some other text was read as this message arriving")
        wire.forwardedToOther(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "this message arriving in another run's transcript was read as delivery to the target")

        wire.forwarded(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .delivered,
                      "the message text in the agent's own transcript did not settle delivered")
    }

    /// Correlated one-to-one: two sends of the same text to the same run are two messages, and one
    /// forwarded frame is evidence for one of them.
    ///
    /// Without the correlation both records read *Delivered* off the same frame — which is the
    /// premature conclusion in its quietest form, because the surface looks entirely correct.
    func testOneForwardedFrameDeliversOneSendAndNotBoth() {
        var wire = RelayWire()
        wire.open()
        let first = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)
        let second = wire.record(promptUUID: RelayWire.secondPromptUUID)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.toolResult(id: RelayWire.secondSendCall, isError: false)

        wire.forwarded(RelayWire.message)

        XCTAssertTrue(wire.state(of: first) == .delivered,
                      "the first send did not take the one forwarded frame")
        XCTAssertFalse(wire.state(of: second) == .delivered,
                       "one forwarded frame was read as delivering two separate sends")
    }

    // MARK: - Settlement across a rebuild (recomposition finding 1)

    /// **A settled arm survives *Check again*, and the call it did not claim stays free.**
    ///
    /// The turn boundary this machine reads its no-call arm from is a `turnSummary`, and a turn
    /// summary comes from a `result` frame, which is wire-only: §7.3 puts per-turn cost and usage in
    /// the ephemeral overlay, and the recorded transcript of a two-turn session carries no `result`
    /// record at all. So a timeline rebuilt from the transcript files — what *Check again* leaves
    /// behind — has no boundary in it, and an older record that had already read *Not delivered*
    /// scans on past its own turn into the next one.
    ///
    /// Both halves are asserted, because either alone passes against the defect's opposite: the
    /// older record must keep the conclusion it settled on, **and** the newer record must still get
    /// the call, which is item 51's one-to-one correlation.
    func testASettledArmSurvivesARebuildThatCarriesNoTurnSummaries() {
        var wire = RelayWire()
        wire.open()
        let older = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()
        XCTAssertTrue(wire.state(of: older) == .notDelivered(.noCall),
                      "the first turn closed with no SendMessage call and did not settle the no-call arm")

        // The same channel as its transcript files hold it: every record, and none of the overlay.
        XCTAssertEqual(wire.rebuiltFromFiles.overlay.turns.count, 0,
                       "the file-only rebuild carries \(wire.rebuiltFromFiles.overlay.turns.count) turn summary(s), "
                       + "so this asserts nothing about a timeline with no turn boundary in it")
        XCTAssertTrue(wire.state(of: older, in: wire.rebuiltFromFiles) == .notDelivered(.noCall),
                      "a settled no-call arm returned to another state once the turn boundary was gone")

        // A second send of the same text to the same run, in a later turn, which the model relays.
        let newer = wire.record(promptUUID: RelayWire.secondPromptUUID)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        wire.forwarded(RelayWire.message)

        XCTAssertTrue(wire.state(of: older, in: wire.rebuiltFromFiles) == .notDelivered(.noCall),
                      "the older record claimed a later send's call once the turn boundary was gone")
        XCTAssertTrue(wire.state(of: newer, in: wire.rebuiltFromFiles) == .delivered,
                      "the newer record did not claim its own call and delivery after the rebuild")
    }

    /// **The one-to-one contract holds across a rebuild even for a record nobody read.**
    ///
    /// Settlement is memory, and memory is only written when something asks: a relay sent on a
    /// channel the reader then leaves, whose turn closes with nobody drawing its row, has no
    /// conclusion stored when *Check again* rebuilds the timeline. The correlation must not depend
    /// on that. A younger record's own prompt echo is in the transcript and survives the rebuild, so
    /// a call that lies after it and carries the younger record's message is the younger record's.
    ///
    /// The older record reads *Pending* here rather than *Not delivered* — its turn boundary is
    /// genuinely gone and pending is the honest answer — and what this asserts is that it did not
    /// take the younger send's call, which is what item 51's one-to-one correlation is.
    func testAnUnreadRecordStillDoesNotClaimALaterSendsCallAfterARebuild() {
        var wire = RelayWire()
        wire.open()
        let older = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()                                     // the turn closes, and nothing reads it

        let newer = wire.record(promptUUID: RelayWire.secondPromptUUID)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        wire.forwarded(RelayWire.message)

        // The first reading of either record is taken against the rebuilt timeline: no conclusion
        // was ever stored, so this is the derivation alone.
        let rebuilt = wire.rebuiltFromFiles
        XCTAssertTrue(wire.state(of: newer, in: rebuilt) == .delivered,
                      "the younger send did not claim its own call and delivery")
        XCTAssertTrue(wire.state(of: older, in: rebuilt) == .pending,
                      "an unread older record took the younger send's call once the turn boundary was gone")
    }

    /// **A turn that closed with nobody drawing the channel still concluded (tracker 435).**
    ///
    /// The channel publishes; the reader is somewhere else, so no row and no node asks for a
    /// reading. The turn closes with no `SendMessage` in it, which is item 51's first *Not
    /// delivered* arm — and the only evidence for it is the turn's `result`, which §7.3 puts in the
    /// ephemeral overlay and no transcript record carries. So unless the publish itself takes the
    /// conclusion, *Check again* rebuilds the timeline and the record reads *Pending* for ever: the
    /// user is told a message is on its way that the model never sent, and is offered no *Retry*.
    ///
    /// The discriminating half is that no reading is taken before the rebuild. With one, this passes
    /// against the derivation alone — which is what `testASettledArmSurvivesARebuildThatCarriesNoTurnSummaries`
    /// above already covers.
    func testAConclusionReachedWithNothingDrawingItSurvivesARebuild() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()
        wire.publish()

        let rebuilt = wire.rebuiltFromFiles
        XCTAssertEqual(rebuilt.overlay.turns.count, 0,
                       "the file-only rebuild carries \(rebuilt.overlay.turns.count) turn summary(s), "
                       + "so this asserts nothing about a timeline with no turn boundary in it")
        XCTAssertTrue(wire.state(of: record, in: rebuilt) == .notDelivered(.noCall),
                      "a turn that closed while nothing drew the channel lost its conclusion to the rebuild")
    }

    /// **And it does not take a later turn's call for its own.**
    ///
    /// The sharper direction of the same loss. A record whose turn boundary is gone scans on into
    /// the turns after it, and where no younger *relay* bounds the scan — the ordinary case, because
    /// the next turn is usually an ordinary prompt — the next `SendMessage` naming this run is read
    /// as this record's own. The row then says *Relayed* about a message the model never sent, which
    /// is worse than *Pending*: it is a wrong answer in the reassuring direction, and it offers no
    /// *Retry* either.
    ///
    /// The later turn relays a **different** message to the same run, so the call is a real call
    /// with a real delivery behind it and nothing about the timeline looks wrong.
    func testAnUnreadConclusionIsNotOverwrittenByALaterTurnsCall() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()
        wire.publish()

        // A later turn of the same channel, which relays something else to the same run.
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall,
                             message: RelayWire.secondMessage)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        wire.forwarded(RelayWire.secondMessage)
        wire.result()
        wire.publish()

        XCTAssertTrue(wire.state(of: record, in: wire.rebuiltFromFiles) == .notDelivered(.noCall),
                      "the record read a later turn's SendMessage call as its own once the turn boundary was gone")
    }

    /// **The publish hook costs nothing on a channel with no relay, and nothing more on a settled one.**
    ///
    /// This runs on the thirty-hertz publish path of **every** channel, and almost no channel has
    /// ever relayed anything: a hook that advanced the derivation regardless would put a pass over
    /// the whole timeline into every publish the app makes, which is the growth §8.3 forbids. The
    /// gate is invisible from the state — the derivation is idempotent, so a skipped pass changes
    /// nothing a surface can see — and the number of passes is the only thing that can assert it.
    func testThePublishHookRunsTheDerivationOnlyForAChannelWithARelayInFlight() {
        var wire = RelayWire()
        wire.open()
        for _ in 0..<30 { wire.publish() }
        XCTAssertEqual(wire.relay.derivations, 0,
                       "30 publishes over a channel that has relayed nothing ran the derivation "
                       + "\(wire.relay.derivations) time(s), not 0")

        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()
        wire.publish()
        XCTAssertEqual(wire.relay.derivations, 1,
                       "the publish that closed the turn ran the derivation \(wire.relay.derivations) time(s), not 1")
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.noCall),
                      "the record did not settle, so the clause below asserts nothing about a settled channel")

        let settled = wire.relay.derivations
        for _ in 0..<30 { wire.publish() }
        XCTAssertEqual(wire.relay.derivations, settled,
                       "30 publishes over a channel whose every record has settled ran the derivation "
                       + "\(wire.relay.derivations - settled) more time(s), not 0")
    }

    /// **Two sends in one turn, concluded at publish time, still settle on their own calls.**
    ///
    /// Item 51's correlation is one-to-one and the settlement is what protects it across a rebuild,
    /// so a settlement written by the publish rather than by a reading must claim the same call the
    /// reading would have. The turn relays twice: the first call is refused and the second goes
    /// through, and both conclusions are taken with nothing drawing either row.
    func testTwoSendsInOneTurnConcludedAtPublishTimeKeepTheirOwnCalls() {
        var wire = RelayWire()
        wire.open()
        let first = wire.record()
        let second = wire.record(promptUUID: RelayWire.secondPromptUUID, message: RelayWire.secondMessage)

        wire.sendMessageCall(to: RelayWire.target, message: RelayWire.message)
        wire.sendMessageResult(success: false)
        wire.publish()
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall,
                             message: RelayWire.secondMessage)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        wire.result()
        wire.publish()

        let rebuilt = wire.rebuiltFromFiles
        XCTAssertTrue(wire.state(of: first, in: rebuilt) == .notDelivered(.refused),
                      "the refused send did not keep the call that carried its own message")
        XCTAssertTrue(wire.state(of: second, in: rebuilt) == .relayed,
                      "the second send took the first send's conclusion after the rebuild")
    }

    /// **A settled *Not delivered* still yields to the message arriving.**
    ///
    /// The fourth arm is the provisional one: it concludes that a run stopped without taking the
    /// message, and the message can still turn up in that run's own transcript afterwards. A
    /// settlement that froze it would leave *Not delivered* and a *Retry* on a message that had
    /// arrived, and the retry would send it twice.
    func testASettledNotDeliveredYieldsToTheMessageArriving() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.sendMessageResult(success: true)
        wire.assistantText(RelayWire.reply)
        wire.result()                                     // the turn closes: the arm below settles
        wire.taskNotification()
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.stoppedBeforeNextRound),
                      "the fourth arm did not settle, so the correction below proves nothing")

        wire.forwarded(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .delivered,
                      "the message arrived in the run's own transcript and the record kept its refusal")
    }

    /// **The fourth arm survives the process that filled the mirror.**
    ///
    /// It is read off `RegistryEntry`, and the mirror is emptied when the process exits, because
    /// only a live process can fill it. The run's own node is the evidence that is left: a run the
    /// exit ended after the relay took no round after it, which is the same conclusion by the same
    /// rule. Without the fallback the record reads *Relayed* for ever about a message that will
    /// never arrive — the reassuring direction item 51 exists to end.
    func testTheFourthArmIsStillReadWhenTheProcessThatFilledTheMirrorIsGone() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.sendMessageResult(success: true)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "the call did not settle relayed, so the arm below is reached from another state")

        wire.processExited()
        XCTAssertEqual(wire.timeline.registry.entries.count, 0,
                       "the exit left \(wire.timeline.registry.entries.count) mirror row(s), so the fallback "
                       + "below is never reached")
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.stoppedBeforeNextRound),
                      "a run the process exit ended after the relay was not read as having stopped")
    }

    // MARK: - The four Not delivered arms

    /// **G4, arm one: the turn ends with no `SendMessage` call.**
    ///
    /// The evidence is the `result` frame the reducer attributes to *this* prompt uuid. Both sides
    /// are asserted over one timeline: while the turn is open the reading is *Pending*, because a
    /// model that has not yet called the tool has not declined to; the `result` is what makes it a
    /// refusal.
    func testATurnEndingWithNoSendMessageIsNotDelivered() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)

        XCTAssertTrue(wire.state(of: record) == .pending,
                      "an open turn with no SendMessage call yet was already called not delivered")

        wire.result()
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.noCall),
                      "a turn that closed with no SendMessage call did not settle the no-call arm")
        XCTAssertTrue(wire.reading(of: record).reply == RelayWire.reply,
                      "the no-call arm dropped the model's own reply")
    }

    /// **G4, arm two in its flagged shape: an `is_error` `tool_result`, with the model's reply
    /// kept.**
    ///
    /// This is the tool's **validate-input** refusal — an empty message, a malformed recipient —
    /// which is the one thing the engine flags. A *refused resume* is the same arm arriving in the
    /// other shape and is asserted below. Either way the reading is taken from the result and never
    /// from the engine's sentence, which is the engine's to word and not this leaf's to match.
    func testAnErrorToolResultIsNotDeliveredAndKeepsTheModelsReply() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: true)

        XCTAssertTrue(wire.state(of: record) == .notDelivered(.refused),
                      "an error tool result did not settle the refused arm")
        XCTAssertTrue(wire.reading(of: record).reply == RelayWire.reply,
                      "the refused arm dropped the model's own reply")
        XCTAssertNotNil(wire.reading(of: record).retry,
                        "a refused relay offered no retry")
    }

    /// **G4, arm two's other half: a refused resume carries no `is_error`, and is still not
    /// delivered.**
    ///
    /// The pinned bundle's `SendMessage` returns `{success, message}` and the engine serialises that
    /// object into one text block of an **ordinary** `tool_result`. `is_error` is reserved for the
    /// tool's validate-input refusals; the four resume refusals parity §18.25.4 lists — a run the
    /// user stopped, a missing transcript, forked-skill scoping, a worktree gone — arrive as results
    /// the engine never flags.
    ///
    /// Both halves run over one timeline, in this order, because the discrimination is the whole
    /// point: two results identical in every field a flag-reading machine looks at, one of which is
    /// a delivery in progress and the other of which is a message that will never arrive. A machine
    /// reading only the flag passes the first assertion and fails here — and in production says
    /// *Relayed* for ever about an agent that was stopped, which is the reassuring direction of the
    /// silent failure item 51 exists to end.
    func testARefusedResumeCarriesNoErrorFlagAndIsStillNotDelivered() {
        var wire = RelayWire()
        wire.open()
        let first = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.sendMessageResult(success: true)
        XCTAssertTrue(wire.state(of: first) == .relayed,
                      "a result whose body says the tool succeeded did not settle relayed")

        let second = wire.record(promptUUID: RelayWire.secondPromptUUID)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: false)
        XCTAssertTrue(wire.state(of: second) == .notDelivered(.refused),
                      "a refused resume with no error flag was read as relayed")
        XCTAssertNotNil(wire.reading(of: second).retry,
                        "a refused resume offered no retry")
    }

    /// A result body the tool did not write answers nothing: an unreadable body is not evidence of a
    /// refusal, and reading it as one would put *Not delivered* on a relay that went through.
    func testAResultBodyThatIsNotTheToolsObjectDoesNotSettleRefused() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)

        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "a non-error result whose body is not the tool's own object was read as a refusal")
    }

    /// **G4, arm four: the target's `task_notification` arrives after *Relayed* with no further tool
    /// round.**
    ///
    /// The near miss is the ordinary case item 51 is written about: the run was **already complete**
    /// when the message was sent, so its terminal status is not evidence of anything. What settles
    /// the arm is a notification whose frame arrived *after* the relay, which is why the reading is
    /// asserted twice — once with the run finished before the send, and once after it ended again.
    func testANotificationAfterRelayedWithNoFurtherRoundIsNotDelivered() {
        var wire = RelayWire()
        wire.open()
        wire.taskNotification()                       // the run completed before the user ever sent
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)

        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "a run that finished before the send was read as having stopped after it")

        wire.taskNotification()
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.stoppedBeforeNextRound),
                      "a notification after the relay with no further round did not settle the fourth arm")
    }

    /// The fourth arm never overtakes delivery: a run that received the message and then ended is
    /// *Delivered*, because the text is in its transcript.
    func testARunThatReceivedTheMessageAndThenEndedIsDelivered() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)
        wire.forwarded(RelayWire.message)
        wire.taskNotification()

        XCTAssertTrue(wire.state(of: record) == .delivered,
                      "a run that received the message and then ended was reported as not delivered")
    }

    /// The four reasons stay four named cases. A fifth way to fail has to be named to be added, which
    /// is what stops it being folded behind a sentence already on screen.
    func testTheFourReasonsAreNamedSeparately() {
        XCTAssertEqual(AgentRelayState.Reason.allCases.count, 4,
                       "item 51's arms are four, and this enum holds \(AgentRelayState.Reason.allCases.count)")
        let sentences = Set(AgentRelayState.Reason.allCases.map { AgentRelayState.notDelivered($0).sentence })
        XCTAssertEqual(sentences.count, 4,
                       "\(4 - sentences.count) of the four arms share a sentence with another")
    }

    /// **One turn, two sends to one run: each record settles on its own call.**
    ///
    /// The model relays two messages in one turn; the first call is refused and the second goes
    /// through. A machine that took "the first `SendMessage` naming this run" settles **both**
    /// records on the refused call, so the second message is reported *Not delivered* while it is
    /// on its way — and the arm shown is a real arm, so nothing about the surface looks wrong.
    func testTwoSendsToOneRunInOneTurnSettleOnTheirOwnCalls() {
        var wire = RelayWire()
        wire.open()
        let first = wire.record()
        let second = wire.record(promptUUID: RelayWire.secondPromptUUID, message: RelayWire.secondMessage)

        wire.sendMessageCall(to: RelayWire.target, message: RelayWire.message)
        wire.sendMessageResult(success: false)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall, message: RelayWire.secondMessage)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)

        XCTAssertTrue(wire.state(of: first) == .notDelivered(.refused),
                      "the refused send did not settle on the call that carried its own message")
        XCTAssertTrue(wire.state(of: second) == .relayed,
                      "the second send settled on the first send's call rather than on its own")
    }

    /// **A refusal the model retried in the same turn is not a refusal.**
    ///
    /// The model calls `SendMessage`, is told the resume failed, calls again and succeeds; the text
    /// then arrives in the run's own transcript. A machine that settled on the first call naming
    /// this run reports *Not delivered* about a message that was delivered — and never reaches the
    /// delivery scan that would contradict it.
    func testARefusalRetriedInTheSameTurnSettlesOnTheCallThatWentThrough() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()

        wire.sendMessageCall(to: RelayWire.target)
        wire.sendMessageResult(success: false)
        XCTAssertTrue(wire.state(of: record) == .notDelivered(.refused),
                      "the refused call did not settle the refused arm, so the retry below changes nothing")

        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "a call that went through in the same turn was outranked by the refusal before it")

        wire.forwarded(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .delivered,
                      "the message arrived in the run's transcript and the record stayed at a refusal")
    }

    /// **The reply shown is what the model said after it learned the outcome.**
    ///
    /// Item 51 shows a *Not delivered* arm "with the model's reply", and on the refused arm the
    /// reply that explains anything is the one *after* the tool result: before the call the model
    /// has only announced what it is about to do. A reading that stopped at the first tool call
    /// keeps the announcement and drops the explanation.
    func testTheReplyIsWhatTheModelSaidAfterTheCall() {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.sendMessageCall(to: RelayWire.target)
        wire.sendMessageResult(success: false)
        wire.assistantText(RelayWire.explanation)
        wire.result()

        XCTAssertTrue(wire.state(of: record) == .notDelivered(.refused),
                      "the refused resume did not settle the refused arm, so the reply below is from another arm")
        XCTAssertTrue(wire.reading(of: record).reply == RelayWire.explanation,
                      "the arm shows what the model said before it called the tool, not what it said "
                      + "once the tool answered")
    }

    // MARK: - The send, and Retry

    /// **The send is X5 and the raise that goes with it, and nothing else** (contract Y5).
    ///
    /// One `sendPrompt` on the node's channel, followed by the `HostSignal.promptSent` carrying the
    /// uuid it minted. A send that skipped the raise leaves the turn it caused reducing as
    /// `.unprompted` — and this leaf's own no-call arm reads that attribution, so the omission would
    /// be invisible until an arm silently stopped settling.
    func testTheSendIsOnePromptAndTheRaiseThatIsInseparableFromIt() async {
        let rig = SendRig()
        let sent = await rig.actions.sendMessage(RelayWire.message, to: rig.content)

        XCTAssertTrue(sent, "the send reported failure with a lifecycle that accepted it")
        let prompts = await rig.lifecycle.prompts
        XCTAssertEqual(prompts.count, 1, "one press sent \(prompts.count) prompt(s)")
        // **The input, and not the count.** A count is satisfied by an empty request, by a prompt
        // naming another run and by one carrying different text — three sends that all reach the
        // engine and none of which is this one. Read off the recorded `UserInput` and stated as
        // booleans, because the operands are the message text and the run's id (§11); and derived
        // from the three facts the prompt has to carry rather than from `prompt(relaying:to:)`,
        // which would make the expectation agree with whatever that expression happens to compose.
        let input = prompts.first
        XCTAssertTrue(input.map { AgentRelayDigest.matches(AgentRelayDigest.of(RelayWire.message), in: $0.text) } == true,
                      "the prompt the engine was given does not carry the message the user typed")
        XCTAssertTrue(input?.text.contains(rig.content.id) == true,
                      "the prompt the engine was given does not name the run it is for")
        XCTAssertTrue(input?.text.contains("SendMessage") == true,
                      "the prompt the engine was given does not ask for the tool that does the relaying")
        let onTheNodesChannel = await rig.lifecycle.channels.allSatisfy { $0 == rig.key }
        XCTAssertTrue(onTheNodesChannel, "the prompt went out on a channel other than the node's")
        XCTAssertEqual(rig.raised.count, 1, "the send raised \(rig.raised.count) host signal(s), not 1")
        let minted = await rig.lifecycle.minted.first
        XCTAssertTrue(rig.raisedTheMintedPrompt(minted),
                      "the raise did not carry the uuid the lifecycle minted for this send")
        XCTAssertEqual(rig.relay.records(in: rig.key).count, 1,
                       "one send opened \(rig.relay.records(in: rig.key).count) relay record(s)")
    }

    /// A refused send opens **no** record: a message with a state and no message is worse than no
    /// message at all.
    func testARefusedSendOpensNoRecord() async {
        let rig = SendRig()
        await rig.lifecycle.refuse(.notOwned)

        let sent = await rig.actions.sendMessage(RelayWire.message, to: rig.content)

        XCTAssertFalse(sent, "a refused send reported success")
        XCTAssertEqual(rig.relay.records(in: rig.key).count, 0,
                       "a refused send opened \(rig.relay.records(in: rig.key).count) relay record(s)")
        XCTAssertEqual(rig.raised.count, 0,
                       "a refused send raised \(rig.raised.count) host signal(s), and the engine was given no prompt")
    }

    /// **G4: *Retry* opens a second record, and the first is still not delivered.**
    ///
    /// The failed record keeps its state and its place — a relay that failed is a thing that happened
    /// — and the new one records what it descended from.
    func testRetryOpensANewRecordAndTheFailedOneKeepsItsState() async throws {
        let rig = SendRig()
        await rig.actions.sendMessage(RelayWire.message, to: rig.content)
        let first = rig.relay.records(in: rig.key)[0]

        // **A relay that actually failed**, on the channel's own frames: the turn this send started
        // closed with no `SendMessage` in it. Without it there is no failure for the retry to
        // preserve and no *Retry* to press — the reading offers one only on a *Not delivered* arm.
        var wire = RelayWire()
        wire.open()
        wire.echo(promptUUID: first.promptUUID)
        wire.result()
        rig.timeline = wire.timeline
        XCTAssertTrue(rig.reading(of: first).state == .notDelivered(.noCall),
                      "the first relay did not fail, so nothing below is about a retry")

        // Pressed through the reading the row draws, not through the registry's member: what item
        // 51 offers is a button, and a reading that offered none would pass a direct call.
        let retry = try XCTUnwrap(rig.reading(of: first).retry, "a failed relay offered no Retry to press")
        retry()
        let opened = await Self.settle { rig.relay.records(in: rig.key).count == 2 }
        XCTAssertTrue(opened, "Retry opened \(rig.relay.records(in: rig.key).count) record(s), not 2")

        let records = rig.relay.records(in: rig.key)
        XCTAssertTrue(records[0].id == first.id, "Retry replaced the record that failed instead of adding one")
        XCTAssertTrue(records[1].retryOf == first.id, "the retry recorded no lineage back to the relay it retried")
        XCTAssertTrue(records[1].textDigest == first.textDigest, "the retry re-sent something other than the message")
        let prompts = await rig.lifecycle.prompts
        XCTAssertEqual(prompts.count, 2, "Retry sent \(prompts.count) prompt(s) in total, not 2")

        // **The retry's own turn, and the failure that survives it.** The re-sent message is
        // relayed and arrives; the record that failed keeps its arm and its *Retry*. A delivery
        // scan that awarded the retry's forwarded frame to the older record would report the first
        // send as delivered — erasing the only evidence the user has that it was not.
        wire.echo(promptUUID: records[1].promptUUID)
        wire.sendMessageCall(to: RelayWire.target, id: RelayWire.secondSendCall)
        wire.sendMessageResult(id: RelayWire.secondSendCall, success: true)
        wire.forwarded(RelayWire.message)
        rig.timeline = wire.timeline

        XCTAssertTrue(rig.reading(of: records[1]).state == .delivered,
                      "the retry's own relay did not conclude from the run's transcript")
        XCTAssertTrue(rig.reading(of: first).state == .notDelivered(.noCall),
                      "the retry's frames moved the record that failed, so the failed relay's history is gone")
        XCTAssertTrue(rig.reading(of: first).retry != nil,
                      "the record that failed stopped offering a retry once its retry succeeded")
    }

    // MARK: - The sheet's draft

    /// **A refused send keeps the draft and says why** (item 51, `ComposerModel.post(_:)`'s rule).
    ///
    /// The field is the only copy of what the user typed until `sendPrompt` answers: no record is
    /// open, so a sheet that dismissed before awaiting the answer destroys the message on every
    /// transport failure and every ownership refusal, leaving nothing to retry from. The press
    /// answers a sentence exactly when it did **not** send, and the sheet closes on nil alone.
    ///
    /// Discriminating: a press that ignored the send's result answers nil on both halves, so the
    /// refused half is what fails against it.
    func testARefusedPressKeepsTheDraftAndSaysWhy() async {
        let refusing = SendRig()
        await refusing.lifecycle.refuse(.notOwned)

        let refusal = await SendMessageSheet.send(RelayWire.message, to: refusing.content,
                                                  through: refusing.actions)

        XCTAssertTrue(refusal != nil,
                      "a refused send answered no sentence, so the sheet closes and the draft is gone")
        XCTAssertTrue(refusal?.isEmpty == false, "the refused press answered an empty sentence")
        XCTAssertEqual(refusing.relay.records(in: refusing.key).count, 0,
                       "a refused send opened \(refusing.relay.records(in: refusing.key).count) relay record(s)")

        // The other half, on a lifecycle that accepts: the press answers nil, which is the only
        // thing that closes the sheet — without it the clause above passes on a sheet that never
        // closes at all.
        let accepting = SendRig()
        let accepted = await SendMessageSheet.send(RelayWire.message, to: accepting.content,
                                                   through: accepting.actions)
        XCTAssertTrue(accepted == nil, "an accepted send answered a refusal, so the sheet stays open on a sent message")
        XCTAssertEqual(accepting.relay.records(in: accepting.key).count, 1,
                       "an accepted send opened \(accepting.relay.records(in: accepting.key).count) relay record(s), not 1")
    }

    /// **G4: *Retry* survives the panel session that sent the message.**
    ///
    /// The relay record and the row that draws it are app-scoped — the row is on the channel column,
    /// which is not this tab — so the *Retry* the row offers has to be too. A resend that captured
    /// the panel's own action object goes silent the moment the host evicts that channel's session
    /// or *Check again* replaces the workspace: the record still offers *Retry*, and pressing it
    /// sends nothing at all, which is the silent non-delivery item 51 exists to prevent.
    ///
    /// Discriminating: the action object is released before the press, and the assertion is that a
    /// second prompt reached the engine anyway.
    func testRetrySurvivesTheEvictedPanelSession() async {
        let lifecycle = PromptDouble()
        let relay = AgentRelayRegistry()
        let key = ChannelKey(configHome: RelayWire.configHome, session: RelayWire.session)
        let box = RaiseBox()
        var actions: AgentNodeActions? = AgentNodeActions(lifecycle: lifecycle, reaching: { lifecycle },
                                                          channel: key, relay: relay,
                                                          raiseSignal: { _, signal in await box.record(signal) })
        weak var evicted = actions
        await actions?.sendMessage(RelayWire.message, to: SendRig.content)
        let first = relay.records(in: key)[0]

        // The eviction: the host releases the panel's session for this channel and nothing else
        // holds its actions. A boolean, not `XCTAssertNil` — the operand is an object holding the
        // channel and the fleet (§11).
        actions = nil
        XCTAssertTrue(evicted == nil,
                      "something still holds the panel's action object, so the press below proves nothing")

        relay.retry(first.id)

        let opened = await Self.settle { relay.records(in: key).count == 2 }
        XCTAssertTrue(opened, "Retry after the session was evicted opened \(relay.records(in: key).count) "
                      + "record(s), not 2")
        let prompts = await lifecycle.prompts
        XCTAssertEqual(prompts.count, 2, "Retry after the session was evicted sent \(prompts.count) prompt(s), not 2")
        XCTAssertTrue(prompts.last?.text == AgentNodeActions.prompt(relaying: RelayWire.message,
                                                                    to: SendRig.content),
                      "the retry sent something other than the relay the record descended from")
    }

    /// **G4, the other half: *Retry* sends through the workspace the app holds *now*.**
    ///
    /// The record and the *Retry* it offers are app-scoped and outlive the panel session — which is
    /// what the test above asserts — and that is only right while the resend also **follows** the
    /// app. *Check again* runs the launch again and attaches a new workspace with a new fleet; a
    /// resend that captured the fleet of the session that made it sends every retry into the
    /// workspace the app has replaced, while the timeline the arm is derived from is the new one.
    /// The message goes to a process nobody is looking at and the record stays *Not delivered*.
    ///
    /// Driven at the registry the tab reaches through, because that is where `attach` replaces the
    /// fleet; the two fleets are told apart by what each was sent and never by printing either (§11).
    func testRetryAfterCheckAgainSendsThroughTheWorkspaceTheAppNowHolds() async throws {
        let replaced = PromptDouble()
        let current = PromptDouble()
        let timelines = ChannelTimelineRegistry()
        timelines.lifecycle = replaced
        let relay = AgentRelayRegistry()
        let host = PanelHostModel()
        try host.register(AgentsTab(timelines: { _ in nil }, selection: AgentSelectionStore(),
                                    lifecycle: { [timelines] in timelines.lifecycle }, relay: relay))
        let context = PanelFixtures.context(PanelFixtures.key(3))
        let session = try XCTUnwrap(host.session(for: .agents, context: context) as? AgentsModel,
                                    "the tab made something other than its own session")

        await session.actions?.sendMessage(RelayWire.message, to: SendRig.content)
        XCTAssertEqual(relay.records(in: context.key).count, 1,
                       "the send opened \(relay.records(in: context.key).count) relay record(s), not 1")
        let record = relay.records(in: context.key)[0]

        // *Check again*: the launch reaches a new workspace and `attach` replaces the fleet.
        timelines.lifecycle = current

        relay.retry(record.id)

        let opened = await Self.settle { relay.records(in: context.key).count == 2 }
        XCTAssertTrue(opened, "Retry after the workspace was replaced opened "
                      + "\(relay.records(in: context.key).count) record(s), not 2")
        let toTheReplaced = await replaced.prompts.count
        let toTheCurrent = await current.prompts.count
        XCTAssertEqual(toTheReplaced, 1,
                       "the workspace the app replaced was sent \(toTheReplaced) prompt(s); it took the "
                       + "original send and must take nothing after it")
        XCTAssertEqual(toTheCurrent, 1,
                       "the workspace the app now holds was sent \(toTheCurrent) prompt(s) by the retry, not 1")
    }

    // MARK: - §11

    /// **No record, reading, drawn row or description carries the message text.**
    ///
    /// The record is reflected whole rather than field by field, so a field added later that held the
    /// text is caught by this test rather than by a report that printed it.
    func testNoReportEverCarriesTheMessageText() async {
        let rig = SendRig()
        await rig.actions.sendMessage(RelayWire.message, to: rig.content)
        let record = rig.relay.records(in: rig.key)[0]

        XCTAssertFalse(String(describing: record).contains(RelayWire.message),
                       "a relay record's own description carries the message text")
        XCTAssertFalse(String(describing: record).contains(RelayWire.message.uppercased()),
                       "a relay record's description carries the message text in another case")
        let drawn = ViewTree.values(of: String.self,
                                    in: AgentRelayNote(reading: AgentRelayReading(state: .pending, reply: nil,
                                                                                  retry: nil)))
        XCTAssertFalse(drawn.contains { $0.contains(RelayWire.message) },
                       "the drawn delivery state carries the message text")
        for reason in AgentRelayState.Reason.allCases {
            XCTAssertFalse(AgentRelayState.notDelivered(reason).sentence.contains(RelayWire.target),
                           "one of the four sentences names the run it is about")
        }
    }

    // MARK: - Contract Y8

    /// **Y8: the row draws the state for its own prompt uuid.**
    ///
    /// Two rows, one context: the message that sent the relay draws the reading, and a second message
    /// of the same channel draws nothing extra. A row that drew the app's one relay on every message
    /// passes the first assertion alone.
    func testTheRowDrawsTheStateForItsOwnPromptUUID() throws {
        var wire = RelayWire()
        wire.open()
        let record = wire.record()
        wire.assistantText(RelayWire.reply)
        wire.result()

        let navigation = AgentNavigator(selection: AgentSelectionStore(),
                                        focusChannel: { _ in }, selectTab: {},
                                        relay: wire.relay,
                                        timelines: { [wire] key in key == wire.key ? wire.timeline : nil })
        let context = InventedItems.context(agents: navigation, key: wire.key)

        let row = UserMessageBody(item: Self.message(promptUUID: record.promptUUID), context: context).content
        let sending = ViewTree.values(of: String.self, in: row)
        XCTAssertTrue(sending.contains(AgentRelayState.notDelivered(.noCall).sentence),
                      "the row that sent the relay drew no delivery state")

        // **And the note's own body, evaluated.** The clause above reads the strings the note
        // stores, which is what a `Mirror` walk can reach — it does not enter a `@ViewBuilder`, so
        // the row's own body is as far as reflection goes. The note is a view this test can hold,
        // and a held view's `body` can be built: a note that stored the sentence and drew something
        // else passes the clause above and fails here.
        let note = try XCTUnwrap(ViewTree.values(of: AgentRelayNote.self, in: row).first,
                                 "the row drew no delivery note at all")
        let drawnByTheNote = ViewTree.values(of: String.self, in: note.body)
        XCTAssertTrue(drawnByTheNote.contains(AgentRelayState.notDelivered(.noCall).sentence),
                      "the note's own body draws no delivery sentence")
        XCTAssertTrue(drawnByTheNote.contains("Retry"),
                      "a Not delivered note draws no Retry, so the arm offers nothing to act on")

        let other = ViewTree.values(of: String.self,
                                    in: UserMessageBody(item: Self.message(promptUUID: RelayWire.secondPromptUUID,
                                                                           key: "u-invented-key-2"),
                                                        context: context).content)
        XCTAssertFalse(other.contains(AgentRelayState.notDelivered(.noCall).sentence),
                       "a message that sent no relay drew another message's delivery state")
    }

    /// **Y8, the other half: a row with no relay record draws nothing extra.**
    ///
    /// The channel column is untouched wherever this leaf never acted, which is every channel in
    /// which nobody has used *Send message*. Asserted as the drawn strings being the same set with
    /// and without a relay registry behind the context.
    func testARowWithNoRelayRecordDrawsNothingExtra() {
        let message = Self.message(promptUUID: RelayWire.promptUUID)
        let plain = ViewTree.values(of: String.self,
                                    in: UserMessageBody(item: message, context: InventedItems.context()).content)

        var wire = RelayWire()
        wire.open()
        // A relay exists in this channel — for **another** message. A reader keyed by anything
        // looser than the prompt uuid draws that one here, which is the failure this arm is for.
        wire.record(promptUUID: RelayWire.secondPromptUUID)
        wire.result()
        let navigation = AgentNavigator(selection: AgentSelectionStore(),
                                        focusChannel: { _ in }, selectTab: {},
                                        relay: wire.relay,
                                        timelines: { [wire] key in key == wire.key ? wire.timeline : nil })
        let withRegistry = ViewTree.values(of: String.self,
                                           in: UserMessageBody(item: message,
                                                               context: InventedItems.context(agents: navigation,
                                                                                              key: wire.key)).content)

        // A boolean and a count, never the two arrays (§11): the drawn strings carry the message
        // text and the row's item keys, and a failing `XCTAssertEqual` prints both operands.
        XCTAssertTrue(plain == withRegistry,
                      "a message with no relay record drew \(withRegistry.count - plain.count) extra string(s), "
                      + "and \(withRegistry.filter { !plain.contains($0) }.count) string(s) the plain row does not draw")
    }

    /// The node draws the same reading the row does, from the same derivation — item 51 puts the
    /// state in both places and two answers about one delivery is the failure that would follow from
    /// two registries.
    func testTheNodeAndTheRowReadOneRegistry() async {
        let rig = SendRig()
        await rig.actions.sendMessage(RelayWire.message, to: rig.content)

        let readings = rig.model.relayReadings(of: rig.content.id)
        XCTAssertEqual(readings.count, 1, "the node drew \(readings.count) relay(s) for one send")
        XCTAssertTrue(readings.first?.state == .pending,
                      "the node concluded something other than pending from a send with no frames behind it")
    }

    // MARK: - The digest

    /// The delivery test tolerates a wrapper the harness added and refuses a mere mention.
    ///
    /// The engine forwards a relayed message as a frame of its own and nothing in the bundle promises
    /// the body is byte-identical, so a whole line of the original matches; a transcript that only
    /// talks *about* the message does not.
    func testTheDigestMatchesAWrappedForwardAndNotAMention() {
        let digest = AgentRelayDigest.of(RelayWire.message)
        XCTAssertTrue(AgentRelayDigest.matches(digest, in: "Relayed message:\n\n\(RelayWire.message)"),
                      "a forwarded message with a wrapper line was not recognised")
        XCTAssertTrue(AgentRelayDigest.matches(digest, in: "  \(RelayWire.message)  "),
                      "a forwarded message with surrounding whitespace was not recognised")
        XCTAssertFalse(AgentRelayDigest.matches(digest, in: String(RelayWire.message.prefix(8))),
                       "a fragment of the message was accepted as the message")
        XCTAssertFalse(AgentRelayDigest.matches(digest, in: "the user sent an errand a moment ago"),
                       "a transcript that only mentions a message was accepted as delivery")
        XCTAssertFalse(AgentRelayDigest.matches(digest, in: ""),
                       "an empty frame was accepted as delivery")
    }

    // MARK: - Helpers

    static func message(promptUUID: String, key: String = "u-invented-key-1") -> UserMessageItem {
        UserMessageItem(id: InventedItems.id(key), timestamp: InventedItems.epoch,
                        provenance: InventedItems.provenance,
                        blocks: [InventedItems.text("an invented request")], text: "an invented request",
                        promptUUID: promptUUID)
    }

    /// Bounded polling, the shape the other suites here use: a press starts a `Task`, and a test that
    /// waited a duration would be asserting about the scheduler.
    static func settle(until condition: @MainActor () async -> Bool) async -> Bool {
        // The budget is a **hang guard and not a measurement**: every press this waits on is
        // fulfilled by the work it starts, so the loop returns on the first satisfied poll and the
        // ceiling only decides how long a genuinely broken press takes to fail. It is generous
        // because a suite running under load schedules an unstructured task late, and a wait that
        // expired for that reason would fail for the scheduler rather than for the assertion.
        for _ in 0..<3_000 {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await condition()
    }
}

// MARK: - The wire

/// One channel's frames, decoded and folded by C3's own reducer, with a relay registry beside it.
///
/// Every frame is written as JSON and put through `FrameDecoder`, so the arms are asserted over the
/// projection production produces rather than over items a test assembled. Every identifier is
/// invented (§11) and nothing is read from or written to disk (X9): the config home is a value the
/// tree computes URLs from and this rig asks for none of them.
@MainActor
struct RelayWire {

    static let configHome = URL(fileURLWithPath: "/invented/relay-config-home")
    static let session = SessionID("dddddddd-4444-4444-8444-dddddddddddd")!
    static let target: AgentRunID = "task_invented_relay01"
    static let targetToolUse = "toolu_invented_run01"
    static let otherAgent: AgentRunID = "task_invented_relay02"
    static let otherToolUse = "toolu_invented_run02"
    static let promptUUID = "aaaaaaa1-1111-4111-8111-aaaaaaaaaaa1"
    static let secondPromptUUID = "aaaaaaa2-2222-4222-8222-aaaaaaaaaaa2"
    static let sendCall = "toolu_invented_send01"
    static let secondSendCall = "toolu_invented_send02"
    static let message = "an invented errand for the agent"
    /// A second errand, for a turn that relays twice: two messages to one run are two sends, and a
    /// machine that assigned calls by their order alone cannot tell them apart.
    static let secondMessage = "a second invented errand for the same agent"
    /// What the model says **after** the tool result tells it the resume was refused. The sentence
    /// item 51 asks to be shown, and the one a reply read up to the first call never sees.
    static let explanation = "an invented sentence the model explained the refusal with"
    static let reply = "an invented sentence the model answered with"
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    let relay = AgentRelayRegistry()
    private var reducer: WireReducer
    private var tick = 0

    var key: ChannelKey { ChannelKey(configHome: Self.configHome, session: Self.session) }

    init() {
        reducer = WireReducer(stream: LogicalStream(configHome: Self.configHome, sessionID: Self.session, name: .main),
                              slug: "an-invented-slug")
    }

    /// The channel as the panel reads it: the fold's own halves in one snapshot.
    var timeline: ChannelTimeline {
        ChannelTimeline(durable: reducer.durable, overlay: reducer.overlay, preview: reducer.preview,
                        agents: reducer.agents, registry: reducer.registry)
    }

    // MARK: - Driving it

    /// The run this suite relays to, started the way a live channel learns of one.
    mutating func open() {
        push(["type": .string("system"), "subtype": .string("task_started"),
              "task_id": .string(Self.target), "tool_use_id": .string(Self.targetToolUse),
              "description": .string("an invented errand"), "subagent_type": .string("an-invented-agent"),
              "spawn_depth": .integer(1), "task_type": .string("local_agent"),
              "uuid": .string("bbbbbbb1-1111-4111-8111-bbbbbbbbbbb1"),
              "session_id": .string(Self.session.description)])
    }

    /// A *Send message*: the prompt afleet composed, echoed by the engine, and the record it opened.
    ///
    /// The `promptSent` raise goes in first, exactly as the send path raises it, because it is what
    /// the reducer attributes the turn's `result` to.
    @discardableResult
    mutating func record(promptUUID: String = RelayWire.promptUUID,
                         message: String = RelayWire.message) -> AgentRelayRecord {
        echo(promptUUID: promptUUID)
        // A resend closure, because production always installs one: the send site captures the text
        // it would re-send, and a record opened without one could not offer *Retry* at all.
        return relay.open(promptUUID: promptUUID, target: Self.target,
                          textDigest: AgentRelayDigest.of(message), in: key, at: stamp(),
                          resend: { _, _ in })
    }

    /// The engine's echo of one prompt, and the `promptSent` raise the send path makes inseparable
    /// from it — what the reducer attributes the turn's `result` to. Split out of `record(…)` so a
    /// prompt **the send path itself minted** can be echoed here, which is what a test of the real
    /// send needs: the uuid is the lifecycle's and no test can choose it.
    mutating func echo(promptUUID: String) {
        _ = reducer.apply(.promptSent(uuid: promptUUID, at: Self.epoch), at: stamp())
        push(["type": .string("user"), "uuid": .string(promptUUID),
              "session_id": .string(Self.session.description),
              "origin": .object(["kind": .string("human")]),
              "message": .object(["role": .string("user"),
                                  "content": .string("an invented composed relay prompt")])])
    }

    /// A **second** run of this channel, so a frame can be routed to an agent that is not the
    /// target. Without it "the text in another run's transcript is not delivery" cannot be stated:
    /// there is nowhere else for it to be.
    mutating func openOther() {
        push(["type": .string("system"), "subtype": .string("task_started"),
              "task_id": .string(Self.otherAgent), "tool_use_id": .string(Self.otherToolUse),
              "description": .string("a second invented errand"), "subagent_type": .string("an-invented-agent"),
              "spawn_depth": .integer(1), "task_type": .string("local_agent"),
              "uuid": .string("bbbbbbb2-2222-4222-8222-bbbbbbbbbbb2"),
              "session_id": .string(Self.session.description)])
    }

    /// The same forwarded frame, into the **other** run's stream.
    mutating func forwardedToOther(_ text: String) {
        push(["type": .string("user"), "uuid": .string("acacacac-\(tick)111-4111-8111-acacacacacac"),
              "session_id": .string(Self.session.description),
              "parent_tool_use_id": .string(Self.otherToolUse),
              "message": .object(["role": .string("user"),
                                  "content": .string("Relayed message:\n\n\(text)")])])
    }

    /// The main agent's `SendMessage` call, naming `to` and carrying `message` — which is what the
    /// relay prompt asks the model to send exactly as written, and what tells one send's call from
    /// another's in a turn that relays twice.
    mutating func sendMessageCall(to agent: AgentRunID, id: String = RelayWire.sendCall,
                                  message: String = RelayWire.message) {
        push(["type": .string("assistant"), "uuid": .string("cccccccc-\(tick)111-4111-8111-cccccccccccc"),
              "session_id": .string(Self.session.description),
              "message": .object(["id": .string("msg_invented\(tick)"), "type": .string("message"),
                                  "role": .string("assistant"), "model": .string("an-invented-model"),
                                  "content": .array([
                                    .object(["type": .string("tool_use"), "id": .string(id),
                                             "name": .string("SendMessage"),
                                             "input": .object(["to": .string(agent),
                                                               "message": .string(message)])])])])])
    }

    /// The `tool_result` for that call.
    mutating func toolResult(id: String = RelayWire.sendCall, isError: Bool) {
        push(["type": .string("user"), "uuid": .string("dddddddd-\(tick)111-4111-8111-dddddddddddd"),
              "session_id": .string(Self.session.description),
              "message": .object(["role": .string("user"),
                                  "content": .array([
                                    .object(["type": .string("tool_result"), "tool_use_id": .string(id),
                                             "is_error": .bool(isError),
                                             "content": .string(isError
                                                ? "an invented refusal the engine worded"
                                                : "an invented queued-for-next-round sentence")])])])])
    }

    /// The `tool_result` as `SendMessage` itself answers: **one text block carrying the tool's own
    /// `{success, message}` object, and no `is_error` key at all.**
    ///
    /// The engine flags a `SendMessage` result only for its validate-input refusals — an empty
    /// message, a malformed recipient. Every route outcome, including a refused resume, comes back
    /// as an ordinary result whose body states it. `toolResult(isError:)` above is the other shape
    /// and both are real; this is the one the four resume refusals arrive in.
    mutating func sendMessageResult(id: String = RelayWire.sendCall, success: Bool) {
        let body = success
            ? #"{"success":true,"message":"an invented queued-for-next-round sentence"}"#
            : #"{"success":false,"message":"an invented sentence refusing to resume a stopped agent"}"#
        push(["type": .string("user"), "uuid": .string("daaadddd-\(tick)111-4111-8111-dddddddddddd"),
              "session_id": .string(Self.session.description),
              "message": .object(["role": .string("user"),
                                  "content": .array([
                                    .object(["type": .string("tool_result"), "tool_use_id": .string(id),
                                             "content": .array([.object(["type": .string("text"),
                                                                         "text": .string(body)])])])])])])
    }

    /// The model speaking in the turn the relay was asked for.
    mutating func assistantText(_ text: String) {
        push(["type": .string("assistant"), "uuid": .string("eeeeeeee-\(tick)111-4111-8111-eeeeeeeeeeee"),
              "session_id": .string(Self.session.description),
              "message": .object(["id": .string("msg_invented_reply\(tick)"), "type": .string("message"),
                                  "role": .string("assistant"), "model": .string("an-invented-model"),
                                  "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }

    /// The turn's `result`, which is what closes it.
    mutating func result() {
        push(["type": .string("result"), "subtype": .string("success"), "duration_ms": .integer(1),
              "is_error": .bool(false), "num_turns": .integer(1), "total_cost_usd": .number(0),
              "uuid": .string("ffffffff-\(tick)111-4111-8111-ffffffffffff"),
              "session_id": .string(Self.session.description)])
    }

    /// The message arriving in the **agent's own** stream: a user frame carried by the run's own
    /// spawning block, which is how the reducer routes a forwarded frame to that run.
    mutating func forwarded(_ text: String) {
        push(["type": .string("user"), "uuid": .string("abababab-\(tick)111-4111-8111-abababababab"),
              "session_id": .string(Self.session.description),
              "parent_tool_use_id": .string(Self.targetToolUse),
              "message": .object(["role": .string("user"),
                                  "content": .string("Relayed message:\n\n\(text)")])])
    }

    /// The same text on the **main** stream — the near miss the delivery arm has to refuse.
    mutating func mainStreamMessage(_ text: String) {
        push(["type": .string("user"), "uuid": .string("bcbcbcbc-\(tick)111-4111-8111-bcbcbcbcbcbc"),
              "session_id": .string(Self.session.description),
              "message": .object(["role": .string("user"), "content": .string(text)])])
    }

    /// The channel's process exits. Every run still reading running ends with it and the registry
    /// mirror goes empty, because only a live process fills it.
    mutating func processExited() {
        _ = reducer.apply(.exited(.code(0, stderrTail: ""), .first), at: stamp())
    }

    /// The run's `task_notification` — what hands the result back and what the fourth arm reads.
    mutating func taskNotification(status: String = "completed") {
        push(["type": .string("system"), "subtype": .string("task_notification"),
              "task_id": .string(Self.target), "tool_use_id": .string(Self.targetToolUse),
              "status": .string(status), "output_file": .string("/invented/scratch/an-invented.output"),
              "summary": .string("an invented summary"),
              "uuid": .string("cdcdcdcd-\(tick)111-4111-8111-cdcdcdcdcdcd"),
              "session_id": .string(Self.session.description)])
    }

    /// The same channel **as its transcript files hold it** — the *Check again* path, and the
    /// file-only rebuild of a channel opened from disk. The durable half is every record; the
    /// overlay is dropped, because §7.3's overlay is "everything only the wire carries" and the
    /// turn summary this machine reads a turn boundary from is folded from a `result` frame, which
    /// no transcript record carries. The registry mirror goes with it: only a live process fills it.
    var rebuiltFromFiles: ChannelTimeline {
        ChannelTimeline(durable: reducer.durable, overlay: .empty, preview: nil,
                        agents: reducer.agents, registry: RegistryMirror())
    }

    // MARK: - Publishing it

    /// What the channel's own publish does with this registry — `ChannelTimelineModel.publish()`
    /// calls exactly this, with the timeline the fold has just produced.
    ///
    /// **Nothing is read here**, which is the whole point of the tests that call it: a channel
    /// publishes whether or not a surface is drawing it, and the conclusions below are taken with no
    /// row and no node having asked for a reading.
    func publish() { relay.observe(timeline, in: key) }

    // MARK: - Reading it

    func state(of record: AgentRelayRecord) -> AgentRelayState { reading(of: record).state }

    /// The same reading, against a timeline this rig did not publish — the rebuild.
    func state(of record: AgentRelayRecord, in timeline: ChannelTimeline) -> AgentRelayState {
        relay.reading(of: record, in: key, of: timeline).state
    }

    func reading(of record: AgentRelayRecord) -> AgentRelayReading {
        relay.reading(of: record, in: key, of: timeline)
    }

    // MARK: - Frames

    private mutating func push(_ object: [String: JSONValue]) {
        guard let data = try? JSONValue.object(object).canonicalData() else {
            preconditionFailure("an invented frame did not encode as JSON")
        }
        let frame = FrameDecoder.decode(line: data)
        if case .opaque = frame { preconditionFailure("an invented frame did not decode as a typed frame") }
        _ = reducer.apply(.frame(frame, .first), at: stamp())
    }

    /// A fresh instant per frame, so the merged item order is the order the frames arrived in and
    /// nothing depends on when the suite ran.
    private mutating func stamp() -> Date {
        tick += 1
        return Self.epoch.addingTimeInterval(TimeInterval(tick))
    }
}

// MARK: - The send

/// The send path with a lifecycle that records prompts and a fold that records raises.
@MainActor
final class SendRig {

    let key = ChannelKey(configHome: RelayWire.configHome, session: RelayWire.session)
    let lifecycle = PromptDouble()
    let relay = AgentRelayRegistry()
    let actions: AgentNodeActions
    let model: AgentsModel

    var content: AgentNodeContent { Self.content }

    static let content = AgentNodeContent(node: AgentRunNode(id: RelayWire.target, agentType: "an-invented-agent",
                                                     description: "an invented errand",
                                                     status: .completed, depth: 1,
                                                     elapsedOrigin: RelayWire.epoch,
                                                     toolUseID: RelayWire.targetToolUse, startedCount: 1),
                                   entry: nil, isParked: false, waitingCount: 0, parentDisputed: false)

    /// The channel's published timeline, as the fold publishes it: one value, replaced in place,
    /// which is what the model's closure and every reading reach for on every access. Mutable so a
    /// test can settle a relay against real frames rather than against an empty channel.
    let published = TimelineBox()

    var timeline: ChannelTimeline {
        get { published.timeline }
        set { published.timeline = newValue }
    }

    init() {
        let box = RaiseBox()
        actions = AgentNodeActions(lifecycle: lifecycle, reaching: { [lifecycle] in lifecycle },
                                   channel: key, relay: relay,
                                   raiseSignal: { _, signal in await box.record(signal) })
        let published = self.published
        model = AgentsModel(channel: key, timelines: { [published] _ in published.timeline },
                            store: AgentSelectionStore(), actions: actions, relay: relay)
        self.box = box
    }

    /// What a surface draws for one record, over the channel's published timeline.
    func reading(of record: AgentRelayRecord) -> AgentRelayReading {
        relay.reading(of: record, in: key, of: published.timeline)
    }

    private let box: RaiseBox

    /// The signals the send raised. Read after the send returns, which is after the raise it awaits.
    var raised: [HostSignal] { box.signals }

    /// Whether the raise carried the uuid the lifecycle minted for this send, as a boolean: the two
    /// operands are prompt uuids and an equality assertion would print both (§11).
    func raisedTheMintedPrompt(_ minted: UUID?) -> Bool {
        guard case .promptSent(let uuid, _)? = box.signals.first, let minted else { return false }
        return uuid == minted.uuidString.lowercased()
    }
}

/// The channel's timeline, in a box the rig's closures read through: a `ChannelTimeline` is a value
/// and a closure that captured one could never see it move.
@MainActor
final class TimelineBox {
    var timeline = ChannelTimeline()
}

/// A single-owner box for the raises, serialised by the main actor: every write is inside the send's
/// own `await` on the main actor and every read is a main-actor test line.
@MainActor
final class RaiseBox {
    private(set) var signals: [HostSignal] = []
    func record(_ signal: HostSignal) { signals.append(signal) }
}

/// A `LifecycleAPI` that answers `sendPrompt` and records it, and traps on everything else — a double
/// that quietly answers a question it was never designed to answer is how a test starts asserting
/// against the double.
actor PromptDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    private(set) var prompts: [UserInput] = []
    private(set) var channels: [ChannelKey] = []
    private(set) var minted: [UUID] = []
    private var refusal: LifecycleError?

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func refuse(_ error: LifecycleError) { refusal = error }

    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID {
        if let refusal { throw refusal }
        prompts.append(input)
        channels.append(key)
        let uuid = UUID()
        minted.append(uuid)
        return uuid
    }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { [] }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState { unreachable("perform") }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("PromptDouble.\(member) is not part of the relay's surface")
    }
}

// MARK: - The fixture replay (G4's fixture half)

/// C6.4 Task 8: item 51's five arms replayed end to end out of one recording.
///
/// **What this adds over the arms above.** Those assert the machine over frame sequences a test
/// wrote; this asserts the same five conclusions over a *recording* — one session, six turns, the
/// five arms in order — so the claim moves from "afleet reads these sequences correctly" to "these
/// sequences are a session, and afleet reads it".
///
/// **It skips until the recording is signed, and starts asserting by itself the moment it is.**
/// A fixture enters the repository only when a person other than its author has walked
/// `Fixtures/REVIEW.md` and signed it, and `make verify-fixtures` refuses an unsigned directory —
/// so the recording is staged outside the tree until then. This suite is committed now, green now,
/// and needs no edit when the signature arrives. The skip's sentence is fixed and names no path,
/// no session and no slug (§11).
@MainActor
final class AgentRelayFixtureTests: XCTestCase {

    static let fixture = "send-message-delivery"

    /// The recording's own invented identifiers. **Written here rather than derived from the
    /// frames**: deriving the target run and the five messages from the recording would make the
    /// assertion agree with whatever the recording happens to say, which is the one thing a replay
    /// must not do. The generator under `Tools/probe/synthetic/` authored both halves and these are
    /// its values — invented, of the engine's `^a[0-9a-f]{16}$` agent-id shape, nobody's own (§11).
    static let target: AgentRunID = "a1111111111111111"
    static let messages = ["an invented errand for the first arm",
                           "an invented errand for the second arm",
                           "an invented errand for the third arm",
                           "an invented errand for the fourth arm",
                           "an invented errand for the fifth arm"]

    /// **Each of the five arms, from the recording, in one pass.**
    ///
    /// The five records are opened against the five prompt uuids the recording carries, in the order
    /// the human turns appear, and every arm's conclusion is asserted over the finished timeline —
    /// which is stricter than asserting each as it arrives, because a machine that settled an arm
    /// early and then let a later turn's frames move it would pass a turn-by-turn reading.
    func testTheFiveArmsReplayToTheirFiveStates() throws {
        let replay = try Replay.open(Self.fixture)

        XCTAssertEqual(replay.promptUUIDs.count, 6,
                       "the recording carries \(replay.promptUUIDs.count) human turn(s), not the 6 the arms need")
        XCTAssertEqual(replay.timeline.agents?.nodes.count, 2,
                       "the recording started \(replay.timeline.agents?.nodes.count ?? 0) run(s), not 2")

        // The first human turn starts the two runs; the five that follow are the arms.
        let records = (0..<5).map { arm in
            replay.relay.open(promptUUID: replay.promptUUIDs[arm + 1], target: Self.target,
                              textDigest: AgentRelayDigest.of(Self.messages[arm]), in: replay.key,
                              at: Replay.epoch.addingTimeInterval(TimeInterval(arm)), resend: { _, _ in })
        }
        let expected: [AgentRelayState] = [.delivered,
                                           .notDelivered(.noCall),
                                           .notDelivered(.wrongTarget),
                                           .notDelivered(.refused),
                                           .notDelivered(.stoppedBeforeNextRound)]
        let outcomes = replay.relay.outcomes(in: replay.key, of: replay.timeline)
        for (arm, record) in records.enumerated() {
            let state = outcomes[record.id]?.state
            XCTAssertTrue(state == expected[arm],
                          "arm \(arm + 1) of 5 replayed to \(String(describing: state)) and not "
                          + "\(String(describing: expected[arm])); the state names carry no id, text or path")
        }
    }

    /// The arm the recording exists to discriminate: its fourth turn's `tool_result` carries **no**
    /// error flag, and the arm is still not delivered.
    ///
    /// Asserted against the recording's own bytes rather than against the reading, so a recording
    /// re-made with an `is_error` on that result would fail here instead of quietly turning the arm
    /// above into a test of the flag.
    func testTheRefusedArmsResultCarriesNoErrorFlag() throws {
        let replay = try Replay.open(Self.fixture)
        let refusals = replay.timeline.items.compactMap { item -> ToolCallItem? in
            guard case .toolCall(let call) = item, call.name == "SendMessage" else { return nil }
            return call
        }
        XCTAssertEqual(refusals.count, 4, "the recording carries \(refusals.count) SendMessage call(s), not 4")
        XCTAssertTrue(refusals.allSatisfy { $0.isError != true },
                      "the recording flags a SendMessage result as an error; every route it shows is an ordinary result")
    }

    // MARK: - The replay

    /// One recording, folded by C3's own reducer, with the relay registry beside it.
    ///
    /// The host signal each turn needs is raised here and not in the recording: `promptSent` is
    /// afleet's own act — the recording is the engine's half of the conversation — and it is what
    /// the reducer attributes a turn's `result` to. Raising it before each human turn's echo is
    /// exactly what the send path does.
    @MainActor
    struct Replay {

        static let configHome = URL(fileURLWithPath: "/invented/replay-config-home")
        static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

        let key: ChannelKey
        let relay = AgentRelayRegistry()
        let promptUUIDs: [String]
        let timeline: ChannelTimeline

        static func open(_ fixture: String) throws -> Replay {
            guard FileManager.default.fileExists(atPath: FixtureRunner.directory(fixture).path) else {
                throw XCTSkip("the synthetic delivery recording is not in the tree; it enters when its review is signed")
            }
            guard let session = SessionID("66666666-6666-4666-8666-666666666666") else {
                throw AgentGateBail("an invented session id did not parse")
            }
            var reducer = WireReducer(stream: LogicalStream(configHome: configHome, sessionID: session, name: .main),
                                      slug: "an-invented-slug")
            var uuids: [String] = []
            var tick = 0
            func stamp() -> Date { tick += 1; return epoch.addingTimeInterval(TimeInterval(tick)) }
            for line in try FixtureRunner.outboundLines(fixture) {
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                if object["type"] as? String == "user",
                   (object["origin"] as? [String: Any])?["kind"] as? String == "human",
                   let uuid = object["uuid"] as? String {
                    uuids.append(uuid)
                    _ = reducer.apply(.promptSent(uuid: uuid, at: stamp()), at: stamp())
                }
                _ = reducer.apply(.frame(FrameDecoder.decode(line: line), .first), at: stamp())
            }
            return Replay(key: ChannelKey(configHome: configHome, session: session),
                          promptUUIDs: uuids,
                          timeline: ChannelTimeline(durable: reducer.durable, overlay: reducer.overlay,
                                                    preview: reducer.preview, agents: reducer.agents,
                                                    registry: reducer.registry))
        }
    }
}
