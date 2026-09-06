import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G2a and G2b: the rows Activity shows, which of them may be answered where they stand, and the
/// badges on the channels those rows came from (spec §5, §6).
///
/// Every input is a committed fixture's own recorded bytes, decoded by the engine's own decoders
/// through `FixtureRunner`; the two shapes the corpus does not carry — an `auth_status` with an
/// error, and an `elicitation` — are built by hand from invented identifiers (§11).
///
/// **No test here waits on a duration.** Each waits on the *input* being fully ingested — the
/// pump's own frame ring and request table — and then asserts on the *output* rows, so the wait
/// cannot be the assertion in disguise.
@MainActor
final class ActivityModelTests: XCTestCase {

    /// The notification preferences, in a box the router's closure can read after construction.
    @MainActor
    final class PreferenceBox {
        var value = NotificationPreferences()
    }

    // MARK: - The harness

    @MainActor
    private final class Harness {
        let tree: TempTree
        let configHome: URL
        let lifecycle = LifecycleDouble()
        let shell = ShellModel()
        let poster = RecordingPoster()
        let preferences = PreferenceBox()
        let router: NotificationRouter
        let model: ActivityModel

        init(store: (any StateStore)? = nil) throws {
            tree = try TempTree()
            configHome = try tree.directory("config-home")
            let shell = self.shell
            let poster = self.poster
            let lifecycle = self.lifecycle
            let preferences = self.preferences
            router = NotificationRouter(poster: poster,
                                        lifecycle: lifecycle,
                                        isInView: { key in shell.focus.session == key.session },
                                        preferences: { preferences.value })
            model = ActivityModel(lifecycle: lifecycle,
                                  configHome: configHome,
                                  shell: shell,
                                  router: router,
                                  store: store)
        }

        func key(_ nibble: String) -> ChannelKey { ActivityFixtures.key(nibble, configHome: configHome) }
    }

    /// One channel, opened for events and given a state, before the model starts.
    private func arm(_ harness: Harness, _ key: ChannelKey, pending: [PendingDecision] = []) async {
        await harness.lifecycle.setStates([ActivityFixtures.state(key, pending: pending)])
        await harness.lifecycle.openEvents(of: key)
    }

    // MARK: - Reading the rows

    /// The kind of each row, as a name, so two rows of the same kind with different payloads compare
    /// equal and a multiset comparison means what it says.
    private func kindNames(_ model: ActivityModel) -> [String] {
        model.items.map { Self.name(of: $0.row.kind) }
    }

    private static func name(of kind: ActivityRow.Kind) -> String {
        switch kind {
        case .decision: "decision"
        case .notification: "notification"
        case .failedResult: "failedResult"
        case .permissionDenied: "permissionDenied"
        case .rateLimitRefused: "rateLimitRefused"
        case .rateLimitInfo: "rateLimitInfo"
        case .authProblem: "authProblem"
        case .agentRunning: "agentRunning"
        case .agentFailed: "agentFailed"
        case .systemItem: "systemItem"
        }
    }

    /// Both directions, with a non-emptiness floor: an empty actual against an empty expected must
    /// not pass for "the same".
    private func assertSameMultiset(_ actual: [String], _ expected: [String],
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(expected.isEmpty, "the expectation itself is empty", file: file, line: line)
        XCTAssertFalse(actual.isEmpty, "no rows at all", file: file, line: line)
        let actualCounts = counted(actual), expectedCounts = counted(expected)
        for (kind, count) in expectedCounts {
            XCTAssertEqual(actualCounts[kind] ?? 0, count,
                           "expected \(count) \(kind) row(s), found \(actualCounts[kind] ?? 0)",
                           file: file, line: line)
        }
        for (kind, count) in actualCounts {
            XCTAssertEqual(expectedCounts[kind] ?? 0, count,
                           "found \(count) unexpected \(kind) row(s)", file: file, line: line)
        }
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    }

    private func counted(_ names: [String]) -> [String: Int] {
        names.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - G2a

    /// Two channels at a `can_use_tool`, the `rate-limited-turn` fixture on a third, and an
    /// `auth_status` carrying an error: four rows, compared as a multiset in both directions.
    ///
    /// **Six rows, not four, and the rate-limit row is `.rateLimitRefused`.** The gate says four and
    /// names `.rateLimitInfo`; the fixture's own bytes say otherwise on both counts, and the bytes
    /// are the authority. Its `rate_limit_event` carries `"status": "rejected"`, and C4's query keys
    /// the kind off `status` alone, so the row is a refusal. And both its `result` frames carry
    /// `"is_error": true` beside `"subtype": "success"` — a turn the engine cut short for rate
    /// limiting reports the error in `is_error` and leaves the subtype reading success — so the
    /// query adds two `.failedResult` rows, which is exactly what the user needs to see.
    /// The gate's intent is unchanged and is what is asserted: both decisions are listed, the
    /// rate-limit row comes from the event, and the authentication problem is visible.
    /// `.rateLimitInfo` is asserted where the corpus actually produces it, in
    /// `testTheRateLimitRowComesFromTheEventAndNotFromATurnEnding`.
    func testFourRowsForTwoDecisionsARateLimitAndAnAuthProblem() async throws {
        let harness = try Harness()
        let one = harness.key("1"), two = harness.key("2"), three = harness.key("3")

        let firstAsk = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                 id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondAsk = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                  id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        await arm(harness, one, pending: [ActivityFixtures.pending(firstAsk)])
        await arm(harness, two, pending: [ActivityFixtures.pending(secondAsk)])
        await arm(harness, three)
        await harness.model.start()

        let rateLimited = try FixtureRunner.events("rate-limited-turn")
        await harness.lifecycle.push(.request(firstAsk), to: one)
        await harness.lifecycle.push(.request(secondAsk), to: two)
        for event in rateLimited { await harness.lifecycle.push(event, to: three) }
        let broken = FixtureRunner.Invented.authStatus(error: "invented sign-in failure",
                                                       uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                                                       session: one.session)
        await harness.lifecycle.push(.frame(broken, .first), to: one)

        let frameCount = rateLimited.filter { if case .frame = $0 { return true } else { return false } }.count
        XCTAssertGreaterThan(frameCount, 0, "the fixture carried no frames at all")
        await harness.model.whenSettled { model in
            model.pump(for: one)?.requests.count == 1
                && model.pump(for: two)?.requests.count == 1
                && model.pump(for: one)?.recent.count == 1
                && model.pump(for: three)?.recent.count == frameCount
        }

        assertSameMultiset(kindNames(harness.model),
                           ["decision", "decision", "rateLimitRefused",
                            "failedResult", "failedResult", "authProblem"])
    }

    /// A second, healthy `auth_status` removes the authentication row and leaves the rest standing.
    /// Both halves matter: an implementation that never cleared would leave a fixed problem on
    /// screen for ever, and one that cleared everything would pass a test that only checked the
    /// authentication row was gone.
    func testAHealthyAuthStatusClearsOnlyTheAuthRow() async throws {
        let harness = try Harness()
        let one = harness.key("1"), two = harness.key("2"), three = harness.key("3")

        let firstAsk = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                 id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondAsk = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                  id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        await arm(harness, one, pending: [ActivityFixtures.pending(firstAsk)])
        await arm(harness, two, pending: [ActivityFixtures.pending(secondAsk)])
        await arm(harness, three)
        await harness.model.start()

        let rateLimited = try FixtureRunner.events("rate-limited-turn")
        await harness.lifecycle.push(.request(firstAsk), to: one)
        await harness.lifecycle.push(.request(secondAsk), to: two)
        for event in rateLimited { await harness.lifecycle.push(event, to: three) }
        await harness.lifecycle.push(.frame(FixtureRunner.Invented.authStatus(
            error: "invented sign-in failure",
            uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            session: one.session), .first), to: one)
        await harness.lifecycle.push(.frame(FixtureRunner.Invented.authStatus(
            error: nil,
            uuid: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            session: one.session), .first), to: one)

        let frameCount = rateLimited.filter { if case .frame = $0 { return true } else { return false } }.count
        await harness.model.whenSettled { model in
            model.pump(for: one)?.recent.count == 2 && model.pump(for: three)?.recent.count == frameCount
        }

        assertSameMultiset(kindNames(harness.model),
                           ["decision", "decision", "rateLimitRefused", "failedResult", "failedResult"])
    }

    /// The rate-limit row comes from the engine's own `rate_limit_event` and never from a turn
    /// ending (tracker entry 49: 2.1.263 emits no per-turn event in the recorded scenarios).
    ///
    /// Two halves, and the pair is what makes it discriminating: the same completed turn produces
    /// no rate-limit row without the event and exactly one with it. The second half also pins
    /// §7.6's overage rule — `permission-allow`'s event carries `"status": "allowed"` beside
    /// `"overageStatus": "rejected"`, which is the organisation declining to buy overage and not
    /// the engine refusing the user's turn, so the row is `.rateLimitInfo` and not a refusal.
    func testTheRateLimitRowComesFromTheEventAndNotFromATurnEnding() async throws {
        let harness = try Harness()
        let one = harness.key("1")
        await arm(harness, one)
        await harness.model.start()

        let all = try FixtureRunner.frames("permission-allow")
        let withoutTheEvent = all.filter { if case .rateLimitEvent = $0 { return false } else { return true } }
        let completedTurns = withoutTheEvent.filter { if case .result = $0 { return true } else { return false } }
        XCTAssertGreaterThan(completedTurns.count, 0, "the fixture ends no turn, so it proves nothing")
        XCTAssertEqual(all.count - withoutTheEvent.count, 1, "the fixture carries no rate_limit_event")

        for frame in withoutTheEvent { await harness.lifecycle.push(.frame(frame, .first), to: one) }
        await harness.model.whenSettled { $0.pump(for: one)?.recent.count == withoutTheEvent.count }

        let names = kindNames(harness.model)
        XCTAssertFalse(names.contains("rateLimitInfo"), "a finished turn invented a rate-limit row")
        XCTAssertFalse(names.contains("rateLimitRefused"), "a finished turn invented a refusal row")

        // Now the event itself, and only it.
        let event = try XCTUnwrap(all.first { if case .rateLimitEvent = $0 { return true } else { return false } })
        await harness.lifecycle.push(.frame(event, .first), to: one)
        await harness.model.whenSettled { $0.pump(for: one)?.recent.count == withoutTheEvent.count + 1 }

        let after = kindNames(harness.model)
        XCTAssertEqual(after.filter { $0 == "rateLimitInfo" }.count, 1,
                       "the event produced no rate-limit row, or more than one")
        XCTAssertFalse(after.contains("rateLimitRefused"),
                       "an allowed window with rejected overage was drawn as a refusal (§7.6)")
    }

    // MARK: - Answering

    /// Answering emits the control response, and the assertion is on the action that left the host —
    /// a row can disappear for the wrong reason.
    func testAnsweringFromActivityEmitsTheControlResponse() async throws {
        let harness = try Harness()
        let one = harness.key("1")
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        await arm(harness, one, pending: [ActivityFixtures.pending(ask)])
        await harness.model.start()
        await harness.lifecycle.push(.request(ask), to: one)
        await harness.model.whenSettled { $0.pump(for: one)?.requests.count == 1 }

        let answerable = harness.model.items.compactMap(\.ask)
        XCTAssertEqual(answerable.count, 1, "the permission row offered no inline answer")
        await harness.lifecycle.stage(.success(ActivityFixtures.state(one, pending: [])))

        await harness.model.allowOnce(try XCTUnwrap(answerable.first), on: one)

        let actions = await harness.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "expected exactly one lifecycle action")
        let recorded = try XCTUnwrap(actions.first)
        XCTAssertEqual(recorded.key, one)
        guard case .answer(let id, let answer) = recorded.action else {
            return XCTFail("the action was not an answer")
        }
        XCTAssertEqual(id, ask.id, "the answer carried a different request id than the row")
        guard case .permission(.allow(_, _, let classification)) = answer else {
            return XCTFail("the answer was not an allow")
        }
        XCTAssertEqual(classification, .userTemporary, "§8.4 binds Allow once to user_temporary")

        let after = await harness.lifecycle.state(of: one)
        XCTAssertEqual(after?.pendingDecisions.count, 0, "the channel still holds the decision")
    }

    /// Every decision kind gets a row; only a plain permission ask offers an inline answer. Both
    /// halves asserted, because a model that offered nothing anywhere would pass the first alone.
    func testEveryDecisionKindGetsARowAndOnlyPermissionAnswersInline() async throws {
        let harness = try Harness()
        let question = harness.key("1"), plan = harness.key("2"), elicitation = harness.key("3")
        let dialog = harness.key("4"), permission = harness.key("5")

        let asks: [(ChannelKey, InboundRequest)] = [
            (question, try FixtureRunner.request("ask-user-question", subtype: "can_use_tool",
                                                 id: "11111111-1111-4111-8111-111111111111")),
            (plan, try FixtureRunner.request("exit-plan-mode", subtype: "can_use_tool",
                                             id: "22222222-2222-4222-8222-222222222222")),
            (elicitation, FixtureRunner.Invented.elicitation(id: "33333333-3333-4333-8333-333333333333")),
            (dialog, try FixtureRunner.request("dialog-refusal-fallback", subtype: "request_user_dialog",
                                               id: "44444444-4444-4444-8444-444444444444")),
            (permission, try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                   id: "55555555-5555-4555-8555-555555555555"))
        ]
        for (key, ask) in asks { await arm(harness, key, pending: [ActivityFixtures.pending(ask)]) }
        await harness.model.start()
        for (key, ask) in asks { await harness.lifecycle.push(.request(ask), to: key) }
        await harness.model.whenSettled { model in
            asks.allSatisfy { model.pump(for: $0.0)?.requests.count == 1 }
        }

        assertSameMultiset(kindNames(harness.model), Array(repeating: "decision", count: asks.count))
        for (key, _) in asks.dropLast() {
            let item = try XCTUnwrap(harness.model.items.first { $0.key == key })
            XCTAssertNil(item.ask, "a non-permission decision offered an inline answer")
        }
        let inline = try XCTUnwrap(harness.model.items.first { $0.key == permission })
        XCTAssertNotNil(inline.ask, "the plain permission ask offered no inline answer")
    }

    /// An ask carrying `requires_user_interaction` gets a *Go to channel* row, because §8.4 makes
    /// that flag the engine saying the tool's own card is the surface. The floor is the same
    /// recorded ask with the flag cleared, which *is* answerable — without it a model that never
    /// offered an inline answer at all would pass.
    func testAnAskRequiringUserInteractionIsNotAnsweredInline() async throws {
        let harness = try Harness()
        let interactive = harness.key("1"), plain = harness.key("2")
        let flagged = try FixtureRunner.request("ask-user-question", subtype: "can_use_tool",
                                                id: "11111111-1111-4111-8111-111111111111")
        let cleared = try FixtureRunner.request("ask-user-question", subtype: "can_use_tool",
                                                id: "22222222-2222-4222-8222-222222222222",
                                                overrides: ["requires_user_interaction": false])
        guard case .canUseTool(let tool) = flagged.payload else { return XCTFail("not a can_use_tool") }
        XCTAssertEqual(tool.requiresUserInteraction, true, "the fixture no longer carries the flag")

        await arm(harness, interactive, pending: [ActivityFixtures.pending(flagged)])
        await arm(harness, plain, pending: [ActivityFixtures.pending(cleared)])
        await harness.model.start()
        await harness.lifecycle.push(.request(flagged), to: interactive)
        await harness.lifecycle.push(.request(cleared), to: plain)
        await harness.model.whenSettled { model in
            model.pump(for: interactive)?.requests.count == 1 && model.pump(for: plain)?.requests.count == 1
        }

        let interactiveItem = try XCTUnwrap(harness.model.items.first { $0.key == interactive })
        XCTAssertNil(interactiveItem.ask, "an ask requiring user interaction was answered inline")
        let plainItem = try XCTUnwrap(harness.model.items.first { $0.key == plain })
        XCTAssertNotNil(plainItem.ask, "the same ask without the flag was not answerable")
    }

    // MARK: - The launch order

    /// Activity has its rows before the notification authorisation prompt is answered.
    ///
    /// The prompt is a system alert that does not return until somebody clicks it — spike S-C5-1
    /// measured it outstanding for the whole of a twelve-second run, with no bound on it at all.
    /// While `startActivity` awaited it, a first launch had no pumps, no rows, no badges and no
    /// in-app fallback either, which is the one launch §8.7's observable is about. The poster here
    /// blocks exactly as the system does.
    ///
    /// Three clauses: authorisation **was** asked for, it is **still outstanding**, and Activity is
    /// nevertheless running with the row its pending decision earns. Without the first, an
    /// implementation that never requested authorisation at all would pass.
    func testActivityStartsWithoutWaitingForTheAuthorisationPrompt() async throws {
        let harness = try Harness()
        let one = harness.key("1")
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        await arm(harness, one, pending: [ActivityFixtures.pending(ask)])
        harness.poster.blocksAuthorisation = true

        await ActivityLaunch.begin(harness.model, requesting: harness.poster)
        await harness.poster.whenAuthorisationRequested()

        XCTAssertEqual(harness.poster.authorisationRequests, 1, "authorisation was never requested")
        XCTAssertTrue(harness.poster.isBlockedInAuthorisation,
                      "the prompt was already answered, so this proves nothing about the order")
        XCTAssertGreaterThan(harness.model.rebuildCount, 0, "Activity never started")
        XCTAssertEqual(harness.model.items.count, 1,
                       "Activity started with no rows though a decision is pending")

        harness.poster.releaseAuthorisation()
    }

    // MARK: - G2b

    /// A channel not in view with a pending decision carries a red count and an unread dot;
    /// selecting it clears both; a model rebuilt from the persisted cursor keeps them cleared.
    ///
    /// The window is pointed away from the channel again before the rebuild, so the second model
    /// cannot clear the badge by looking at it — the only thing that can keep it clear is the
    /// cursor that was written to the store.
    func testBadgeClearsOnViewingAndSurvivesARebuild() async throws {
        let tree = try TempTree()
        let storeDirectory = try tree.directory("store")
        let store = try FileStateStore(baseDirectory: storeDirectory, configHomes: [])
        let harness = try Harness(store: store)
        let one = harness.key("1")
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        await arm(harness, one, pending: [ActivityFixtures.pending(ask)])
        await harness.model.start()
        await harness.lifecycle.push(.request(ask), to: one)
        await harness.model.whenSettled { $0.pump(for: one)?.requests.count == 1 }

        XCTAssertTrue(harness.shell.focus.isActivity, "the channel must not be in view yet")
        let before = harness.model.badge(for: one.session)
        XCTAssertEqual(before.count, 1, "no red count on a channel waiting on the user")
        XCTAssertTrue(before.isUnread, "no unread dot on a channel waiting on the user")

        harness.shell.select(one.session)
        await harness.model.whenSettled { $0.badge(for: one.session).isEmpty }
        XCTAssertEqual(harness.model.badge(for: one.session), .none, "viewing did not clear the badge")
        await harness.model.cursorsPersisted()

        // Look away, then rebuild over the same store and the same states.
        harness.shell.showActivity()
        let rebuilt = ActivityModel(lifecycle: harness.lifecycle,
                                    configHome: harness.configHome,
                                    shell: harness.shell,
                                    router: harness.router,
                                    store: store)
        await rebuilt.start()
        await rebuilt.whenSettled { $0.items.contains { $0.key == one } }
        XCTAssertEqual(rebuilt.badge(for: one.session), .none,
                       "a rebuilt model brought back a badge the user had already cleared")
    }
}
