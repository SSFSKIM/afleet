import XCTest
import WireFrames
import WireTransport
import WireTestSupport

/// `WireEventPolicy` over C1's recorded corpus: the ordered effects the transport derives from a
/// fixture's engine-to-host frames are pinned, fixture by fixture.
///
/// This is the test a downstream replay (FleetKit's timeline, parent C3) leans on. It replays a
/// recording through the same pure mapping the live actor calls, so "what a fixture reduces to" and
/// "what `ClaudeProcess` publishes" cannot drift apart without one of them failing here.
///
/// **No fixture bytes are asserted or committed.** Every expectation below is a list of effect-kind
/// names — `publish(frame)`, `writeAnswer`, `routeToMCP` — in the order the policy yields them, with
/// runs of one kind collapsed to `kind ×n`. The recording is read from `Fixtures/` at run time.
///
/// The policy under test is built from the fixture's own `initialize` request: the dialog kinds it
/// declared and the hook callback ids it registered are what the engine was answering, so deciding a
/// recorded request against a differently-configured policy would be asserting a session that never
/// happened.
final class WireEventPolicyFixtureTests: XCTestCase {
    private var fixturesRoot: URL {
        TestPaths.support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private struct RecordedFrame { let outbound: Bool; let value: JSONValue }

    private func frames(of fixture: String) throws -> [RecordedFrame] {
        let url = fixturesRoot.appendingPathComponent(fixture).appendingPathComponent("frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
            guard let frame = value["frame"] else { return nil }
            // `out` is engine-to-host — the direction this actor receives.
            return RecordedFrame(outbound: value["dir"]?.stringValue == "out", value: frame)
        }
    }

    /// The policy the host ran with in the recording, read back off the `initialize` it sent.
    private func recordedPolicy(_ frames: [RecordedFrame]) throws -> InboundPolicy {
        let request = try XCTUnwrap(frames.first {
            !$0.outbound && $0.value["type"]?.stringValue == "control_request"
                && $0.value["request"]?["subtype"]?.stringValue == "initialize"
        }?.value["request"], "fixture has no outbound initialize")
        let kinds = request["supportedDialogKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let callbacks = (request["hooks"]?.objectValue ?? [:]).values.flatMap { matchers in
            matchers.arrayValue?.flatMap { $0["hookCallbackIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] } ?? []
        }
        return InboundPolicy(declaredDialogKinds: Set(kinds), registeredHookCallbackIDs: Set(callbacks))
    }

    /// Every engine-to-host frame of the fixture through the policy, with the context advanced by the
    /// effects themselves — exactly as the actor advances its own state.
    private func effectKinds(of fixture: String) throws -> [String] {
        let recorded = try frames(of: fixture)
        let policy = WireEventPolicy(policy: try recordedPolicy(recorded))
        var context = WireEventPolicy.Context(epoch: .first)
        // What the host is waiting on: every control_request it sent in the recording. Registered up
        // front because a response can only ever follow its request, so a whole-recording set and a
        // progressively-built one agree on every frame that matters.
        for frame in recorded where !frame.outbound && frame.value["type"]?.stringValue == "control_request" {
            if let id = frame.value["request_id"]?.stringValue { context.pendingOutbound.insert(RequestID(rawValue: id)) }
        }
        var kinds: [String] = []
        for frame in recorded where frame.outbound {
            let decoded = FrameDecoder.decode(line: try frame.value.canonicalData())
            let effects = policy.effects(for: decoded, in: context, receivedAt: .now)
            for effect in effects {
                switch effect {
                case .markSeen(let id): context.seenInbound.insert(id)
                case .markPending(let request): context.pendingInbound.insert(request.id)
                case .clearPending(let id): context.pendingInbound.remove(id)
                default: break
                }
                kinds.append(effect.kind.description)
            }
        }
        return kinds
    }

    /// Runs of one kind collapsed, so an expectation reads as the shape of the session rather than as
    /// a wall of `publish(frame)`.
    private func runLengths(_ kinds: [String]) -> [String] {
        var out: [String] = []
        for kind in kinds {
            if let last = out.last, last == kind || last.hasPrefix(kind + " ×") {
                let n = Int(last.split(separator: "×").last.map(String.init) ?? "1") ?? 1
                out[out.count - 1] = "\(kind) ×\(last == kind ? 2 : n + 1)"
            } else {
                out.append(kind)
            }
        }
        return out
    }

    /// A whole recorded session, effect for effect: the MCP handshake the engine opens before it will
    /// answer `initialize`, the permission prompt the host surfaces, and the engine's echo of each
    /// answer the host wrote — which is what every `dropUncorrelated` below is.
    func testPermissionAllowReducesToItsRecordedEffects() throws {
        XCTAssertEqual(runLengths(try effectKinds(of: "permission-allow")), [
            "markSeen", "routeToMCP",                   // the server's JSON-RPC initialize, before frame 4
            "settleHandshake",
            "publish(frame)",
            "dropUncorrelated",                         // the engine echoing the host's JSON-RPC answer
            "markSeen", "routeToMCP",
            "dropUncorrelated",
            "markSeen", "routeToMCP",
            "publish(frame)",
            "dropUncorrelated",
            "publish(frame) ×27",
            "markSeen", "markPending", "publish(request)",
            "dropUncorrelated",
            "publish(frame) ×19",
            "settleOutbound",                           // end_session, the one request the host sent
            "publish(frame) ×2",
        ])
    }

    /// The dialog path, both branches. Four `refusal_fallback_prompt`s are a kind this host declared and
    /// are surfaced; the fifth is a kind it did not, so it is held pending and published as an unanswered
    /// dialog rather than answered. The engine then cancels that one: the cancel clears the pending
    /// entry, publishes `requestCancelled`, and publishes the cancel frame itself.
    func testRefusalFallbackDialogAndItsCancelReduceToTheirRecordedEffects() throws {
        let kinds = try effectKinds(of: "dialog-refusal-fallback")
        XCTAssertEqual(kinds.filter { $0 != "publish(frame)" }, [
            "settleHandshake",
            "markSeen", "markPending", "publish(request)",
            "markSeen", "markPending", "publish(request)",
            "markSeen", "markPending", "publish(request)",
            "markSeen", "markPending", "publish(request)",
            "markSeen", "markPending", "publish(unansweredDialog)",
            "clearPending", "publish(requestCancelled)", "cancelMCPTask",
        ])
    }

    /// The hook callback the host registered is surfaced rather than answered on its behalf; the MCP
    /// traffic is routed; the echoes of the host's two answers are dropped.
    func testNotificationHookReducesToItsRecordedEffects() throws {
        let kinds = try effectKinds(of: "notification-hook")
        XCTAssertEqual(kinds.filter { $0 != "publish(frame)" }, [
            "markSeen", "routeToMCP",
            "settleHandshake",
            "dropUncorrelated",
            "markSeen", "routeToMCP",
            "dropUncorrelated",
            "markSeen", "routeToMCP",
            "dropUncorrelated",
            "markSeen", "markPending", "publish(request)",      // hook_callback, a registered id
            "markSeen", "markPending", "publish(request)",      // can_use_tool
            "dropUncorrelated", "dropUncorrelated",             // the echoes of both answers
            "settleOutbound",                                   // end_session
        ])
    }

    /// The control-shape fixture drives twelve host-initiated control requests. Each response settles
    /// the waiter for it — the two the engine answered with an error included, because an error body is
    /// a settled request, not a dropped one — and only the three MCP echoes are uncorrelated.
    func testControlShapesSettlesEveryResponseItIsWaitingOn() throws {
        let kinds = try effectKinds(of: "control-shapes")
        XCTAssertEqual(kinds.filter { $0.hasPrefix("settle") || $0 == "dropUncorrelated" },
                       ["settleHandshake"] + Array(repeating: "dropUncorrelated", count: 3)
                        + Array(repeating: "settleOutbound", count: 13))
    }

    /// The host's own tool: `mcp_message` requests are routed to the server, never published as
    /// requests and never answered by the policy.
    func testSendUserFileRoutesEveryMCPMessage() throws {
        let kinds = try effectKinds(of: "send-user-file")
        XCTAssertEqual(kinds.filter { $0 == "routeToMCP" }.count, 4)
        XCTAssertFalse(kinds.contains("writeAnswer"))
    }
}
