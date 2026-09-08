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

/// Which row of quick-open's list the keyboard is on (Q8).
///
/// A value type, and outside the view, because "Enter opens the selected URL" is a rule and a
/// `@State` integer mutated inside a gesture is not one a test can drive. The view owns an instance
/// of this, the arrow keys move it, and the submit reads the same one.
public struct BrowserQuickOpenSelection: Equatable, Sendable {

    /// The highlighted row, always a valid index into the results it was last clamped against, or
    /// 0 when there are none.
    public private(set) var index: Int = 0

    public init() {}

    /// Up arrow: the row above, stopping at the first. It does not wrap — a list that jumps from
    /// its top to its bottom under a held key is a list nobody can aim at.
    public mutating func moveUp() {
        index = max(0, index - 1)
    }

    /// Down arrow: the row below, stopping at the last.
    public mutating func moveDown(resultCount: Int) {
        guard resultCount > 0 else { return }
        index = min(resultCount - 1, index + 1)
    }

    /// The filter changed. The highlight stays where it is if that row still exists and lands on
    /// the last row if it does not, so a query that narrows the list cannot leave the selection
    /// pointing past the end of it.
    public mutating func resultsChanged(count: Int) {
        index = min(index, max(0, count - 1))
    }

    /// A row the pointer aimed at. The tap and the arrow keys move the one selection, so what a
    /// click submits and what Enter submits can never be two different rows.
    public mutating func select(_ row: Int) {
        index = max(0, row)
    }

    /// Which row a submission opens, or `nil` when there is nothing to open.
    public func chosenIndex(resultCount: Int) -> Int? {
        guard resultCount > 0, index < resultCount else { return nil }
        return index
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
