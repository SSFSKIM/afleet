import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// What `ClaudeProcess` would have pushed for a recorded fixture, reproduced from the recording rather than by
/// re-running it.
///
/// Out-direction frames go through C2's own `WireEventPolicy` — the same pure function the transport calls, over a
/// `Context` this replay threads exactly as the actor does — so a control request is never a `.frame` here either.
/// In-direction frames are what the host did and become `HostSignal`s. Nothing here re-implements the mapping, and
/// nothing here asserts a fixture byte.
enum FixtureWireReplay {

    struct Step {
        let t: Int
        let events: [WireEvent]
        let signal: HostSignal?
    }

    /// Everything one walk produced, so a test can assert on the policy's own bookkeeping and not only on the events.
    struct Trace {
        let steps: [Step]
        /// The `Context` after the last out-direction frame — `pendingOutbound`, `pendingInbound`, `seenInbound`.
        let context: WireEventPolicy.Context
        /// Every effect kind in order, named by `Effect.Kind.description`, never by payload.
        let effectKinds: [String]
        /// The ids the host's own `control_request`s put into `pendingOutbound` before the walk began.
        let hostRequestIDs: Set<RequestID>
        let handshakeRequestID: RequestID
        /// Request ids the policy surfaced or left unanswered, with the subtype each carried.
        let surfaced: [RequestID: String]
    }

    // MARK: - The recorded policy

    /// `InboundPolicy.default(...)` from the fixture's own `initialize` request: `supportedDialogKinds` and every
    /// `hooks.*[].hookCallbackIds`. Verbatim in shape from ClaudeWire's `WireEventPolicyFixtureTests`.
    static func policy(for fx: FixtureCorpus.Fixture) throws -> InboundPolicy {
        let request = try initialize(fx).request
        let kinds = request["supportedDialogKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let callbacks = (request["hooks"]?.objectValue ?? [:]).values.flatMap { matchers in
            matchers.arrayValue?.flatMap { $0["hookCallbackIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] } ?? []
        }
        return InboundPolicy.default(declaredDialogKinds: Set(kinds), registeredHookCallbackIDs: Set(callbacks))
    }

    /// The value the transport builds: the recorded policy under the id the recording's own `initialize` was sent as.
    static func wirePolicy(for fx: FixtureCorpus.Fixture) throws -> WireEventPolicy {
        WireEventPolicy(policy: try policy(for: fx), handshakeRequestID: try initialize(fx).id)
    }

    private static func initialize(_ fx: FixtureCorpus.Fixture) throws -> (id: RequestID, request: JSONValue) {
        for recorded in try fx.frames() where recorded.direction == "in" {
            guard case .controlRequest(let request) = recorded.frame, request.subtype == "initialize" else { continue }
            return (request.requestID, request.request)
        }
        throw FixtureCorpus.Failure("fixture \(fx.name): no in-direction initialize control_request")
    }

    // MARK: - The walk

    static func steps(for fx: FixtureCorpus.Fixture, epoch: ProcessEpoch = .first) throws -> [Step] {
        try trace(for: fx, epoch: epoch).steps
    }

    /// One `WireEventPolicy.Context` per recording, threaded frame by frame in `t` order.
    ///
    /// The host's own `control_request`s go into `pendingOutbound` — the sender populates that set in the actor, so
    /// the replay does it here. Out-direction frames go to `effects(for:in:receivedAt:)`; the state effects
    /// (`settleOutbound`, `dropUncorrelated`, `markSeen`, `markPending`, `clearPending`) are applied to the context,
    /// `writeAnswer`, `recordPolicyAnswer`, `routeToMCP` and `cancelMCPTask` are the actor's side effects and are
    /// discarded, and `settleHandshake(body)` re-arms the body's pending requests exactly as the actor does. Only
    /// `.publish(event)` reaches the reducer, in order.
    static func trace(for fx: FixtureCorpus.Fixture, epoch: ProcessEpoch = .first) throws -> Trace {
        let recorded = try fx.frames().sorted { $0.t == $1.t ? $0.index < $1.index : $0.t < $1.t }
        let wire = try wirePolicy(for: fx)
        var context = WireEventPolicy.Context(epoch: epoch)
        var hostRequestIDs: Set<RequestID> = []
        var rewindRequestIDs: Set<RequestID> = []
        for frame in recorded where frame.direction == "in" {
            guard case .controlRequest(let request) = frame.frame else { continue }
            hostRequestIDs.insert(request.requestID)
            if request.subtype == "rewind_conversation" { rewindRequestIDs.insert(request.requestID) }
            context.pendingOutbound.insert(request.requestID)
        }

        var steps: [Step] = []
        var kinds: [String] = []
        var surfaced: [RequestID: String] = [:]

        func consume(_ effects: [WireEventPolicy.Effect], into events: inout [WireEvent]) {
            for effect in effects {
                kinds.append(effect.kind.description)
                switch effect {
                case .settleHandshake(let body):
                    // What the actor does with the handshake body: every re-armed request is marked seen and then
                    // decided, so a permission the engine restates at the handshake surfaces exactly once.
                    guard case .success(let success) = body else { break }
                    for request in success.pendingPermissionRequests + success.pendingUserDialogRequests {
                        let inbound = InboundRequest.parse(frame: request, epoch: context.epoch, receivedAt: .now)
                        guard !context.seenInbound.contains(inbound.id) else { continue }
                        context.seenInbound.insert(inbound.id)
                        consume(wire.effects(deciding: inbound), into: &events)
                    }
                case .settleOutbound(let id, _), .dropUncorrelated(let id):
                    context.pendingOutbound.remove(id)
                case .markSeen(let id):
                    context.seenInbound.insert(id)
                case .markPending(let request):
                    context.pendingInbound.insert(request.id)
                    surfaced[request.id] = request.subtype
                case .clearPending(let id):
                    context.pendingInbound.remove(id)
                case .writeAnswer, .recordPolicyAnswer, .routeToMCP, .cancelMCPTask:
                    break
                case .publish(let event):
                    events.append(event)
                }
            }
        }

        for frame in recorded {
            if frame.direction == "in" {
                guard let signal = hostSignal(of: frame, surfaced: surfaced) else { continue }
                steps.append(Step(t: frame.t, events: [], signal: signal))
                continue
            }
            var events: [WireEvent] = []
            consume(wire.effects(for: frame.frame, in: context, receivedAt: .now), into: &events)
            if !events.isEmpty { steps.append(Step(t: frame.t, events: events, signal: nil)) }
            // The one host action the engine reports back rather than being told: a rewind the host asked for and the
            // engine honoured. In production the host reads its own `rewind_conversation` answer and hands the
            // reducer the `.rewound` itself, so the replay does the same, as its own step at the same instant.
            if let signal = rewindSignal(of: frame.frame, requests: rewindRequestIDs) {
                steps.append(Step(t: frame.t, events: [], signal: signal))
            }
        }

        return Trace(steps: steps, context: context, effectKinds: kinds, hostRequestIDs: hostRequestIDs,
                     handshakeRequestID: wire.handshakeRequestID, surfaced: surfaced)
    }

    /// The in-direction mapping, C3's own: a `user` frame is a prompt the host sent, and a `control_response`
    /// answering a request the replay surfaced is the host's decision. The `initialize` request and interrupts are
    /// neither.
    private static func hostSignal(of recorded: FixtureCorpus.RecordedFrame,
                                   surfaced: [RequestID: String]) -> HostSignal? {
        switch recorded.frame {
        case .user(let user):
            guard let uuid = user.uuid else { return nil }
            return .promptSent(uuid: uuid, at: Date(timeIntervalSince1970: Double(recorded.t) / 1000))
        case .controlResponse(let response):
            guard let subtype = surfaced[response.requestID] else { return nil }
            return .decisionAnswered(response.requestID, outcome: outcome(of: response.body, subtype: subtype))
        default:
            return nil
        }
    }

    /// The `control_response` to a `rewind_conversation` the host sent, read the way a host must read it: both legs
    /// answer inside a `success` envelope, so only the body says which happened. `rewound: true` carries
    /// `precedingAssistantUuid`, the record the transcript's leaf moves to and therefore the last row that survives;
    /// `rewound: false` carries a body-level `error` and changed nothing, so it produces no signal at all.
    private static func rewindSignal(of frame: Frame, requests: Set<RequestID>) -> HostSignal? {
        guard case .controlResponse(let response) = frame, requests.contains(response.requestID),
              case .success(let success) = response.body,
              success.response?["rewound"]?.boolValue == true,
              let uuid = success.response?["precedingAssistantUuid"]?.stringValue else { return nil }
        return .rewound(toUUID: uuid)
    }

    private static func outcome(of body: ControlResponseBody, subtype: String) -> DecisionOutcome {
        switch body {
        case .error:
            return .cancelled
        case .success(let success):
            switch success.response?["behavior"]?.stringValue {
            case "allow": return .allowed
            case "deny": return .denied(message: success.response?["message"]?.stringValue)
            default: return .answered(summary: subtype)
            }
        }
    }

    // MARK: - The reducer

    /// A reducer seeded from `initial/` when the fixture has one — the record reducer's merged projection of those
    /// files, which is what `StreamIngestion.open` hands the wire reducer on a resume — else empty.
    static func reducer(for fx: FixtureCorpus.Fixture) throws -> WireReducer {
        let stream = LogicalStream(configHome: FixtureCorpus.recordedConfigHome, sessionID: fx.sessionID, name: .main)
        return WireReducer(stream: stream, slug: try slug(of: fx), seed: try seed(for: fx))
    }

    /// The record reducer over `initial/`, merged. Empty where `initial/` holds only its `.gitkeep`.
    static func seed(for fx: FixtureCorpus.Fixture) throws -> DurableProjection {
        let files = try fx.initialFiles()
        guard !files.isEmpty else { return .empty }
        var projections: [StreamProjection] = []
        var main: LogicalStream?
        for (stream, kind, url) in files {
            let records = try TranscriptReader(url: url).readAll().records
            projections.append(RecordReducer.reduce(records, stream: stream, sourceFile: url))
            if case .mainTranscript = kind { main = stream }
        }
        guard let main else { throw FixtureCorpus.Failure("fixture \(fx.name): initial/ holds no main transcript") }
        return RecordReducer.merge(projections, main: main)
    }

    /// The project-directory alias the recording's transcripts live under (`_slug_` in every committed fixture).
    static func slug(of fx: FixtureCorpus.Fixture) throws -> String {
        for (_, kind, _) in try fx.transcriptFiles() + fx.initialFiles() {
            switch kind {
            case .mainTranscript(let slug), .agentTranscript(let slug, _), .agentMetadata(let slug, _): return slug
            }
        }
        return "_slug_"
    }

    /// `reducer(for:)`, then every step in `t` order.
    static func replay(_ fx: FixtureCorpus.Fixture) throws -> WireReducer {
        var reducer = try reducer(for: fx)
        for step in try steps(for: fx) { apply(step, to: &reducer) }
        return reducer
    }

    /// One step against a reducer, at the step's own recorded instant.
    @discardableResult
    static func apply(_ step: Step, to reducer: inout WireReducer) -> [TimelineChange] {
        let now = Date(timeIntervalSince1970: Double(step.t) / 1000)
        var changes: [TimelineChange] = []
        for event in step.events { changes.append(contentsOf: reducer.apply(event, at: now)) }
        if let signal = step.signal { changes.append(contentsOf: reducer.apply(signal, at: now)) }
        return changes
    }
}
