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
                                _ answering: DecisionAnswering) throws -> PermissionCardView {
        PermissionCardView(card: card, tool: try tool(of: card), presentation: presentation,
                           channel: Self.channel, answering: answering)
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

}
