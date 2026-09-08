import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G3: Activity renders the card component and constructs no card, no action and no answer of its
/// own (contract Y2, spec D4).
///
/// The first clause is a **source-graph** assertion, because that is what Y2 constrains: a
/// behavioural test would pass against two implementations that happened to agree today. The second
/// is behavioural and byte-level. The third is C5's human-gate ruling 4, re-asserted after the
/// adoption in both directions.
@MainActor
final class ActivityCardAdoptionTests: XCTestCase {

    // MARK: - The harness

    @MainActor
    private final class Harness {
        let tree: TempTree
        let configHome: URL
        let lifecycle = LifecycleDouble()
        let shell = ShellModel()
        let poster = RecordingPoster()
        let router: NotificationRouter
        let model: ActivityModel

        init() throws {
            tree = try TempTree()
            configHome = try tree.directory("config-home")
            let shell = self.shell
            shell.isApplicationActive = true
            router = NotificationRouter(poster: poster,
                                        lifecycle: lifecycle,
                                        isInView: { key in shell.isInView(key) },
                                        preferences: { NotificationPreferences() })
            model = ActivityModel(lifecycle: lifecycle,
                                  configHome: configHome,
                                  shell: shell,
                                  router: router,
                                  store: nil)
        }

        func key(_ nibble: String) -> ChannelKey { ActivityFixtures.key(nibble, configHome: configHome) }

        func arm(_ keys: [(ChannelKey, InboundRequest)]) async {
            await lifecycle.setStates(keys.map { ActivityFixtures.state($0.0, pending: [ActivityFixtures.pending($0.1)]) })
            for (key, _) in keys { await lifecycle.openEvents(of: key) }
        }
    }

    // MARK: - Reading the source graph

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App")
    }

    /// Every Swift source under a directory, with comments dropped, so a sentence about a button is
    /// not read as a button.
    private func sources(under directory: String) throws -> [(name: String, code: String)] {
        let root = Self.appRoot.appending(path: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { name in
            let text = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (name, code)
        }
    }

    /// G3a: no card view is declared under `App/Activity/`, and nothing there builds an answer.
    ///
    /// Stated as a static check because Y2 constrains the source. The floor is the last clause: the
    /// directory must actually reach the shared component, so a sweep over an empty or renamed
    /// directory cannot pass.
    func testActivityConstructsNoCardOfItsOwn() throws {
        let activity = try sources(under: "Activity")
        XCTAssertGreaterThan(activity.count, 0, "no source was found under Activity")

        for (name, code) in activity {
            XCTAssertFalse(code.contains(": View"),
                           "a view type is declared beside Activity's model in \(name)")
            XCTAssertFalse(code.contains("func allowOnce"), "\(name) declares an allow body of its own")
            XCTAssertFalse(code.contains("func deny"), "\(name) declares a deny body of its own")
            XCTAssertFalse(code.contains("InboundAnswer"), "\(name) names an answer type of its own")
            XCTAssertFalse(code.contains(".permission(.allow"), "\(name) builds an allow of its own")
            XCTAssertFalse(code.contains(".permission(.deny"), "\(name) builds a deny of its own")
            XCTAssertFalse(code.contains("classification:"), "\(name) classifies a decision of its own")
        }
        XCTAssertTrue(activity.contains { $0.code.contains("DecisionAnswering") },
                      "Activity reaches no shared answering object, so nothing was adopted")

        // The row view lives beside the other columns, and the same rule holds for it: it hosts the
        // component and builds neither a card nor an answer.
        let row = try XCTUnwrap(try sources(under: "Views").first { $0.name == "ActivityView.swift" },
                                "Activity's view is no longer where the check looks")
        XCTAssertTrue(row.code.contains("DecisionCardView"), "Activity's row hosts no card component")
        XCTAssertFalse(row.code.contains("InboundAnswer"), "Activity's row names an answer type")
        XCTAssertFalse(row.code.contains(".permission(.allow"), "Activity's row builds an allow")
        XCTAssertFalse(row.code.contains(".permission(.deny"), "Activity's row builds a deny")
    }

    // MARK: - The same request, from either host

    /// G3b: one request, answered from Activity's compact row and from the timeline's full card,
    /// produces the **byte-identical** answer. The presentation changes the layout and nothing else.
    func testTheSameRequestAnsweredFromEitherHostProducesTheSameAnswer() async throws {
        for label in ["Allow once", "Always allow", "Deny"] {
            // Activity's host: its own row, its own model, and the answering object the model holds.
            let harness = try Harness()
            let key = harness.key("1")
            let request = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab2")
            let item = try XCTUnwrap(DecisionItem(surfacing: request, in: key), "no item was opened")
            let card = DecisionCard(item)
            await harness.lifecycle.always(.success(ActivityFixtures.state(key)))

            let row = ActivityRowView(item: ActivityItem(row: ActivityRow(key: key,
                                                                          kind: .decision(request.id),
                                                                          text: "can_use_tool"),
                                                         card: card, position: 0),
                                      title: "An invented channel",
                                      activity: harness.model,
                                      shell: harness.shell)
            let compact = try XCTUnwrap(CardTree.permissionBody(in: row.body),
                                        "Activity's row drew no permission card")
            try press(label, in: compact)
            await harness.model.answering.whenIdle()
            let fromActivity = try bytes(of: await harness.lifecycle.actions, card, label)

            // The timeline's host: the same card, in the full presentation, over its own double.
            let lifecycle = LifecycleDouble()
            await lifecycle.always(.success(ActivityFixtures.state(key)))
            let answering = DecisionAnswering(lifecycle: lifecycle)
            let full = try XCTUnwrap(CardTree.permissionBody(in: DecisionCardView(card: card,
                                                                                  presentation: .full,
                                                                                  in: key,
                                                                                  answering: answering).body),
                                     "the full card drew no permission card")
            try press(label, in: full)
            await answering.whenIdle()
            let fromTimeline = try bytes(of: await lifecycle.actions, card, label)

            XCTAssertTrue(fromActivity == fromTimeline,
                          "the two hosts sent different bytes for \(label)")
        }
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "no \(label) button was drawn")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    /// The one answer a double received, as the bytes the transport would write.
    private func bytes(of actions: [(key: ChannelKey, action: LifecycleAction)],
                       _ card: DecisionCard, _ label: String) throws -> Data {
        XCTAssertEqual(actions.count, 1, "one press on \(label) produced \(actions.count) actions")
        guard case .answer(let id, let answer)? = actions.first?.action else {
            XCTFail("the action \(label) emitted was not an answer")
            return Data()
        }
        XCTAssertTrue(id == card.requestID, "the \(label) answer carried a different request id")
        guard case .success(let success) = answer.controlResponse(for: id).body,
              let response = success.response else {
            XCTFail("the \(label) answer did not encode as a success body")
            return Data()
        }
        return try response.canonicalData()
    }

    // MARK: - Row identity

    /// sweep#2: a row's identity carries the **request**, not only its position.
    ///
    /// `ActivityItem.id` was the position alone, and the compact permission card holds `@State` —
    /// the destination an *Always allow* would be filed at. A List that reuses the row for a
    /// different request at the same position keeps that state, and the retained destination is
    /// then applied to the replacement request's rules. Two clauses, because either alone can be
    /// satisfied by an implementation that still reuses the card: the item's identity must move
    /// with the request, and the card itself must be keyed by the request it is drawing.
    func testARowsIdentityMovesWithTheRequestItDraws() async throws {
        let harness = try Harness()
        let key = harness.key("1")
        await harness.lifecycle.always(.success(ActivityFixtures.state(key)))

        func item(_ id: String, at position: Int) throws -> ActivityItem {
            let request = try FixtureRunner.request("permission-allow", subtype: "can_use_tool", id: id)
            let decision = try XCTUnwrap(DecisionItem(surfacing: request, in: key), "no item was opened")
            return ActivityItem(row: ActivityRow(key: key, kind: .decision(request.id), text: "can_use_tool"),
                                card: DecisionCard(decision), position: position)
        }

        let first = try item("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaac01", at: 0)
        let second = try item("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaac02", at: 0)
        XCTAssertNotEqual(first.id, second.id,
                          "two different requests drawn at one position share a row identity")

        let row = ActivityRowView(item: second, title: "An invented channel",
                                  activity: harness.model, shell: harness.shell)
        let requestID = try XCTUnwrap(second.card?.requestID.rawValue, "the row drew no card to key")
        XCTAssertTrue(Self.explicitIdentities(in: row.body).contains(requestID),
                      "the row hosts a stateful card that is not keyed by the request it draws")
    }

    /// Every identity a body pins with `.id(_:)`, read from the view value SwiftUI built.
    ///
    /// `.id(_:)` wraps its content in a generic whose stored `id` is the value passed. Reflecting
    /// for it is how a test sees an identity that a rendered hierarchy would otherwise only show by
    /// behaviour — and the identity is exactly what stops `@State` from being carried onto a
    /// different request.
    private static func explicitIdentities(in value: Any) -> [String] {
        let mirror = Mirror(reflecting: value)
        var found: [String] = []
        if String(describing: mirror.subjectType).hasPrefix("IDView<"),
           let id = mirror.descendant("id") as? String {
            found.append(id)
        }
        for child in mirror.children { found += explicitIdentities(in: child.value) }
        return found
    }

    // MARK: - C5's ruling, after the adoption

    /// G3c: every decision kind still gets a row, and only a plain permission ask answers inline.
    /// Both directions, because a model that answered nothing inline would pass the first alone.
    func testEveryDecisionKindStillGetsARowAndOnlyPermissionAnswersInline() async throws {
        let harness = try Harness()
        let question = harness.key("1"), plan = harness.key("2"), elicitation = harness.key("3")
        let dialog = harness.key("4"), permission = harness.key("5")

        let asks: [(ChannelKey, InboundRequest)] = [
            (question, try FixtureRunner.request("ask-user-question", subtype: "can_use_tool",
                                                 id: "11111111-1111-4111-8111-11111111111a")),
            (plan, try FixtureRunner.request("exit-plan-mode", subtype: "can_use_tool",
                                             id: "22222222-2222-4222-8222-22222222222a")),
            (elicitation, FixtureRunner.Invented.elicitation(id: "33333333-3333-4333-8333-33333333333a")),
            (dialog, try FixtureRunner.request("dialog-refusal-fallback", subtype: "request_user_dialog",
                                               id: "44444444-4444-4444-8444-44444444444a")),
            (permission, try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                                   id: "55555555-5555-4555-8555-55555555555a"))
        ]
        await harness.arm(asks)
        await harness.model.start()
        for (key, ask) in asks { await harness.lifecycle.push(.request(ask), to: key) }
        await harness.model.whenSettled { model in
            asks.allSatisfy { model.pump(for: $0.0)?.requests.count == 1 }
        }

        XCTAssertEqual(harness.model.items.count, asks.count,
                       "\(harness.model.items.count) rows for \(asks.count) decisions")
        for (key, _) in asks.dropLast() {
            let item = try XCTUnwrap(harness.model.items.first { $0.key == key }, "a decision lost its row")
            XCTAssertNil(item.card, "a non-permission decision offered an inline answer")
            let body = ActivityRowView(item: item, title: "An invented channel",
                                       activity: harness.model, shell: harness.shell).body
            XCTAssertNotNil(ViewTree.button("Go to channel", in: body),
                            "a non-permission decision lost its way into the channel")
            XCTAssertNil(CardTree.permissionBody(in: body), "a non-permission row drew a permission card")
        }

        let inline = try XCTUnwrap(harness.model.items.first { $0.key == permission },
                                   "the permission ask lost its row")
        XCTAssertNotNil(inline.card, "the plain permission ask offered no inline answer")
        let body = ActivityRowView(item: inline, title: "An invented channel",
                                   activity: harness.model, shell: harness.shell).body
        XCTAssertNil(ViewTree.button("Go to channel", in: body),
                     "the answerable row also offered a way out instead of an answer")
        let card = try XCTUnwrap(CardTree.permissionBody(in: body), "the answerable row drew no card")
        XCTAssertNotNil(ViewTree.button("Allow once", in: card), "the answerable row lost Allow once")
        XCTAssertNotNil(ViewTree.button("Deny", in: card), "the answerable row lost Deny")
    }
}
