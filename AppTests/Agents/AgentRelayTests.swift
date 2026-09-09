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
        let record = wire.record()
        wire.sendMessageCall(to: RelayWire.target)
        wire.toolResult(isError: false)

        wire.mainStreamMessage(RelayWire.message)
        XCTAssertTrue(wire.state(of: record) == .relayed,
                      "the message text appearing in the main stream was read as delivery")

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

    /// **G4, arm two: the `tool_result` is an error — a refused resume — and the model's reply is
    /// kept.**
    ///
    /// Parity §18.25.4 lists the refusals the engine answers a resume with (user-stopped, missing
    /// transcript, forked-skill scoping, worktree gone) and §18.26.2 says the same text arrives as
    /// the `SendMessage` tool result. The arm is the error flag on the result and not the sentence,
    /// which is the engine's to word and not this leaf's to match.
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
    func testRetryOpensANewRecord() async {
        let rig = SendRig()
        await rig.actions.sendMessage(RelayWire.message, to: rig.content)
        let first = rig.relay.records(in: rig.key)[0]

        rig.relay.retry(first.id)
        let opened = await Self.settle { rig.relay.records(in: rig.key).count == 2 }
        XCTAssertTrue(opened, "Retry opened \(rig.relay.records(in: rig.key).count) record(s), not 2")

        let records = rig.relay.records(in: rig.key)
        XCTAssertTrue(records[0].id == first.id, "Retry replaced the record that failed instead of adding one")
        XCTAssertTrue(records[1].retryOf == first.id, "the retry recorded no lineage back to the relay it retried")
        XCTAssertTrue(records[1].textDigest == first.textDigest, "the retry re-sent something other than the message")
        let prompts = await rig.lifecycle.prompts
        XCTAssertEqual(prompts.count, 2, "Retry sent \(prompts.count) prompt(s) in total, not 2")
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
    func testTheRowDrawsTheStateForItsOwnPromptUUID() {
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

        let sending = ViewTree.values(of: String.self,
                                      in: UserMessageBody(item: Self.message(promptUUID: record.promptUUID),
                                                          context: context).content)
        XCTAssertTrue(sending.contains(AgentRelayState.notDelivered(.noCall).sentence),
                      "the row that sent the relay drew no delivery state")

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
        for _ in 0..<200 {
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
    static let promptUUID = "aaaaaaa1-1111-4111-8111-aaaaaaaaaaa1"
    static let secondPromptUUID = "aaaaaaa2-2222-4222-8222-aaaaaaaaaaa2"
    static let sendCall = "toolu_invented_send01"
    static let secondSendCall = "toolu_invented_send02"
    static let message = "an invented errand for the agent"
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
    mutating func record(promptUUID: String = RelayWire.promptUUID) -> AgentRelayRecord {
        _ = reducer.apply(.promptSent(uuid: promptUUID, at: Self.epoch), at: stamp())
        push(["type": .string("user"), "uuid": .string(promptUUID),
              "session_id": .string(Self.session.description),
              "origin": .object(["kind": .string("human")]),
              "message": .object(["role": .string("user"),
                                  "content": .string("an invented composed relay prompt")])])
        // A resend closure, because production always installs one: the send site captures the text
        // it would re-send, and a record opened without one could not offer *Retry* at all.
        return relay.open(promptUUID: promptUUID, target: Self.target,
                          textDigest: AgentRelayDigest.of(Self.message), in: key, at: stamp(),
                          resend: { _ in })
    }

    /// The main agent's `SendMessage` call, naming `to`.
    mutating func sendMessageCall(to agent: AgentRunID, id: String = RelayWire.sendCall) {
        push(["type": .string("assistant"), "uuid": .string("cccccccc-\(tick)111-4111-8111-cccccccccccc"),
              "session_id": .string(Self.session.description),
              "message": .object(["id": .string("msg_invented\(tick)"), "type": .string("message"),
                                  "role": .string("assistant"), "model": .string("an-invented-model"),
                                  "content": .array([
                                    .object(["type": .string("tool_use"), "id": .string(id),
                                             "name": .string("SendMessage"),
                                             "input": .object(["to": .string(agent),
                                                               "message": .string(Self.message)])])])])])
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

    /// The run's `task_notification` — what hands the result back and what the fourth arm reads.
    mutating func taskNotification(status: String = "completed") {
        push(["type": .string("system"), "subtype": .string("task_notification"),
              "task_id": .string(Self.target), "tool_use_id": .string(Self.targetToolUse),
              "status": .string(status), "output_file": .string("/invented/scratch/an-invented.output"),
              "summary": .string("an invented summary"),
              "uuid": .string("cdcdcdcd-\(tick)111-4111-8111-cdcdcdcdcdcd"),
              "session_id": .string(Self.session.description)])
    }

    // MARK: - Reading it

    func state(of record: AgentRelayRecord) -> AgentRelayState { reading(of: record).state }

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

    let content = AgentNodeContent(node: AgentRunNode(id: RelayWire.target, agentType: "an-invented-agent",
                                                     description: "an invented errand",
                                                     status: .completed, depth: 1,
                                                     elapsedOrigin: RelayWire.epoch,
                                                     toolUseID: RelayWire.targetToolUse, startedCount: 1),
                                   entry: nil, isParked: false, waitingCount: 0, parentDisputed: false)

    init() {
        let box = RaiseBox()
        actions = AgentNodeActions(lifecycle: lifecycle, channel: key, relay: relay,
                                   raiseSignal: { _, signal in await box.record(signal) })
        model = AgentsModel(channel: key, timelines: { _ in ChannelTimeline() },
                            store: AgentSelectionStore(), actions: actions, relay: relay)
        self.box = box
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
                              at: Replay.epoch.addingTimeInterval(TimeInterval(arm)), resend: { _ in })
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
