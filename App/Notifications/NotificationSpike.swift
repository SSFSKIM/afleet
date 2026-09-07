import Foundation
import OSLog

/// Spike S-C5-1: does `UNUserNotificationCenter` authorise and deliver for an ad-hoc-signed,
/// non-notarised application launched out of `DerivedData`?
///
/// It runs only when `AFLEET_NOTIFICATION_SPIKE` is set in the environment, so an ordinary launch
/// never reaches it, and it writes one line per step to standard output and to the unified log —
/// the launch that ran it is not attached to a terminal, so the log is where the verdict is read
/// from. It posts one notification with an invented identifier and then reads back what the centre
/// says it has filed.
///
/// **That readback is not the answer, and the spike's own result is why.** "The centre accepted the
/// request" and "the user was told" are different facts; §8.7 promises the second, and the readback
/// reports the first. On this build it reported our identifier three runs running while the same
/// process read `authorizationStatus == denied` — so a green readback is compatible with a user who
/// saw nothing. The line that decides the verdict is the authorisation status; the delivered count
/// is printed beside it as the trap it turned out to be, not as corroboration.
///
/// It is kept rather than deleted after the spike: it is the only way to re-run the check on a new
/// macOS, and it costs an environment-variable read on launch.
enum NotificationSpike {

    static let variable = "AFLEET_NOTIFICATION_SPIKE"

    /// True when this launch is a spike run, in which case the caller has already started it.
    @discardableResult
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment[variable] != nil else { return false }
        Task.detached(priority: .userInitiated) { await run() }
        return true
    }

    private static func run() async {
        let log = Logger(subsystem: "com.afleet.app", category: "spike")
        let poster = UserNotificationPoster()

        func say(_ line: String) {
            print("spike/notifications: \(line)")
            fflush(stdout)
            log.notice("spike/notifications: \(line, privacy: .public)")
        }

        say("status before request: \(await poster.authorisationStatus().rawValue)")
        let granted = await poster.requestAuthorisation()
        say("authorisation granted: \(granted)")
        say("status after request: \(await poster.authorisationStatus().rawValue)")

        let identifier = "spike-c5-1"
        await poster.post(AfleetNotification(identifier: identifier,
                                             source: .engineHook,
                                             title: "afleet",
                                             body: "Spike S-C5-1: one notification from an ad-hoc-signed build."))
        // The centre files a delivery asynchronously; one short wait is the only way to ask it
        // afterwards, and this is a spike rather than a test, so a wait is honest here.
        try? await Task.sleep(for: .seconds(2))
        let delivered = await poster.deliveredIdentifiers()
        say("delivered count: \(delivered.count)")
        say("our identifier delivered: \(delivered.contains(identifier))")
        say("done")
    }
}
