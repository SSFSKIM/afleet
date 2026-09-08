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

    // MARK: - Invented items

    static func message(promptUUID: String, text: String, key: String = "u-invented-key") -> UserMessageItem {
        UserMessageItem(id: InventedItems.id(key),
                        timestamp: InventedItems.epoch,
                        provenance: InventedItems.provenance,
                        blocks: [InventedItems.text(text)],
                        text: text,
                        promptUUID: promptUUID)
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
