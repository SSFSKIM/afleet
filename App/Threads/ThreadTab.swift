import Foundation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// Contract Y3: the panel tab that holds `.thread`, taken from C5's `PlaceholderTab` by
/// `unregister(.thread)` and then `register` (spec §7.5, acceptance G2).
///
/// **Why the handover runs at launch and not in `AppModel.init`.** `PanelHost.unregister(_:)` is
/// `async` on purpose — it *awaits* the link-target withdrawal, so a withdrawal landing after the
/// replacement's registration cannot delete the new tab's target — and an initialiser cannot await.
/// The composition root therefore keeps C5's placeholder as the first registration and hands `.thread`
/// over on the one path that is both asynchronous and runs once: the launch that reaches a workspace.
/// That is also the first moment a lifecycle exists, and this tab cannot answer a card or post a
/// reply without one, so the two constraints have the same answer.
///
/// The tab holds the lifecycle and nothing else. Per-channel state — which thread is open, what the
/// user has typed, a side question's accumulated history — lives in the `ThreadModel` the host
/// retains per (tab, channel), because SwiftUI discards `@State` when a channel switch unmounts the
/// subtree and a thread that vanished on a switch would not be a Slack-style thread at all.
@MainActor
final class ThreadTab: PanelTab {

    let id: PanelTabID = .thread
    var title: String { id.defaultTitle }
    var systemImage: String { id.defaultSystemImage }

    /// X5, the one seam every answer, send and control request in this tab leaves by.
    private let lifecycle: any LifecycleAPI

    init(lifecycle: any LifecycleAPI) {
        self.lifecycle = lifecycle
    }

    /// Available for every channel: every channel has messages, tools and decisions to open a
    /// thread on, and an empty thread tab reads *no thread open* rather than disappearing.
    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        ThreadModel(channel: context.key, lifecycle: lifecycle)
    }

    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let model = session as? ThreadModel else { return AnyView(EmptyView()) }
        return AnyView(ThreadView(model: model))
    }
}
