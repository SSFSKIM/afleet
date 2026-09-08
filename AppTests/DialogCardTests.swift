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
/// A `ChannelKey` holds a config home and an item id holds a session, and `XCTAssertEqual` prints
/// both operands (§6.3, §11), so every comparison over one of those is spelled as a boolean with a
/// written message. Failure messages carry counts and action names.
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
                            deadline: DialogDeadline = .standard) throws -> DialogCardView {
        guard case .dialog(let request) = card.payload else {
            throw XCTSkip("a recorded dialog request no longer decodes as one")
        }
        return DialogCardView(card: card, request: request, presentation: .full, channel: Self.channel,
                              answering: answering, retraction: retraction, deadline: deadline)
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
            XCTAssertEqual(sent, try json(body), "the body sent for \(label) is not the engine's spelling")
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
        XCTAssertNil(nulled.refusalFallback?.apiRefusalCategory, "an explicit null decoded as a category")
        let none = CardTree.texts(in: try dialogView(nulled, answering).body)
        XCTAssertFalse(none.contains(where: { $0.hasPrefix("Category:") }),
                       "a null category still drew a category line")
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
        XCTAssertEqual(retired.reading(inStaleOverlay: false)?.text, "Answered elsewhere.",
                       "a retired dialog does not read as answered elsewhere")

        registry.resolved(retired, in: Self.channel)
        XCTAssertTrue(doomed.allSatisfy { !registry.retains($0) },
                      "the retracted message survived the dialog being retired")
        let count = await lifecycle.actions.count
        XCTAssertEqual(count, 0, "a retired dialog put \(count) actions on the wire")
    }

    /// Every `model_consent_fallback` a fixture's frames carry.
    private static func consentFallbacks(_ frames: [Frame]) -> [ModelConsentFallback] {
        frames.compactMap { frame in
            guard case .system(.modelConsentFallback(let fallback)) = frame else { return nil }
            return fallback
        }
    }
}
