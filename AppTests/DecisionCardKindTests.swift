import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The four card kinds §8.4 names beside the permission card: question, plan, elicitation and task
/// (acceptance G1b through G1e).
///
/// **Every answer clause asserts the value that left the host**, never that a card changed — a card
/// changes for many reasons and only one of them is the right answer having been sent. The three
/// answering cards are asserted on the `InboundAnswer` the double received; the task card is
/// asserted on the `AnyControlRequest`, because its two actions are control requests and not
/// answers at all (spec D15).
///
/// **What is invented and what is recorded.** The question card runs on `Fixtures/ask-user-question`
/// and the plan card on `Fixtures/exit-plan-mode`, both recorded. **No fixture carries an
/// elicitation of either mode, and none carries the extended question variant**, so those requests
/// are built here with invented identifiers (§11) and the tests say so rather than implying a
/// recording exists. The task card's foreground arm is the recorded shape with `is_backgrounded`
/// flipped, because the one recorded run is already in the background and that flag is the clause
/// under test.
///
/// Failure messages carry counts and action names. A fixture's input holds a path and a
/// `ChannelKey` holds a config home, and `XCTAssertEqual` prints both operands (§6.3, §11), so every
/// comparison over one of those is spelled as a boolean with a written message.
@MainActor
final class DecisionCardKindTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("b", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-kinds-unwritten"))
    }

    private func ask(_ fixture: String, id: String, overrides: [String: Any] = [:]) throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id, overrides: overrides)
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel),
                                 "the surfacing initialiser opened no item for a recorded ask")
        return DecisionCard(item)
    }

    /// An `elicitation` this corpus does not carry, with invented identifiers throughout.
    private func elicitationCard(id: String, _ request: [String: Any]) throws -> DecisionCard {
        var object = request
        object["subtype"] = "elicitation"
        let frame: [String: Any] = ["type": "control_request", "request_id": id, "request": object]
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard case .controlRequest(let control) = FrameDecoder.decode(line: data) else {
            throw XCTSkip("an invented control_request did not decode as one")
        }
        let parsed = InboundRequest.parse(frame: control, epoch: .first, receivedAt: .now)
        let item = try XCTUnwrap(DecisionItem(surfacing: parsed, in: Self.channel),
                                 "the surfacing initialiser opened no item for an invented elicitation")
        return DecisionCard(item)
    }

    private func hosted() async -> (LifecycleDouble, DecisionAnswering) {
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        return (lifecycle, DecisionAnswering(lifecycle: lifecycle))
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
        guard case .success(let success) = answer.controlResponse(for: RequestID(rawValue: "bbbb-1")).body,
              let response = success.response else {
            XCTFail("the answer for \(label) did not encode as a success body")
            return .null
        }
        return response
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The `updatedInput` of the answer a fixture *recorded*, so G1b compares against the recording
    /// rather than against a restatement of it.
    private func recordedUpdatedInput(_ fixture: String) throws -> JSONValue {
        let url = FixtureRunner.directory(fixture).appending(path: "frames.ndjson")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["dir"] as? String == "in",
                  let frame = object["frame"] as? [String: Any],
                  let response = frame["response"] as? [String: Any],
                  let body = response["response"] as? [String: Any],
                  let input = body["updatedInput"] else { continue }
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: input))
        }
        throw XCTSkip("the fixture records no answer carrying updatedInput")
    }

    // MARK: - G1b, the question card

    /// Each option's `label`, `description` and **singular** `preview`, side by side.
    ///
    /// Discriminating both ways: the recorded ask carries `preview`, so a card reading `previews`
    /// renders no preview at all and the first half fails; and an ask carrying `previews` must
    /// render none, so a card reading both keys fails the second.
    func testEachOptionRendersItsLabelDescriptionAndSingularPreview() async throws {
        let (_, answering) = await hosted()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
        let view = try questionView(card, answering)
        let prompt = try XCTUnwrap(view.questions.first, "the recorded ask carries no question")
        XCTAssertEqual(prompt.options.count, 2, "the recorded ask carries \(prompt.options.count) options")

        for option in prompt.options {
            let texts = CardTree.texts(in: view.option(option, of: prompt))
            XCTAssertTrue(texts.contains(option.label), "an option's label is not drawn")
            let description = try XCTUnwrap(option.description, "a recorded option carries no description")
            XCTAssertTrue(texts.contains(description), "an option's description is not drawn beside it")
            let preview = try XCTUnwrap(option.preview, "a recorded option carries no singular preview")
            XCTAssertTrue(texts.contains(preview), "an option's preview is not drawn beside it")
        }

        // The plural spelling is not the field. An invented ask, because no recording carries one.
        let plural = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2", overrides: [
            "input": ["questions": [["question": "An invented question?", "header": "Invented",
                                     "multiSelect": false,
                                     "options": [["label": "First", "previews": ["an invented preview"]],
                                                 ["label": "Second"]]]]]
        ])
        let pluralView = try questionView(plural, answering)
        let pluralPrompt = try XCTUnwrap(pluralView.questions.first, "the invented ask carries no question")
        XCTAssertNil(pluralPrompt.options.first?.preview, "a `previews` key was read as the preview field")
    }

    /// Anchor 9: the answer echoes the whole input with `answers` keyed by raw question text, and
    /// carries **no** `annotations` key when the card produced none — which is the shape the fixture
    /// itself recorded.
    func testTheQuestionAnswerEchoesTheRecordedInputAndOmitsAnnotations() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3")
        let draft = QuestionCardView.Draft()
        let view = try questionView(card, answering, draft: draft)
        let prompt = try XCTUnwrap(view.questions.first, "the recorded ask carries no question")
        let chosen = try XCTUnwrap(prompt.options.first, "the recorded ask carries no option")

        try press(chosen.label, in: view.option(chosen, of: prompt))
        try press("Send", in: view.body)
        await answering.whenIdle()

        let body = try await sentBody(lifecycle, "Send")
        let recorded = try recordedUpdatedInput("ask-user-question")
        XCTAssertTrue(body["updatedInput"] == recorded,
                      "the answer's updatedInput is not the input the fixture recorded")
        XCTAssertNil(recorded["annotations"], "the fixture's recorded answer now carries annotations")
        XCTAssertNil(body["updatedInput"]?["annotations"],
                     "the card wrote an annotations key it produced no annotation for")
        XCTAssertTrue(body["decisionClassification"] == .string("user_temporary"),
                      "the question answer carries no user_temporary classification (spec D16)")
    }

    /// A multi-select answer is one string joined with `", "` — the engine's own coercion — and a
    /// note becomes an `annotations` entry keyed the same way. Both directions, so a card that
    /// always wrote `annotations` fails the previous test and a card that never writes one fails
    /// this.
    func testAMultiSelectAnswerIsJoinedAndANoteBecomesAnAnnotation() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4", overrides: [
            "input": ["questions": [["question": "Which invented options?", "header": "Invented",
                                     "multiSelect": true,
                                     "options": [["label": "First"], ["label": "Second"]]]]]
        ])
        let draft = QuestionCardView.Draft()
        draft.notes["Which invented options?"] = "an invented note"
        let view = try questionView(card, answering, draft: draft)
        let prompt = try XCTUnwrap(view.questions.first, "the invented ask carries no question")
        for option in prompt.options {
            try press(option.label, in: view.option(option, of: prompt))
        }
        try press("Send", in: view.body)
        await answering.whenIdle()

        let body = try await sentBody(lifecycle, "Send")
        XCTAssertTrue(body["updatedInput"]?["answers"] == .object(["Which invented options?": .string("First, Second")]),
                      "a multi-select answer is not the engine's comma-and-space join")
        XCTAssertTrue(body["updatedInput"]?["annotations"]
                        == .object(["Which invented options?": .object(["notes": .string("an invented note")])]),
                      "a typed note did not become an annotations entry keyed by question text")
    }

    /// The extended variant (`cli.pretty.js:758385–758461`), which **no fixture carries** — the ask
    /// below is invented. A `text` kind renders a field, a `number` kind renders its bounds and unit,
    /// and an unrecognised kind renders a text field rather than nothing at all.
    func testAnExtendedQuestionKindRendersItsControlAndAnUnknownKindRendersText() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb5", overrides: [
            "input": ["questions": [["question": "An invented text question?", "header": "Text",
                                     "kind": "text", "placeholder": "an invented placeholder",
                                     "options": []],
                                    ["question": "An invented number question?", "header": "Number",
                                     "kind": "number", "min": 1, "max": 9, "step": 2, "unit": "widgets",
                                     "defaultValue": 3, "options": []],
                                    ["question": "An invented future question?", "header": "Future",
                                     "kind": "an_invented_kind", "options": []]]]
        ])
        let draft = QuestionCardView.Draft()
        let view = try questionView(card, answering, draft: draft)
        XCTAssertEqual(view.questions.count, 3, "the invented ask carries \(view.questions.count) questions")

        let text = view.questions[0], number = view.questions[1], future = view.questions[2]
        XCTAssertEqual(text.kind, .text, "an extended text question was not read as one")
        XCTAssertEqual(number.kind, .number, "an extended number question was not read as one")
        XCTAssertEqual(future.kind, .unrecognised("an_invented_kind"),
                       "an unrecognised kind was not carried as one")
        for prompt in view.questions {
            XCTAssertFalse(prompt.isChoice, "an extended question was rendered as a choice")
            XCTAssertFalse(ViewTree.values(of: TextField<Text>.self, in: view.question(prompt)).isEmpty,
                           "an extended question drew no field to answer it with")
        }
        XCTAssertEqual(QuestionCardView.rangeLabel(number), "min 1, max 9, step 2",
                       "a number question's bounds are not drawn")
        XCTAssertEqual(QuestionCardView.initialText(number), "3", "a defaultValue is not the field's start")

        // The unrecognised kind still answers, which is the point of falling back to a text field.
        draft.typed["An invented future question?"] = "an invented answer"
        try press("Send", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Send")
        XCTAssertTrue(body["updatedInput"]?["answers"]?["An invented future question?"] == .string("an invented answer"),
                      "an unrecognised question kind could not be answered")
        XCTAssertTrue(body["updatedInput"]?["answers"]?["An invented number question?"] == .string("3"),
                      "a number question's default was not carried as its answer")
    }

    private func questionView(_ card: DecisionCard, _ answering: DecisionAnswering,
                              draft: QuestionCardView.Draft = QuestionCardView.Draft()) throws -> QuestionCardView {
        guard case .question(let tool) = card.payload else {
            throw XCTSkip("the ask is no longer a question card")
        }
        return QuestionCardView(card: card, tool: tool, presentation: .full,
                                channel: Self.channel, answering: answering, draft: draft)
    }

    // MARK: - G1c, the plan card

    /// The three actions, each asserted as the body that left the host. Anchor 8 for the update, and
    /// spec D16 for the classification Task 1 shipped without: both approvals are `user_temporary`
    /// and the rejection is `user_reject`.
    func testThePlanCardsThreeActionsEmitTheirAnswers() async throws {
        let expected: [(label: String, body: String)] = [
            ("Approve", """
             {"behavior":"allow","decisionClassification":"user_temporary",
              "updatedInput":{"plan":"an invented plan"},
              "updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}
             """),
            ("Approve and auto-accept edits", """
             {"behavior":"allow","decisionClassification":"user_temporary",
              "updatedInput":{"plan":"an invented plan"},
              "updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
             """),
            ("Reject with feedback", """
             {"behavior":"deny","message":"The user rejected this plan.","interrupt":false,
              "decisionClassification":"user_reject"}
             """)
        ]
        for (index, arm) in expected.enumerated() {
            let (lifecycle, answering) = await hosted()
            let card = try ask("exit-plan-mode", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbc\(index)",
                                overrides: ["input": ["plan": "an invented plan"]])
            let view = try planView(card, answering)
            try press(arm.label, in: view.body)
            await answering.whenIdle()
            let body = try await sentBody(lifecycle, arm.label)
            XCTAssertTrue(body == (try json(arm.body)), "the body for \(arm.label) is not the one §8.4 states")
        }
    }

    /// The rejection carries what the user typed, and the standing sentence when they typed nothing.
    /// The discriminating half is the first: a card that sent the constant either way would pass the
    /// second alone.
    func testThePlanRejectionCarriesTheTypedFeedback() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try ask("exit-plan-mode", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbc9",
                            overrides: ["input": ["plan": "an invented plan"]])
        let draft = PlanCardView.Draft()
        draft.feedback = "an invented objection"
        let view = try planView(card, answering, draft: draft)
        XCTAssertEqual(view.rejectionMessage, "an invented objection", "the typed feedback is not the message")
        try press("Reject with feedback", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Reject with feedback")
        XCTAssertTrue(body["message"] == .string("an invented objection"),
                      "the rejection did not carry the typed feedback")

        let (_, second) = await hosted()
        let empty = try planView(card, second)
        XCTAssertEqual(empty.rejectionMessage, PlanCardView.unstatedRejection,
                       "an unstated rejection is not the standing sentence")
    }

    private func planView(_ card: DecisionCard, _ answering: DecisionAnswering,
                          draft: PlanCardView.Draft = PlanCardView.Draft()) throws -> PlanCardView {
        guard case .plan(let tool) = card.payload else { throw XCTSkip("the ask is no longer a plan card") }
        return PlanCardView(card: card, tool: tool, presentation: .full,
                            channel: Self.channel, answering: answering, draft: draft)
    }

    // MARK: - G1d, the elicitation card, both modes

    /// Form mode over the stated subset (spec D8): a required string, an enum, an integer, a boolean
    /// and an array of strings, and `content` as a **sibling of `action`** (anchor 10). The request
    /// is invented — **no fixture carries an elicitation**.
    func testFormModeRendersTheSubsetAndAcceptsContentBesideAction() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try elicitationCard(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd1", [
            "mcp_server_name": "invented-server",
            "message": "An invented server asks for five invented values.",
            "requested_schema": ["type": "object",
                                 "required": ["name"],
                                 "properties": [
                                    "name": ["type": "string", "title": "A name", "default": "an invented name"],
                                    "colour": ["type": "string", "enum": ["red", "blue"], "default": "blue"],
                                    "count": ["type": "integer", "default": 2],
                                    "loud": ["type": "boolean", "default": true],
                                    "tags": ["type": "array", "items": ["type": "string", "enum": ["one", "two"]],
                                             "default": ["one"]]]]
        ])
        let view = try elicitationView(card, answering)
        let form = try XCTUnwrap(view.form, "the invented form-mode request produced no form")
        XCTAssertEqual(form.fields.count, 5, "the subset drew \(form.fields.count) controls for five properties")
        XCTAssertFalse(form.isPartial, "a schema inside the subset was reported as partial")
        XCTAssertTrue(form.fields.contains { $0.name == "name" && $0.isRequired },
                      "the required property was not marked required")

        try press("Accept", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Accept")
        XCTAssertTrue(body == (try json("""
            {"action":"accept","content":{"name":"an invented name","colour":"blue","count":2,
                                          "loud":true,"tags":["one"]}}
            """)),
                      "the accept body is not `content` beside `action` over the five values")
    }

    /// Url mode (spec D8): no form at all, the address rendered, and `decline`/`cancel` still
    /// available. The discriminating clause — a form-only implementation renders an empty card and
    /// drops the URL, and would pass no part of this.
    func testUrlModeRendersNoFormAndStillDeclinesAndCancels() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try elicitationCard(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd2", [
            "mcp_server_name": "invented-server",
            "message": "An invented server asks you to finish this in a browser.",
            "mode": "url",
            "url": "https://invented.example/finish",
            "elicitation_id": "elic-bbbb-1"
        ])
        let view = try elicitationView(card, answering)
        XCTAssertTrue(view.isURLMode, "a url-mode request was not read as one")
        XCTAssertNil(view.form, "url mode drew a form")
        XCTAssertFalse(offers("Accept", in: view.body), "url mode offered an accept with nothing to accept")
        XCTAssertTrue(CardTree.texts(in: view.body).contains("https://invented.example/finish"),
                      "url mode did not render the address it was given")

        try press("Decline", in: view.body)
        await answering.whenIdle()
        let declined = try await sentBody(lifecycle, "Decline")
        XCTAssertTrue(declined == (try json(#"{"action":"decline"}"#)),
                      "url mode's decline is not the engine's decline")

        let (second, secondAnswering) = await hosted()
        let cancelView = try elicitationView(card, secondAnswering)
        try press("Cancel", in: cancelView.body)
        await secondAnswering.whenIdle()
        let cancelled = try await sentBody(second, "Cancel")
        XCTAssertTrue(cancelled == (try json(#"{"action":"cancel"}"#)),
                      "url mode's cancel is not the engine's cancel")
    }

    /// A schema outside the subset — a nested object and an array of numbers — renders as raw JSON
    /// fields, says the form is partial, and **still answers** (§6.4). The request is invented.
    func testASchemaOutsideTheSubsetRendersRawAndStillAnswers() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try elicitationCard(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd3", [
            "mcp_server_name": "invented-server",
            "message": "An invented server asks for a shape afleet does not draw.",
            "requested_schema": ["type": "object",
                                 "properties": [
                                    "nested": ["type": "object", "properties": ["inner": ["type": "string"]]],
                                    "sizes": ["type": "array", "items": ["type": "number"]]]]
        ])
        let draft = ElicitationCardView.Draft()
        let view = try elicitationView(card, answering, draft: draft)
        let form = try XCTUnwrap(view.form, "the invented request produced no form")
        XCTAssertTrue(form.isPartial, "a schema outside the subset was not reported as partial")
        for field in form.fields {
            guard case .raw = field.control else {
                return XCTFail("a property outside the subset was drawn as a typed control")
            }
            XCTAssertFalse(ViewTree.values(of: TextField<Text>.self, in: view.control(field)).isEmpty,
                           "a raw property drew no field to answer it with")
        }

        draft.values["nested"] = try json(#"{"inner":"an invented value"}"#)
        draft.values["sizes"] = try json("[1,2]")
        try press("Accept", in: view.body)
        await answering.whenIdle()
        let accepted = try await sentBody(lifecycle, "Accept")
        XCTAssertTrue(accepted
                        == (try json(#"{"action":"accept","content":{"nested":{"inner":"an invented value"},"sizes":[1,2]}}"#)),
                      "a form outside the subset could not be answered")
    }

    private func elicitationView(_ card: DecisionCard, _ answering: DecisionAnswering,
                                 draft: ElicitationCardView.Draft = ElicitationCardView.Draft()) throws -> ElicitationCardView {
        guard case .elicitation(let request) = card.payload else {
            throw XCTSkip("the invented request is no longer an elicitation card")
        }
        return ElicitationCardView(card: card, request: request, presentation: .full,
                                   channel: Self.channel, answering: answering, draft: draft)
    }
}
