import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 6, gate **G4** — *Edit*, the conversation rewind, and *Fork from here*.
///
/// Both legs come out of the `rewind-turn` fixture and neither is written down here: the recorded
/// `control_response` bodies are read out of `frames.ndjson` **at run time** and staged on the
/// lifecycle double, and the conversation itself is the fixture's own transcript, folded by a real
/// `StreamIngestion` in a scratch config home (X9). No engine byte reaches this file, and no
/// assertion below prints a path, a title, a session id or an environment (§11).
///
/// The arms the recording cannot produce — `"unseen later turn"`, an unrecognised refusal — are
/// injected as bodies of the fixture's own shape, which is what the spec's G4 asks for: the fixture
/// was recorded before `last_seen_user_message_uuid` existed and can only answer `"stale target"`.
@MainActor
final class EditAndRewindTests: XCTestCase {

    // MARK: - The honoured leg

    /// The engine honoured the rewind: the field carries `prefillText` **verbatim**, and
    /// `HostSignal.rewound` is raised exactly once.
    ///
    /// The prefill is compared against the string read out of the fixture's own response, so a
    /// composer that reconstructed the text from the edited message would fail even when the two
    /// happened to look alike — and a composer that raised the signal twice, or not at all, fails on
    /// the count.
    func testHonouredRewindPrefillsTheEngineTextAndRaisesTheSignalOnce() async throws {
        let rig = try await Rig()
        let messages = rig.renderedUserMessages()
        XCTAssertGreaterThanOrEqual(messages.count, 2,
                                    "the fixture folded \(messages.count) user message(s); this gate needs at least 2")
        let honoured = try Rig.recordedHonouredBody()
        let prefill = try XCTUnwrap(honoured["prefillText"]?.stringValue,
                                    "the recorded honoured body carries no `prefillText` to prefill from")

        await rig.lifecycle.stageSend("rewind_conversation", .success(honoured))
        rig.composer.draft = "what the user had half-typed"
        await rig.composer.edit(messages[messages.count - 1])

        XCTAssertEqual(rig.composer.draft, prefill,
                       "the field does not carry the \(prefill.count)-character prefill the engine returned")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 1,
                       "an honoured rewind raised \(rig.composer.rewindSignalsRaised) host signal(s), not exactly 1")
        XCTAssertNil(rig.composer.editNote,
                     "an honoured rewind left a note behind, which says a fork was opened when none was")
        let actions = await rig.lifecycle.actions
        XCTAssertTrue(actions.isEmpty, "an honoured rewind performed \(actions.count) lifecycle action(s)")
        let forks = await rig.lifecycle.forkCount
        XCTAssertEqual(forks, 0, "an honoured rewind opened \(forks) fork(s)")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The honoured rewind reaches the channel's **fold**, not merely the composer's own counter.
    ///
    /// The stake is the streaming preview: `HostSignal.rewound` is what clears the half-drawn turn
    /// the engine has just discarded, and a composer whose raise never arrived would leave it on
    /// screen. An invented `stream_event` opens a preview, the honoured answer is replayed, and the
    /// preview is gone afterwards. A floor first, so a test that never had a preview cannot pass by
    /// finding none.
    func testTheHonouredRewindClearsThePreviewTheEngineDiscarded() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        let leaf = try XCTUnwrap(rig.precedingAssistantRecord(before: target),
                                 "the chosen message has no preceding assistant record to rewind to")
        await rig.openAPreview()
        let opened = await rig.settleUntil { $0.timeline.preview != nil }
        XCTAssertTrue(opened, "no streaming preview was open, so its absence afterwards would prove nothing")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedHonouredBody(preceding: leaf)))
        await rig.composer.edit(target)

        XCTAssertNil(rig.timeline.timeline.preview,
                     "the honoured rewind left the discarded turn's preview on screen")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 1,
                       "an honoured rewind raised \(rig.composer.rewindSignalsRaised) host signal(s), not exactly 1")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The mirror of the arm above: a **refused** rewind leaves the preview exactly where it was.
    ///
    /// This is the assertion the gate calls for in the negative — a preview cleared by a refused
    /// rewind is a timeline that disagrees with the engine, and nothing else in the app puts it back.
    func testARefusedRewindLeavesThePreviewAlone() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        await rig.openAPreview()
        let opened = await rig.settleUntil { $0.timeline.preview != nil }
        XCTAssertTrue(opened, "no streaming preview was open, so this arm proves nothing")

        await rig.lifecycle.stageFork(.success(ChannelKey(configHome: rig.key.configHome, session: SessionID())))
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        XCTAssertNotNil(rig.timeline.timeline.preview,
                        "a refused rewind cleared the preview, which the engine did not discard")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - The refusals

    /// The recorded `"stale target"` refusal: a fork is opened, a note is shown, and **no** host
    /// signal is raised.
    ///
    /// The not-raised arm is the one that matters. A preview left behind by a refused rewind is a
    /// timeline that disagrees with the engine about what the conversation holds, and nothing else
    /// in the app would ever put it back.
    func testTheRecordedStaleTargetRefusalForksAndRaisesNoSignal() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()

        // **The oracle, and the fixture's own value that certifies it.** The expected fork point used
        // to be a second copy of production's `precedingAssistantKey(before:)`, so a wrong walk in
        // both places passed (Task 10's audit). It now follows the recording's `parentUuid` links —
        // a different source from the fold's item order — and the recording's honoured body, which
        // measured one such answer on the engine itself, is what says that walk is right.
        let honoured = try Rig.recordedHonouredBody()
        let recordedTarget = try XCTUnwrap(honoured["targetMessageUuid"]?.stringValue,
                                           "the recorded honoured leg names no target message")
        let recordedPreceding = try XCTUnwrap(honoured["precedingAssistantUuid"]?.stringValue,
                                              "the recorded honoured leg names no preceding assistant")
        XCTAssertTrue(try Rig.recordedParentAssistantRecord(of: recordedTarget) == recordedPreceding,
                      "the oracle disagrees with the engine's own answer on the recorded leg, "
                      + "so it cannot be trusted on this one")
        let entry = try Rig.recordedParentAssistantRecord(of: target.promptUUID)
        XCTAssertNotEqual(entry, target.promptUUID,
                          "the fork point and the edited message are the same record, so this arm proves nothing")
        // **The floor for the record-versus-item arm.** The fold merges an assistant message's records into one
        // item keyed by the *first* of them, and this fixture's assistant messages carry two — so an entry taken
        // from the item's key would name a record the fork drops while `dropsTurn` claims only the edited turn was
        // discarded. Without this the two answers could coincide and the assertion below would prove nothing.
        XCTAssertNotEqual(entry, try rig.itemKey(holding: entry),
                          "the assistant item before the edited message holds one record, so this arm cannot tell "
                          + "the last record from the item's key")

        let sibling = ChannelKey(configHome: rig.key.configHome, session: SessionID())
        await rig.lifecycle.stageFork(.success(sibling))
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let points = await rig.lifecycle.forkPoints
        XCTAssertEqual(points.count, 1, "the refusal opened \(points.count) fork(s), not exactly 1")
        let fork = try XCTUnwrap(points.first ?? nil, "the fork carries no fork point, so it forks from the end")
        XCTAssertEqual(fork.entryUUID, entry,
                       "the fork's entry is not the last assistant record the transcript names before the edited "
                       + "message, so the fork keeps less of the preceding turn than the timeline shows")
        XCTAssertEqual(fork.dropsTurn, target.promptUUID,
                       "the fork does not drop the edited message's own turn")
        let forked = try XCTUnwrap(rig.composers.model(for: sibling), "the fork opened no composer of its own")
        XCTAssertEqual(forked.draft, target.text,
                       "the fork's field does not carry the \(target.text.count)-character text of the edited message")
        let note = try XCTUnwrap(rig.composer.editNote, "the refused rewind showed no note at all")
        XCTAssertTrue(note.contains("not rewound") && note.contains("fork"),
                      "the \(note.count)-character note does not say the conversation was not rewound and a fork was opened")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// **The fork's prefill belongs to the fork.** The edited message's text is put into the
    /// **sibling's** composer, that channel is brought into view, and the source's own draft is left
    /// exactly as the user left it.
    ///
    /// The stake is where the next Return goes. A prefill written into the source is a message the
    /// user believes is being sent into the fork and which the engine receives on the conversation
    /// they were editing away from — the one outcome *Fork from here* exists to avoid. The sibling
    /// has no composer of its own when the fork returns, which is why the prefill waits under its key
    /// and this test asks the registry for that composer only afterwards.
    ///
    /// Deliberate break: assign `draft` on this composer in `forkInstead` → the source carries the
    /// prefill and the sibling opens empty.
    func testTheForksPrefillLandsOnTheSiblingAndTheSourceDraftIsUntouched() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        let sibling = ChannelKey(configHome: rig.key.configHome, session: SessionID())
        let halfTyped = "what the user had half-typed"
        rig.composer.draft = halfTyped
        await rig.lifecycle.stageFork(.success(sibling))
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))

        await rig.composer.edit(target)

        let forkCount = await rig.lifecycle.forkCount
        XCTAssertEqual(forkCount, 1, "the refusal opened \(forkCount) fork(s), not exactly 1")
        XCTAssertEqual(rig.composer.draft, halfTyped,
                       "the source's field was overwritten; the \(halfTyped.count) character(s) the user had "
                       + "typed there are the source conversation's, not the fork's")
        let forked = try XCTUnwrap(rig.composers.model(for: sibling),
                                   "the registry built no composer for the channel the fork answered")
        XCTAssertEqual(forked.draft, target.text,
                       "the fork's field does not carry the \(target.text.count)-character text of the edited "
                       + "message, so sending it would reach the conversation the edit forked away from")
        XCTAssertEqual(rig.selected, [sibling], "the fork was not brought into view exactly once")
        XCTAssertNotNil(rig.composer.editNote,
                        "the note explaining what happened to the edit left the source, where the user is looking")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// **The draft is handed to the identity the fork resolved to, not to the id its spawn was minted under.**
    ///
    /// `fork(at:on:)` answers while the sibling is still keyed on a provisional session, and the fleet re-keys the
    /// channel when the engine announces its own on `auth_status`. The browser lists that channel under the resolved
    /// id, and the registry keys both the pending prefill and the selection by whatever key it is handed — so a
    /// handoff on the provisional key selects nothing and leaves the edited message in a channel that never appears.
    ///
    /// Deliberate break: hand `handOffToFork` the key `fork(at:on:)` answered.
    func testTheForksPrefillLandsOnTheIdentityTheForkResolvedTo() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        let provisional = ChannelKey(configHome: rig.key.configHome, session: SessionID())
        let resolved = ChannelKey(configHome: rig.key.configHome, session: SessionID())
        await rig.lifecycle.stageFork(.success(provisional))
        await rig.lifecycle.stageForkIdentity(resolved, resolving: provisional)
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))

        await rig.composer.edit(target)

        // Booleans and a count over the keys: an equality would print a config home and two session ids (§11).
        XCTAssertEqual(rig.selected.count, 1, "the window was moved to \(rig.selected.count) channel(s), not 1")
        XCTAssertTrue(rig.selected.first == resolved,
                      "the window was moved to a channel that is not the one the fork resolved to")
        let forked = try XCTUnwrap(rig.composers.model(for: resolved),
                                   "the registry holds no composer for the identity the fork resolved to")
        XCTAssertEqual(forked.draft, target.text,
                       "the fork's field carries \(forked.draft.count) character(s) of the edited message")
        // And nothing was left behind under the provisional key: one prefill, taken once.
        let stranded = try XCTUnwrap(rig.composers.model(for: provisional),
                                     "the registry could not build a composer for the provisional key")
        XCTAssertEqual(stranded.draft.count, 0,
                       "\(stranded.draft.count) character(s) of the edited message were left under the "
                       + "provisional key, where nothing will ever look for them")
        XCTAssertNotNil(rig.composer.editNote, "the refused rewind showed no note at all")
        await rig.finish()
    }

    /// `"unseen later turn"` takes the identical path and says something different.
    ///
    /// Injected, because `rewind-turn` was recorded without `last_seen_user_message_uuid` and the
    /// engine only answers this string to a caller that sent one. Both notes are asserted to differ,
    /// so a composer with one sentence for every refusal fails while the path stays shared.
    func testUnseenLaterTurnTakesTheSamePathWithDifferentWording() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()

        await rig.lifecycle.stageFork(.success(ChannelKey(configHome: rig.key.configHome, session: SessionID())))
        await rig.lifecycle.stageSend("rewind_conversation", .success(Rig.refusal(reason: "unseen later turn")))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let points = await rig.lifecycle.forkPoints
        XCTAssertEqual(points.count, 1, "the refusal opened \(points.count) fork(s), not exactly 1")
        XCTAssertEqual(points.first??.dropsTurn, target.promptUUID,
                       "the fork does not drop the edited message's own turn")
        let note = try XCTUnwrap(rig.composer.editNote, "the refused rewind showed no note at all")
        XCTAssertNotEqual(note, ComposerModel.forkNote("stale target"),
                          "the two refusals are shown with the same \(note.count)-character wording")
        XCTAssertEqual(note, ComposerModel.forkNote("unseen later turn"),
                       "the note is not this refusal's own wording")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// A body-level `error` this leaf has never seen also falls back rather than reporting success.
    ///
    /// The engine has ten distinct refusal strings and this leaf knows two of them; a composer that
    /// recognised only its own two and treated the rest as honoured would show eight refusals as
    /// completed rewinds.
    func testAnUnrecognisedRefusalStillFallsBack() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()

        await rig.lifecycle.stageFork(.success(ChannelKey(configHome: rig.key.configHome, session: SessionID())))
        await rig.lifecycle.stageSend("rewind_conversation", .success(Rig.refusal(reason: "an invented reason")))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "an unrecognised refusal raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let forks = await rig.lifecycle.forkCount
        XCTAssertEqual(forks, 1, "the unrecognised refusal opened \(forks) fork(s), not exactly 1")
        let note = try XCTUnwrap(rig.composer.editNote, "the unrecognised refusal showed no note at all")
        XCTAssertEqual(note, ComposerModel.forkNote("an invented reason"),
                       "the \(note.count)-character note is not the unnamed-refusal wording")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - Typing across the request

    /// The user keeps typing while the rewind request is in flight: **their** words stay in the field, and the
    /// composer says why the edited message did not come back into it.
    ///
    /// `edit` is one await against the engine and nothing disables the field across it, so a prefill assigned on the
    /// far side lands on top of whatever was typed in between — input the user can see in front of them and never
    /// gave to anything. The request is held open by the double, the field is typed into while it is suspended, and
    /// the honoured answer is then released.
    ///
    /// Deliberate break: assign `draft = prefill` unconditionally → the typing is gone.
    func testTypingWhileTheRewindIsInFlightIsKeptAndTheReasonIsShown() async throws {
        let rig = try await Rig()
        let messages = rig.renderedUserMessages()
        let target = try XCTUnwrap(messages.last, "the fixture folded no user message to edit")
        let honoured = try Rig.recordedHonouredBody()
        let prefill = try XCTUnwrap(honoured["prefillText"]?.stringValue, "the recorded honoured body carries no prefill")
        await rig.lifecycle.stageSend("rewind_conversation", .success(honoured))
        await rig.lifecycle.holdSend()

        let editing = Task { await rig.composer.edit(target) }
        let arrived = await rig.settleUntilAsync { await rig.lifecycle.sentSubtypes.contains("rewind_conversation") }
        XCTAssertTrue(arrived, "the rewind request never reached the double, so nothing was typed across anything")
        let typedSince = "a sentence typed while the rewind was in flight"
        rig.composer.draft = typedSince
        await rig.lifecycle.releaseSend()
        await editing.value

        XCTAssertEqual(rig.composer.draft, typedSince,
                       "the \(typedSince.count) character(s) typed while the request was in flight were overwritten")
        XCTAssertNotEqual(rig.composer.draft, prefill, "the prefill replaced what the user had typed since")
        XCTAssertEqual(rig.composer.editNote, ComposerModel.typedAheadNote,
                       "nothing said why the edited message was not put back into the field")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 1,
                       "the rewind itself was honoured, so its host signal is still raised exactly once")
        await rig.finish()
    }

    // MARK: - The payload

    /// Every request carries `last_seen_user_message_uuid`, and it is the **newest** rendered user
    /// message — not the edit target's own uuid.
    ///
    /// This is the arm that matters. The probe measured the field naming the target itself answering
    /// `"unseen later turn"`, so a composer that reached for the obvious value would be refused on
    /// every edit of an older message and would fall back to a fork every time — correct-looking in a
    /// smoke test with the feature gone. The oldest rendered message is edited so the two uuids
    /// differ, and both the equality and the inequality are asserted: substituting the target's uuid
    /// fails on both.
    func testTheRequestNamesTheNewestRenderedMessageAndNotTheTarget() async throws {
        let rig = try await Rig()
        let messages = rig.renderedUserMessages()
        XCTAssertGreaterThanOrEqual(messages.count, 2,
                                    "the fixture folded \(messages.count) user message(s); this arm needs at least 2")
        let target = try XCTUnwrap(messages.first, "the fixture folded no user message to edit")
        let newest = try XCTUnwrap(messages.last, "the fixture folded no newest user message")
        XCTAssertNotEqual(target.promptUUID, newest.promptUUID,
                          "the oldest and newest of the fold's \(messages.count) user message(s) are the same message")

        await rig.lifecycle.stageFork(.success(ChannelKey(configHome: rig.key.configHome, session: SessionID())))
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        let subtypes = await rig.lifecycle.sentSubtypes
        XCTAssertEqual(subtypes, ["rewind_conversation"],
                       "editing sent \(subtypes.count) control request(s), not exactly 1 rewind_conversation")
        let sent = await rig.lifecycle.payload(ofFirst: "rewind_conversation")
        let payload = try XCTUnwrap(sent, "the rewind request carries no payload")
        XCTAssertEqual(payload["target_message_uuid"]?.stringValue, target.promptUUID,
                       "the request does not name the edited message under `target_message_uuid`")
        let lastSeen = try XCTUnwrap(payload["last_seen_user_message_uuid"]?.stringValue,
                                     "the request carries no `last_seen_user_message_uuid`, which refuses every older edit")
        XCTAssertEqual(lastSeen, newest.promptUUID,
                       "`last_seen_user_message_uuid` is not the newest of the fold's \(messages.count) rendered user message(s)")
        XCTAssertNotEqual(lastSeen, target.promptUUID,
                          "`last_seen_user_message_uuid` is the edit target's own uuid, which the engine refuses with `unseen later turn`")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The same field is on the honoured leg's request too — presence is asserted on both arms, not
    /// only on the one that happens to be refused.
    func testTheHonouredRequestCarriesTheFieldAsWell() async throws {
        let rig = try await Rig()
        let newest = try XCTUnwrap(rig.renderedUserMessages().last, "the fixture folded no user message to edit")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedHonouredBody()))
        await rig.composer.edit(newest)

        let sent = await rig.lifecycle.payload(ofFirst: "rewind_conversation")
        let payload = try XCTUnwrap(sent, "the rewind request carries no payload")
        XCTAssertEqual(payload["last_seen_user_message_uuid"]?.stringValue, newest.promptUUID,
                       "the honoured leg's request does not carry the newest rendered message under `last_seen_user_message_uuid`")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - Nothing to fork from

    /// An edited message with no assistant record before it has no fork point: nothing is offered,
    /// the reason is shown, and no fork reaches the lifecycle.
    ///
    /// The fixture's own refused target is that message — the first conversational `user` record —
    /// so this arm is the recording's leg exactly as it was recorded.
    func testAMessageWithNoPrecedingAssistantOffersNoForkAndSaysWhy() async throws {
        let rig = try await Rig()
        let target = try XCTUnwrap(rig.renderedUserMessages().first, "the fixture folded no user message to edit")
        XCTAssertNil(rig.precedingAssistantKey(before: target),
                     "the fold put an assistant item before the conversation's first user message, so this arm proves nothing")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        let forks = await rig.lifecycle.forkCount
        XCTAssertEqual(forks, 0, "a message with no fork point opened \(forks) fork(s)")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let note = try XCTUnwrap(rig.composer.editNote, "no reason was shown for offering no fork")
        XCTAssertEqual(note, ComposerModel.noForkPointNote("stale target"),
                       "the \(note.count)-character note is not the no-fork-point reason")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - The note, on screen

    /// **G4's "shows a visible note", through the view.** `ComposerModel.editNote` was set, and
    /// asserted, by every arm above; until Task 11 no view read it, so the clause was a claim about a
    /// property rather than about anything a person could see.
    ///
    /// Walked with `ComposerViewTree`, which stops at every reference type that is not a view — an
    /// unbounded `Mirror` walk leaves the view layer, runs into the app's cyclic object graph and
    /// takes the bundle down, after which `xcodebuild` retries it and the suite reports `Executed 0`
    /// at exit 0 (tracker 147).
    func testTheRefusedRewindsNoteIsDrawnByTheComposer() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        await rig.lifecycle.stageFork(.success(ChannelKey(configHome: rig.key.configHome, session: SessionID())))
        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))

        await rig.composer.edit(target)

        let note = try XCTUnwrap(rig.composer.editNote, "the refused rewind set no note to draw")
        let surface = try XCTUnwrap(ComposerViewTree.view(named: "EditNoteSurface",
                                                          in: ComposerViewTree.body(of: ComposerView(model: rig.composer))),
                                    "the composer's body draws no surface for the edit note")
        let drawn = try XCTUnwrap(Mirror(reflecting: surface).descendant("note") as? String,
                                  "the note surface was drawn with nothing in it")
        XCTAssertTrue(drawn == note,
                      "the drawn note is \(drawn.count) character(s); the model's is \(note.count)")
        XCTAssertTrue(drawn.contains("not rewound") && drawn.contains("fork"),
                      "the drawn \(drawn.count)-character note does not say the conversation was not rewound "
                      + "and a fork was opened")

        // The floor: the same surface carries nothing once the model has no note, so the arm above is
        // about the note reaching the view and not about the surface merely existing.
        rig.composer.editNote = nil
        let empty = try XCTUnwrap(ComposerViewTree.view(named: "EditNoteSurface",
                                                        in: ComposerViewTree.body(of: ComposerView(model: rig.composer))),
                                  "the composer stopped drawing the surface once the note was cleared")
        XCTAssertNil(Mirror(reflecting: empty).descendant("note") as? String,
                     "the note surface still carries a note after the model dropped it")

        await rig.finish()
    }
}

// MARK: - Support

/// One channel over the `rewind-turn` fixture: a real `TranscriptIndex`, a real `StreamIngestion`
/// behind C6.1's `ChannelTimelineModel`, a real `ComposerModel`, and one `ComposerLifecycleDouble`
/// serving as X5.
///
/// The same shape as `QueueChipTests`' rig and for the same reason — a `LaunchSequence` adds a
/// binary probe and two gates that say nothing about a rewind. The scratch tree is a `TempTree`,
/// which refuses to build inside any config home (X9).
@MainActor
private final class Rig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: ComposerLifecycleDouble
    let timelines: ChannelTimelineRegistry
    let composers: ComposerRegistry
    let key: ChannelKey
    /// Every channel the registry was asked to bring into view, in order — C5's `ShellModel.select` stands here.
    private var selection = SelectionLog()
    var selected: [ChannelKey] { selection.keys }

    /// A box, so the closure the registry keeps does not capture the rig itself.
    @MainActor final class SelectionLog { var keys: [ChannelKey] = [] }


    enum RigError: Error { case noMainTranscript, noRecordedLeg, noMessageWithAPrecedingAssistant }

    var timeline: ChannelTimelineModel { timelines.model(for: key) }
    var composer: ComposerModel { composers.model(for: key)! }

    init(fixture: String = "rewind-turn") async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        guard let main = try Self.mainTranscript(of: fixture) else { throw RigError.noMainTranscript }
        let destination = projects
            .appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
            .appending(path: "\(main.session).jsonl")
        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: main.slugDirectory, to: destination.deletingLastPathComponent())

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = ComposerLifecycleDouble()
        workspace = Workspace(configHome: home.configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)
        await lifecycle.openEvents(of: key)
        await lifecycle.alwaysPerform(.success(ActivityFixtures.state(key)))

        timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        composers = ComposerRegistry()
        let selection = SelectionLog()
        self.selection = selection
        composers.selectChannel = { key in selection.keys.append(key) }
        composers.attach(to: workspace,
                         timeline: { [timelines] in timelines.model(for: $0) },
                         lifecycle: lifecycle)

        await timelines.model(for: key).open(row())
        _ = composers.model(for: key)
    }

    // MARK: - Reading the fold

    /// The fold's user messages, in its own order. The test's own walk, so the composer's answer is
    /// compared against the timeline rather than against itself.
    func renderedUserMessages() -> [UserMessageItem] {
        timeline.timeline.items.compactMap {
            if case .userMessage(let message) = $0, !message.promptUUID.isEmpty { message } else { nil }
        }
    }

    /// The `ItemID.key` of the assistant item immediately before `target`, computed here by walking
    /// the fold backwards.
    func precedingAssistantKey(before target: UserMessageItem) -> String? {
        let items = timeline.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.id.key }
        }
        return nil
    }

    /// The last record of the assistant item immediately before `target` — the uuid the engine's own
    /// leaf names after it honours a rewind to that turn.
    func precedingAssistantRecord(before target: UserMessageItem) -> String? {
        let items = timeline.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.recordUUIDs.last ?? assistant.id.key }
        }
        return nil
    }

    /// The assistant **record** the fixture's own transcript names before `uuid`, followed through
    /// the recording's `parentUuid` links.
    ///
    /// This is G4's independent oracle for the fork point. Production walks the **fold's item order**
    /// backwards (`ComposerModel.precedingAssistantKey(before:)`); this follows the **engine's own
    /// parent links in the recording**, skipping the attachment and bookkeeping records that render
    /// nothing. Two different sources, so a wrong answer in one is not a wrong answer in the other —
    /// which is what the previous expectation, a second copy of the production walk, could not claim.
    ///
    /// The oracle is itself checked against the recording's `precedingAssistantUuid` in the test that
    /// uses it, so the engine's own measurement is what says this walk is right.
    static func recordedParentAssistantRecord(of uuid: String) throws -> String {
        guard let main = try mainTranscript(of: "rewind-turn") else { throw RigError.noMainTranscript }
        let file = main.slugDirectory.appending(path: "\(main.session).jsonl")
        let decoder = JSONDecoder()
        var byUUID: [String: JSONValue] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(JSONValue.self, from: data),
                  let id = record["uuid"]?.stringValue
            else { continue }
            byUUID[id] = record
        }
        var cursor = byUUID[uuid]?["parentUuid"]?.stringValue
        while let current = cursor, let record = byUUID[current] {
            if record["type"]?.stringValue == "assistant" { return current }
            cursor = record["parentUuid"]?.stringValue
        }
        throw RigError.noRecordedLeg
    }

    /// The `ItemID.key` of the assistant item that **holds** `record`.
    ///
    /// A containment lookup and never an ordering one: the fold groups consecutive assistant records
    /// of one message into a run keyed by the run's first record, and this only resolves a record
    /// into the run that holds it. Nothing here asks what comes before what.
    func itemKey(holding record: String) throws -> String {
        for item in timeline.timeline.items {
            if case .assistantMessage(let assistant) = item, assistant.recordUUIDs.contains(record) {
                return assistant.id.key
            }
        }
        throw RigError.noRecordedLeg
    }

    /// The **oldest** user message the fold rendered that has an assistant item before it, so a fork
    /// point exists and the target is not the newest message either.
    func messageWithAPrecedingAssistant() throws -> UserMessageItem {
        for message in renderedUserMessages() where precedingAssistantKey(before: message) != nil {
            return message
        }
        throw RigError.noMessageWithAPrecedingAssistant
    }

    /// Opens a streaming preview by pushing one invented `message_start` onto the channel's tap.
    ///
    /// The ids are this suite's own repeated nibbles and the frame is decoded by the production
    /// decoder, as a real one would be; nothing engine-recorded is spelled here (§11).
    func openAPreview() async {
        let line = Data(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_invented0000","type":"message","role":"assistant","content":[],"model":"an-invented-model"}},"session_id":"\#(key.session.description)","uuid":"00000000-0000-4000-8000-0000000000b1"}"#.utf8)
        let frame = FrameDecoder.decode(line: line)
        guard case .streamEvent = frame else {
            return XCTFail("the invented line did not decode as a stream_event frame")
        }
        lifecycle.enqueue(.frame(frame, .first), to: key)
    }

    /// Waits, bounded, for the channel's fold to satisfy `predicate`, and **returns whether it did**
    /// so the caller asserts the outcome.
    func settleUntil(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate(timeline) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(timeline)
    }

    /// The same bounded wait for a condition the double answers rather than the fold: a request the composer is
    /// suspended inside has arrived, which is where a test types across an await.
    func settleUntilAsync(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    /// Zero `rewind_files` requests, on every arm. *Edit* is not `/rewind`.
    func assertNoFileRewind(file: StaticString = #filePath, line: UInt = #line) async throws {
        let subtypes = await lifecycle.sentSubtypes
        XCTAssertFalse(subtypes.contains("rewind_files"),
                       "the edit path sent a file rewind among its \(subtypes.count) control request(s)",
                       file: file, line: line)
    }

    // MARK: - The recording

    /// The recorded honoured body: `{rewound: true, targetMessageUuid, prefillText, precedingAssistantUuid}`.
    static func recordedHonouredBody() throws -> JSONValue {
        try recordedBody { $0["rewound"]?.boolValue == true }
    }

    /// The recorded honoured body with its `precedingAssistantUuid` replaced by a record this fold
    /// actually holds. Every other key, `prefillText` included, is the recording's own.
    static func recordedHonouredBody(preceding uuid: String) throws -> JSONValue {
        guard case .object(var body) = try recordedHonouredBody() else { throw RigError.noRecordedLeg }
        body["precedingAssistantUuid"] = .string(uuid)
        return .object(body)
    }

    /// The recorded refusal: `{rewound: false, prefillText: null, precedingAssistantUuid: null, error}`,
    /// inside a `control_response {subtype: "success"}` envelope.
    static func recordedRefusedBody() throws -> JSONValue {
        try recordedBody { $0["error"]?.stringValue != nil }
    }

    /// A refusal of the recording's own shape carrying another of the engine's reasons. The two
    /// null-valued keys are kept because a composer that read them instead of `error` must fail here
    /// exactly as it fails on the recorded leg.
    static func refusal(reason: String) -> JSONValue {
        .object(["rewound": .bool(false), "prefillText": .null,
                 "precedingAssistantUuid": .null, "error": .string(reason)])
    }

    /// Reads the fixture's `frames.ndjson` and returns the first `control_response` body matching
    /// `predicate`. Nothing read here is written anywhere; it lives for the duration of one test.
    private static func recordedBody(_ predicate: (JSONValue) -> Bool) throws -> JSONValue {
        let url = fixtures.appending(path: "rewind-turn").appending(path: "frames.ndjson")
        let decoder = JSONDecoder()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(JSONValue.self, from: data),
                  record["frame"]?["type"]?.stringValue == "control_response",
                  let response = record["frame"]?["response"],
                  response["subtype"]?.stringValue == "success",
                  let body = response["response"], predicate(body)
            else { continue }
            return body
        }
        throw RigError.noRecordedLeg
    }

    // MARK: - Teardown and fixtures

    func finish() async {
        await lifecycle.finishEvents(of: key)
        composers.release(key)
        timelines.release(key)
    }

    func row() -> ChannelRow {
        ChannelRow(key: key,
                   title: "an invented channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: URL(fileURLWithPath: "/invented/project"),
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: ActivityFixtures.state(key))
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures")
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = fixtures.appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, slug)
            }
        }
        return nil
    }
}
