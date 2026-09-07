import Foundation
import AfleetCore

/// One notification afleet wants the system to raise (spec §6).
///
/// It carries only what the poster needs and nothing the engine did not say. The body of a hook
/// notification is the hook input's own `message`, copied rather than reconstructed, because §8.7
/// declares that text display-ready and a sentence afleet composed in its place would be afleet's
/// opinion of what the engine meant.
struct AfleetNotification: Hashable, Sendable {

    /// Why this notification exists. Closed, so a fourth source is a compile error here rather than
    /// a silent fourth kind of alert.
    enum Source: Hashable, Sendable {
        /// A decision the engine is waiting on, in a channel the user is not looking at.
        case decision
        /// A turn that finished in a channel the user is not looking at.
        case turnCompleted
        /// A turn that ended in an error, in a channel the user is not looking at.
        case turnFailed
        /// The engine's own `Notification` hook.
        case engineHook
    }

    /// Unique per notification, so a second post cannot silently replace the first in Notification
    /// Center. The request id or the frame's uuid where there is one; a fresh UUID otherwise.
    var identifier: String
    var source: Source
    var title: String
    var body: String
    /// Which channel it came from, so a click could route to it. Nothing in C5 handles the click.
    var session: SessionID?

    init(identifier: String, source: Source, title: String, body: String, session: SessionID? = nil) {
        self.identifier = identifier
        self.source = source
        self.title = title
        self.body = body
        self.session = session
    }
}

/// The seam every notification leaves the app through (spec §6, G2c).
///
/// Production is `UserNotificationPoster` over `UNUserNotificationCenter`; the tests use a recording
/// double. It exists because G2c is asserted headlessly: a gate that could only be checked by a
/// human watching the corner of a screen is a gate that is checked once.
protocol NotificationPosting: Sendable {
    /// Asks the system for permission, once. Returns what the system said, and false for any
    /// failure — a refusal and a broken authorisation path are the same thing to a caller that can
    /// only decide whether to bother posting.
    @discardableResult func requestAuthorisation() async -> Bool
    func post(_ notification: AfleetNotification) async
}
