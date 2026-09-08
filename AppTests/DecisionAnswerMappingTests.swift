import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The answer mapping of §8.4, asserted as the body that goes on the wire.
///
/// Every clause asserts the `InboundAnswer` the mapping produced, never that a card changed: a card
/// changes for many reasons and only one of them is the right answer having been sent. The bodies
/// are compared through `InboundAnswer.controlResponse(for:)`, which is what the transport writes,
/// so `decisionClassification` and `interrupt` are inside the comparison rather than beside it.
///
/// Failure messages carry counts and action names only. A recorded fixture's input can hold a path,
/// and `XCTAssertEqual` would print it (§6.3, §11), so every comparison over a wire body is spelled
/// as a boolean with a written message.
final class DecisionAnswerMappingTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one: this suite only
    /// needs a `ChannelKey`'s value, and X9 forbids the app side writing under any config home.
    private static var channel: ChannelKey {
        ActivityFixtures.key("a", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-decisions-unwritten"))
    }

    /// A fixture's recorded request, re-keyed to an invented id, as the card the hosts render.
    private func card(_ fixture: String, subtype: String = "can_use_tool", id: String,
                      overrides: [String: Any] = [:]) throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: subtype, id: id, overrides: overrides)
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel),
                                 "the surfacing initialiser opened no item for a request the reducer opens one for")
        return DecisionCard(item)
    }

    /// The body the transport would write for an answer.
    private func body(_ answer: InboundAnswer?, _ label: String) throws -> JSONValue {
        let answer = try XCTUnwrap(answer, "the mapping produced no answer for \(label)")
        guard case .success(let success) = answer.controlResponse(for: RequestID(rawValue: "aaaa-1")).body,
              let response = success.response else {
            XCTFail("the answer for \(label) did not encode as a success body")
            return .null
        }
        return response
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func assertBody(_ answer: InboundAnswer?, is expected: String, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try body(answer, label)
        let wanted = try json(expected)
        XCTAssertTrue(actual == wanted, "the answer body for \(label) is not the one §8.4 states",
                      file: file, line: line)
    }

    // MARK: - Permission

    func testEveryPermissionActionMapsToItsAnswer() throws {
        let card = try card("permission-allow", id: "aaaa-permission-1")

        try assertBody(card.answer(.allowOnce),
                       is: #"{"behavior":"allow","decisionClassification":"user_temporary"}"#,
                       "allow once")

        try assertBody(card.answer(.alwaysAllow(destination: nil)),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_permanent",
                        "updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
                       """,
                       "always allow over a setMode suggestion")

        try assertBody(card.answer(.deny(message: "not this one")),
                       is: #"{"behavior":"deny","message":"not this one","interrupt":false,"decisionClassification":"user_reject"}"#,
                       "deny with text")

        // The clause a wrong mapping gets wrong silently, because the engine accepts either.
        guard case .permission(.allow(_, _, let allowClass))? = card.answer(.allowOnce),
              case .permission(.allow(_, _, let alwaysClass))? = card.answer(.alwaysAllow(destination: nil)),
              case .permission(.deny(_, let interrupt, let denyClass))? = card.answer(.deny(message: "x")) else {
            return XCTFail("a permission action did not map to a permission result")
        }
        XCTAssertEqual(allowClass, .userTemporary)
        XCTAssertEqual(alwaysClass, .userPermanent)
        XCTAssertEqual(denyClass, .userReject)
        XCTAssertFalse(interrupt, "a denial never interrupts the turn (spec D6)")
    }

    /// Spec D5. A `setMode` suggestion switches the session's permission mode and its destination is
    /// `session`; filing one into a settings file is not what the suggestion says. Only the rule- and
    /// directory-carrying variants take the picker's choice.
    func testAlwaysAllowSendsSetModeVerbatimAndRewritesOnlyRuleDestinations() throws {
        // The setMode-only card: an offer with no picker, and the suggestion goes back untouched.
        let mode = try card("permission-allow", id: "aaaa-permission-2")
        let modeOffer = try XCTUnwrap(mode.alwaysAllow, "a card with one setMode suggestion still offers always allow")
        XCTAssertTrue(modeOffer.destinations.isEmpty, "a setMode-only card shows no destination picker")
        XCTAssertNil(modeOffer.preselected, "a card with no picker preselects nothing")
        try assertBody(mode.answer(.alwaysAllow(destination: nil)),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_permanent",
                        "updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
                       """,
                       "always allow with no picker")

        // The rule card: three destinations, preselecting the suggestion's own.
        let rule = try card("send-user-file", id: "aaaa-permission-3")
        let ruleOffer = try XCTUnwrap(rule.alwaysAllow, "a card with an addRules suggestion offers always allow")
        XCTAssertEqual(ruleOffer.destinations, [.userSettings, .projectSettings, .localSettings])
        XCTAssertEqual(ruleOffer.preselected, .localSettings, "the picker starts on the suggestion's own destination")
        for destination in ruleOffer.destinations {
            try assertBody(rule.answer(.alwaysAllow(destination: destination)),
                           is: """
                           {"behavior":"allow","decisionClassification":"user_permanent",
                            "updatedPermissions":[{"type":"addRules",
                                                   "rules":[{"toolName":"mcp__afleet__send_user_file"}],
                                                   "behavior":"allow","destination":"\(destination.rawValue)"}]}
                           """,
                           "always allow filed at one of three destinations")
        }

        // The discriminating case: both variants on one card, with a destination chosen. A mapping
        // that rewrites every suggestion's destination moves the setMode too, and fails here.
        let mixed = try card("send-user-file", id: "aaaa-permission-4", overrides: [
            "permission_suggestions": [
                ["type": "addRules",
                 "rules": [["toolName": "mcp__afleet__send_user_file"]],
                 "behavior": "allow",
                 "destination": "localSettings"],
                ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
            ]
        ])
        try assertBody(mixed.answer(.alwaysAllow(destination: .userSettings)),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_permanent",
                        "updatedPermissions":[{"type":"addRules",
                                               "rules":[{"toolName":"mcp__afleet__send_user_file"}],
                                               "behavior":"allow","destination":"userSettings"},
                                              {"type":"setMode","mode":"acceptEdits","destination":"session"}]}
                       """,
                       "always allow over a rule and a setMode together")
    }

    func testAlwaysAllowIsAbsentWithoutSuggestionsAndWithSuppression() throws {
        let offered = try card("send-user-file", id: "aaaa-permission-5")
        XCTAssertNotNil(offered.alwaysAllow, "the positive case: a suggestion with nothing suppressing it")

        let none = try card("send-user-file", id: "aaaa-permission-6",
                            overrides: ["permission_suggestions": [] as [Any]])
        XCTAssertNil(none.alwaysAllow, "no suggestions, no always allow")
        XCTAssertNil(none.answer(.alwaysAllow(destination: .localSettings)),
                     "a card that offers no always allow answers none either")

        let suppressed = try card("send-user-file", id: "aaaa-permission-7",
                                  overrides: ["suppress_always_allow_rule": true])
        XCTAssertNil(suppressed.alwaysAllow, "suppress_always_allow_rule removes the action")
        XCTAssertNil(suppressed.answer(.alwaysAllow(destination: .localSettings)),
                     "a suppressed card answers no always allow")
    }

    /// Spec D5's last clause. An unmodelled suggestion re-encodes losslessly, but nothing in it can
    /// be described to the user, so a card whose suggestions are all unmodelled offers no *Always
    /// allow* at all — and rewriting a field of an opaque value would be guessing.
    func testAnAllUnknownSuggestionSetOffersNoAlwaysAllow() throws {
        let opaque = try card("send-user-file", id: "aaaa-permission-8", overrides: [
            "permission_suggestions": [["type": "invented_future_variant", "destination": "session"]]
        ])
        guard case .permission(let tool) = opaque.payload else {
            return XCTFail("the invented suggestion took the whole request out of its typed case")
        }
        XCTAssertEqual(tool.fields.permissionSuggestions?.count, 1, "the unmodelled suggestion survived the decode")
        XCTAssertEqual(tool.fields.permissionSuggestions?.filter(\.isUnmodelled).count, 1)
        XCTAssertNil(opaque.alwaysAllow, "an all-unmodelled suggestion set offers no always allow")
        XCTAssertNil(opaque.answer(.alwaysAllow(destination: .localSettings)))

        // Alongside one that can be described, the offer returns and the opaque suggestion is sent
        // exactly as it arrived.
        let mixed = try card("send-user-file", id: "aaaa-permission-9", overrides: [
            "permission_suggestions": [
                ["type": "invented_future_variant", "destination": "session"],
                ["type": "addRules",
                 "rules": [["toolName": "mcp__afleet__send_user_file"]],
                 "behavior": "allow",
                 "destination": "localSettings"]
            ]
        ])
        try assertBody(mixed.answer(.alwaysAllow(destination: .projectSettings)),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_permanent",
                        "updatedPermissions":[{"type":"invented_future_variant","destination":"session"},
                                              {"type":"addRules",
                                               "rules":[{"toolName":"mcp__afleet__send_user_file"}],
                                               "behavior":"allow","destination":"projectSettings"}]}
                       """,
                       "always allow beside an unmodelled suggestion")
    }

    // MARK: - Question and plan

    /// Anchor 9: the answer echoes the whole input with `answers` added, keyed by raw question text,
    /// and a multi-select reply is one string joined with `", "`.
    func testTheQuestionAnswerEchoesTheWholeInputKeyedByQuestionText() throws {
        let card = try card("ask-user-question", id: "aaaa-question-1", overrides: [
            "input": ["questions": [["question": "Which invented option?",
                                     "header": "Invented",
                                     "multiSelect": true,
                                     "options": [["label": "First"], ["label": "Second"]]]]]
        ])
        try assertBody(card.answer(.answerQuestion([
            QuestionResponse(question: "Which invented option?", selections: ["First", "Second"], annotation: nil)
        ])),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_temporary",
                        "updatedInput":{"questions":[{"question":"Which invented option?","header":"Invented",
                                                      "multiSelect":true,
                                                      "options":[{"label":"First"},{"label":"Second"}]}],
                                        "answers":{"Which invented option?":"First, Second"}}}
                       """,
                       "a multi-select question answer")

        try assertBody(card.answer(.answerQuestion([
            QuestionResponse(question: "Which invented option?", selections: ["First"],
                             annotation: .init(preview: nil, notes: "an invented note"))
        ])),
                       is: """
                       {"behavior":"allow","decisionClassification":"user_temporary",
                        "updatedInput":{"questions":[{"question":"Which invented option?","header":"Invented",
                                                      "multiSelect":true,
                                                      "options":[{"label":"First"},{"label":"Second"}]}],
                                        "answers":{"Which invented option?":"First"},
                                        "annotations":{"Which invented option?":{"notes":"an invented note"}}}}
                       """,
                       "a question answer carrying an annotation")
    }

    /// Anchor 8: the plan's update is `{type:"setMode", destination:"session", mode:<chosen>}`.
    func testThePlanActionsCarrySetModeAtTheSession() throws {
        let card = try card("exit-plan-mode", id: "aaaa-plan-1", overrides: ["input": ["plan": "an invented plan"]])
        try assertBody(card.answer(.approvePlan(autoAcceptEdits: false)),
                       is: """
                       {"behavior":"allow","updatedInput":{"plan":"an invented plan"},
                        "updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}
                       """,
                       "approve a plan")
        try assertBody(card.answer(.approvePlan(autoAcceptEdits: true)),
                       is: """
                       {"behavior":"allow","updatedInput":{"plan":"an invented plan"},
                        "updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
                       """,
                       "approve a plan and auto-accept edits")
        try assertBody(card.answer(.rejectPlan(feedback: "an invented objection")),
                       is: #"{"behavior":"deny","message":"an invented objection","interrupt":false,"decisionClassification":"user_reject"}"#,
                       "reject a plan with feedback")
    }

    // MARK: - Dialogs

    /// Anchors 2 and 3: six result strings, and `{behavior:"cancelled"}` for a closed card.
    func testEveryDialogResultIsTheEngineSpelling() throws {
        let refusal = try card("dialog-refusal-fallback", subtype: "request_user_dialog", id: "aaaa-dialog-1")
        try assertBody(refusal.answer(.retryOnFallbackModel),
                       is: #"{"behavior":"completed","result":"retry_fallback"}"#, "retry on the fallback model")
        try assertBody(refusal.answer(.editPrompt),
                       is: #"{"behavior":"completed","result":"edit_prompt"}"#, "edit the prompt")
        try assertBody(refusal.answer(.keepTheRefusal),
                       is: #"{"behavior":"completed","result":"cancelled"}"#, "keep the refusal")
        try assertBody(refusal.answer(.closeDialog),
                       is: #"{"behavior":"cancelled"}"#, "close the refusal card")

        let overage = try card("dialog-fable-overage", subtype: "request_user_dialog", id: "aaaa-dialog-2")
        XCTAssertTrue(overage.overagesEnabled, "the recorded first overage dialog has billing on")
        try assertBody(overage.answer(.useUsageCredits),
                       is: #"{"behavior":"completed","result":"consent"}"#, "use usage credits")
        try assertBody(overage.answer(.switchToDefaultModel),
                       is: #"{"behavior":"completed","result":"switch_default"}"#, "switch to the default model")
        try assertBody(overage.answer(.notNow),
                       is: #"{"behavior":"completed","result":"cancelled"}"#, "not now")
        try assertBody(overage.answer(.closeDialog),
                       is: #"{"behavior":"cancelled"}"#, "close the overage card")

        // Neither card answers the other's actions, and the billing route is not an answer at all.
        XCTAssertNil(refusal.answer(.useUsageCredits), "a refusal card answers no overage action")
        XCTAssertNil(overage.answer(.retryOnFallbackModel), "an overage card answers no refusal action")
        XCTAssertNil(overage.answer(.setUpUsageCredits), "the billing route sends nothing (spec D7)")
    }

    /// §8.4's *Result* column: `consent` is offered only when `overagesEnabled` is true, because a
    /// bare wire reply never enables billing. Both directions, so a card that offered it always
    /// cannot pass.
    func testConsentIsNotOfferedWhenOveragesAreDisabled() throws {
        let enabled = try card("dialog-fable-overage", subtype: "request_user_dialog", id: "aaaa-dialog-3",
                               overrides: ["payload": ["overagesEnabled": true, "modelName": "an invented model"]])
        XCTAssertTrue(enabled.overagesEnabled)
        try assertBody(enabled.answer(.useUsageCredits),
                       is: #"{"behavior":"completed","result":"consent"}"#, "consent with billing on")

        let disabled = try card("dialog-fable-overage", subtype: "request_user_dialog", id: "aaaa-dialog-4",
                                overrides: ["payload": ["overagesEnabled": false, "modelName": "an invented model"]])
        XCTAssertFalse(disabled.overagesEnabled)
        XCTAssertNil(disabled.answer(.useUsageCredits), "consent is not offered when billing is off")
        // The card still answers its other two actions, so the arm is disabled and not the card.
        try assertBody(disabled.answer(.switchToDefaultModel),
                       is: #"{"behavior":"completed","result":"switch_default"}"#, "switch with billing off")
        try assertBody(disabled.answer(.notNow),
                       is: #"{"behavior":"completed","result":"cancelled"}"#, "not now with billing off")
    }

    // MARK: - Elicitation

    /// Anchor 10: `{action, content?}`, with `content` a sibling of `action`. No fixture carries an
    /// elicitation, so the request is invented (§11) and says so here.
    func testElicitationAcceptDeclineCancel() throws {
        let request = FixtureRunner.Invented.elicitation(id: "aaaa-elicitation-1")
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel))
        let card = DecisionCard(item)
        guard case .elicitation = card.payload else {
            return XCTFail("an invented elicitation did not decode into the elicitation case")
        }
        try assertBody(card.answer(.acceptElicitation(content: .object(["invented_field": .string("a value")]))),
                       is: #"{"action":"accept","content":{"invented_field":"a value"}}"#, "accept an elicitation")
        try assertBody(card.answer(.declineElicitation), is: #"{"action":"decline"}"#, "decline an elicitation")
        try assertBody(card.answer(.cancelElicitation), is: #"{"action":"cancel"}"#, "cancel an elicitation")
    }

    // MARK: - The surfacing initialiser

    /// Spec D14. Activity holds the live `InboundRequest` and the timeline holds C3's item; the two
    /// hosts must hand the component the same value. This drives every `can_use_tool`,
    /// `request_user_dialog` and `elicitation` request the corpus records through both derivations —
    /// the reducer's own and this child's — and compares the five fields a card reads.
    func testTheSurfacingInitialiserAgreesWithTheReducer() throws {
        let key = Self.channel
        let stream = LogicalStream(configHome: key.configHome, sessionID: key.session, name: .main)
        var requests: [InboundRequest] = []
        for fixture in try Self.fixturesWithFrames() {
            for event in try FixtureRunner.events(fixture) {
                let request: InboundRequest?
                switch event {
                case .request(let r): request = r
                case .unansweredDialog(let r): request = r
                case .policyAnswered(let r, _): request = r
                default: request = nil
                }
                guard let request,
                      ["can_use_tool", "request_user_dialog", "elicitation"].contains(request.subtype) else { continue }
                requests.append(request)
            }
        }
        // No fixture records an elicitation, so the one invented request stands in for that subtype.
        requests.append(FixtureRunner.Invented.elicitation(id: "aaaa-elicitation-2"))

        // The floor: an empty sweep must not pass for want of anything to compare.
        XCTAssertGreaterThanOrEqual(requests.count, 18,
                                    "the sweep found fewer requests than the corpus records")

        var compared = 0
        for request in requests {
            var reducer = WireReducer(stream: stream, slug: "invented-slug")
            _ = reducer.apply(.request(request))
            guard let reduced = reducer.overlay.decisions[request.id] else {
                XCTFail("the reducer opened no decision for a request of a subtype it models")
                continue
            }
            let surfaced = try XCTUnwrap(DecisionItem(surfacing: request, in: key),
                                         "the surfacing initialiser opened no item where the reducer did")
            XCTAssertTrue(surfaced.kind == reduced.kind, "the two derivations disagree on kind")
            XCTAssertTrue(surfaced.title == reduced.title, "the two derivations disagree on title")
            XCTAssertTrue(surfaced.toolUseID == reduced.toolUseID, "the two derivations disagree on tool_use_id")
            XCTAssertTrue(surfaced.agentID == reduced.agentID, "the two derivations disagree on agent_id")
            XCTAssertTrue(surfaced.payload == reduced.payload, "the two derivations disagree on the raw payload")
            XCTAssertTrue(surfaced.state == .pending, "a surfaced request is pending")
            compared += 1
        }
        XCTAssertEqual(compared, requests.count, "one or more requests were not compared")
    }

    /// Every fixture directory carrying a recording.
    private static func fixturesWithFrames() throws -> [String] {
        let root = FixtureRunner.repositoryRoot.appending(path: "Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path()).sorted()
        return names.filter { FileManager.default.fileExists(atPath: root.appending(path: $0)
            .appending(path: "frames.ndjson").path()) }
    }
}
