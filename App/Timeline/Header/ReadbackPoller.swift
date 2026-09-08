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

    /// Y5's construction, once, so there is one spelling of the subtype in this leaf.
    static let settingsRequest = AnyControlRequest(subtype: "get_settings", payload: .object([:]))

    /// One `get_settings`, plus the channel's retained handshake for the mode the answer does not
    /// carry. Nil when either the request was refused or the answer was not a settings body.
    func settings() async -> SettingsReadback? {
        guard let answer = try? await lifecycle.send(Self.settingsRequest, on: key) else { return nil }
        guard answer["applied"] != nil else { return nil }
        let handshake = await lifecycle.engineReports(of: key)?.handshake
        return SettingsReadback(answer: answer, handshake: handshake)
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
}
