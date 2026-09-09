import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// The two control requests the header's readbacks are made of, and the rules about when they may
/// go out (child spec §10).
///
/// **Contract Y5, and it is the whole reason this type constructs its requests the way it does.**
/// Both go out through `LifecycleAPI.send(_:on:)` as an `AnyControlRequest` built **by subtype and
/// payload**. `AnyControlRequest` is a FleetSessions type; `GetSettings` and `GetContextUsage` are
/// ClaudeWire `ControlRequestSpec`s and Y5 forbids a leaf constructing one. The rule is invisible at
/// the call site — an `AnyControlRequest` built from a `GetSettings` spec compiles here just as
/// readily, and reads the same at a glance — so
/// `HeaderReadoutTests.testNoClaudeWireSpecIsConstructed` asserts it mechanically over
/// `App/Timeline/`.
///
/// **A refusal leaves the last readback standing.** Every failure answers nil and the caller keeps
/// what it had rather than blanking the header, and nothing here retries: X5's rule is that a
/// refusal is reported and not re-issued, and a surface that argued with the engine would loop
/// against a channel that is busy for a reason.
@MainActor
struct ReadbackPoller {

    let key: ChannelKey
    let lifecycle: any LifecycleAPI

    /// Y5's construction, once, so there is one spelling of each subtype in this leaf.
    static let settingsRequest = AnyControlRequest(subtype: "get_settings", payload: .object([:]))
    static let contextRequest = AnyControlRequest(subtype: "get_context_usage", payload: .object([:]))

    /// One `get_settings`, plus the channel's retained handshake for the mode the answer does not
    /// carry. Nil when either the request was refused or the answer was not a settings body.
    func settings() async -> SettingsReadback? {
        guard let answer = try? await lifecycle.send(Self.settingsRequest, on: key) else { return nil }
        guard answer["applied"] != nil else { return nil }
        let handshake = await lifecycle.engineReports(of: key)?.handshake
        return SettingsReadback(answer: answer, handshake: handshake)
    }

    /// One `get_context_usage`. Nil on a refusal and on a body with no totals in it.
    func contextUsage() async -> ContextUsage? {
        guard let answer = try? await lifecycle.send(Self.contextRequest, on: key) else { return nil }
        return ContextUsage(answer: answer)
    }

    /// Whether this channel has a process of afleet's own to ask.
    ///
    /// The same three origins C5's Activity model calls live, and for the same reason: a foreign
    /// terminal's session and a background job are somebody else's process, an archived channel has
    /// none, and only an owned one has a control channel at the other end. A request sent to any of
    /// the others is refused by the fleet before it reaches a wire, so this is about not asking.
    static func hasLiveProcess(_ origin: ChannelOrigin?) -> Bool {
        switch origin {
        case .owned(.connecting), .owned(.ready), .owned(.contended): true
        default: false
        }
    }

    /// The one moment a turn is known to have ended, which is when the context meter is polled.
    static func isTurnEnd(_ event: WireEvent) -> Bool {
        if case .frame(.result, _) = event { return true }
        return false
    }

    /// The process an event belongs to, and nil for the three that name a request rather than a
    /// process.
    ///
    /// A restart replaces the process under a channel model that outlives it, and the epoch is the
    /// engine-side statement that it happened — carried on the handshake, on the exit and on every
    /// frame in between, so a reader does not have to catch one particular event to notice.
    static func epoch(of event: WireEvent) -> ProcessEpoch? {
        switch event {
        case .handshakeCompleted(_, let epoch), .sessionIdentityResolved(_, let epoch),
             .frame(_, let epoch), .requestCancelled(_, let epoch), .hostToolInvoked(_, let epoch),
             .stderr(_, let epoch), .exited(_, let epoch):
            epoch
        case .request, .policyAnswered, .unansweredDialog:
            nil
        }
    }

    /// The permission mode a `system/status` frame reported, or nil for a frame that reports none
    /// (child spec §10, corrected 2026-09-09).
    ///
    /// **`permissionMode` is optional on the frame and is almost always absent**: across the fixture
    /// corpus's 40 status frames exactly one carries a value, in the one recording where a mode
    /// actually changes. So nil means "this frame says nothing about the mode" and never "no mode" —
    /// a reader that folded nil in would blank the header on every heartbeat.
    ///
    /// A spelling this build does not model reads as nil for the same reason: going on showing the
    /// last mode that could be named is better than showing one that cannot.
    static func liveMode(_ event: WireEvent) -> PermissionMode? {
        guard case .frame(.system(.status(let status)), _) = event,
              let spelling = status.fields.permissionMode else { return nil }
        return PermissionMode(rawValue: spelling)
    }
}
