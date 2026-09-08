import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// What the two answering forms — the elicitation card's schema form and the question card's
/// options — send when the user does something other than fill every field in once and press.
///
/// The clauses here are the ones a happy-path gate cannot see: a value that cannot survive the
/// conversion the card performs on it, a field the user *emptied* rather than never touched, an
/// explicit `null`, a schema shape outside D8's subset arriving through a key the dispatch never
/// reads, an object with no properties at all, and a control whose displayed value is not the value
/// an answer would carry. **Every clause asserts either the value that would leave the host or the
/// value the card is showing**, and the two are asserted against each other wherever a card can
/// show one thing and send another.
///
/// **Nothing here is recorded.** No fixture carries an elicitation (D8), and the multi-question ask
/// is invented; identifiers are invented throughout (§11). Failure messages carry counts and
/// property names, never paths or environments (§6.3, §11).
@MainActor
final class DecisionFormAnswerTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("b", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-forms-unwritten"))
    }

    private func hosted() async -> (LifecycleDouble, DecisionAnswering) {
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        return (lifecycle, DecisionAnswering(lifecycle: lifecycle))
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the card offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

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

    private func elicitationView(_ card: DecisionCard, _ answering: DecisionAnswering,
                                 draft: ElicitationCardView.Draft = ElicitationCardView.Draft())
    throws -> ElicitationCardView {
        guard case .elicitation(let request) = card.payload else {
            throw XCTSkip("the invented request is no longer an elicitation card")
        }
        return ElicitationCardView(card: card, request: request, presentation: .full,
                                   channel: Self.channel, answering: answering, draft: draft)
    }

    /// A form-mode elicitation over the given properties, with `required` as named.
    private func formView(id: String, properties: [String: Any], required: [String] = [],
                          draft: ElicitationCardView.Draft = ElicitationCardView.Draft(),
                          answering: DecisionAnswering) throws -> ElicitationCardView {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        let card = try elicitationCard(id: id, [
            "mcp_server_name": "invented-server",
            "message": "An invented server asks for an invented shape.",
            "requested_schema": schema
        ])
        return try elicitationView(card, answering, draft: draft)
    }

    private func field(_ view: ElicitationCardView, _ name: String) throws -> ElicitationForm.Field {
        let form = try XCTUnwrap(view.form, "the invented request produced no form")
        return try XCTUnwrap(form.fields.first { $0.name == name },
                             "the form drew \(form.fields.count) fields and none of them is the one under test")
    }

    /// What a picker is drawing, as a value rather than as the empty string it holds for nothing.
    private func shown(_ view: ElicitationCardView, _ field: ElicitationForm.Field) -> String? {
        let value = view.selection(for: field).wrappedValue
        return value.isEmpty ? nil : value
    }

    private func ask(_ fixture: String, id: String, overrides: [String: Any] = [:]) throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id, overrides: overrides)
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel),
                                 "the surfacing initialiser opened no item for an ask")
        return DecisionCard(item)
    }

    private func questionView(_ card: DecisionCard, _ answering: DecisionAnswering,
                              draft: QuestionCardView.Draft) throws -> QuestionCardView {
        guard case .question(let tool) = card.payload else {
            throw XCTSkip("the ask is no longer a question card")
        }
        return QuestionCardView(card: card, tool: tool, presentation: .full,
                                channel: Self.channel, answering: answering, draft: draft)
    }

    // MARK: - The numeric conversion

    /// A number the card cannot carry as an `integer` is **refused**, not converted.
    ///
    /// `Int64(_: Double)` traps on a non-finite value and on one outside `Int64`'s range, and the
    /// card ran it on three inputs it does not choose: the text a user types, a schema's `default`,
    /// and the value a numeric control spells back. `1e20` and `nan` are legal JSON numbers and
    /// legal things to type, so each of those paths could end the process. Refusal is the field
    /// staying empty and the value staying out of `content` — which is also what the required-field
    /// clause below asserts, so a card that silently substituted a clamped number would fail too.
    func testANumberOutsideInt64OrNonFiniteIsRefusedRatherThanConverted() async throws {
        XCTAssertNil(ElicitationForm.numberValue("1e20", isInteger: true),
                     "an integer beyond Int64 was converted rather than refused")
        XCTAssertNil(ElicitationForm.numberValue("-1e20", isInteger: true),
                     "an integer below Int64 was converted rather than refused")
        XCTAssertNil(ElicitationForm.numberValue("nan", isInteger: false),
                     "a non-finite number was carried into an answer")
        XCTAssertNil(ElicitationForm.numberValue("inf", isInteger: true),
                     "an infinite number was carried into an answer")
        XCTAssertTrue(ElicitationForm.numberValue("-3", isInteger: true) == .integer(-3),
                      "a whole number in range is not read as an integer")
        XCTAssertTrue(ElicitationForm.numberValue("2.5", isInteger: false) == .number(2.5),
                      "a fractional number is not read as a number")
        XCTAssertNil(ElicitationForm.initialValue(.number(isInteger: true, default: 1e20)),
                     "a schema default beyond Int64 was converted rather than refused")

        // The three paths as the card runs them: a default it displays, a value it spells back, and
        // text the user types. None of the three may reach a trapping conversion.
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe1",
                                properties: ["count": ["type": "integer", "default": 1e20],
                                             "size": ["type": "number", "default": 1e20]],
                                required: ["count"], draft: draft, answering: answering)
        let count = try field(view, "count")
        XCTAssertEqual(view.number("count", isInteger: true, default: 1e20).wrappedValue, "",
                       "an out-of-range integer default was spelled into the field")
        XCTAssertNil(view.content["count"], "an out-of-range integer default reached the answer")
        XCTAssertFalse(view.canAccept, "a required field with no carryable value could be accepted")
        XCTAssertTrue(count.isRequired, "the invented schema no longer marks the property required")

        // A number control keeps a large finite value, because `number` has no Int64 to fall out of.
        XCTAssertTrue(view.content["size"] == .number(1e20),
                      "a large finite number outside the integer range was dropped from a number field")

        view.number("count", isInteger: true, default: nil).wrappedValue = "1e20"
        XCTAssertNil(view.content["count"], "typed text beyond Int64 was converted rather than refused")
        view.number("count", isInteger: true, default: nil).wrappedValue = "7"
        XCTAssertTrue(view.content["count"] == .integer(7), "a typed integer in range did not reach the answer")
    }

    // MARK: - Emptying a field

    /// A field the user **emptied** is not a field the user never touched.
    ///
    /// Both directions in one test, because they are the same distinction: an untouched field still
    /// carries the schema's `default` (the second half), and an emptied one does not carry it back
    /// (the first). A card that dropped defaults entirely would pass the first half and fail the
    /// second.
    func testAnEmptiedFieldDoesNotRestoreTheSchemasDefault() async throws {
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe2",
                                properties: [
                                    "name": ["type": "string", "default": "an invented name"],
                                    "tags": ["type": "array", "items": ["type": "string", "enum": ["one", "two"]],
                                             "default": ["one"]],
                                    "words": ["type": "array", "items": ["type": "string"],
                                              "default": ["an invented word"]],
                                    "kept": ["type": "string", "default": "an untouched default"]
                                ], draft: draft, answering: answering)

        view.text("name", default: "an invented name").wrappedValue = ""
        XCTAssertNil(view.content["name"], "an emptied text field restored the schema's default")
        XCTAssertEqual(view.text("name", default: "an invented name").wrappedValue, "",
                       "an emptied text field redrew the schema's default")

        // Deselecting the one default option is an explicit empty array, which `string[]` allows.
        view.pick("one", in: "tags", default: ["one"])
        XCTAssertTrue(view.content["tags"] == .array([]),
                      "deselecting the last default option restored the default rather than emptying the list")

        view.list("words", default: ["an invented word"]).wrappedValue = ""
        XCTAssertTrue(view.content["words"] == .array([]),
                      "clearing a defaulted list restored the default rather than emptying it")

        XCTAssertTrue(view.content["kept"] == .string("an untouched default"),
                      "an untouched field lost the schema's default")

        // Typing again is an answer again, not a permanent emptiness.
        view.text("name", default: "an invented name").wrappedValue = "a second invented name"
        XCTAssertTrue(view.content["name"] == .string("a second invented name"),
                      "a field emptied and then retyped did not carry the second value")
    }

    /// A raw field holding `null` is **answered**. `null` is a legal JSON value and the raw field
    /// exists so that a schema outside the subset can still be answered (§6.4); a required nullable
    /// property that cannot be answered is exactly the failure mode D8 forbids.
    func testAnExplicitNullInARawFieldIsAnAnswer() async throws {
        let (lifecycle, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe3",
                                properties: ["nested": ["type": "object",
                                                        "properties": ["inner": ["type": "string"]]]],
                                required: ["nested"], draft: draft, answering: answering)
        view.raw("nested").wrappedValue = "null"
        XCTAssertTrue(view.content["nested"] == .null, "an explicit null was filtered out of the answer")
        XCTAssertTrue(view.canAccept, "a required nullable property answered with null could not be accepted")

        try press("Accept", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Accept")
        XCTAssertTrue(body == (try json(#"{"action":"accept","content":{"nested":null}}"#)),
                      "the accept body did not carry the null the user typed")

        // An untouched raw field is still absent, which is what makes the null above an answer.
        let (_, second) = await hosted()
        let untouched = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe4",
                                     properties: ["nested": ["type": "object",
                                                             "properties": ["inner": ["type": "string"]]]],
                                     answering: second)
        XCTAssertTrue(untouched.content == .object([:]), "an untouched raw field reached the answer")
    }

    /// sweep#2: the third state applies to **numbers** too.
    ///
    /// A number control stored `nil` for anything it could not parse and touched nothing else, so
    /// the getter and `content` both fell back to the schema's `default`: a defaulted number could
    /// not be cleared, and the field redrew the value the user had just deleted. Both halves are
    /// asserted — what the control shows and what an accept would carry — because a card that
    /// cleared one and not the other is the failure this is about.
    func testAnEmptiedNumberDoesNotRestoreTheSchemasDefault() async throws {
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe8",
                                properties: ["count": ["type": "integer", "default": 3],
                                             "ratio": ["type": "number", "default": 1.5],
                                             "kept": ["type": "integer", "default": 9]],
                                draft: draft, answering: answering)

        XCTAssertTrue(view.content["count"] == .integer(3), "an untouched number lost the schema's default")

        view.number("count", isInteger: true, default: 3).wrappedValue = ""
        XCTAssertNil(view.content["count"], "an emptied number restored the schema's default")
        XCTAssertEqual(view.number("count", isInteger: true, default: 3).wrappedValue, "",
                       "an emptied number redrew the schema's default")

        // Text that is not a number is not a number, and not the default either.
        view.number("ratio", isInteger: false, default: 1.5).wrappedValue = "not a number"
        XCTAssertNil(view.content["ratio"], "unparseable text in a number field restored the schema's default")
        XCTAssertEqual(view.number("ratio", isInteger: false, default: 1.5).wrappedValue, "not a number",
                       "a number field threw away the text the user was typing")

        XCTAssertTrue(view.content["kept"] == .integer(9), "an untouched number lost the schema's default")

        // Typing again is an answer again, not a permanent emptiness.
        view.number("count", isInteger: true, default: 3).wrappedValue = "12"
        XCTAssertTrue(view.content["count"] == .integer(12),
                      "a number emptied and then retyped did not carry the second value")
    }

    /// sweep#3: an enum-array control has to say which of its options are chosen.
    ///
    /// The row was a plain `Button(option)`, which draws the same whether the option is in the
    /// answer or not: the user pressed and the card looked unchanged. The two halves are asserted
    /// as one — the state the control draws and the value an accept would carry — so neither a
    /// control that shows a selection it would not send nor one that sends a selection it does not
    /// show can pass.
    func testAnEnumArrayControlDrawsWhichOptionsAreSelected() async throws {
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe9",
                                properties: ["tags": ["type": "array",
                                                      "items": ["type": "string",
                                                                "enum": ["one", "two", "three"]],
                                                      "default": ["two"]]],
                                draft: draft, answering: answering)
        let tags = try field(view, "tags")

        // The row is a control with an on-state, and that state is the binding asserted below —
        // a `Button` label, which is what it was, carries neither.
        XCTAssertTrue(String(describing: type(of: view.option("one", in: tags))).contains("Toggle"),
                      "an enum-array option is drawn by a control that has no selected state")

        func drawn(_ option: String) -> Bool { view.optionSelection(option, in: tags).wrappedValue }

        XCTAssertTrue(drawn("two"), "the schema's defaulted option was not drawn as selected")
        XCTAssertFalse(drawn("one"), "an option nobody chose was drawn as selected")

        view.pick("one", in: "tags", default: ["two"])
        XCTAssertTrue(drawn("one"), "a chosen option was not drawn as selected")
        XCTAssertTrue(view.content["tags"] == .array([.string("two"), .string("one")]),
                      "the accept would not carry the options the control draws as selected")

        view.pick("two", in: "tags", default: ["two"])
        XCTAssertFalse(drawn("two"), "a deselected option was still drawn as selected")
    }

    /// scalpel-4#2: `default: []` is an answer and an absent `default` is not.
    ///
    /// Schema decoding collapsed the two into one empty array and `initialValue` then returned nil
    /// for both, so a server that asked for "none of these by default" got a property missing from
    /// `content` instead — and a required one could not be accepted at all without touching a
    /// control whose state was already correct.
    func testAnExplicitlyEmptyArrayDefaultIsAnAnswer() async throws {
        let (lifecycle, answering) = await hosted()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbea",
                                properties: [
                                    "chosen": ["type": "array", "items": ["type": "string", "enum": ["one"]],
                                               "default": []],
                                    "unset": ["type": "array", "items": ["type": "string", "enum": ["one"]]]
                                ], required: ["chosen"], answering: answering)

        XCTAssertTrue(view.content["chosen"] == .array([]),
                      "an explicitly empty array default did not reach the answer")
        XCTAssertNil(view.content["unset"], "a property with no default reached the answer anyway")
        XCTAssertTrue(view.canAccept, "a required property answered by its own empty default could not be accepted")

        try press("Accept", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Accept")
        XCTAssertTrue(body == (try json(#"{"action":"accept","content":{"chosen":[]}}"#)),
                      "the accept body did not carry the server's own empty-array default")
    }

    /// scalpel-4#3: text written as JSON that does not parse is a **mistake**, not a string.
    ///
    /// `{"a": 1` used to be carried to the server as the literal text `{"a": 1`, so a property
    /// asking for an object was answered with a string that looks like a half-typed one. Both sides
    /// of the discriminator are asserted here, because refusing everything that does not parse
    /// would break the raw field's whole purpose: a bare phrase is still a string.
    func testMalformedJSONBlocksAcceptAndABareStringDoesNot() async throws {
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbeb",
                                properties: ["nested": ["type": "object",
                                                        "properties": ["inner": ["type": "string"]]],
                                             "branchy": ["type": "string", "oneOf": [["const": "one"]]]],
                                draft: draft, answering: answering)

        view.raw("nested").wrappedValue = #"{"inner": 1"#
        XCTAssertNil(view.content["nested"], "an incomplete object was carried into the answer")
        XCTAssertFalse(view.canAccept, "a field written as JSON that does not parse could be accepted")
        XCTAssertEqual(view.raw("nested").wrappedValue, #"{"inner": 1"#,
                       "the card threw away the text the user was writing")
        XCTAssertTrue(CardTree.texts(in: view.control(try field(view, "nested")))
                        .contains(ElicitationCardView.malformedReading),
                      "the card refused the value without saying why")

        // A bare phrase is not JSON and is not a mistake: the raw field exists to answer schemas
        // outside the subset (§6.4), and most of them accept a string.
        view.raw("branchy").wrappedValue = "an invented phrase"
        XCTAssertTrue(view.content["branchy"] == .string("an invented phrase"),
                      "a bare phrase in a raw field was refused rather than carried as a string")

        // Completing the object clears the refusal.
        view.raw("nested").wrappedValue = #"{"inner": "an invented value"}"#
        XCTAssertTrue(view.content["nested"] == .object(["inner": .string("an invented value")]),
                      "a completed object did not reach the answer")
        XCTAssertTrue(view.canAccept, "a corrected field left the form unacceptable")
    }

    // MARK: - The subset's boundary

    /// D8's boundary is a property's **shape**, not its `type` keyword. A `oneOf` beside a
    /// `type: "string"` means the branches decide what the value may be, and a text field drawn from
    /// the `type` alone drops them silently and claims the form is whole.
    func testACompositionKeywordFallsBackToTheRawFieldWhateverTheTypeSays() async throws {
        let (_, answering) = await hosted()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe5",
                                properties: [
                                    "branchy": ["type": "string",
                                                "oneOf": [["const": "one"], ["const": "two"]]],
                                    "anyBranch": ["type": "integer", "anyOf": [["minimum": 1]]],
                                    "plain": ["type": "string"]
                                ], answering: answering)
        let form = try XCTUnwrap(view.form, "the invented request produced no form")
        for name in ["branchy", "anyBranch"] {
            let control = try field(view, name).control
            guard case .raw = control else {
                return XCTFail("a property carrying a composition keyword was drawn as a typed control")
            }
        }
        guard case .text = try field(view, "plain").control else {
            return XCTFail("a plain string stopped being a text field")
        }
        XCTAssertTrue(form.isPartial, "a form with a composition keyword was not reported as partial")
    }

    /// An object with **no properties** is a valid request whose valid answer is `{}`. The card
    /// refusing to accept it is §6.4's forbidden state: a request on screen with no way to answer it.
    func testAnObjectWithNoPropertiesStillAccepts() async throws {
        let (lifecycle, answering) = await hosted()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe6",
                                properties: [:], answering: answering)
        let form = try XCTUnwrap(view.form, "an object with no properties produced no form")
        XCTAssertEqual(form.fields.count, 0, "an empty object drew \(form.fields.count) fields")
        XCTAssertFalse(form.isPartial, "an empty object was reported as partial")
        XCTAssertTrue(view.canAccept, "a valid empty-object request could not be accepted")

        try press("Accept", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Accept")
        XCTAssertTrue(body == (try json(#"{"action":"accept","content":{}}"#)),
                      "the empty-object accept did not carry an empty content object")
    }

    // MARK: - What a picker shows against what it sends

    /// The picker shows what an accept would send, and nothing when an accept would send nothing.
    ///
    /// A picker with no `default` used to draw the first option while `content` omitted the
    /// property: the card said "blue" and the answer said nothing, and a required field stayed
    /// unacceptable with a visible answer in it. Both halves are asserted as the *same* equality, so
    /// neither a card that shows nothing and sends the first option nor one that shows the first
    /// option and sends nothing can pass.
    func testAPickerShowsExactlyWhatItWouldSend() async throws {
        let (_, answering) = await hosted()
        let draft = ElicitationCardView.Draft()
        let view = try formView(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbe7",
                                properties: [
                                    "colour": ["type": "string", "enum": ["red", "blue"]],
                                    "shade": ["type": "string", "enum": ["light", "dark"], "default": "dark"]
                                ], required: ["colour"], draft: draft, answering: answering)
        let colour = try field(view, "colour"), shade = try field(view, "shade")

        XCTAssertNil(shown(view, colour), "a picker with no default drew a selection")
        XCTAssertEqual(shown(view, colour), view.content["colour"]?.stringValue,
                       "the picker's shown selection is not the value the accept would carry")
        XCTAssertFalse(view.canAccept, "a required enum with nothing selected could be accepted")

        XCTAssertEqual(shown(view, shade), "dark", "a picker with a default drew no selection")
        XCTAssertEqual(shown(view, shade), view.content["shade"]?.stringValue,
                       "a defaulted picker's shown selection is not the value the accept would carry")

        view.text("colour", default: "").wrappedValue = "red"
        XCTAssertEqual(shown(view, colour), "red", "a picked option is not drawn as selected")
        XCTAssertEqual(shown(view, colour), view.content["colour"]?.stringValue,
                       "a picked option is not the value the accept would carry")
        XCTAssertTrue(view.canAccept, "a required enum with a selection could not be accepted")
    }

    // MARK: - The question card

    /// *Other* and the options are one answer, not two. A single-select question that submits both
    /// the label the user chose and the alternative they typed sends an answer the user never gave —
    /// and the engine joins the two with `", "`, so it reads as a deliberate pair.
    func testOtherIsExclusiveWithTheOptionsOfASingleSelectQuestion() async throws {
        let (_, answering) = await hosted()

        // Typed first, then an option pressed: the option is the answer.
        let draft = QuestionCardView.Draft()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbf1")
        let view = try questionView(card, answering, draft: draft)
        let prompt = try XCTUnwrap(view.questions.first, "the recorded ask carries no question")
        XCTAssertFalse(prompt.multiSelect, "the recorded ask is no longer single-select")
        let chosen = try XCTUnwrap(prompt.options.first, "the recorded ask carries no option")

        view.other(prompt).wrappedValue = "an invented alternative"
        try press(chosen.label, in: view.option(chosen, of: prompt))
        XCTAssertEqual(view.responses.first?.selections, [chosen.label],
                       "a single-select answer carried both the chosen option and the typed alternative")

        // The other order: an option pressed, then an alternative typed. The alternative is the answer.
        let second = QuestionCardView.Draft()
        let secondView = try questionView(card, answering, draft: second)
        try press(chosen.label, in: secondView.option(chosen, of: prompt))
        secondView.other(prompt).wrappedValue = "an invented alternative"
        XCTAssertEqual(secondView.responses.first?.selections, ["an invented alternative"],
                       "a typed alternative did not replace the option it was typed instead of")

        // A multi-select question is the case where both together *are* the answer.
        let multiCard = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbf2", overrides: [
            "input": ["questions": [["question": "Which invented options?", "header": "Invented",
                                     "multiSelect": true,
                                     "options": [["label": "First"], ["label": "Second"]]]]]
        ])
        let multiDraft = QuestionCardView.Draft()
        let multiView = try questionView(multiCard, answering, draft: multiDraft)
        let multiPrompt = try XCTUnwrap(multiView.questions.first, "the invented ask carries no question")
        let first = try XCTUnwrap(multiPrompt.options.first, "the invented ask carries no option")
        try press(first.label, in: multiView.option(first, of: multiPrompt))
        multiView.other(multiPrompt).wrappedValue = "an invented alternative"
        XCTAssertEqual(multiView.responses.first?.selections, ["First", "an invented alternative"],
                       "a multi-select answer lost either the chosen option or the typed alternative")
    }

    /// A note is something the user said. A question answered with a note and nothing else used to
    /// be dropped from the reply entirely, so its annotation never reached the engine — silently,
    /// because the *other* question's answer made the send look complete.
    func testANoteOnlyQuestionStillCarriesItsAnnotation() async throws {
        let (lifecycle, answering) = await hosted()
        let card = try ask("ask-user-question", id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbf3", overrides: [
            "input": ["questions": [["question": "Which invented option?", "header": "Invented",
                                     "multiSelect": false,
                                     "options": [["label": "First"], ["label": "Second"]]],
                                    ["question": "A second invented question?", "header": "Invented",
                                     "multiSelect": false,
                                     "options": [["label": "Third"], ["label": "Fourth"]]]]]
        ])
        let draft = QuestionCardView.Draft()
        draft.notes["A second invented question?"] = "an invented note"
        let view = try questionView(card, answering, draft: draft)
        XCTAssertEqual(view.questions.count, 2, "the invented ask carries \(view.questions.count) questions")
        let answered = view.questions[0]
        let option = try XCTUnwrap(answered.options.first, "the invented ask carries no option")
        try press(option.label, in: view.option(option, of: answered))

        XCTAssertEqual(view.responses.count, 2,
                       "the card built \(view.responses.count) responses for one answer and one note")

        try press("Send", in: view.body)
        await answering.whenIdle()
        let body = try await sentBody(lifecycle, "Send")
        XCTAssertTrue(body["updatedInput"]?["annotations"]?["A second invented question?"]
                        == .object(["notes": .string("an invented note")]),
                      "a note on an otherwise unanswered question did not reach the annotations")
        XCTAssertTrue(body["updatedInput"]?["answers"]?["Which invented option?"] == .string("First"),
                      "the answered question lost its answer")
    }
}
