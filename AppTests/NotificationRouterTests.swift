import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G2c: which events become a notification, and the `Notification` hook route (spec §6, §8.7).
///
/// Asserted headlessly against `RecordingPoster`. Spike S-C5-1 measured that the system's own
/// centre reports a notification as delivered even when authorisation is denied and nobody was
/// shown anything, so what the system says is not evidence and is not asserted on; what the app
/// decides is, and that is what these four tests hold it to.
@MainActor
final class NotificationRouterTests: XCTestCase {

    @MainActor
    private final class PreferenceBox {
        var value = NotificationPreferences()
    }

    @MainActor
    private final class Harness {
        let tree: TempTree
        let configHome: URL
        let lifecycle = LifecycleDouble()
        let shell = ShellModel()
        let poster = RecordingPoster()
        let preferences = PreferenceBox()
        let router: NotificationRouter

        init() throws {
            tree = try TempTree()
            configHome = try tree.directory("config-home")
            let shell = self.shell, poster = self.poster
            let lifecycle = self.lifecycle, preferences = self.preferences
            router = NotificationRouter(poster: poster,
                                        lifecycle: lifecycle,
                                        isInView: { key in shell.focus.session == key.session },
                                        preferences: { preferences.value })
        }

        func key(_ nibble: String) -> ChannelKey { ActivityFixtures.key(nibble, configHome: configHome) }
    }

    // MARK: - G2c

    /// A decision in a channel not in view posts one notification; the same decision in the selected
    /// channel posts none. Both directions, because a router that never posted would pass the second
    /// alone and one that always posted would pass the first.
    func testNotificationOnlyForAChannelNotInView() async throws {
        let harness = try Harness()
        let away = harness.key("1"), watched = harness.key("2")
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

        harness.shell.select(watched.session)
        harness.router.handle(.request(ask), on: away)
        await harness.poster.whenPosted { !$0.isEmpty }
        XCTAssertEqual(harness.poster.count, 1, "a decision away from the window posted nothing")
        XCTAssertEqual(harness.poster.posted.first?.source, .decision)

        harness.router.handle(.request(ask), on: watched)
        // A non-event: there is nothing to be told by, so the assertion is that the count did not
        // move once the main actor has run everything the call could have scheduled.
        await Task.yield()
        XCTAssertEqual(harness.poster.count, 1, "the channel in view was notified about itself")
    }

    /// The `notification-hook` fixture's `hook_callback` for `afleet.notification` posts the hook
    /// input's own `message` **and** answers the engine with an empty continue.
    ///
    /// The answer clause is the discriminating one: a router that posts and forgets leaves the
    /// engine waiting for ever, and a test asserting only the notification would pass against it.
    func testHookCallbackPostsTheEnginesOwnTextAndIsAnswered() async throws {
        let harness = try Harness()
        let key = harness.key("1")
        await harness.lifecycle.always(.success(ActivityFixtures.state(key)))

        let events = try FixtureRunner.events("notification-hook")
        let hook = try XCTUnwrap(events.compactMap { event -> InboundRequest? in
            guard case .request(let request) = event,
                  case .hookCallback(let callback) = request.payload,
                  callback.callbackID == HookRoute.notification else { return nil }
            return request
        }.first, "the fixture surfaced no afleet.notification callback — the policy answered it")
        guard case .hookCallback(let callback) = hook.payload else { return XCTFail("not a hook callback") }
        let message = try XCTUnwrap(callback.input["message"]?.stringValue)
        XCTAssertFalse(message.isEmpty, "the fixture's hook input carries no message")

        harness.router.handle(.request(hook), on: key)
        await harness.poster.whenPosted { !$0.isEmpty }
        await harness.router.settle()

        XCTAssertEqual(harness.poster.count, 1)
        let posted = try XCTUnwrap(harness.poster.posted.first)
        XCTAssertEqual(posted.source, .engineHook)
        XCTAssertEqual(posted.body, message, "the body was not the engine's own text")

        let actions = await harness.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the engine was left waiting, or answered twice")
        let recorded = try XCTUnwrap(actions.first)
        XCTAssertTrue(recorded.key == key, "the answer was recorded against a different channel")
        guard case .answer(let id, let answer) = recorded.action else {
            return XCTFail("the action was not an answer")
        }
        XCTAssertEqual(id, hook.id)
        guard case .hookContinue(let output) = answer else { return XCTFail("not a hook continue") }
        XCTAssertEqual(output, .empty, "the continue carried fields the engine never asked for")
    }

    /// A completed turn notifies only when the channel is not in view, and not at all when the
    /// preference is off. Three clauses, because §8.7 names completed turns as one of its three
    /// sources and an implementation that never handled turns would pass every other G2 test.
    func testACompletedTurnNotifiesOnlyWhenTheChannelIsNotInView() async throws {
        let harness = try Harness()
        let away = harness.key("1"), watched = harness.key("2")
        let frames = try FixtureRunner.frames("permission-allow")
        let completed = try XCTUnwrap(frames.compactMap { frame -> Frame? in
            guard case .result(let result) = frame, !result.isError else { return nil }
            return frame
        }.first, "the fixture ends no turn successfully")

        harness.shell.select(watched.session)
        harness.router.handle(.frame(completed, .first), on: away)
        await harness.poster.whenPosted { !$0.isEmpty }
        XCTAssertEqual(harness.poster.count, 1, "a finished turn away from the window posted nothing")
        XCTAssertEqual(harness.poster.posted.first?.source, .turnCompleted)

        harness.router.handle(.frame(completed, .first), on: watched)
        await Task.yield()
        XCTAssertEqual(harness.poster.count, 1, "the channel in view was told its own turn finished")

        harness.poster.reset()
        harness.preferences.value = NotificationPreferences(turnCompleted: false)
        harness.router.handle(.frame(completed, .first), on: away)
        harness.router.handle(.frame(completed, .first), on: watched)
        await Task.yield()
        XCTAssertEqual(harness.poster.count, 0, "the completed-turn preference was ignored")
    }

    /// `afleet.config-change` is **registered**, and therefore surfaced to the app exactly as
    /// `afleet.notification` is — so it must be answered, or the engine blocks on it until its
    /// process dies. It is not a notification, so nothing is posted for it.
    ///
    /// Both clauses matter and the answer is the discriminating one: a router that dropped the
    /// callback silently would pass a test that only checked nothing was posted, which is how the
    /// hang survived the first pass over this file. The first assertion is the floor — it shows the
    /// inbound policy really does hand this id to the app rather than answering it itself, so the
    /// obligation the rest of the test is about is real.
    func testAConfigChangeCallbackIsAnsweredAndPostsNothing() async throws {
        let harness = try Harness()
        let key = harness.key("1")
        await harness.lifecycle.always(.success(ActivityFixtures.state(key)))

        let callback = FixtureRunner.Invented.hookCallback(
            id: "abababab-abab-4bab-8bab-abababababab",
            callbackID: HookRoute.configChange,
            message: "an invented settings change")
        let event = FixtureRunner.event(for: callback)
        guard case .request = event else {
            return XCTFail("the policy answered afleet.config-change itself; it is registered and must surface")
        }

        harness.router.handle(event, on: key)
        await harness.router.settle()

        let actions = await harness.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the engine was left waiting on a registered hook callback")
        let recorded = try XCTUnwrap(actions.first)
        XCTAssertTrue(recorded.key == key, "the answer was recorded against a different channel")
        guard case .answer(let id, let answer) = recorded.action else {
            return XCTFail("the action was not an answer")
        }
        XCTAssertEqual(id, callback.id)
        guard case .hookContinue(let output) = answer else { return XCTFail("not a hook continue") }
        XCTAssertEqual(output, .empty)
        XCTAssertEqual(harness.poster.count, 0, "a settings change was raised as a notification")
    }

    /// A `hook_callback` whose id afleet never registered is answered by `InboundPolicy` itself, so
    /// the router never sees a `.request` for it and posts nothing.
    ///
    /// The zero is asserted as a trace — the poster was not called — and it is paired with the same
    /// callback under the *registered* id, which does post. Without that floor a harness that
    /// delivered nothing at all would look like a correct refusal.
    func testAnUnregisteredHookIDIsNotSurfaced() async throws {
        let harness = try Harness()
        let key = harness.key("1")
        await harness.lifecycle.always(.success(ActivityFixtures.state(key)))

        let unregistered = FixtureRunner.Invented.hookCallback(
            id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            callbackID: "afleet.invented-unregistered",
            message: "an invented message nobody registered for")
        let policyEvent = FixtureRunner.event(for: unregistered)
        guard case .policyAnswered = policyEvent else {
            return XCTFail("the policy surfaced a callback id afleet never registered")
        }
        harness.router.handle(policyEvent, on: key)
        await Task.yield()
        XCTAssertEqual(harness.poster.count, 0, "an unregistered callback reached the user")
        let actions = await harness.lifecycle.actions
        XCTAssertEqual(actions.count, 0, "the router answered a request it was never handed")

        // The floor: the same shape under the registered id does post, so the zero above is a
        // refusal and not an inert harness.
        let registered = FixtureRunner.Invented.hookCallback(
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            callbackID: HookRoute.notification,
            message: "an invented message the engine did raise")
        harness.router.handle(FixtureRunner.event(for: registered), on: key)
        await harness.poster.whenPosted { !$0.isEmpty }
        await harness.router.settle()
        XCTAssertEqual(harness.poster.count, 1)
    }
}
