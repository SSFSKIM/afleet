import Foundation
import SwiftUI
import AfleetCore
import ClaudeWire
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

    /// How this tab reaches a channel's fold. See `ChannelFold`.
    private let fold: ChannelFold

    /// The app's one set of in-flight answer reservations, shared with Activity. See
    /// `DecisionReservations`.
    private let reservations: DecisionReservations

    init(lifecycle: any LifecycleAPI, fold: ChannelFold = ChannelFold(),
         reservations: DecisionReservations = DecisionReservations()) {
        self.lifecycle = lifecycle
        self.fold = fold
        self.reservations = reservations
    }

    /// Available for every channel: every channel has messages, tools and decisions to open a
    /// thread on, and an empty thread tab reads *no thread open* rather than disappearing.
    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        ThreadModel(channel: context.key, lifecycle: lifecycle, fold: fold, reservations: reservations)
    }

    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let model = session as? ThreadModel else { return AnyView(EmptyView()) }
        return AnyView(ThreadView(model: model))
    }
}

/// How the Thread tab reaches the channel's fold: the two things a tab that answers decisions for a
/// channel it does not own a timeline model for still has to be able to do.
///
/// **Why a value of closures and not the registry itself.** The app holds exactly one
/// `ChannelTimelineRegistry`, `AppModel.timelines`, and every consumer reaches a channel's fold
/// through it; handing this tab a second route to a fold — or a registry of its own — is the
/// duplicate capability path the C6 cut exists to prevent. Two closures over the one registry are
/// the whole of the access this tab needs, and the default pair reaches nothing, which is the right
/// behaviour for a host built without a workspace.
///
/// **This is not C6.1's `TimelineRenderContext`.** That value carries a *row's* capabilities — links,
/// the per-row answering object — and the timeline row's own `raise` waits on it (contract Y7). The
/// Thread tab is a panel tab and has no row: it is constructed once, at `performLaunch`, where the
/// app-scoped registry already exists, so nothing here waits on that carrier.
@MainActor
struct ChannelFold {

    /// Raises a host signal on a channel's fold — `ChannelTimelineModel.signal(_:)`, spec D2 and
    /// contract X4. The engine sends **no frame back for an answer**, so this is the only thing that
    /// can move an answered decision out of `.pending`.
    var raise: (ChannelKey, HostSignal) async -> Void = { _, _ in }

    /// The fold's decision for a request id, as it stands now, or nil when the channel has no fold
    /// or the fold has never seen the request. A thread anchored on a decision reads this rather
    /// than the card it was opened on, so what it draws is the state C3's reducer wrote.
    var decision: (ChannelKey, RequestID) -> DecisionItem? = { _, _ in nil }
}

extension ChannelFold {

    /// The app's one `ChannelTimelineRegistry`, as this tab's access to a channel's fold.
    ///
    /// Written here rather than at the registration line so the running app and the tests that
    /// drive this tab over a fold reach the fold the same way: a wiring that is spelled once cannot
    /// be spelled differently in the two places.
    init(timelines: ChannelTimelineRegistry) {
        self.init(raise: { key, signal in await timelines.model(for: key).signal(signal) },
                  decision: { key, id in timelines.model(for: key).timeline.overlay.decisions[id] })
    }
}
