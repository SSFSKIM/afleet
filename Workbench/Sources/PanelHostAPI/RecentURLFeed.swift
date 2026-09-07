import Foundation
import FleetKit

/// The URLs this channel's timeline has shown, most recent first, as C3 records them.
/// The Browser panel reads it; nothing here can write to the timeline.
public protocol RecentURLFeed: Sendable {
    func current(limit: Int) async -> [SeenURL]
    var updates: AsyncStream<[SeenURL]> { get }
}
