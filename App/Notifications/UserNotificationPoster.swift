import Foundation
import OSLog
import UserNotifications

/// `NotificationPosting` over the system's own centre (spec §6).
///
/// **Nothing in the test bundle constructs one.** `UNUserNotificationCenter.current()` raises an
/// Objective-C exception when the running process has no application bundle to attribute the
/// notification to, and an XCTest bundle hosted by the app is a different process shape than the
/// app; every G2c assertion therefore runs against `RecordingPoster`. What this type is checked by
/// is spike S-C5-1, which launches the built application and watches what the system does with it.
final class UserNotificationPoster: NotificationPosting {

    private let log = Logger(subsystem: "com.afleet.app", category: "notifications")

    init() {}

    @discardableResult
    func requestAuthorisation() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Counts and kinds, never the payload (§11).
            log.error("notification authorisation failed: \(type(of: error), privacy: .public)")
            return false
        }
    }

    func post(_ notification: AfleetNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // A nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: notification.identifier,
                                            content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("notification post failed: \(type(of: error), privacy: .public)")
        }
    }

    /// What the system currently says about this application's authorisation. Read by the spike;
    /// nothing in the product branches on it, because a refusal is already the `false` above.
    func authorisationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The identifiers the system is currently showing for this application. The spike's evidence
    /// that a post was *delivered* rather than merely accepted.
    func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }
}
