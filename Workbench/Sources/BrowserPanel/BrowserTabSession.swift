import Foundation
import FleetKit
import Observation
import PanelHostAPI

/// Quick-open's filter, as a free function so it can be tested by table (Q8).
///
/// Case-insensitive substring over the **absolute string**, so a query can name a scheme, a host, a
/// port or a path fragment and mean the obvious thing. It does not sort: `RecentURLFeed` returns
/// most recent first, and re-ordering the answer would throw away the only ranking the panel has.
public enum BrowserQuickOpen {

    public static func filter(_ entries: [SeenURL], query: String) -> [SeenURL] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.url.absoluteString.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}

/// The Browser tab's per-channel state, and **only** what is per channel (Q20).
///
/// The tab set is shared across the window and lives on `BrowserModel`, which the `BrowserTab`
/// owns. What is genuinely per channel is quick-open: it answers "what did *this* session just
/// print", from `ChannelContext.recentURLs` — contract W8's feed, and the only way a URL from a
/// timeline reaches this panel, because X1 forbids the Workbench to read a timeline at all.
///
/// This type holds no web view and no tab list, and `BrowserModelTests` pins its member set so that
/// a later convenience cannot quietly give it one. That is what keeps root item 39 structural: a
/// channel switch makes one of these, and one of these cannot make a web view.
@Observable
@MainActor
public final class BrowserTabSession: PanelTabSession {

    /// Q8's snapshot size.
    public static let quickOpenLimit = 50

    public private(set) var isPresented = false

    /// What the user has typed into the sheet's field.
    public var query = ""

    /// The feed's list, most recent first, kept current while the sheet is up.
    public private(set) var entries: [SeenURL] = []

    /// What the sheet draws.
    public var results: [SeenURL] { BrowserQuickOpen.filter(entries, query: query) }

    private let recentURLs: any RecentURLFeed
    @ObservationIgnored private var watcher: Task<Void, Never>?

    public init(recentURLs: any RecentURLFeed) {
        self.recentURLs = recentURLs
    }

    deinit { watcher?.cancel() }

    /// Takes a fresh snapshot and follows the feed for as long as the sheet is up (Q8).
    ///
    /// **The subscription is taken before the snapshot**, the ordering C5's placeholder records and
    /// for the same reason: `updates` does not replay, `current(limit:)` is an actor hop, and a
    /// publication landing between them would reach nobody.
    public func openQuickOpen() {
        guard !isPresented else { return }
        isPresented = true
        query = ""
        entries = []
        let updates = recentURLs.updates
        let feed = recentURLs
        watcher = Task { [weak self] in
            let snapshot = await feed.current(limit: Self.quickOpenLimit)
            guard !Task.isCancelled else { return }
            self?.entries = snapshot
            for await urls in updates {
                guard let self, !Task.isCancelled else { return }
                self.entries = urls
            }
        }
    }

    /// Closes the sheet and cancels the subscription. Q8 says the feed is followed *while it is up*
    /// and no longer: a panel that kept N channels' subscriptions alive for the life of the window
    /// would be following feeds nobody is looking at.
    public func closeQuickOpen() {
        isPresented = false
        watcher?.cancel()
        watcher = nil
    }
}
