import Foundation
import AppKit
import UserNotifications

/// Where a notification actually goes, decided per post from app activation and the launch
/// authorisation result — spike S-C5-1's fallback, taken *beside* the native path rather
/// than instead of it.
///
/// The spike measured, on macOS 26.5.2 against this ad-hoc-signed build: the authorisation prompt
/// **is** presented on first launch, so the native path is one click away from working; but until
/// somebody clicks it the status is `denied`, `requestAuthorization` returns false at once, and —
/// the trap — `deliveredNotifications()` still lists a request the centre accepted, so the app
/// cannot tell from the centre whether the user was told anything. So it does not ask the centre.
/// It asks for the authorisation status, and when that is not `authorized` it raises the
/// notification inside the app instead (also while afleet is foregrounded, where macOS
/// suppresses system presentation without a delegate): an Activity banner and a Dock tile badge, which keeps
/// §8.7's observable — the user is told about a decision in a channel they are not looking at —
/// true whether or not the prompt was ever answered.
///
/// The status is read once per launch and again after `requestAuthorisation`, not per post: a
/// notification that has to wait for an XPC round trip before it is decided arrives after the
/// thing it is about.
actor SystemOrInAppPoster: NotificationPosting {

    private let system: any SystemNotificationPosting
    private let inApp: @MainActor (AfleetNotification) -> Void
    private var isAuthorised = false
    private let isApplicationActive: @MainActor @Sendable () -> Bool

    init(system: any SystemNotificationPosting = UserNotificationPoster(),
         isApplicationActive: @escaping @MainActor @Sendable () -> Bool = { NSApplication.shared.isActive },
         inApp: @escaping @MainActor (AfleetNotification) -> Void) {
        self.system = system
        self.inApp = inApp
        self.isApplicationActive = isApplicationActive
    }

    @discardableResult
    func requestAuthorisation() async -> Bool {
        let granted = await system.requestAuthorisation()
        let status = await system.authorisationStatus()
        isAuthorised = granted || status == .authorized
        return isAuthorised
    }

    func post(_ notification: AfleetNotification) async {
        let active = await isApplicationActive()
        if isAuthorised && !active {
            await system.post(notification)
        } else {
            let present = inApp
            await MainActor.run { present(notification) }
        }
    }
}
