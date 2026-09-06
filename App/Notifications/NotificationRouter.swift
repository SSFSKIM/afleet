import Foundation
import AppKit
import OSLog
import AfleetCore
import ClaudeWire
import FleetKit

/// Which events become notifications, and — for the engine's own `Notification` hook — the answer
/// that lets the engine carry on (spec §6, §8.7, G2c).
///
/// It sits on the app's side of `ChannelEventPump` and sees exactly what the pump saw. The three
/// sources §8.7 names:
/// - a **pending decision** in a channel not in view;
/// - a **completed turn** in a channel not in view;
/// - **every notification the engine raises through the `Notification` hook**, which is not
///   conditioned on what is in view because the engine raised it deliberately.
///
/// The hook route is the one that must not be got wrong. `InitializeConfiguration.afleetDefaults`
/// registers `afleet.notification`, so `InboundPolicy` *surfaces* that callback rather than
/// answering it by policy — which means the engine is **waiting** for afleet, and a router that
/// posted the notification and stopped there would leave the turn hanging. The body is the hook
/// input's own `message`, copied rather than reconstructed (§8.7 calls that text display-ready),
/// and the answer is an empty continue.
@MainActor
final class NotificationRouter {

    private let poster: any NotificationPosting
    private let lifecycle: any LifecycleAPI
    private let isInView: @MainActor (ChannelKey) -> Bool
    private let preferences: @MainActor () -> NotificationPreferences
    private let log = Logger(subsystem: "com.afleet.app", category: "notifications")

    /// How many notifications have been posted and how many hook callbacks answered. Counts, for
    /// the diagnostics line and for a test that needs a floor (§11).
    private(set) var postCount = 0
    private(set) var hookAnswerCount = 0
    /// The answer in flight. Each waits for the one before it, so the engine is answered in ask
    /// order; a test awaits it rather than waiting on a duration.
    private var answerTask: Task<Void, Never>?

    /// Returns once every answer this router has sent has been performed.
    func settle() async { await answerTask?.value }

    init(poster: any NotificationPosting,
         lifecycle: any LifecycleAPI,
         isInView: @escaping @MainActor (ChannelKey) -> Bool,
         preferences: @escaping @MainActor () -> NotificationPreferences) {
        self.poster = poster
        self.lifecycle = lifecycle
        self.isInView = isInView
        self.preferences = preferences
    }

    func handle(_ event: WireEvent, on key: ChannelKey) {
        switch event {
        case .request(let request):
            handle(request, on: key)
        case .frame(let frame, _):
            handle(frame, on: key)
        default:
            // `.policyAnswered` is deliberately here: a request the inbound policy answered itself
            // — an unregistered hook callback id, an unsupported subtype — was never surfaced to
            // the user and must not become a notification either.
            break
        }
    }

    // MARK: - Requests

    private func handle(_ request: InboundRequest, on key: ChannelKey) {
        switch request.payload {
        case .hookCallback(let hook):
            // **Every** surfaced hook callback is answered, and only one of them is a notification.
            //
            // `InboundPolicy` surfaces a `hook_callback` precisely *because* its id is registered,
            // and `InitializeConfiguration.afleetDefaults` registers two: `afleet.notification` and
            // `afleet.config-change`. A route that answered only the first left the second
            // outstanding for ever — the registered matcher carries no timeout, so the engine
            // blocks until its process dies. The default arm is unconditional rather than a list of
            // known ids, so registering a third id cannot reintroduce the hang.
            if hook.callbackID == HookRoute.notification {
                postHook(hook, id: request.id, on: key)
            } else {
                // §6.4's `afleet.config-change`: "refreshes `get_settings` and answers likewise".
                // C5 answers and does not refresh. `get_settings` is a per-channel control request
                // whose reader — the channel's settings and permissions view — is C6's; this child
                // renders no engine settings, so a refresh here would fetch a value nothing draws.
                // The hang is the defect and the answer is what closes it; the refresh is owed and
                // is tracker entry 61.
                log.notice("hook callback answered without a route: \(hook.callbackID, privacy: .public)")
                answer(request.id, on: key)
            }

        case .canUseTool, .requestUserDialog, .elicitation:
            guard preferences().permissionRequests, !isInView(key) else { break }
            post(AfleetNotification(identifier: request.id.rawValue,
                                    source: .decision,
                                    title: "A channel is waiting on you",
                                    body: Self.sentence(for: request),
                                    session: key.session))

        case .mcpMessage, .unknown, .malformed:
            break
        }
    }

    /// The engine's own notification, then the answer it is waiting for.
    private func postHook(_ hook: HookCallbackRequest, id: RequestID, on key: ChannelKey) {
        let input = hook.input
        let message = input["message"]?.stringValue ?? ""
        let kind = input["notification_type"]?.stringValue
        post(AfleetNotification(identifier: id.rawValue,
                                source: .engineHook,
                                title: kind.map { "afleet — \($0)" } ?? "afleet",
                                body: message,
                                session: key.session))
        answer(id, on: key)
    }

    /// The empty continue every surfaced hook callback gets, whether or not it was also a
    /// notification. An unanswered surfaced request leaves the engine waiting; `decisionGone` is
    /// the ordinary outcome of a cancelled callback and is nothing to report.
    private func answer(_ id: RequestID, on key: ChannelKey) {
        hookAnswerCount += 1
        let lifecycle = self.lifecycle
        let previous = answerTask
        answerTask = Task {
            await previous?.value
            _ = try? await lifecycle.perform(.answer(id, .hookContinue(.empty)), on: key)
        }
    }

    /// What a decision row says in a notification: the subtype, and the tool where there is one.
    /// Never the tool's input — that is the engine's text about the user's files (§11).
    private static func sentence(for request: InboundRequest) -> String {
        switch request.payload {
        case .canUseTool(let tool): "Permission to use \(tool.toolName)."
        case .requestUserDialog(let dialog): "A dialog is open: \(dialog.dialogKind)."
        case .elicitation: "An MCP server is asking a question."
        default: request.subtype
        }
    }

    // MARK: - Frames

    private func handle(_ frame: Frame, on key: ChannelKey) {
        guard case .result(let result) = frame, !isInView(key) else { return }
        if result.isError {
            guard preferences().channelFailed else { return }
            post(AfleetNotification(identifier: result.uuid,
                                    source: .turnFailed,
                                    title: "A turn failed",
                                    body: "The turn ended with \(result.subtype).",
                                    session: key.session))
        } else {
            guard preferences().turnCompleted else { return }
            post(AfleetNotification(identifier: result.uuid,
                                    source: .turnCompleted,
                                    title: "A turn finished",
                                    body: "The turn ended with \(result.subtype).",
                                    session: key.session))
        }
    }

    private func post(_ notification: AfleetNotification) {
        postCount += 1
        let poster = self.poster
        Task { await poster.post(notification) }
    }
}

/// The hook callback ids afleet registers, named once. `InitializeConfiguration.afleetDefaults`
/// declares them to the engine; this is the app's side of the same two strings.
enum HookRoute {
    static let notification = "afleet.notification"
    /// Registered by `InitializeConfiguration.afleetDefaults` and therefore *surfaced* by the
    /// inbound policy. Named here because a reader of the router needs to know the second id
    /// exists; the router does not branch on it, because its default arm already answers every id
    /// it does not route and a branch would be one more place to forget.
    static let configChange = "afleet.config-change"
}

/// The Dock tile's badge, the visible half of spike S-C5-1's fallback.
///
/// A free function rather than a seam: `NSApp` is nil in a unit-test process that never finished
/// launching, and a badge nobody can see is not a property worth asserting. What the tests assert
/// is that the notification was posted at all, which is `RecordingPoster`'s business.
enum DockBadge {
    @MainActor
    static func set(_ count: Int) {
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}
