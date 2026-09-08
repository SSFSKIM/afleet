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
