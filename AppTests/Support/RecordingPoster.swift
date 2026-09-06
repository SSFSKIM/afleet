import Foundation
@testable import Afleet

/// The `NotificationPosting` G2c is asserted against: it records and posts nothing.
///
/// A double rather than the real centre because the real centre cannot be asserted on. Spike S-C5-1
/// measured that `UNUserNotificationCenter.deliveredNotifications()` lists a request it accepted
/// even when authorisation is **denied** and the user was shown nothing — so a gate that read the
/// system back would be green on a machine that notifies nobody. What the app controls, and what
/// §8.7 is actually about, is which events become a notification at all; that is what this records.
@MainActor
final class RecordingPoster: NotificationPosting {

    private(set) var posted: [AfleetNotification] = []
    private(set) var authorisationRequests = 0
    /// What `requestAuthorisation` answers.
    var isAuthorised = true

    nonisolated init() {}

    func requestAuthorisation() async -> Bool {
        authorisationRequests += 1
        return isAuthorised
    }

    func post(_ notification: AfleetNotification) async {
        posted.append(notification)
        releaseWaiters()
    }

    // MARK: - Reading it

    var count: Int { posted.count }
    func posts(from source: AfleetNotification.Source) -> [AfleetNotification] {
        posted.filter { $0.source == source }
    }
    func reset() { posted.removeAll() }

    // MARK: - Being told, rather than asked

    /// Suspends until `predicate` holds of what has been posted, resumed by the post that makes it
    /// true. No test here waits on a duration: a wait is fulfilled by the event it waits for.
    func whenPosted(_ predicate: @escaping @MainActor ([AfleetNotification]) -> Bool) async {
        if predicate(posted) { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(predicate: predicate, continuation: continuation))
        }
    }

    private struct Waiter {
        let predicate: @MainActor ([AfleetNotification]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiters: [Waiter] = []

    private func releaseWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(posted) { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }
}
