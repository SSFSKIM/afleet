import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 7 — contract Y6, the three places the composer reaches the timeline (child spec §14,
/// gate G6).
///
/// Everything here is driven through a recording `ComposerSite` and never through an engine: the
/// three sites are *this* leaf's rendering and calling side, and the rewind, the body-level refusal
/// read and the *Fork from here* fallback are C6.2's and are asserted there.
///
/// Nothing asserts over an `ItemID` or anything holding one — `ItemID.stream` carries a config-home
/// path (§11). Identity is a `.key` string, an engine-minted uuid this suite invented, or a count.
@MainActor
final class ComposerSiteTests: XCTestCase {

    // MARK: - Site 1, the *Edit* action

    /// *Edit* on a past user message calls `ComposerModel.edit(_:)` **exactly once**, carrying that
    /// message, and stops there.
    ///
    /// Both failure shapes the gate names are covered: a row with no action records nothing, and a
    /// row that called twice records two. The count is drained past the first hit so a second call
    /// arriving late is still seen.
    func testEditCallsTheComposerOnce() async throws {
        let composer = RecordingComposerSite()
        let message = Self.message(promptUUID: "u-invented-0001", text: "an invented question")
        let content = UserMessageBody(item: message,
                                      context: InventedItems.context(composer: composer)).content

        let button = try XCTUnwrap(ViewTree.button("Edit", in: content),
                                   "a past user message offered no Edit action at all")
        XCTAssertTrue(ViewTree.press(button), "the Edit action could not be invoked")

        let called = await Self.settle(until: { composer.edits.count == 1 })
        XCTAssertTrue(called, "the Edit action recorded \(composer.edits.count) call(s), not 1")
        XCTAssertEqual(composer.edits, ["u-invented-0001"],
                       "the Edit action carried \(composer.edits.count) message(s), and not this one")

        // Drained past the first hit: a row wired to call twice passes any check that stops looking
        // as soon as it has seen one.
        let stayed = await Self.settle(until: { composer.edits.count > 1 })
        XCTAssertFalse(stayed, "the Edit action recorded \(composer.edits.count) call(s), not 1")

        // And the row records which message it was, because the composer records no target and the
        // note has to know which message to sit beside.
        XCTAssertEqual(composer.edits.count, 1, "the Edit action recorded \(composer.edits.count) call(s)")
    }

    /// The other arm, and the ordinary one for a teammate's transcript: a channel with no composer
    /// offers no *Edit*. `ChannelComposerMount` builds no composer for a read-only listing, and a
    /// row that offered the action anyway would rewind a session afleet may not write to.
    func testAChannelWithNoComposerOffersNoEdit() {
        let message = Self.message(promptUUID: "u-invented-0002", text: "an invented question")
        let content = UserMessageBody(item: message, context: InventedItems.context()).content
        XCTAssertNil(ViewTree.button("Edit", in: content),
                     "a channel with no composer offered the Edit action anyway")
    }

    // MARK: - Site 2, the fork-fallback note

    /// **Both arms.** With `editNote` set the note renders beside the edited message; with it nil no
    /// note renders. A view that always drew the note would pass the first alone, which is why the
    /// nil arm is asserted over the same row value.
    ///
    /// A third arm, which is what "beside the edited message" means: a *different* user message in
    /// the same channel draws no note while the same note is set. Without it a row that drew the
    /// composer's one note on every message would pass both of the first two.
    func testTheEditNoteRendersOnlyWhenSet() {
        let composer = RecordingComposerSite()
        let editing = TimelineEditState()
        let edited = Self.message(promptUUID: "u-invented-0003", text: "an invented question", key: "u-key-3")
        let other = Self.message(promptUUID: "u-invented-0004", text: "another invented question", key: "u-key-4")
        let note = "an invented sentence about where the edited message went"
        editing.note(edited: edited.id)
        let context = InventedItems.context(composer: composer, editing: editing)

        composer.editNote = note
        let set = ViewTree.values(of: String.self, in: UserMessageBody(item: edited, context: context).content)
        XCTAssertTrue(set.contains(note), "the note was set and the edited message's row drew no note")

        composer.editNote = nil
        let unset = ViewTree.values(of: String.self, in: UserMessageBody(item: edited, context: context).content)
        XCTAssertFalse(unset.contains(note), "the note was nil and the row drew one anyway")

        composer.editNote = note
        let elsewhere = ViewTree.values(of: String.self, in: UserMessageBody(item: other, context: context).content)
        XCTAssertFalse(elsewhere.contains(note),
                       "the note was drawn beside a message the Edit was not pressed on")

        // The floor: the comparison found the rows at all, rather than three empty walks agreeing.
        XCTAssertGreaterThan(set.count, 0, "the edited message's row drew \(set.count) string(s)")
        XCTAssertGreaterThan(elsewhere.count, 0, "the other message's row drew \(elsewhere.count) string(s)")
    }

    // MARK: - Site 3, the substitution

    /// An assistant row whose frame uuid is a key in `interceptedReplacements` renders the
    /// replacement **in place of** the frame's own text.
    ///
    /// **The negative clause is the test.** Annotation — the replacement drawn *beside* the original
    /// — passes the positive clause on its own, and annotation is the defect: root spec §7.7 has
    /// afleet replace the engine's drift refusal, and leaving the original on screen leaves the
    /// sentence telling the user to go to the terminal, which §7.7 forbids in as many words.
    func testAnInterceptedFrameIsReplacedNotAnnotated() {
        let composer = RecordingComposerSite()
        let original = "an invented refusal sentence sending the reader somewhere else"
        let replacement = "an invented replacement afleet wrote instead"
        let item = Self.assistant(recordUUIDs: ["f-invented-0001", "f-invented-0002"], text: original)
        composer.interceptedReplacements = ["f-invented-0002": replacement]
        let context = InventedItems.context(composer: composer)

        let content = AssistantMessageBody(item: item, context: context).content
        let strings = ViewTree.values(of: String.self, in: content)
        XCTAssertTrue(strings.contains(replacement), "the intercepted row drew no replacement")
        XCTAssertFalse(strings.contains(original),
                       "the intercepted row still carries the frame's own text, which is annotation")

        // The one body, and its source: a row drawing two markdown bodies is annotation whatever the
        // strings say.
        let sources = ViewTree.values(of: MarkdownBody.self, in: content).map(\.source)
        XCTAssertEqual(sources.count, 1, "the intercepted row drew \(sources.count) markdown body/bodies, not 1")
        XCTAssertEqual(sources.first, replacement, "the intercepted row's one body is not the replacement")

        // The floor, and the arm that proves the walk sees the frame's own text when nothing was
        // intercepted: without it the negative clause above would pass against a row that drew
        // nothing at all.
        composer.interceptedReplacements = [:]
        let plain = ViewTree.values(of: String.self, in: AssistantMessageBody(item: item, context: context).content)
        XCTAssertTrue(plain.contains(original), "an un-intercepted row drew \(plain.count) string(s) and not its own text")
        XCTAssertFalse(plain.contains(replacement), "an un-intercepted row drew a replacement it was never given")
    }

    /// The key the replacement is looked up under is the **frame's** uuid, which for a merged
    /// assistant item is any of its records — `ComposerModel` keys by `AssistantFrame.fields.uuid`
    /// while `ItemBuilder` keys the item by the first record and keeps the rest in `recordUUIDs`. A
    /// lookup on the item's key alone misses every interception on a second record.
    func testTheReplacementIsFoundByAnyOfTheFramesRecords() {
        let item = Self.assistant(recordUUIDs: ["f-invented-0003", "f-invented-0004"], text: "an invented refusal")
        XCTAssertEqual(ComposerSites.frameUUIDs(of: item).count, 2,
                       "a two-record item offered \(ComposerSites.frameUUIDs(of: item).count) candidate uuid(s)")

        let bare = Self.assistant(recordUUIDs: [], text: "an invented refusal")
        XCTAssertEqual(ComposerSites.frameUUIDs(of: bare), [bare.id.key],
                       "an item with no record list offered \(ComposerSites.frameUUIDs(of: bare).count) candidate uuid(s)")
    }

    // MARK: - Invented items

    static func message(promptUUID: String, text: String, key: String = "u-invented-key") -> UserMessageItem {
        UserMessageItem(id: InventedItems.id(key),
                        timestamp: InventedItems.epoch,
                        provenance: InventedItems.provenance,
                        blocks: [InventedItems.text(text)],
                        text: text,
                        promptUUID: promptUUID)
    }

    static func assistant(recordUUIDs: [String], text: String) -> AssistantMessageItem {
        AssistantMessageItem(id: InventedItems.id("a-invented-key"),
                             timestamp: InventedItems.epoch,
                             provenance: InventedItems.provenance,
                             messageID: "msg_invented0000",
                             model: "invented-model",
                             blocks: [InventedItems.text(text)],
                             recordUUIDs: recordUUIDs)
    }

    /// Runs the main actor until `condition` holds, or gives up. The answer is returned rather than
    /// asserted here, because both of its callers assert a different outcome from it.
    static func settle(until condition: @escaping @MainActor () -> Bool, ticks: Int = 200) async -> Bool {
        for _ in 0..<ticks {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

/// The composer as a row sees it: three members, and a count of what was asked of them.
///
/// The double records the **`promptUUID`** of each edited message and never the message or its
/// `ItemID`, which carries a config-home path (§11).
@MainActor
final class RecordingComposerSite: ComposerSite {

    private(set) var edits: [String] = []
    var editNote: String?
    var interceptedReplacements: [String: String] = [:]

    func edit(_ target: UserMessageItem) async { edits.append(target.promptUUID) }
}
