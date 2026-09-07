import Foundation
import Observation
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI
@testable import Afleet

/// The placeholder tab's reader of X4's recent-URL feed (spec §7).
@MainActor
final class PlaceholderTabFeedTests: XCTestCase {

    /// A publication landing between the snapshot and the subscription is not lost.
    ///
    /// `RecentURLFeed.updates` does not replay: a subscriber attached after a publication never
    /// sees it. `current(limit:)` is an actor hop, so a tab that awaited the snapshot *first* left
    /// a window in which the channel's timeline could publish into no subscriber at all — and the
    /// host retains this session, so `follow` refuses to run a second time and the count stays at
    /// the stale snapshot's for the life of the channel. Subscribing first closes the window by
    /// construction: what is published before the snapshot is in the snapshot, and what is
    /// published after the subscription is in that subscription's unbounded buffer.
    ///
    /// The window is a real suspension the test releases, not a sleep, and both halves are
    /// asserted: the order the two calls happened in, and the count the lost publication carried.
    func testAPublicationBetweenTheSnapshotAndTheSubscriptionIsNotLost() async throws {
        let feed = GatedRecentURLFeed()
        let session = PlaceholderTabSession()

        session.follow(feed, limit: 10)

        // On a timeout the session never reached the feed at all, and every clause below would be
        // asserting about a reader that had not started.
        let entered = await XCTWaiter().fulfillment(of: [feed.reachedSnapshot], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(entered, .completed, "the session never read the feed's snapshot")
        XCTAssertEqual(feed.calls, ["subscribe", "snapshot"],
                       "the session took its snapshot and subscription in the order \(feed.calls)")

        // The window: the channel publishes while the snapshot is still in flight.
        let watcher = CountWatcher(session: session, target: 2)
        feed.publish(Self.urls(2))
        feed.releaseSnapshot()

        let outcome = await XCTWaiter().fulfillment(of: [watcher.reached], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(outcome, .completed,
                       "the publication was lost: the tab reads \(session.recentURLCount) URLs, not 2")
    }

    /// `count` invented URLs, each with its own item id. Nothing here comes from any recording.
    private static func urls(_ count: Int) -> [SeenURL] {
        let stream = LogicalStream(configHome: URL(fileURLWithPath: "/invented/config-home"),
                                   sessionID: LaunchFixtures.sessionA, name: .main)
        return (0..<count).map { index in
            let id = ItemID(stream: stream, key: "invented-\(index)")
            return SeenURL(url: URL(string: "https://invented.example/\(index)")!,
                           firstSeen: id, firstSeenAt: nil, lastSeen: id, lastSeenAt: nil)
        }
    }
}

// MARK: - Support

/// Fulfils its expectation when the tab's count reaches `target`, by observation rather than by
/// polling: the wait below is fulfilled by the write itself.
@MainActor
private final class CountWatcher {

    let reached: XCTestExpectation
    private let session: PlaceholderTabSession
    private let target: Int

    init(session: PlaceholderTabSession, target: Int) {
        self.session = session
        self.target = target
        reached = XCTestExpectation(description: "the tab's count reaches \(target)")
        observe()
    }

    private func observe() {
        guard session.recentURLCount != target else { return reached.fulfill() }
        withObservationTracking {
            _ = session.recentURLCount
        } onChange: { [self] in
            // `onChange` fires *before* the value is written, so the read happens in a task hopped
            // past the write rather than inside the callback.
            Task { @MainActor in self.observe() }
        }
    }
}

/// A recent-URL feed that parks inside `current(limit:)` until the test releases it, records the
/// order its two members were called in, and publishes only to subscribers already attached.
///
/// The no-replay rule is the point: a publication made while nothing is subscribed is gone, exactly
/// as `TimelineRecentURLFeed`'s is.
///
/// `@unchecked Sendable` is sound because every mutable field is read and written only inside
/// `withLock` of this instance's private `NSLock`, and the gate's continuation is itself safe to
/// touch from any thread.
private final class GatedRecentURLFeed: RecentURLFeed, @unchecked Sendable {

    let reachedSnapshot = XCTestExpectation(description: "the reader is inside current(limit:)")

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[SeenURL]>.Continuation] = [:]
    private var order: [String] = []
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() { (gate, gateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded) }

    /// The two members in the order they were called.
    var calls: [String] { lock.withLock { order } }

    /// Buffered, so a release issued before the snapshot reaches the gate is not lost.
    func releaseSnapshot() { gateContinuation.yield(()) }

    func publish(_ urls: [SeenURL]) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(urls) }
    }

    func current(limit: Int) async -> [SeenURL] {
        lock.withLock { order.append("snapshot") }
        reachedSnapshot.fulfill()
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return []
    }

    var updates: AsyncStream<[SeenURL]> {
        let (stream, continuation) = AsyncStream<[SeenURL]>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock {
            order.append("subscribe")
            continuations[UUID()] = continuation
        }
        return stream
    }
}
