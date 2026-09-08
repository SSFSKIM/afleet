import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// A probe on the one piece of state `DecisionAnswering` holds. `send(_:on:in:)` claims the request
/// id before it returns, so a caller that has pressed a button can wait for the round trip without
/// waiting on a duration.
extension DecisionAnswering {
    func whenIdle() async {
        while !inFlight.isEmpty { await Task.yield() }
    }
}

/// Reaching a nested card's own body.
///
/// `ViewTree` reflects stored properties, and a child `View` stores its inputs rather than its
/// body — so a host's body contains the card *value* and not the card's buttons. Each step is
/// spelled out rather than recursed, because a blind recursion into `body` would call it on a
/// primitive view like `Text`, whose `Body` is `Never`.
@MainActor
enum CardTree {

    /// The permission card's own body, inside whatever host built it — the card component's body,
    /// a row's body that contains it, or the permission card itself.
    static func permissionBody(in hostBody: Any) -> Any? {
        if let permission = ViewTree.values(of: PermissionCardView.self, in: hostBody).first {
            return permission.body
        }
        if let card = ViewTree.values(of: DecisionCardView.self, in: hostBody).first {
            return permissionBody(in: card.body)
        }
        return nil
    }

    /// Every string any `Text` in a body carries.
    static func texts(in body: Any) -> [String] {
        ViewTree.values(of: Text.self, in: body).flatMap { ViewTree.values(of: String.self, in: $0) }
    }

    /// The strings the card's **tool-input** view draws, at whatever depth the branch it took puts
    /// them. Spelled out for the same reason the descent above is: the card stores the input view as
    /// a value, and the generic branch stores a second one inside that.
    static func inputTexts(in cardBody: Any) -> [String] {
        guard let view = ViewTree.values(of: ToolInputView.self, in: cardBody).first else { return [] }
        var drawn = texts(in: view.body)
        // The generic branch draws its rows from a `ForEach` closure, which reflection does not
        // enter; the fields it was built with are stored, and they are what those rows draw.
        for generic in ViewTree.values(of: GenericToolInputView.self, in: view.body) {
            drawn += generic.fields.flatMap { [$0.key, $0.text] }
        }
        return drawn
    }
}

/// The card component: what it emits, what it disables, what it reads out, and the four readings a
/// card that is no longer waiting gives (spec §8.4, D12).
///
/// **Every answer clause asserts the action that left the host**, never that a card changed: a card
/// changes for many reasons and only one of them is the right answer having been sent.
///
/// Failure messages carry counts and action names. A recorded fixture's input holds a path and a
/// `ChannelKey` holds a config home, and `XCTAssertEqual` prints both operands (§6.3, §11), so every
/// comparison over one of those is spelled as a boolean with a written message.
@MainActor
final class DecisionCardTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one: these tests need
    /// a `ChannelKey`'s value alone, and X9 forbids the app side writing under any config home.
    private static var channel: ChannelKey {
        ActivityFixtures.key("a", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-cards-unwritten"))
    }

    private func card(_ fixture: String, id: String, overrides: [String: Any] = [:]) throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id, overrides: overrides)
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel),
                                 "the surfacing initialiser opened no item for a recorded ask")
        return DecisionCard(item)
    }

    private func tool(of card: DecisionCard) throws -> CanUseToolRequest {
        guard case .permission(let tool) = card.payload else {
            throw XCTSkip("the recorded ask is no longer a permission card")
        }
        return tool
    }

    private func permissionView(_ card: DecisionCard,
                                _ presentation: DecisionCardView.Presentation = .full,
                                _ answering: DecisionAnswering,
                                isActive: Bool = true) throws -> PermissionCardView {
        PermissionCardView(card: card, tool: try tool(of: card), presentation: presentation,
                           channel: Self.channel, isActive: isActive, answering: answering)
    }

    /// A lifecycle that accepts every answer, and the answering object over it.
    private func answering() async -> (LifecycleDouble, DecisionAnswering) {
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        return (lifecycle, DecisionAnswering(lifecycle: lifecycle))
    }

    /// The bytes the transport would write for an answer — the comparison "byte-identical" means.
    private func wireBytes(_ answer: InboundAnswer?, for id: RequestID) throws -> Data {
        let answer = try XCTUnwrap(answer, "the mapping produced no answer")
        guard case .success(let success) = answer.controlResponse(for: id).body,
              let response = success.response else {
            XCTFail("the answer did not encode as a success body")
            return Data()
        }
        return try response.canonicalData()
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the card offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    // MARK: - The answers the card emits

    /// G1a's first half, and Y2's invariant: the card emits the mapping's answer and builds none of
    /// its own. One press, one action, and the action carries the body `answer(_:)` produced.
    func testTheCardEmitsTheAnswerTheMappingProduces() async throws {
        let card = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")

        let expected: [(label: String, action: DecisionAction)] = [
            ("Allow once", .allowOnce),
            ("Always allow", .alwaysAllow(destination: card.alwaysAllow?.preselected)),
            ("Deny", .deny(message: PermissionCardView.unstatedDenial))
        ]

        for (label, action) in expected {
            let (lifecycle, answering) = await answering()
            let view = try permissionView(card, .full, answering)
            try press(label, in: view.body)
            await answering.whenIdle()

            let actions = await lifecycle.actions
            XCTAssertEqual(actions.count, 1, "one press on \(label) produced \(actions.count) actions")
            guard case .answer(let id, let sent)? = actions.first?.action else {
                return XCTFail("the action \(label) emitted was not an answer")
            }
            XCTAssertTrue(id == card.requestID, "the \(label) answer carried a different request id")
            let sentBytes = try wireBytes(sent, for: card.requestID)
            let mapped = try wireBytes(card.answer(action), for: card.requestID)
            XCTAssertTrue(sentBytes == mapped, "the \(label) answer is not the body the mapping produces")
        }
    }

    /// An answer on the wire disables the card's actions, and a second click sends nothing.
    ///
    /// The discriminating half is the second clause. A card that only greyed its buttons on a state
    /// it re-derives would still send twice from two clicks in one turn, and the double is the only
    /// witness of that: the count of actions it received.
    func testAnAnswerInFlightDisablesTheActionsAndASecondClickSendsNothing() async throws {
        let card = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")
        let (lifecycle, answering) = await answering()
        let view = try permissionView(card, .full, answering)

        XCTAssertFalse(answering.isAnswering(card.requestID), "the card was disabled before any click")
        try press("Allow once", in: view.body)
        XCTAssertTrue(answering.isAnswering(card.requestID),
                      "the answer was not marked in flight, so the actions stayed live")
        try press("Allow once", in: view.body)
        await answering.whenIdle()

        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 1, "two clicks in one turn produced \(actions.count) answers")
        XCTAssertFalse(answering.isAnswering(card.requestID), "the settled answer stayed in flight")
    }

    // MARK: - The two flags that change which actions exist

    /// `default_to_no` is the engine saying the safe answer is no: decline opens focused and approve
    /// binds no shortcut, so Return cannot approve by reflex. With the negative, because a card that
    /// never bound the shortcut at all would pass the first half alone.
    func testDefaultToNoFocusesDeclineAndBindsNoApproveShortcut() async throws {
        let (_, answering) = await answering()

        let cautious = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3",
                                overrides: ["default_to_no": true])
        let cautiousView = try permissionView(cautious, .full, answering)
        XCTAssertEqual(cautiousView.initialFocus, .decline, "default_to_no did not focus decline")
        XCTAssertNil(cautiousView.approveShortcut, "default_to_no left the approve shortcut bound")

        // The negative, and the floor for "omitted means false": the recorded ask carries no flag.
        let plain = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4")
        XCTAssertNil(try tool(of: plain).fields.defaultToNo, "the recorded ask now carries the flag")
        let plainView = try permissionView(plain, .full, answering)
        XCTAssertEqual(plainView.initialFocus, .approve, "an ask without the flag did not focus approve")
        XCTAssertEqual(plainView.approveShortcut, .defaultAction,
                       "an ask without the flag bound no approve shortcut")
    }

    /// `requires_user_interaction` removes the one-tap approve and deny **entirely**: the engine is
    /// saying the tool's own card is the surface, so an answer here would answer a question the user
    /// has not been shown. With the negative, on the same recorded ask.
    func testRequiresUserInteractionOffersNoOneTapAnswer() async throws {
        let (_, answering) = await answering()

        let interactive = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5",
                                   overrides: ["requires_user_interaction": true])
        let interactiveView = try permissionView(interactive, .full, answering)
        XCTAssertFalse(interactiveView.offersOneTapAnswer, "the flag left the one-tap answers in place")
        XCTAssertNil(ViewTree.button("Allow once", in: interactiveView.body),
                     "an ask requiring the tool's own card still offered Allow once")
        XCTAssertNil(ViewTree.button("Deny", in: interactiveView.body),
                     "an ask requiring the tool's own card still offered Deny")

        let plain = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6")
        XCTAssertNil(try tool(of: plain).fields.requiresUserInteraction,
                     "the recorded ask now carries the flag")
        let plainView = try permissionView(plain, .full, answering)
        XCTAssertTrue(plainView.offersOneTapAnswer, "the same ask without the flag offered no answer")
        XCTAssertNotNil(ViewTree.button("Allow once", in: plainView.body), "Allow once was absent")
        XCTAssertNotNil(ViewTree.button("Deny", in: plainView.body), "Deny was absent")
    }

    /// scalpel-5#2: **no card owns Return by default.** `default_to_no` unbinding the shortcut is
    /// not the whole rule — a card that is one of many in a list must not bind it either, because
    /// Activity draws a compact card per waiting channel and a single Return would answer whichever
    /// of them registered the default action first.
    ///
    /// Asserted on the compact presentation, which is the one Activity draws.
    func testACompactCardBindsNoApproveShortcut() async throws {
        let (_, answering) = await answering()
        let plain = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaab01")
        XCTAssertNil(try permissionView(plain, .compact, answering, isActive: false).approveShortcut,
                     "a compact card in a multi-channel list claimed Return as its default action")

        // And the same for a full card the host has not marked active: a timeline of pending cards
        // is a list too, and Return belongs to one of them or to none.
        XCTAssertNil(try permissionView(plain, .full, answering, isActive: false).approveShortcut,
                     "an inactive card claimed Return as its default action")
        XCTAssertEqual(try permissionView(plain, .full, answering, isActive: true).approveShortcut,
                       .defaultAction, "the active card bound no approve shortcut")
    }

    // MARK: - What Always allow will do

    /// scalpel-2#2: the card **says what each suggestion will do** before the user chooses it.
    ///
    /// `permission-allow`'s only suggestion is `setMode(acceptEdits, session)`, which the mapping
    /// sends verbatim: pressing *Always allow* on this ask makes every later edit in the session
    /// automatic. A card that offered the button without saying so would collect consent for an
    /// expansion it never described. The mode and its scope are both asserted, because either alone
    /// leaves the sentence uninformative.
    func testTheCardDescribesASetModeSuggestionBeforeOfferingIt() async throws {
        let (_, answering) = await answering()
        let card = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaab02")
        for presentation in [DecisionCardView.Presentation.full, .compact] {
            let texts = CardTree.texts(in: try permissionView(card, presentation, answering).body)
            XCTAssertTrue(texts.contains { $0.contains("Accept edits") },
                          "the card offered Always allow without naming the mode it would set")
            XCTAssertTrue(texts.contains { $0.contains("this session") },
                          "the card offered Always allow without naming the scope of the mode")
        }
    }

    /// scalpel-2#3: a rule-carrying suggestion names the rule **and the destination it will be
    /// filed at**, in both presentations — the compact card shows no picker, so the destination it
    /// would submit is the one thing it has to disclose.
    ///
    /// `send-user-file` records the one `addRules` ask in the corpus, at `localSettings`.
    func testARuleSuggestionNamesItsRuleAndDestinationInBothPresentations() async throws {
        let (_, answering) = await answering()
        let card = try card("send-user-file", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaab03")
        let offer = try XCTUnwrap(card.alwaysAllow, "the recorded ask offers no Always allow")
        XCTAssertFalse(offer.destinations.isEmpty, "the recorded ask carries no rule to file")
        for presentation in [DecisionCardView.Presentation.full, .compact] {
            let texts = CardTree.texts(in: try permissionView(card, presentation, answering).body)
            XCTAssertTrue(texts.contains { $0.contains("send_user_file") },
                          "the card offered Always allow without naming the rule it would add")
            XCTAssertTrue(texts.contains { $0.contains("This project, locally") },
                          "the card offered Always allow without naming where the rule would be filed")
        }
    }

    /// scalpel-2#2: a directory-carrying suggestion names **every directory**, not how many.
    ///
    /// `DecisionAnswerMapping` sends the suggestions as they arrived, so *Always allow* grants the
    /// engine access to each of these directories for the rest of the session and beyond. No other
    /// control on the card exposes the list — the picker chooses where the rule is filed, not what
    /// it covers — so a reading that said "3 directories" was the only description of the grant, and
    /// it described none of it.
    func testADirectorySuggestionNamesEveryDirectoryItWouldAdd() async throws {
        let (_, answering) = await answering()
        let directories = ["/invented/workspace/alpha", "/invented/workspace/beta",
                           "/invented/workspace/gamma"]
        let suggestion: [String: Any] = ["type": "addDirectories", "directories": directories,
                                         "destination": "localSettings"]
        let card = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaab04",
                            overrides: ["permission_suggestions": [suggestion]])
        for presentation in [DecisionCardView.Presentation.full, .compact] {
            let texts = CardTree.texts(in: try permissionView(card, presentation, answering).body)
            let reading = try XCTUnwrap(texts.first { $0.contains("Always allow adds") },
                                        "the card offered Always allow without describing the grant")
            let unnamed = directories.filter { !reading.contains($0) }
            XCTAssertEqual(unnamed.count, 0,
                           "\(unnamed.count) of \(directories.count) directories were left out of the reading")
        }
    }

    /// sweep#1: a card **shows the input it is asking approval for**, whatever the tool.
    ///
    /// The specialised views cover the file and search tools; an MCP call parses as `.other`, and
    /// `Agent` and `SendMessage` have no branch of their own. Those cards drew a title, a reason and
    /// three buttons over nothing at all — an approval of arguments the user was never shown, which
    /// is the one thing a permission card exists to prevent. Each sample below is invented, and each
    /// clause asserts both halves: the arguments are drawn, and the approval is still offered, so a
    /// card that answered by hiding its buttons would fail here too.
    func testAToolWithNoSpecialisedViewStillShowsTheInputItAsksApprovalFor() async throws {
        let (_, answering) = await answering()
        let samples: [(tool: String, input: [String: Any], drawn: [String])] = [
            ("mcp__invented-ledger__record_entry",
             ["account": "invented-account-7", "memo": "a line the user has to read", "amount": 42],
             ["account", "invented-account-7", "memo", "a line the user has to read"]),
            ("Agent",
             ["description": "an invented errand", "prompt": "do the invented thing",
              "subagent_type": "invented-worker"],
             ["description", "an invented errand", "prompt", "do the invented thing"]),
            ("SendMessage",
             ["to": "invented-worker", "message": "an invented instruction"],
             ["to", "invented-worker", "message", "an invented instruction"])
        ]
        for (index, sample) in samples.enumerated() {
            let card = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaab1\(index)",
                                overrides: ["tool_name": sample.tool, "input": sample.input])
            let body = try permissionView(card, .full, answering).body
            let drawn = CardTree.inputTexts(in: body)
            let missing = sample.drawn.filter { needle in !drawn.contains { $0.contains(needle) } }
            XCTAssertEqual(missing.count, 0,
                           "\(missing.count) of \(sample.drawn.count) parts of the input were not drawn")
            XCTAssertNotNil(ViewTree.button("Allow once", in: body),
                            "the card drew its input and then offered no approval")
        }

        // And the rendering is bounded: an engine may send an argument of any size, and one field
        // must not be able to push the buttons off the screen. What is held back is reachable.
        let long = String(repeating: "n", count: GenericToolInput.visibleCharacters * 3)
        XCTAssertTrue(GenericToolInput.isElided(long), "an argument three times the bound was drawn whole")
        let head = GenericToolInput.head(of: long)
        XCTAssertLessThan(head.count, long.count, "the elided head is not shorter than the value")
        XCTAssertTrue(long.hasPrefix(head.dropLast()), "the elided head is not the start of the value")
        let short = "an invented instruction"
        XCTAssertEqual(GenericToolInput.head(of: short), short, "an ordinary argument was elided")
    }

    // MARK: - Why the engine is asking

    /// An empty `decision_reason` is rebuilt from `decision_reason_type` and `matched_ask_rule`
    /// (*A-24*), which are the two fields that still say why. Asserted against the raw string: a
    /// card that rendered `decision_reason` as it arrived shows nothing at all here.
    func testAnEmptyDecisionReasonIsRebuiltFromItsTypeAndRule() async throws {
        let (_, answering) = await answering()
        let rule: [String: Any] = ["source": "projectSettings", "tool_name": "Bash",
                                   "rule_content": "find:*"]
        let rebuilt = try card("nested-depth-2", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7",
                               overrides: ["decision_reason": "", "decision_reason_type": "hook",
                                           "matched_ask_rule": rule])
        let fields = try tool(of: rebuilt).fields
        XCTAssertEqual(fields.decisionReason, "", "the raw reason under test was not empty")

        let reason = try XCTUnwrap(try permissionView(rebuilt, .full, answering).reason,
                                   "an empty reason was not rebuilt and the card says nothing")
        XCTAssertTrue(reason.contains("hook"), "the rebuilt reason did not name the reason type")
        XCTAssertTrue(reason.contains("Bash(find:*)"), "the rebuilt reason did not name the matched rule")

        // The floor: with neither field there is nothing to rebuild from and the card says nothing,
        // rather than inventing a sentence.
        let silent = try card("nested-depth-2", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8",
                              overrides: ["decision_reason": "", "decision_reason_type": "other"])
        XCTAssertNil(try permissionView(silent, .full, answering).reason,
                     "a card with nothing to say invented a reason")
    }

    /// The engine writes `decision_reason` for a terminal. Asserted against the raw string, which
    /// still carries the escape bytes: a card that rendered it as it arrived draws them as glyphs.
    func testANSIIsStripped() async throws {
        let (_, answering) = await answering()
        let raw = "\u{1B}[1;31mfind with -exec\u{1B}[0m cannot be auto-allowed"
        let stripped = try card("nested-depth-2", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa9",
                                overrides: ["decision_reason": raw])
        let fields = try tool(of: stripped).fields
        XCTAssertTrue(fields.decisionReason?.contains("\u{1B}") == true,
                      "the raw reason under test carried no escape")

        let reason = try XCTUnwrap(try permissionView(stripped, .full, answering).reason,
                                   "the reason vanished")
        XCTAssertFalse(reason.contains("\u{1B}"), "the rendered reason still carries escape bytes")
        XCTAssertEqual(reason, "find with -exec cannot be auto-allowed",
                       "stripping the escapes changed the sentence")
    }

    // MARK: - D12's four inert readings

    /// All four readings, and the two live ones either side of them.
    ///
    /// The discriminating pair is *session ended* against *left to the binary*: `.inert` has two
    /// producers — `.exited` rewriting every pending decision, and an undeclared dialog kind left to
    /// the binary — and `overlay.stale` is the only thing that separates them. An implementation
    /// reading `.inert` alone tells the user a live session has ended.
    func testTheFourInertReadings() async throws {
        let (_, answering) = await answering()
        let pending = try card("permission-allow", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab1")

        func reading(_ state: DecisionItem.State, stale: Bool) -> [String] {
            var card = pending
            card.state = state
            let view = DecisionCardView(card: card, presentation: .full, in: Self.channel,
                                        isStale: stale, answering: answering)
            return CardTree.texts(in: view.body)
        }

        XCTAssertTrue(reading(.cancelled, stale: false).contains("Answered elsewhere."),
                      "a cancelled card did not read answered elsewhere")
        XCTAssertTrue(reading(.inert, stale: true).contains("This session ended."),
                      "an inert card in a stale overlay did not read session ended")
        let binary = reading(.inert, stale: false)
        XCTAssertFalse(binary.contains("This session ended."),
                       "an inert card in a live overlay claimed the session had ended")
        XCTAssertTrue(binary.contains(where: { $0.contains("Left to the binary") }),
                      "an inert card in a live overlay did not read left to the binary")
        XCTAssertTrue(reading(.policyAnswered(error: "an invented policy refusal"), stale: false)
                        .contains("an invented policy refusal"),
                      "a policy-answered card did not show its error verbatim")
        XCTAssertTrue(reading(.answered(outcome: "Allowed once"), stale: false).contains("Allowed once"),
                      "an answered card did not show its outcome")

        // The floor: a pending card is not inert and keeps its actions, in both overlays.
        for stale in [false, true] {
            let view = DecisionCardView(card: pending, presentation: .full, in: Self.channel,
                                        isStale: stale, answering: answering)
            let body = try XCTUnwrap(CardTree.permissionBody(in: view.body),
                                     "a pending card drew no permission card")
            XCTAssertNotNil(ViewTree.button("Allow once", in: body),
                            "a pending card lost its actions")
        }
    }
}
