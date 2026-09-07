import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Replays a committed fixture's recorded engine bytes into `WireEvent`s, through the same decoders
/// a live process uses.
///
/// **What it is not.** It does not spawn `fake-claude`. What the app's Activity tests are about is
/// the wiring between C4's query and the app's three inputs, and the only thing a spawned replayer
/// would add over this is the process boundary itself — `Tools/fake-claude` writes the very lines
/// in `frames.ndjson` back out, and `ClaudeProcess` turns them into events with
/// `FrameDecoder.decode(line:)`, `InboundRequest.parse(frame:epoch:receivedAt:)` and
/// `InboundPolicy.decide(_:)`, which are the three calls below. Going through a process would also
/// need a `Fleet`, a scratch config home and a spawn precondition to pass, none of which is under
/// test here and each of which can fail for reasons that say nothing about Activity.
///
/// Every byte it reads comes from a fixture already committed and redacted; nothing here invents an
/// engine frame except where a test needs a shape the corpus does not carry, and those are built in
/// `Invented` below with identifiers that are visibly not anybody's (§11).
enum FixtureRunner {

    // MARK: - Locating the corpus

    /// `AppTests/Support/` → the repository root.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func directory(_ fixture: String) -> URL {
        repositoryRoot.appending(path: "Fixtures").appending(path: fixture)
    }

    /// The inbound policy the app really runs: the dialog kinds and hook callback ids
    /// `InitializeConfiguration` declares to the engine, read from that type rather than restated.
    static var afleetPolicy: InboundPolicy {
        let configuration = InitializeConfiguration()
        let ids = configuration.hooks.values.flatMap { $0.flatMap(\.hookCallbackIds) }
        return InboundPolicy(declaredDialogKinds: Set(configuration.supportedDialogKinds),
                             registeredHookCallbackIDs: Set(ids))
    }

    // MARK: - Reading

    /// Every line the engine wrote, in order, as raw JSON objects.
    static func outboundLines(_ fixture: String) throws -> [Data] {
        let url = directory(fixture).appending(path: "frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [Data] = []
        for line in text.split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["dir"] as? String == "out",
                  let frame = object["frame"] else { continue }
            out.append(try JSONSerialization.data(withJSONObject: frame))
        }
        return out
    }

    /// The fixture's frames, decoded by the engine's own decoder. Control requests are excluded:
    /// they are requests, not frames, and reach a consumer as `.request` events.
    static func frames(_ fixture: String) throws -> [Frame] {
        try outboundLines(fixture).map(decode).filter { frame in
            if case .controlRequest = frame { return false }
            return true
        }
    }

    /// One recorded control request, re-keyed to an invented request id so two channels can be
    /// driven from one recording without sharing an id.
    ///
    /// `overrides` are written into the request object itself, for the one test that needs the same
    /// recorded ask both with and without `requires_user_interaction` — the flag is the difference
    /// the test is about, and inventing a second ask would change more than that.
    static func request(_ fixture: String, subtype: String, id: String,
                        overrides: [String: Any] = [:],
                        epoch: ProcessEpoch = .first) throws -> InboundRequest {
        for line in try outboundLines(fixture) {
            guard var object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "control_request",
                  var request = object["request"] as? [String: Any],
                  request["subtype"] as? String == subtype else { continue }
            for (key, value) in overrides { request[key] = value }
            object["request"] = request
            object["request_id"] = id
            let reKeyed = try JSONSerialization.data(withJSONObject: object)
            guard case .controlRequest(let frame) = decode(reKeyed) else { break }
            return InboundRequest.parse(frame: frame, epoch: epoch, receivedAt: .now)
        }
        throw FixtureError.noSuchRequest(fixture: fixture, subtype: subtype)
    }

    /// The whole fixture as the events a pump would have seen: frames as frames, control requests
    /// through the real inbound policy, so a request the policy answers itself arrives as
    /// `.policyAnswered` and never as `.request`.
    static func events(_ fixture: String, epoch: ProcessEpoch = .first,
                       policy: InboundPolicy? = nil) throws -> [WireEvent] {
        let policy = policy ?? afleetPolicy
        var out: [WireEvent] = []
        for line in try outboundLines(fixture) {
            let frame = decode(line)
            if case .controlRequest(let control) = frame {
                let request = InboundRequest.parse(frame: control, epoch: epoch, receivedAt: .now)
                out.append(event(for: request, policy: policy))
            } else {
                out.append(.frame(frame, epoch))
            }
        }
        return out
    }

    /// One request through the policy, as `ClaudeProcess` routes it.
    static func event(for request: InboundRequest, policy: InboundPolicy? = nil) -> WireEvent {
        switch (policy ?? afleetPolicy).decide(request) {
        case .surface: .request(request)
        case .answer: .policyAnswered(request, error: "")
        case .leaveUnanswered: .unansweredDialog(request)
        case .routeToMCP: .policyAnswered(request, error: "")
        }
    }

    private static func decode(_ line: Data) -> Frame { FrameDecoder.decode(line: line) }

    enum FixtureError: Error, CustomStringConvertible {
        case noSuchRequest(fixture: String, subtype: String)
        var description: String {
            switch self {
            case .noSuchRequest(let fixture, let subtype):
                "fixture \(fixture) carries no outbound control_request of subtype \(subtype)"
            }
        }
    }

    // MARK: - Shapes the corpus does not carry

    /// Frames and requests built by hand, for the two cases no committed fixture records: an
    /// `auth_status` carrying an error, and an `elicitation`. Every identifier here is invented —
    /// a repeated hex nibble, the same convention `SidebarFixtures.session` uses — so nothing in
    /// this file can be mistaken for anybody's own session (§11).
    enum Invented {

        static func authStatus(error: String?, uuid: String, session: SessionID) -> Frame {
            var object: [String: Any] = ["type": "auth_status",
                                         "isAuthenticating": false,
                                         "output": [],
                                         "uuid": uuid,
                                         "session_id": session.description]
            if let error { object["error"] = error }
            return FrameDecoder.decode(line: try! JSONSerialization.data(withJSONObject: object))
        }

        /// A `hook_callback` for a callback id afleet never registered — the shape `InboundPolicy`
        /// answers itself, which is the whole point of the test that uses it.
        static func hookCallback(id: String, callbackID: String, message: String,
                                 epoch: ProcessEpoch = .first) -> InboundRequest {
            let object: [String: Any] = ["type": "control_request",
                                         "request_id": id,
                                         "request": ["subtype": "hook_callback",
                                                     "callback_id": callbackID,
                                                     "input": ["hook_event_name": "Notification",
                                                               "message": message,
                                                               "notification_type": "invented_type"]]]
            return parse(object, epoch: epoch)
        }

        static func elicitation(id: String, epoch: ProcessEpoch = .first) -> InboundRequest {
            let object: [String: Any] = ["type": "control_request",
                                         "request_id": id,
                                         "request": ["subtype": "elicitation",
                                                     "mcp_server_name": "invented-server",
                                                     "message": "An invented server asks an invented question."]]
            return parse(object, epoch: epoch)
        }

        private static func parse(_ object: [String: Any], epoch: ProcessEpoch) -> InboundRequest {
            let data = try! JSONSerialization.data(withJSONObject: object)
            guard case .controlRequest(let frame) = FrameDecoder.decode(line: data) else {
                preconditionFailure("an invented control_request did not decode as one")
            }
            return InboundRequest.parse(frame: frame, epoch: epoch, receivedAt: .now)
        }
    }
}

// MARK: - Building the states Activity queries over

/// The `ChannelState`s the Activity tests hand the lifecycle double. `SidebarFixtures.state` builds
/// the shape the sidebar needs; this adds the two fields Activity reads and it does not.
enum ActivityFixtures {

    static func key(_ nibble: String, configHome: URL) -> ChannelKey {
        ChannelKey(configHome: configHome, session: SidebarFixtures.session(nibble))
    }

    static func state(_ key: ChannelKey,
                      pending: [PendingDecision] = [],
                      origin: ChannelOrigin = .owned(.ready),
                      at moment: Date = Date()) -> ChannelState {
        ChannelState(key: key,
                     origin: origin,
                     desired: .owned,
                     observed: HolderSet(holders: [], observedAt: moment),
                     epoch: .first,
                     identity: .known(key.session),
                     presence: .idle,
                     pendingDecisions: pending,
                     lastActivity: moment)
    }

    /// The pending decision a surfaced request becomes on the supervisor's side. Built from the
    /// request itself so the id and the subtype cannot drift from the card the pump holds.
    static func pending(_ request: InboundRequest, at moment: Date = Date()) -> PendingDecision {
        PendingDecision(id: request.id, subtype: request.subtype, epoch: request.epoch, askedAt: moment)
    }
}
