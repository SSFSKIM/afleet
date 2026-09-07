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
protocol SystemNotificationPosting: NotificationPosting {
    func authorisationStatus() async -> UNAuthorizationStatus
}

final class UserNotificationPoster: SystemNotificationPosting {

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

    /// What the system currently says about this application's authorisation. Read by the spike
    /// and by `SystemOrInAppPoster` after requesting authorisation.
    func authorisationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The identifiers the centre has **accepted and filed** for this application.
    ///
    /// **It is not evidence that anybody was shown anything, and nothing may treat it as such.**
    /// Spike S-C5-1 measured this returning our own identifier on three consecutive runs from a
    /// centre the same process had just read as `denied`. It measures acceptance, which is
    /// correlated with display and is not display. It exists for the spike to report and is read
    /// nowhere else; what a notification actually reached is asserted through `NotificationPosting`
    /// against a recording double.
    func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }
}
