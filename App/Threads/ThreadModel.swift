import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI

/// One channel's Thread tab: the open thread, the half-written reply and the one seam either leaves
/// by (spec §7.5, D10; acceptance G2).
///
/// **This object is the `PanelTabSession` the host retains per (tab, channel)**, which is what makes
/// the open thread survive a channel switch: SwiftUI discards a subtree's `@State` when the subtree
/// unmounts, and a channel switch unmounts this one.
///
/// **What it does not build (D10).** The reply field is one line of text. There is no router, no
/// `@`, no `!`, no attachments and no slash handling: every one of those is C6.2's composer, and a
/// second one here would be the duplicate that seam was recorded to prevent. The three answerable
/// kinds do not even send text — a reply *is* the card's textual outcome, so it goes through the
/// same `DecisionCard.answer(_:)` the buttons go through.
///
/// **Who opens a thread.** Nothing inside this tab does: an anchor arrives from the surface the user
/// clicked — the timeline's tool row, its decision row, *Ask on the side* on a message — and those
/// affordances are C6.1's and C6.2's. This child ships the tab, the five kinds and every reply
/// behaviour; the call sites arrive with the leaves that own the rows.
@MainActor
@Observable
final class ThreadModel: PanelTabSession {

    let channel: ChannelKey

    /// X5. Every answer, every send and every control request in this tab goes through it.
    @ObservationIgnored private let lifecycle: any LifecycleAPI

    /// The one object a card's answer leaves by, shared with the card's own buttons so a reply and a
    /// click cannot answer one request two different ways (contract Y2).
    let answering: DecisionAnswering

    init(channel: ChannelKey, lifecycle: any LifecycleAPI) {
        self.channel = channel
        self.lifecycle = lifecycle
        self.answering = DecisionAnswering(lifecycle: lifecycle)
    }

}
