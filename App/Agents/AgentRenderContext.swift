import Foundation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// The `TimelineRenderContext` one agent run's transcript is drawn through (child spec D4).
///
/// **The same capabilities the channel column passes, and the running objects.** `links` is
/// `PanelHostModel.links` — a plain `let`, never `context(for:cwd:)`, which mutates the host inside
/// a body (tracker 67). `signal` is this channel's own model, `decisions` is the app's one
/// reservation set, and `retraction` is the channel model's own registry. A subagent's transcript
/// draws C6.1's rows, so a row that answers a decision or opens a link from here has to reach the
/// same objects the main list's rows reach; a context built with stand-ins passes every assertion
/// that only reads a field back and answers nothing.
///
/// **`composer` is nil, and that is the point.** A subagent transcript is not a place to type, and
/// contract Y6's *Edit* on a message inside a run would rewind the **main** conversation — the
/// composer belongs to the channel, not to the run, so the row's rewind would take back turns the
/// user is looking at somewhere else. Nil is what the field is for: C6.1's rows offer no *Edit* when
/// there is no composer, which is the same reading a read-only channel gets.
enum AgentRenderContext {

    /// Built from the app's objects and the channel's own model, in one expression a test can call.
    ///
    /// It takes both rather than reading either from the environment, for `TimelineListView`'s
    /// reason: a capability wired to nothing satisfies any assertion that only reads the value back,
    /// so the construction is a function and the test exercises what came out of it.
    @MainActor
    static func context(in app: AppModel, channel: ChannelTimelineModel,
                        collapse: TimelineCollapseState, editing: TimelineEditState) -> TimelineRenderContext {
        let row = app.browser?.row(channel.key.session)
        return TimelineRenderContext(key: channel.key,
                                     links: app.panels.links,
                                     signal: { [channel] signal in await channel.signal(signal) },
                                     decisions: app.decisions,
                                     lifecycle: app.timelines.lifecycle,
                                     // The listing policy's own answer, as the channel column asks
                                     // it: a channel afleet may show and may not act on offers the
                                     // rows' readings and none of their actions (tracker 74).
                                     isOwned: row?.offersOwnedActions == true,
                                     // The channel's own registry: a retraction settled on the main
                                     // list has taken the frame back for this channel, and a run's
                                     // transcript drawing it again would show a message the engine
                                     // has said stopped being true.
                                     retraction: channel.retraction,
                                     cwd: row?.cwd,
                                     agents: app.agentNavigation,
                                     collapse: collapse,
                                     composer: nil,
                                     editing: editing,
                                     // The channel's own snapshot, rebuilt only when the items
                                     // moved. The run's rows are a subset of the channel's items, so
                                     // the neighbourhood they need is the channel's.
                                     neighbourhood: channel.neighbourhood,
                                     isOverlayStale: channel.timeline.overlay.stale,
                                     autoScrollEnabled: channel.readout.autoScrollEnabled,
                                     syntaxHighlightingEnabled: channel.readout.syntaxHighlightingEnabled)
    }
}
