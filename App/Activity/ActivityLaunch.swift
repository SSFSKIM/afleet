import Foundation

/// The order Activity and the notification authorisation are started in, in one place because the
/// order is the whole point and a comment on a call site is not something a test can hold.
///
/// **Activity starts first, and the authorisation request is never awaited on the launch path.**
/// `UNUserNotificationCenter.requestAuthorization` presents a system prompt on a first launch and
/// does not return until somebody answers it — spike S-C5-1 measured it outstanding for the whole
/// of a twelve-second run, and there is no bound on it at all. Awaiting it here left Activity dark
/// for exactly as long: no pumps, no `events(of:)` subscriptions, no rows, no badges and no in-app
/// fallback banners either, on the one launch where the prompt is presented rather than already
/// answered — which is the launch §8.7's observable is about.
///
/// Authorisation is still requested, and the caller keeps the task so nothing about it is silently
/// dropped. It decides only *where* a notification is drawn, and `SystemOrInAppPoster` defaults to
/// the in-app surface until the answer arrives, so a notification raised in the meantime is shown
/// rather than lost.
enum ActivityLaunch {

    /// Starts `model`, then asks `poster` for authorisation in a task of its own. Returns once
    /// Activity is running; the returned task is the authorisation request still in flight.
    @discardableResult
    static func begin(_ model: ActivityModel, requesting poster: any NotificationPosting) async -> Task<Bool, Never> {
        await model.start()
        return Task { await poster.requestAuthorisation() }
    }
}
