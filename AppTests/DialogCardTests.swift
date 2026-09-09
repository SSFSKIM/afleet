import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The two dialog cards and the retraction they settle (acceptance G1f, item 62).
///
/// **Everything here runs on committed fixtures.** `dialog-refusal-fallback` and
/// `dialog-fable-overage` are the evidence half of this clause: their requests, their retracted
/// uuids, their undeclared kind and their `model_consent_fallback` frames are read out of the
/// recordings rather than restated, through `FixtureRunner`'s in-process decode. Two payloads are
/// varied by override where the corpus records only one shape — a null `apiRefusalCategory` and an
/// overage payload with neither balance key at all — and each says so where it is used.
///
/// **Every answer clause asserts the body that left the host**, never that a card changed: a card
/// changes for many reasons and only one of them is the right answer having been sent. The
/// undeclared-kind clause is the inverse and is a **trace**: the dangerous path is answering a
/// dialog the binary owns, that path cannot be executed to prove it wrong, so the assertion is that
/// `perform` was never reached at all (§6.3).
///
/// **No assertion here prints an operand that carries content.** `XCTAssertEqual` prints both sides
/// on failure, and a `ChannelKey` holds a config home, an item id holds a session, and a card's
/// reading, an answer body and a fixture's frame all hold engine bytes (§6.3, §11). Every comparison
/// over one of those is therefore spelled as a boolean with a written message; the equality
/// assertions that remain compare counts and the engine's own millisecond constants, which carry
/// nothing. Failure messages carry counts and action names.
@MainActor
final class DialogCardTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("d", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-dialogs-unwritten"))
    }

    private static var stream: LogicalStream {
        LogicalStream(configHome: channel.configHome, sessionID: channel.session, name: .main)
    }

    /// Every `request_user_dialog` a fixture records, in order and with its recorded id — including
    /// the one the policy leaves unanswered, which arrives as `.unansweredDialog` and not as
    /// `.request`.
    private func dialogRequests(_ fixture: String) throws -> [InboundRequest] {
        try FixtureRunner.events(fixture).compactMap { event in
            let request: InboundRequest?
            switch event {
            case .request(let r): request = r
            case .unansweredDialog(let r): request = r
            default: request = nil
            }
            guard let request, request.subtype == "request_user_dialog" else { return nil }
            return request
        }
    }

    /// A card over one recorded dialog request, with the payload optionally replaced.
    private func card(_ fixture: String, at index: Int,
                      payload: [String: Any]? = nil,
                      state: DecisionItem.State = .pending) throws -> DecisionCard {
        let requests = try dialogRequests(fixture)
        XCTAssertGreaterThan(requests.count, index,
                             "the fixture records \(requests.count) dialogs, fewer than the test needs")
        var item = try XCTUnwrap(DecisionItem(surfacing: requests[index], in: Self.channel),
                                 "the surfacing initialiser opened no item for a recorded dialog")
        if let payload {
            // `DecisionItem.payload` is the request object the engine sent, which is what the card
            // decodes; only its `payload` key is varied.
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload.canonicalData()) as? [String: Any],
                                    "a recorded dialog request is not a JSON object")
            raw["payload"] = payload
            item.payload = try JSONDecoder().decode(JSONValue.self,
                                                    from: JSONSerialization.data(withJSONObject: raw))
        }
        item.state = state
        return DecisionCard(item)
    }

    /// A lifecycle that accepts every answer, and the one object an answer leaves by.
    private func hosted() async -> (LifecycleDouble, DecisionAnswering) {
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        return (lifecycle, DecisionAnswering(lifecycle: lifecycle))
    }

    private func dialogView(_ card: DecisionCard,
                            _ answering: DecisionAnswering,
                            retraction: RetractionRegistry? = nil,
                            composer: (any ComposerSite)? = nil,
                            deadline: DialogDeadline = .standard) throws -> DialogCardView {
        guard case .dialog(let request) = card.payload else {
            throw XCTSkip("a recorded dialog request no longer decodes as one")
        }
        return DialogCardView(card: card, request: request, presentation: .full, channel: Self.channel,
                              answering: answering, retraction: retraction, composer: composer,
                              deadline: deadline)
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the card offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    private func offers(_ label: String, in body: Any) -> Bool { ViewTree.button(label, in: body) != nil }

    /// The one answer the double received, as the JSON body the transport would write.
    private func sentBody(_ lifecycle: LifecycleDouble, _ label: String) async throws -> JSONValue {
        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 1, "one press on \(label) produced \(actions.count) actions")
        guard case .answer(_, let answer)? = actions.first?.action else {
            XCTFail("the action \(label) emitted was not an answer")
            return .null
        }
        guard case .success(let success) = answer.controlResponse(for: RequestID(rawValue: "dddd-1")).body,
              let response = success.response else {
            XCTFail("the answer for \(label) did not encode as a success body")
            return .null
        }
        return response
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The timeline as it stood when the fixture's `index`-th dialog was raised, folded by C3's
    /// reducer. The retracted messages under test are the ones the recording actually streamed, and
    /// the dialog request itself is left to the caller — applying it is what makes a card pending.
    private func reduced(_ fixture: String, untilDialog index: Int) throws -> WireReducer {
        var reducer = WireReducer(stream: Self.stream, slug: "invented-slug")
        var seen = 0
        for event in try FixtureRunner.events(fixture) {
            switch event {
            case .request(let r), .unansweredDialog(let r):
                guard r.subtype == "request_user_dialog" else {
                    _ = reducer.apply(event)
                    continue
                }
                if seen == index { return reducer }
                seen += 1
            default:
                _ = reducer.apply(event)
            }
        }
        return reducer
    }

    // MARK: - The refusal-fallback dialog

    /// The three results and the close, each asserted as the exact body inside the engine's own
    /// envelope (anchor 2, `cli.pretty.js:702406`).
    ///
    /// Discriminating on the envelope as much as on the word: a result sent bare, or `cancelled`
    /// sent as a completed close, is accepted by no engine and would be invisible in a test that
    /// only checked the card had gone.
    func testEachRefusalActionSendsItsEngineResultAndClosingCancels() async throws {
        let expected: [(label: String, body: String)] = [
            ("Retry on the fallback model", #"{"behavior":"completed","result":"retry_fallback"}"#),
            ("Edit the prompt", #"{"behavior":"completed","result":"edit_prompt"}"#),
            ("Keep the refusal", #"{"behavior":"completed","result":"cancelled"}"#),
            ("Close", #"{"behavior":"cancelled"}"#),
        ]
        for (label, body) in expected {
            let (lifecycle, answering) = await hosted()
            let raised = try card("dialog-refusal-fallback", at: 0)
            try press(label, in: try dialogView(raised, answering).body)
            await answering.whenIdle()
            let sent = try await sentBody(lifecycle, label)
            XCTAssertTrue(sent == (try json(body)), "the body sent for \(label) is not the engine's spelling")
        }
    }

    /// Anchor 4: five minutes by default, `CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS` first and a trusted
    /// `dialogExpiry` second, and `never` starts no timer at all. The card carries it because on
    /// expiry the engine answers `{behavior:"cancelled"}` itself and the user is otherwise working a
    /// control that has silently stopped being answerable.
    func testAPendingDialogCardShowsTheFiveMinuteDeadlineAndItsOverrides() async throws {
        let (_, answering) = await hosted()
        let pending = try card("dialog-refusal-fallback", at: 0)

        let standard = DialogDeadline(environment: [:], dialogExpiry: nil)
        XCTAssertEqual(standard.milliseconds, 300_000, "the default deadline is not the engine's 300 000 ms")
        let texts = CardTree.texts(in: try dialogView(pending, answering, deadline: standard).body)
        XCTAssertTrue(texts.contains("This dialog expires in 5 minutes."),
                      "a pending dialog card does not show its five-minute deadline")

        let overridden = DialogDeadline(environment: ["CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS": "60000"],
                                        dialogExpiry: "10m")
        XCTAssertEqual(overridden.milliseconds, 60_000,
                       "the environment override does not take precedence over dialogExpiry")
        XCTAssertEqual(DialogDeadline(environment: [:], dialogExpiry: "10m").milliseconds, 600_000,
                       "a trusted dialogExpiry of 10m is not read")
        let never = DialogDeadline(environment: [:], dialogExpiry: "never")
        XCTAssertNil(never.milliseconds, "dialogExpiry never still starts a timer")
        XCTAssertTrue(CardTree.texts(in: try dialogView(pending, answering, deadline: never).body)
                          .contains("This dialog does not expire."),
                      "a dialog with no deadline does not say so")
    }

    /// `apiRefusalCategory` is **nullable, not merely absent** (anchor 2). Both directions: the
    /// recorded payload carries a category and draws it; a payload carrying an explicit `null` draws
    /// none. A card that read the key's presence would draw a category naming nothing.
    ///
    /// The null payload is an override of the recorded one — no recording carries the null arm.
    func testANullRefusalCategoryDrawsNoCategoryAndAPresentOneDoes() async throws {
        let (_, answering) = await hosted()
        let recorded = try card("dialog-refusal-fallback", at: 0)
        let category = try XCTUnwrap(recorded.refusalFallback?.apiRefusalCategory,
                                     "the recorded refusal payload carries no category")
        let drawn = CardTree.texts(in: try dialogView(recorded, answering).body)
        XCTAssertTrue(drawn.contains("Category: \(category)"), "a recorded category is not drawn")

        let nulled = try card("dialog-refusal-fallback", at: 0, payload: [
            "originalModel": "invented-original", "fallbackModel": "invented-fallback",
            "apiRefusalCategory": NSNull(),
        ])
        XCTAssertTrue(nulled.refusalFallback?.apiRefusalCategory == nil,
                      "an explicit null decoded as a category")
        let none = CardTree.texts(in: try dialogView(nulled, answering).body)
        XCTAssertFalse(none.contains(where: { $0.hasPrefix("Category:") }),
                       "a null category still drew a category line")
    }

    /// §8.4's dialog table: `edit_prompt` — "the engine aborts the turn; the composer is prefilled
    /// with the last user text". The answer alone is not the behaviour; without the prefill the user
    /// presses *Edit the prompt* and is left with an aborted turn and an empty field.
    ///
    /// All four actions, because the prefill belongs to one of them: three resolutions that must
    /// leave the field alone are as much of the clause as the one that must fill it. And the refused
    /// arm, because the prefill rides the same success branch the retraction does — a composer
    /// filled for an answer the engine was never told is a prompt restored for a dialog still open.
    func testOnlyEditThePromptRestoresTheLastPromptAndOnlyOnSuccess() async throws {
        let expected: [(label: String, restores: Int)] = [
            ("Edit the prompt", 1),
            ("Retry on the fallback model", 0),
            ("Keep the refusal", 0),
            ("Close", 0),
        ]
        for (label, restores) in expected {
            let composer = RecordingComposerSite()
            let (_, answering) = await hosted()
            let raised = try card("dialog-refusal-fallback", at: 0)
            try press(label, in: try dialogView(raised, answering, composer: composer).body)
            await answering.whenIdle()
            XCTAssertEqual(composer.restores, restores,
                           "\(label) restored the last prompt \(composer.restores) time(s), not \(restores)")
        }

        let refusing = LifecycleDouble()
        await refusing.always(.failure(.notOwned))
        let answering = DecisionAnswering(lifecycle: refusing)
        let composer = RecordingComposerSite()
        let raised = try card("dialog-refusal-fallback", at: 0)
        try press("Edit the prompt", in: try dialogView(raised, answering, composer: composer).body)
        await answering.whenIdle()
        XCTAssertNotNil(answering.banner, "the refused answer raised no banner, so nothing was refused")
        XCTAssertEqual(composer.restores, 0,
                       "a refused answer restored the last prompt \(composer.restores) time(s)")
    }

    /// A host with no composer answers exactly as it did: the seam is optional and its absence
    /// removes nothing from the wire (C6.3's rule for a host with no list to filter, applied to the
    /// composer).
    func testEditThePromptStillAnswersWhereTheHostHasNoComposer() async throws {
        let (lifecycle, answering) = await hosted()
        let raised = try card("dialog-refusal-fallback", at: 0)
        try press("Edit the prompt", in: try dialogView(raised, answering).body)
        await answering.whenIdle()
        let sent = try await sentBody(lifecycle, "Edit the prompt")
        XCTAssertTrue(sent == (try json(#"{"behavior":"completed","result":"edit_prompt"}"#)),
                      "a host with no composer did not send the engine's edit_prompt body")
    }

    // MARK: - Retraction

    /// The discriminating clause of G1f, asserted across the card's whole lifetime and in both
    /// directions: the messages the dialog names are **retained while it is pending** and gone after
    /// **any** resolution. A registry that evicted on receipt would pass a test that only looked at
    /// the end.
    ///
    /// The items are the recording's own — folded by C3's reducer from the frames that preceded the
    /// dialog — so the uuid under test is one the engine really streamed.
    func testTheRetractedMessagesAreRetainedWhilePendingAndGoneAfterAnyResolution() async throws {
        let resolutions = ["Retry on the fallback model", "Edit the prompt", "Keep the refusal", "Close"]
        for label in resolutions {
            let registry = RetractionRegistry()
            let (_, answering) = await hosted()
            let raised = try card("dialog-refusal-fallback", at: 1)
            let retracted = try XCTUnwrap(raised.refusalFallback?.retractedMessageUUIDs.first,
                                          "the recorded dialog retracts nothing")

            // The timeline as it stood when this dialog was raised.
            let reducer = try reduced("dialog-refusal-fallback", untilDialog: 1)
            let items = reducer.durable.items
            let doomed = items.filter { $0.id.key == retracted }
            XCTAssertEqual(doomed.count, 1, "the recording holds \(doomed.count) items for the retracted uuid")
            let survivors = items.filter { $0.id.key != retracted }
            XCTAssertGreaterThan(survivors.count, 0, "the recording holds nothing but the retracted message")

            // Received *and drawn*, not yet answered: nothing goes. The card is built and its body
            // evaluated before this assertion, so a registry fed at receipt or at draw time — which
            // is the failure this clause exists to catch — is already wrong here.
            let body = try dialogView(raised, answering, retraction: registry).body
            XCTAssertTrue(doomed.allSatisfy(registry.retains),
                          "a message was evicted before \(label) was pressed")

            try press(label, in: body)
            await answering.whenIdle()

            XCTAssertTrue(doomed.allSatisfy { !registry.retains($0) },
                          "the retracted message survived \(label)")
            XCTAssertTrue(survivors.allSatisfy(registry.retains),
                          "\(survivors.count) unretracted items were evicted by \(label)")
        }
    }

    /// sweep#9: a retraction is a **resolution**, so it waits for the answer to succeed.
    ///
    /// The registry has no rollback: once a uuid is in, the message is gone from the list for the
    /// life of the channel. Feeding it when the answer is merely *scheduled* deletes streamed
    /// messages for a `perform` that then threw — the dialog is still open, the engine was never
    /// told, and the conversation it was raised about has holes in it. The lifecycle refuses every
    /// answer here, which is the one arm that can tell a registry fed on dispatch from one fed on
    /// success.
    func testARefusedAnswerRetractsNothing() async throws {
        let registry = RetractionRegistry()
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.failure(.notOwned))
        let answering = DecisionAnswering(lifecycle: lifecycle)

        let raised = try card("dialog-refusal-fallback", at: 1)
        let retracted = try XCTUnwrap(raised.refusalFallback?.retractedMessageUUIDs.first,
                                      "the recorded dialog retracts nothing")
        let items = try reduced("dialog-refusal-fallback", untilDialog: 1).durable.items
        let doomed = items.filter { $0.id.key == retracted }
        XCTAssertEqual(doomed.count, 1, "the recording holds \(doomed.count) items for the retracted uuid")

        try press("Retry on the fallback model", in: try dialogView(raised, answering, retraction: registry).body)
        await answering.whenIdle()

        XCTAssertNotNil(answering.banner, "the refused answer raised no banner, so nothing was refused")
        XCTAssertTrue(doomed.allSatisfy(registry.retains),
                      "a refused answer took back the messages its dialog names")
    }

    /// §8.4: a `control_cancel_request` that retires the dialog is a resolution too. The card reads
    /// D12's first row, the retraction settles, and **nothing** goes on the wire — the binary
    /// already settled the request.
    func testACancelRequestThatRetiresTheDialogAlsoResolvesTheRetraction() async throws {
        let registry = RetractionRegistry()
        let (lifecycle, _) = await hosted()
        let requests = try dialogRequests("dialog-refusal-fallback")
        XCTAssertGreaterThan(requests.count, 1, "the fixture records \(requests.count) dialogs")
        let request = requests[1]

        var reducer = try reduced("dialog-refusal-fallback", untilDialog: 1)
        let items = reducer.durable.items
        _ = reducer.apply(.request(request))
        let pending = try XCTUnwrap(reducer.overlay.decisions[request.id], "the reducer opened no dialog decision")
        let card = DecisionCard(pending)
        let retracted = try XCTUnwrap(card.refusalFallback?.retractedMessageUUIDs.first,
                                      "the recorded dialog retracts nothing")
        let doomed = items.filter { $0.id.key == retracted }
        XCTAssertEqual(doomed.count, 1, "the recording holds \(doomed.count) items for the retracted uuid")
        XCTAssertTrue(doomed.allSatisfy(registry.retains), "a message was evicted while the dialog was pending")

        _ = reducer.apply(.requestCancelled(request.id, .first))
        let retired = DecisionCard(try XCTUnwrap(reducer.overlay.decisions[request.id],
                                                 "the cancelled dialog left the overlay"))
        XCTAssertTrue(retired.state == .cancelled, "a retired dialog did not reach the cancelled state")
        XCTAssertTrue(retired.reading(inStaleOverlay: false)?.text == "Answered elsewhere.",
                      "a retired dialog does not read as answered elsewhere")

        registry.resolved(retired, in: Self.channel)
        XCTAssertTrue(doomed.allSatisfy { !registry.retains($0) },
                      "the retracted message survived the dialog being retired")
        let count = await lifecycle.actions.count
        XCTAssertEqual(count, 0, "a retired dialog put \(count) actions on the wire")
    }

    // MARK: - The overage dialog

    /// `consent` is offered only where the engine says billing is already on (anchor 3): a bare wire
    /// reply enables nothing. Both arms, and the answer asserted as a body — the enabled arm sends
    /// `consent`, the disabled arm offers the credits action in its place.
    func testConsentIsOfferedOnlyWhenOveragesAreEnabled() async throws {
        let (lifecycle, answering) = await hosted()
        let enabled = try card("dialog-fable-overage", at: 0)
        XCTAssertTrue(enabled.overagesEnabled, "the fixture's first overage dialog is not the enabled arm")
        let enabledBody = try dialogView(enabled, answering).body
        XCTAssertTrue(offers("Use usage credits", in: enabledBody), "the enabled arm offers no consent action")
        XCTAssertFalse(offers("Set up usage credits…", in: enabledBody),
                       "the enabled arm offers the credits action as well as consent")
        try press("Use usage credits", in: enabledBody)
        await answering.whenIdle()
        let consent = try await sentBody(lifecycle, "Use usage credits")
        XCTAssertTrue(consent == (try json(#"{"behavior":"completed","result":"consent"}"#)),
                      "the consent answer is not the engine's spelling")

        let (_, second) = await hosted()
        let disabled = try card("dialog-fable-overage", at: 1)
        XCTAssertFalse(disabled.overagesEnabled, "the fixture's second overage dialog is not the disabled arm")
        let disabledBody = try dialogView(disabled, second).body
        XCTAssertFalse(offers("Use usage credits", in: disabledBody),
                       "consent is offered on a dialog the engine says has no billing")
        XCTAssertTrue(offers("Set up usage credits…", in: disabledBody),
                      "the disabled arm offers no way to set credits up")
        XCTAssertTrue(offers("Switch to the default model", in: disabledBody),
                      "the disabled arm offers no way to resolve the dialog")
        XCTAssertTrue(offers("Not now", in: disabledBody), "the disabled arm offers no way to decline")
    }

    /// Spec D7: the payload carries **no URL**, so *Set up usage credits…* opens nothing, sends
    /// nothing and leaves the card pending. The card resolves only on *Switch to the default model*
    /// or *Not now*, and both of those are asserted as bodies.
    func testSetUpUsageCreditsLeavesTheCardPendingAndEmitsNoLink() async throws {
        let (lifecycle, answering) = await hosted()
        let disabled = try card("dialog-fable-overage", at: 1)
        let body = try dialogView(disabled, answering).body
        try press("Set up usage credits…", in: body)
        await answering.whenIdle()
        let count = await lifecycle.actions.count
        XCTAssertEqual(count, 0, "the credits action put \(count) actions on the wire")
        XCTAssertTrue(disabled.state == .pending, "the credits action settled the card")

        let texts = CardTree.texts(in: body)
        XCTAssertTrue(texts.contains(DialogCardView.creditsNote),
                      "the card does not say credits are set up outside the session")
        XCTAssertFalse(texts.contains(where: { $0.contains("http") }),
                       "the card drew an address the payload never carried")

        for (label, expected) in [("Switch to the default model", #"{"behavior":"completed","result":"switch_default"}"#),
                                  ("Not now", #"{"behavior":"completed","result":"cancelled"}"#)] {
            let (resolver, answers) = await hosted()
            let fresh = try card("dialog-fable-overage", at: 1)
            try press(label, in: try dialogView(fresh, answers).body)
            await answers.whenIdle()
            let sent = try await sentBody(resolver, label)
            XCTAssertTrue(sent == (try json(expected)),
                          "the body sent for \(label) is not the engine's spelling")
        }
    }

    /// `model_consent_fallback` renders as the card's outcome **when it arrives**, and its absence
    /// is equally correct: the engine emits nothing when provisioning succeeded (anchor 5), so a
    /// card that waited for the frame would hang on the successful path. Both directions.
    func testTheConsentFallbackIsTheOutcomeAndItsAbsenceStillSettlesTheCard() async throws {
        let settled = try card("dialog-fable-overage", at: 1, state: .answered(outcome: "switch_default"))

        // No frame: the card still settles, and it reads its own outcome.
        let alone = try XCTUnwrap(settled.reading(inStaleOverlay: false, consentFallback: nil),
                                  "an answered overage card is still waiting with no fallback frame")
        XCTAssertTrue(alone.text == "switch_default", "the settled card does not read its own outcome")

        // The frame the recording carries: its content is the outcome, verbatim.
        let frame = try XCTUnwrap(Self.consentFallbacks(try FixtureRunner.frames("dialog-fable-overage")).first,
                                  "the fixture records no model_consent_fallback frame")
        let withFrame = try XCTUnwrap(settled.reading(inStaleOverlay: false, consentFallback: frame),
                                      "the card with a fallback frame is still waiting")
        XCTAssertTrue(withFrame.text == frame.fields.content,
                      "the fallback frame's content is not the card's outcome")

        let (_, answering) = await hosted()
        let drawn = CardTree.texts(in: DecisionCardView(card: settled, presentation: .full, in: Self.channel,
                                                        answering: answering, consentFallback: frame).body)
        XCTAssertTrue(drawn.contains(frame.fields.content), "the hosted card does not draw the frame's content")
    }

    /// The overage payload's `balanceCents` and `currency` are declared and **currently unfed**
    /// (anchor 3, `cli.pretty.js:770104`). A payload with neither key, and one carrying explicit
    /// nulls, both draw no balance — not a zero, which a user would read as an empty account. Where
    /// the engine does feed one, the card draws what arrived.
    func testTheOverageCardShowsNoBalanceWhereTheEngineFedNone() async throws {
        let (_, answering) = await hosted()

        // The disabled arm the fixture records carries explicit nulls.
        let nulled = try card("dialog-fable-overage", at: 1)
        XCTAssertTrue(nulled.overageConsent?.balanceCents == nil, "an explicit null decoded as a balance")
        XCTAssertFalse(CardTree.texts(in: try dialogView(nulled, answering).body)
                           .contains(where: { $0.hasPrefix("Balance:") }),
                       "a null balance still drew a balance line")

        // The shape the engine actually sends today: the two flags and nothing else. An override,
        // because no recording carries it.
        let unfed = try card("dialog-fable-overage", at: 0,
                             payload: ["overagesEnabled": true, "modelName": "invented-model"])
        XCTAssertTrue(DialogCardView.balanceText(try XCTUnwrap(unfed.overageConsent,
                                                               "the overage payload no longer decodes")) == nil,
                      "a payload with no balance key drew a balance")

        // And the positive case, so a card that drew nothing at all could not pass.
        let fed = try card("dialog-fable-overage", at: 0)
        let balance = try XCTUnwrap(fed.overageConsent?.balanceCents, "the recorded enabled arm carries no balance")
        let line = try XCTUnwrap(DialogCardView.balanceText(try XCTUnwrap(fed.overageConsent,
                                                                          "the overage payload no longer decodes")),
                                 "a fed balance drew no line")
        XCTAssertTrue(line.hasPrefix("Balance:"), "a fed balance is not drawn as a balance")
        XCTAssertTrue(balance == 0, "the recorded enabled arm's balance is not the one this clause was written against")
    }

    // MARK: - The kind afleet never declared

    /// §6.3, and D12's third row. A `dialog_kind` afleet did not declare is the binary's to settle:
    /// the policy leaves it unanswered, the reducer opens it `.inert`, the card reads *left to the
    /// binary*, and no action of any kind produces an answer for it.
    ///
    /// **This is a trace assertion.** The dangerous path — answering a dialog afleet never declared —
    /// cannot be executed to prove it wrong, so what is asserted is that it was never entered:
    /// every dialog action is offered to the answering object and `perform` is reached zero times.
    func testAnUndeclaredDialogKindIsNeverAnswered() async throws {
        let (lifecycle, answering) = await hosted()
        let requests = try dialogRequests("dialog-refusal-fallback")
        let undeclared = try XCTUnwrap(requests.first { request in
            guard case .requestUserDialog(let dialog) = request.payload else { return false }
            return DecisionCard.DialogKind(rawValue: dialog.fields.dialogKind) == nil
        }, "the fixture records no undeclared dialog kind")

        var reducer = WireReducer(stream: Self.stream, slug: "invented-slug")
        _ = reducer.apply(.unansweredDialog(undeclared))
        let item = try XCTUnwrap(reducer.overlay.decisions[undeclared.id], "the reducer opened no item for it")
        let opaque = DecisionCard(item)
        XCTAssertTrue(opaque.dialogKind == nil, "an undeclared kind decoded as one afleet declares")
        XCTAssertTrue(opaque.state == .inert, "an unanswered dialog did not open inert")
        XCTAssertTrue(opaque.reading(inStaleOverlay: false)?.text
                          == "Left to the binary: afleet does not handle this kind.",
                      "an undeclared dialog does not read as left to the binary")

        let every: [DecisionAction] = [.retryOnFallbackModel, .editPrompt, .keepTheRefusal,
                                       .useUsageCredits, .switchToDefaultModel, .notNow,
                                       .setUpUsageCredits, .closeDialog]
        for action in every {
            XCTAssertTrue(opaque.answer(action) == nil,
                          "the mapping produced an answer for an undeclared dialog kind")
            answering.send(action, on: opaque, in: Self.channel)
        }
        await answering.whenIdle()
        let count = await lifecycle.actions.count
        XCTAssertEqual(count, 0, "\(every.count) actions on an undeclared dialog reached perform \(count) times")

        // And the binary's own cancellation, which is how this dialog ends: still nothing.
        _ = reducer.apply(.requestCancelled(undeclared.id, .first))
        let after = await lifecycle.actions.count
        XCTAssertEqual(after, 0, "the cancellation of an undeclared dialog put \(after) actions on the wire")
    }

    /// Item 62's fallback frame is part of the **card's own state**, and reaches the timeline row
    /// without any host passing it in.
    ///
    /// The whole recording is replayed through C3's fold — every frame and every declared dialog
    /// request, with the host's own `decisionAnswered` raised for each overage ask as it arrives,
    /// which is what a card's successful answer does in production. The recording answers five
    /// overage dialogs and emits four `model_consent_fallback` frames, each after the ask it
    /// concerns, so the reading is discriminating in both directions: the first ask, which no frame
    /// followed, must read its own outcome, and each of the other four must read the frame that
    /// followed **it** rather than the newest one.
    ///
    /// Drawn through `DecisionRowContent`, which is the timeline's host path, with no
    /// `consentFallback` handed to any view.
    func testTheConsentFallbackReachesTheTimelineRowsCardWithoutBeingHandedIn() async throws {
        var reducer = WireReducer(stream: Self.stream, slug: "invented-slug")
        var answered: [RequestID] = []
        for event in try FixtureRunner.events("dialog-fable-overage") {
            _ = reducer.apply(event)
            guard case .request(let request) = event,
                  case .requestUserDialog(let dialog) = request.payload,
                  DecisionCard.DialogKind(rawValue: dialog.fields.dialogKind) == .overageConsent else { continue }
            _ = reducer.apply(.decisionAnswered(request.id, outcome: .answered(summary: "consent")))
            answered.append(request.id)
        }
        XCTAssertEqual(answered.count, 5, "the recording answered \(answered.count) overage dialogs, not 5")

        let frames = Self.consentFallbacks(try FixtureRunner.frames("dialog-fable-overage"))
        XCTAssertEqual(frames.count, 4, "the recording carries \(frames.count) consent-fallback frames, not 4")

        let (_, answering) = await hosted()
        let context = InventedItems.context(key: Self.channel)

        // The first ask: no frame followed it, so the settled card reads its own outcome and the
        // newest frame in the recording must not have leaked onto it.
        let first = try XCTUnwrap(reducer.overlay.decisions[answered[0]], "the fold dropped the first overage ask")
        let firstDrawn = try Self.rowCardTexts(first, context, answering)
        XCTAssertTrue(firstDrawn.contains("consent"),
                      "the card no frame followed does not read its own outcome")
        XCTAssertFalse(frames.contains { frame in firstDrawn.contains(frame.fields.content) },
                       "a consent-fallback frame reached the card that no frame followed")

        // The four the frames followed, each against the frame that followed *it*.
        for (offset, frame) in frames.enumerated() {
            let item = try XCTUnwrap(reducer.overlay.decisions[answered[offset + 1]],
                                     "the fold dropped an answered overage ask")
            let drawn = try Self.rowCardTexts(item, context, answering)
            XCTAssertTrue(drawn.contains(frame.fields.content),
                          "the row's card does not read the frame that followed ask \(offset + 1)")
        }
    }

    /// The correlation does not depend on the host's answer signal arriving before the engine's
    /// frame.
    ///
    /// The signal and the engine's frames reach the fold by two independent asynchronous paths —
    /// `DecisionAnswering` raises `decisionAnswered` once `perform` has returned, while the frame
    /// comes up the wire — so neither side can promise the order. This arm is the far end of that:
    /// the **whole recording is folded first**, every frame included, and only then is each overage
    /// ask answered. A fold that remembered "the ask answered most recently" has nothing recorded
    /// when any frame lands and loses all four; a fold that records the ask the engine *raised* is
    /// unaffected, because that ordering is the engine's own.
    func testTheConsentFallbackSurvivesTheAnswerSignalArrivingAfterTheFrame() async throws {
        var reducer = WireReducer(stream: Self.stream, slug: "invented-slug")
        var asks: [RequestID] = []
        for event in try FixtureRunner.events("dialog-fable-overage") {
            _ = reducer.apply(event)
            guard case .request(let request) = event,
                  case .requestUserDialog(let dialog) = request.payload,
                  DecisionCard.DialogKind(rawValue: dialog.fields.dialogKind) == .overageConsent else { continue }
            asks.append(request.id)
        }
        XCTAssertEqual(asks.count, 5, "the recording raised \(asks.count) overage dialogs, not 5")

        // Every answer after every frame, which is the order this clause exists for.
        for id in asks {
            _ = reducer.apply(.decisionAnswered(id, outcome: .answered(summary: "consent")))
        }

        let frames = Self.consentFallbacks(try FixtureRunner.frames("dialog-fable-overage"))
        XCTAssertEqual(frames.count, 4, "the recording carries \(frames.count) consent-fallback frames, not 4")

        let (_, answering) = await hosted()
        let context = InventedItems.context(key: Self.channel)
        for (offset, frame) in frames.enumerated() {
            let item = try XCTUnwrap(reducer.overlay.decisions[asks[offset + 1]],
                                     "the fold dropped an answered overage ask")
            let drawn = try Self.rowCardTexts(item, context, answering)
            XCTAssertTrue(drawn.contains(frame.fields.content),
                          "ask \(offset + 1)'s card lost its frame when the answer signal arrived late")
        }
    }

    /// What the timeline's own decision row draws for an item: the row mount's body, the card
    /// component it hosts, and that component's body. The descent is spelled out because reflection
    /// does not evaluate a stored view's `body` — a test that read the row's body alone would find
    /// no text at all and pass whatever the card says.
    private static func rowCardTexts(_ item: DecisionItem,
                                     _ context: TimelineRenderContext,
                                     _ answering: DecisionAnswering) throws -> [String] {
        let row = DecisionRowContent(row: TimelineRow(.decision(item)), context: context, answering: answering)
        let card = try XCTUnwrap(ViewTree.values(of: DecisionCardView.self, in: row.body).first,
                                 "the decision row hosted no card component")
        return CardTree.texts(in: card.body)
    }

    /// Every `model_consent_fallback` a fixture's frames carry.
    private static func consentFallbacks(_ frames: [Frame]) -> [ModelConsentFallback] {
        frames.compactMap { frame in
            guard case .system(.modelConsentFallback(let fallback)) = frame else { return nil }
            return fallback
        }
    }
}
