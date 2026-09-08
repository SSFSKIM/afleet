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

    // MARK: - G1e, the task card

    /// Waits for a pressed button's control request to reach the double, then for the model to
    /// finish with it. A count, not a duration: the property is that the request arrived.
    private func settle(_ control: ControlDouble, _ model: TaskCardModel, expecting count: Int) async {
        var spins = 0
        while await control.sent.count < count, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        await model.whenIdle()
    }

    /// *Move to background* exists only for a running Bash call or agent run the registry mirror
    /// knows. A `Read` produces no task frame at all, so the mirror does not know it and the action
    /// is not offered — the clause a card that offered the action on every task would get wrong with
    /// no other symptom.
    func testOnlyARunningRegisteredBashCallOffersMoveToBackground() async throws {
        let control = ControlDouble()

        let running = model(taskID: "bbbbbbbb1", control: control,
                            registry: Self.mirror([Self.taskStarted(taskID: "bbbbbbbb1", type: "local_bash",
                                                                    backgrounded: false)]))
        XCTAssertTrue(running.offersMoveToBackground, "a running foreground Bash call offered no background action")
        XCTAssertTrue(running.offersStop, "a running task offered no stop")

        // A Read call: no task frame, so no entry. Same item, empty mirror.
        let read = model(taskID: "bbbbbbbb1", control: control, registry: RegistryMirror())
        XCTAssertFalse(read.offersMoveToBackground,
                       "a call the registry mirror does not know offered the background action")
        XCTAssertFalse(offers("Move to background", in: TaskCardView(model: read).body),
                       "a call the mirror does not know drew the background button")

        // An entry of a kind the engine cannot move, which is every plain tool call.
        let plain = model(taskID: "bbbbbbbb2", control: control,
                          registry: Self.mirror([Self.taskStarted(taskID: "bbbbbbbb2", type: "an_invented_type",
                                                                  backgrounded: false)]))
        XCTAssertFalse(plain.offersMoveToBackground, "a non-backgroundable task kind offered the background action")

        // A run already in the background has nowhere to move to.
        let already = model(taskID: "bbbbbbbb3", control: control,
                            registry: Self.mirror([Self.taskStarted(taskID: "bbbbbbbb3", type: "local_bash",
                                                                    backgrounded: true)]))
        XCTAssertFalse(already.offersMoveToBackground, "a backgrounded run offered to be backgrounded again")

        let sent = await control.sent
        XCTAssertEqual(sent.count, 0, "reading a card sent \(sent.count) control requests")
    }

    /// Item 61's **first** arm: `{backgrounded: false}` is a *success* body. The card refreshes, the
    /// action disappears, and **no banner is raised**.
    func testABackgroundedFalseBodyRefreshesTheCardWithNoBanner() async throws {
        let control = ControlDouble()
        await control.stage(.success(.object(["backgrounded": .bool(false)])))
        let model = model(taskID: "bbbbbbbb4", control: control,
                          registry: Self.mirror([Self.taskStarted(taskID: "bbbbbbbb4", type: "local_bash",
                                                                  backgrounded: false)]))
        let completed: TaskRunItem = {
            var item = model.item
            item.status = .completed
            return item
        }()
        model.refresh = { completed }

        try press("Move to background", in: TaskCardView(model: model).body)
        await settle(control, model, expecting: 1)

        let sent = await control.sent
        XCTAssertEqual(sent.count, 1, "one press sent \(sent.count) control requests")
        XCTAssertEqual(sent.first?.subtype, "background_tasks", "the press sent a different control request")
        XCTAssertTrue(sent.first?.payload == .object(["tool_use_id": .string("toolu_invented_bbbbbbbb4")]),
                      "background_tasks did not name the task's tool_use_id")
        XCTAssertNil(model.banner, "a {backgrounded: false} success body raised a banner")
        XCTAssertEqual(model.item.status, .completed, "the card did not refresh from the host")
        XCTAssertFalse(model.offersMoveToBackground, "the action stayed after the engine refused the move")
    }

    /// Item 61's **second** arm, and it arrives somewhere else entirely: the disabled sentence is a
    /// **control error**, not a success body (anchor 12). It raises the banner and hides the action.
    /// A test driving both arms off one path could not fail here.
    func testTheDisabledSentenceArrivesAsAControlErrorAndRaisesTheBanner() async throws {
        let control = ControlDouble()
        let sentence = "Background tasks are disabled in this session."
        await control.stage(.failure(WireError.controlError(sentence)))
        let model = model(taskID: "bbbbbbbb5", control: control,
                          registry: Self.mirror([Self.taskStarted(taskID: "bbbbbbbb5", type: "local_bash",
                                                                  backgrounded: false)]))
        let refreshes = RefreshCount()
        model.refresh = { refreshes.value += 1; return nil }

        try press("Move to background", in: TaskCardView(model: model).body)
        await settle(control, model, expecting: 1)

        XCTAssertEqual(model.banner?.text, sentence, "the engine's refusal did not become the card's banner")
        XCTAssertFalse(model.offersMoveToBackground, "the action stayed after the engine refused it")
        XCTAssertEqual(refreshes.value, 0, "a control error was read as a success body and refreshed the card")
        XCTAssertTrue(CardTree.texts(in: TaskCardView(model: model).body).contains(sentence),
                      "the banner is held but not drawn")
    }

    /// Per-task *Stop* sends `stop_task {task_id}`, whose success body is `{}` (anchor 11). Driven
    /// over `background-shell`'s own recorded task frames, whose card is a `TaskRunItem` and not a
    /// `DecisionItem` (spec D15).
    func testPerTaskStopSendsStopTaskAndTakesAnEmptyBody() async throws {
        let control = ControlDouble()
        await control.stage(.success(.object([:])))
        let frames = try FixtureRunner.frames("background-shell")
        var registry = RegistryMirror()
        var taskID: String?
        for frame in frames {
            guard case .system(let system) = frame else { continue }
            let touched = registry.apply(system, at: Date(), epoch: .first)
            taskID = taskID ?? touched.first
        }
        let recorded = try XCTUnwrap(taskID, "the recording carries no task frames")
        let entry = try XCTUnwrap(registry.entries[recorded], "the mirror folded no entry for the recorded task")
        XCTAssertEqual(entry.status, .completed, "the recorded run did not finish")

        let model = model(taskID: recorded, control: control, registry: registry, status: entry.status)
        XCTAssertFalse(model.offersStop, "a finished run still offered stop")
        XCTAssertNotNil(model.elapsedText(), "a folded entry rendered no elapsed time")

        await model.stop()
        let sent = await control.sent
        XCTAssertEqual(sent.count, 1, "one stop sent \(sent.count) control requests")
        XCTAssertEqual(sent.first?.subtype, "stop_task", "stop sent a different control request")
        XCTAssertTrue(sent.first?.payload == .object(["task_id": .string(recorded)]),
                      "stop_task did not name the task it stops")
        XCTAssertNil(model.banner, "an empty success body raised a banner")
    }

    // MARK: - The task card's fixtures

    /// A `task_started` with invented identifiers: the corpus records one run and it is already in
    /// the background, so the foreground arm is this shape with that one flag flipped.
    private static func taskStarted(taskID: String, type: String, backgrounded: Bool) -> SystemFrame {
        let object: [String: Any] = ["type": "system", "subtype": "task_started",
                                     "task_id": taskID, "tool_use_id": "toolu_invented_\(taskID)",
                                     "description": "An invented task", "is_backgrounded": backgrounded,
                                     "task_type": type,
                                     "uuid": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe1",
                                     "session_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe2"]
        let data = try! JSONSerialization.data(withJSONObject: object)
        guard case .system(let system) = FrameDecoder.decode(line: data) else {
            preconditionFailure("an invented task_started did not decode as a system frame")
        }
        return system
    }

    private static func mirror(_ frames: [SystemFrame]) -> RegistryMirror {
        var mirror = RegistryMirror()
        for frame in frames { mirror.apply(frame, at: Date(), epoch: .first) }
        return mirror
    }

    private func model(taskID: String, control: ControlDouble, registry: RegistryMirror,
                       status: TaskStatus = .running) -> TaskCardModel {
        let stream = LogicalStream(configHome: Self.channel.configHome, sessionID: Self.channel.session, name: .main)
        let item = TaskRunItem(id: ItemID(stream: stream, key: taskID),
                               timestamp: Date(),
                               provenance: Provenance(stream: stream, epoch: .first, origin: .synthesised),
                               taskID: taskID, kind: .localBash, description: "An invented task",
                               status: status, toolUseID: "toolu_invented_\(taskID)")
        return TaskCardModel(item: item, registry: registry, lifecycle: control, channel: Self.channel)
    }
}

/// How many times the host was asked to re-read the item. A reference, because a `@MainActor`
/// closure cannot capture a mutable local.
@MainActor
final class RefreshCount {
    var value = 0
}

/// A `LifecycleAPI` that answers **control requests** and records them.
///
/// `LifecycleDouble` traps on `send(_:on:)` on purpose — every surface before this one answered
/// through `perform`. The task card is the first thing in this child whose actions are control
/// requests, and the two arms of item 61 are a *success body* and a *control error*, so the double
/// has to be able to produce each on its own path. Every other member traps, for the same reason
/// `LifecycleDouble`'s do.
actor ControlDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let updatesContinuation: AsyncStream<ChannelState>.Continuation
    private nonisolated let jobsContinuation: AsyncStream<[JobEntry]>.Continuation

    private(set) var sent: [AnyControlRequest] = []
    private var replies: [Result<JSONValue, WireError>] = []

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// What the next `send` answers. A queue, so a test stages an error and a success in order.
    func stage(_ reply: Result<JSONValue, WireError>) { replies.append(reply) }

    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        sent.append(request)
        guard !replies.isEmpty else { return .object([:]) }
        return try replies.removeFirst().get()
    }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState { unreachable("perform") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func jobs() async -> [JobEntry] { [] }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ControlDouble.\(member) is not part of the task card's surface")
    }
}

/// The one piece of state `TaskCardModel` holds about a call in flight, as a probe: a test that has
/// pressed a button waits for the round trip rather than for a duration.
extension TaskCardModel {
    func whenIdle() async {
        while inFlight { await Task.yield() }
    }
}
