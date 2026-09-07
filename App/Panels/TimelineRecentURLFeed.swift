import Foundation
import FleetKit
import PanelHostAPI

/// X4's `ChannelTimeline.recentURLs(limit:)` as the capability the Browser panel holds (spec §7).
///
/// **It parses nothing and ingests nothing.** X1 forbids Workbench from reading timeline items, and
/// two ingestions on one channel would fight over C3's single-consumer effects stream, so this
/// resolves the channel's model from the app's one `ChannelTimelineRegistry` — the same model the
/// channel column draws — and asks it the query. A feed that opened its own ingestion would publish
/// a timeline nothing else observes, which is the defect the single registry exists to prevent.
///
/// The model is resolved **once, at construction, on the main actor**, and both members read that
/// object. Resolving inside `updates` instead would mean subscribing after an `await`, and a
/// subscriber that attaches asynchronously can miss the very change it was created to see. The host
/// rebuilds the context — and with it this feed — whenever the channel or the workspace changes, so
/// the resolved model is never the stale one.
struct TimelineRecentURLFeed: RecentURLFeed {

    /// The channel's timeline owner. `ChannelTimelineModel` is `@MainActor`, and therefore
    /// `Sendable`, so this value crosses into the nonisolated members below legally.
    private let model: ChannelTimelineModel

    /// How many URLs each published list carries. `RecentURLFeed.updates` takes no limit of its
    /// own — `current(limit:)` is where a caller states one — so the stream publishes a bounded
    /// prefix rather than an unbounded list.
    private let limit: Int

    @MainActor
    init(registry: ChannelTimelineRegistry, key: ChannelKey, limit: Int) {
        self.model = registry.model(for: key)
        self.limit = limit
    }

    func current(limit: Int) async -> [SeenURL] {
        let timeline = await model.timeline
        return timeline.recentURLs(limit: limit)
    }

    /// Every applied timeline as a recent-URL list. A fresh fan-out per read, like the model's own
    /// `timelineUpdates`: the Browser is one consumer and a test is another, and one shared
    /// `AsyncStream` would split the elements between them rather than giving each all of them.
    var updates: AsyncStream<[SeenURL]> {
        let timelines = model.timelineUpdates
        let limit = self.limit
        return AsyncStream { continuation in
            let pump = Task {
                for await timeline in timelines {
                    continuation.yield(timeline.recentURLs(limit: limit))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
