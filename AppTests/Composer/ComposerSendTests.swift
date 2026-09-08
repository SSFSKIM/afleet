import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 1: the send path, and the two refusals that must not eat what the user typed.
///
/// Every assertion here reads `ComposerLifecycleDouble`'s **ordered** log rather than a per-member
/// count, because three of the four behaviours below are about a call that must not happen a second
/// time. Nothing compares an aggregate reaching a `ChannelKey` (§11): the key is asserted through
/// booleans and the sequence through `memberSequence`, which carries member names and no values.
@MainActor
final class ComposerSendTests: XCTestCase {

    /// Invented throughout: an invented config-home path that exists nowhere, and C5's repeated-
    /// nibble session (§11, X9 — nothing here touches a real home and nothing is written at all).
    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("c"))
    }

    private func makeModel(_ double: ComposerLifecycleDouble) -> ComposerModel {
        ComposerModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    /// A line typed and sent is exactly one `perform(.send(UserInput))`, and the field is emptied.
    func testSendPerformsOneSendActionAndClearsTheDraft() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)
        model.draft = "an invented line"

        await model.send()

        let members = await double.memberSequence
        XCTAssertEqual(members, ["perform"],
                       "one send reached \(members.count) lifecycle member(s): \(members.joined(separator: ", "))")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "one send produced \(actions.count) action(s)")
        guard case .send(let input)? = actions.first else {
            return XCTFail("the composer performed an action that is not `.send`")
        }
        XCTAssertEqual(input.text, "an invented line", "the sent text is not the \(model.draft.count)-character draft")
        XCTAssertEqual(input.images.count, 0, "a text-only send carried \(input.images.count) image(s)")
        XCTAssertEqual(model.draft.count, 0, "a successful send left \(model.draft.count) character(s) in the field")
        XCTAssertNil(model.refusal, "a successful send raised an inline refusal")
    }

    /// `LifecycleError.busy` leaves the words in the field, names the operation, and does not retry.
    ///
    /// A success is staged **behind** the refusal: a composer that retried would consume it and the
    /// draft would clear, so the count assertion below is the arm that catches a retry rather than a
    /// crash on an unstaged outcome.
    func testBusyRefusalKeepsTheDraftNamesTheOperationAndDoesNotRetry() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.failure(.busy(.spawn)))
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)
        model.draft = "an invented line"

        await model.send()

        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "a refused send produced \(actions.count) action(s); more than one is a retry")
        XCTAssertEqual(model.draft, "an invented line",
                       "a refused send left \(model.draft.count) character(s) in the field instead of the 16 typed")
        guard let refusal = model.refusal else {
            return XCTFail("a refused send showed no inline explanation")
        }
        XCTAssertTrue(refusal.contains(LifecycleOperation.spawn.rawValue),
                      "the explanation does not name the operation the lifecycle refused for")
    }

    /// `LifecycleError.notEligible` behaves the same way and names the blocker.
    func testNotEligibleRefusalKeepsTheDraftNamesTheBlockerAndDoesNotRetry() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.failure(.notEligible(.turnRunning)))
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)
        model.draft = "an invented line"

        await model.send()

        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "a refused send produced \(actions.count) action(s); more than one is a retry")
        XCTAssertEqual(model.draft, "an invented line",
                       "a refused send left \(model.draft.count) character(s) in the field instead of the 16 typed")
        guard let refusal = model.refusal else {
            return XCTFail("a refused send showed no inline explanation")
        }
        XCTAssertTrue(refusal.lowercased().contains("turn"),
                      "the explanation does not name the blocker the lifecycle refused for")
    }

    /// An empty or whitespace-only draft reaches the lifecycle not at all — not as an empty send,
    /// and not as a refusal either.
    ///
    /// A success is staged even though nothing may reach it. Without one, a composer that *did*
    /// send would trip the double's unstaged-outcome trap and take the whole bundle down with a
    /// fatal error and no assertion; with one, it fails on the count below and says so.
    func testWhitespaceOnlyDraftReachesTheLifecycleNotAtAll() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)
        model.draft = "   \n\t  "

        await model.send()

        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0,
                       "a blank draft reached \(members.count) lifecycle member(s): \(members.joined(separator: ", "))")
        XCTAssertEqual(model.draft.count, 7, "a blank draft was rewritten to \(model.draft.count) character(s)")
        XCTAssertNil(model.refusal, "a blank draft raised an inline refusal")
    }

    /// The refusal is the *last* send's, not a sticky one: a success after a refusal clears it.
    func testASuccessfulSendAfterARefusalClearsTheInlineExplanation() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.failure(.busy(.restart)))
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)
        model.draft = "an invented line"

        await model.send()
        XCTAssertNotNil(model.refusal, "the first, refused, send showed no inline explanation")
        await model.send()

        let actions = await double.actions
        XCTAssertEqual(actions.count, 2, "two sends produced \(actions.count) action(s)")
        XCTAssertNil(model.refusal, "the refusal from the first send survived a successful one")
        XCTAssertEqual(model.draft.count, 0, "the successful second send left \(model.draft.count) character(s)")
    }

    /// Two Return presses while one send is still in flight are **one** send.
    ///
    /// The field fires `send()` from a detached `Task`, so nothing serialises the two: without a
    /// guard both clear the blank-draft check, both read the same draft, and both reach `perform` —
    /// the same message twice. The double holds `perform` open so the second press genuinely lands
    /// inside the first, which is the only arrangement in which an unguarded model can be seen to
    /// send twice; an unheld double answers before the second press is ever made.
    func testASecondSendWhileOneIsInFlightReachesTheLifecycleNotAtAll() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        await double.holdPerform()
        let model = makeModel(double)
        model.draft = "an invented line"

        async let first: Void = model.send()
        async let second: Void = model.send()

        // Let both presses reach the lifecycle, and stop early the moment a second call proves the
        // defect: the loop is a ceiling on how long a passing run waits, not a timing assumption.
        var inFlight = 0
        for _ in 0..<2_000 {
            await Task.yield()
            inFlight = await double.calls.count
            if inFlight > 1 { break }
        }
        let held = await double.callersHeldInPerform
        await double.releasePerform()
        _ = await (first, second)

        XCTAssertEqual(inFlight, 1,
                       "two presses during one in-flight send reached the lifecycle \(inFlight) time(s)")
        XCTAssertEqual(held, 1, "\(held) caller(s) were inside perform at once")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "two concurrent sends produced \(actions.count) action(s)")
        XCTAssertEqual(model.draft.count, 0, "the send left \(model.draft.count) character(s) in the field")
    }
}
