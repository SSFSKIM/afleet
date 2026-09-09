import Foundation
import SwiftUI
import FleetKit

// MARK: - What a row asks of the channel's composer

/// Contract Y6 — the three things the composer owns whose only surface is a row of this leaf
/// (child spec §14, gate G6).
///
/// **A protocol and not `ComposerModel` itself**, for the reason every other capability on the
/// render context is one: the rows are asserted by walking a constructed body, and a test that had
/// to build a real composer would need an X5 double, an event subscription and a workspace to reach
/// a button. It is also the honest dependency — the row needs three members, not a composer.
///
/// The conformance is declared here rather than beside the model: `App/Composer/` is another leaf's,
/// and a retroactive conformance in this file is what keeps the seam entirely inside `App/Timeline/`.
@MainActor
protocol ComposerSite: AnyObject {

    /// Site 1. *Edit* on a past user message, and the row stops there: the `rewind_conversation`
    /// carrying `last_seen_user_message_uuid`, the refusal read from the body rather than the
    /// envelope, and the *Fork from here* fallback are all the composer's.
    func edit(_ target: UserMessageItem) async

    /// Site 2. What *Edit* has to say about a rewind that did not happen — the fork it opened
    /// instead, or why it could offer none. Nil whenever nothing is being said.
    var editNote: String? { get }

    /// Site 3. The replacement for each assistant message this channel's interceptor caught, keyed
    /// by the frame's own uuid.
    var interceptedReplacements: [String: String] { get }
}

extension ComposerModel: ComposerSite {}

// MARK: - Which message the note belongs to

/// Which rendered user message this channel's *Edit* was last pressed on.
///
/// The note is one value on the composer and the timeline holds many user messages, so without this
/// the row has no way to say *which* message the fork was made from — and a note drawn beside every
/// message says the composer forked from all of them. The composer records no target (it has no
/// reason to; its own surface is a single line above the field), and asking it to would be an edit
/// to another leaf's file, so the row records what the row itself did.
///
/// A reference type shared by every row of one channel, for `TimelineCollapseState`'s reason: the
/// row value that pressed the button is discarded long before the refusal comes back.
///
/// **Keyed by `ItemID.key` and never by the `ItemID`** — the id carries the config home (§11).
@MainActor
@Observable
final class TimelineEditState {

    /// The key of the message *Edit* was last pressed on, or nil before any press.
    private(set) var editedKey: String?

    func note(edited id: ItemID) { editedKey = id.key }
}

// MARK: - The three sites, as answers a test can ask

/// The reads the two message rows make of the composer, named rather than buried in a body.
///
/// Each is a function over the context because that is how every other capability in this renderer
/// is asserted (`AgentChip.content(for:in:)`, `ThinkingDisclosure.summary(of:in:)`): an environment
/// value is not populated in a constructed view, so a decision spelled inline in `body` is a
/// decision no test can reach.
@MainActor
enum ComposerSites {

    /// The note that belongs beside `item`, or nil — for a channel with no composer, for a message
    /// that is not the one edited, and for an edit that has nothing to say.
    static func note(for item: UserMessageItem, in context: TimelineRenderContext?) -> String? {
        guard let context, context.editing.editedKey == item.id.key else { return nil }
        return context.composer?.editNote
    }

    /// The text an assistant row draws: **the replacement in place of the frame's own text** when
    /// this channel's interceptor caught it, and the frame's own text otherwise.
    ///
    /// **A substitution and not an annotation, and that is the whole point.** Root spec §7.7 has
    /// afleet intercept the engine's `/<name> isn't available in this environment.` refusal and
    /// *replace* it; drawing the replacement beside the original leaves the refusal on screen
    /// telling the user to go to the terminal, which §7.7 forbids in as many words. So this returns
    /// one string and there is no shape of this function that can return both.
    static func text(of item: AssistantMessageItem, in context: TimelineRenderContext?) -> String {
        let own = MessageText.text(of: item.blocks, fallback: "")
        guard let replacements = context?.composer?.interceptedReplacements, !replacements.isEmpty else { return own }
        for uuid in frameUUIDs(of: item) where replacements[uuid] != nil {
            return replacements[uuid] ?? own
        }
        return own
    }

    /// The uuids the interceptor could have keyed a replacement under.
    ///
    /// `ComposerModel` keys by `AssistantFrame.fields.uuid` — one **record** — while `ItemBuilder`
    /// merges an assistant message's records into one item keyed by the first of them and keeps them
    /// all in `recordUUIDs`. So every record of the item is a candidate, and the item's own key is
    /// the answer only for an item that carries no record list at all.
    static func frameUUIDs(of item: AssistantMessageItem) -> [String] {
        item.recordUUIDs.isEmpty ? [item.id.key] : item.recordUUIDs
    }
}
