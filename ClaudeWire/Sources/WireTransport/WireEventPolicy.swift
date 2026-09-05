import Foundation
import AfleetCore
import WireFrames

/// What one engine-to-host frame means, as a value.
///
/// This is the whole of `ClaudeProcess`'s frame-to-event mapping, lifted out of the actor so that
/// something which is not a live process — a fixture replay, parent C3's timeline — can reduce the
/// same frames to the same events without a second copy of the rules to keep in step. The actor is
/// the mapping's only caller in production: `receive(line:)` decodes, records, captures, then asks
/// this for a list of effects and performs them in order.
///
/// The function is pure. It reads no actor state, performs no I/O, and returns effects rather than
/// doing anything, so everything that depends on live state — a waiter to settle, a write, an MCP
/// task to cancel — is named in the result and carried out by whoever owns that state. `Context` is
/// the only view of that state it takes, and it is a snapshot of sets, not a reference.
///
/// The order of the returned effects is the order the actor performed them in, and is part of the
/// contract: an answer is written before the event announcing it, a request is marked pending before
/// it is published, a cancel's `requestCancelled` precedes the cancel frame itself.
public struct WireEventPolicy: Sendable {
    /// §6.3, which decides what to do with an inbound request.
    public let policy: InboundPolicy
    /// The id the handshake's own `initialize` was sent under. A response to it settles the handshake
    /// and publishes nothing; it is never an ordinary correlated response.
    public let handshakeRequestID: RequestID

    /// The id `ClaudeProcess.spawn` sends `initialize` under.
    public static let defaultHandshakeRequestID = RequestID(rawValue: "init-1")

    public init(policy: InboundPolicy, handshakeRequestID: RequestID = WireEventPolicy.defaultHandshakeRequestID) {
        self.policy = policy
        self.handshakeRequestID = handshakeRequestID
    }

    /// The host state the mapping consults, snapshotted. Nothing here is mutated: the effects say how
    /// it changes, and the caller applies them.
    public struct Context: Sendable {
        /// Requests the host has sent and is waiting on a response for.
        public var pendingOutbound: Set<RequestID>
        /// Inbound requests the host is holding — surfaced or left unanswered — and can still cancel.
        public var pendingInbound: Set<RequestID>
        /// Every inbound request id the host has already decided on, including those re-armed at the
        /// handshake. A second arrival of one of these is a duplicate and means nothing.
        public var seenInbound: Set<RequestID>
        public var epoch: ProcessEpoch

        public init(pendingOutbound: Set<RequestID> = [], pendingInbound: Set<RequestID> = [],
                    seenInbound: Set<RequestID> = [], epoch: ProcessEpoch) {
            self.pendingOutbound = pendingOutbound; self.pendingInbound = pendingInbound
            self.seenInbound = seenInbound; self.epoch = epoch
        }
    }

    /// One thing the frame means. Performed in the order returned.
    public enum Effect: Sendable {
        /// The response to `initialize`. Its pending requests are registered and the handshake waiter
        /// is settled from the body; nothing is published.
        case settleHandshake(ControlResponseBody)
        /// A response the host was waiting on: settle that waiter.
        case settleOutbound(RequestID, ControlResponseBody)
        /// A response for an id nobody is waiting on. Ordinary traffic after an honoured cancel, so it
        /// is recorded and dropped — never an error, never an event.
        case dropUncorrelated(RequestID)
        /// Remember this inbound id, so its re-transmission is recognised as a duplicate.
        case markSeen(RequestID)
        /// Hold this request as answerable by the host.
        case markPending(InboundRequest)
        /// Forget a held request: the engine cancelled it.
        case clearPending(RequestID)
        /// Answer the request on the host's behalf. A failure to write is not an error here — the
        /// child is gone — and does not change what follows.
        case writeAnswer(RequestID, InboundAnswer, subtype: String)
        /// A policy answer that is not an error: recorded, not published.
        case recordPolicyAnswer(RequestID, subtype: String)
        /// Hand the request to the in-process MCP server. `offReader` marks a JSON-RPC request — a
        /// `tools/call` can run long, so it must not hold the reader, and `notifications/cancelled`
        /// has to reach the server while it does.
        case routeToMCP(InboundRequest, offReader: Bool)
        /// Cancel the MCP task running for this id, if there is one. Emitted for every cancel frame:
        /// whether a task is in flight is the caller's knowledge, and cancelling nothing is a no-op.
        case cancelMCPTask(RequestID)
        /// Put this on the event stream.
        case publish(WireEvent)

        /// What this effect is, without what it carries. The vocabulary tests assert in, and the one
        /// thing a fixture-replay assertion may name — a kind is the transport's own word, an effect's
        /// payload is engine bytes.
        public var kind: Kind {
            switch self {
            case .settleHandshake: .settleHandshake
            case .settleOutbound: .settleOutbound
            case .dropUncorrelated: .dropUncorrelated
            case .markSeen: .markSeen
            case .markPending: .markPending
            case .clearPending: .clearPending
            case .writeAnswer: .writeAnswer
            case .recordPolicyAnswer: .recordPolicyAnswer
            case .routeToMCP: .routeToMCP
            case .cancelMCPTask: .cancelMCPTask
            case .publish(let event): .publish(event.kind)
            }
        }

        public enum Kind: Hashable, Sendable, CustomStringConvertible {
            case settleHandshake, settleOutbound, dropUncorrelated, markSeen, markPending, clearPending
            case writeAnswer, recordPolicyAnswer, routeToMCP, cancelMCPTask
            case publish(WireEvent.Kind)

            public var description: String {
                switch self {
                case .settleHandshake: "settleHandshake"
                case .settleOutbound: "settleOutbound"
                case .dropUncorrelated: "dropUncorrelated"
                case .markSeen: "markSeen"
                case .markPending: "markPending"
                case .clearPending: "clearPending"
                case .writeAnswer: "writeAnswer"
                case .recordPolicyAnswer: "recordPolicyAnswer"
                case .routeToMCP: "routeToMCP"
                case .cancelMCPTask: "cancelMCPTask"
                case .publish(let event): "publish(\(event.rawValue))"
                }
            }
        }
    }

    /// The mapping. `receivedAt` stamps a parsed inbound request, which is the only place time enters.
    public func effects(for frame: Frame, in context: Context, receivedAt: ContinuousClock.Instant) -> [Effect] {
        switch frame {
        case .controlResponse(let response):
            if response.requestID == handshakeRequestID { return [.settleHandshake(response.body)] }
            guard context.pendingOutbound.contains(response.requestID) else { return [.dropUncorrelated(response.requestID)] }
            return [.settleOutbound(response.requestID, response.body), .publish(.frame(frame, context.epoch))]

        case .controlRequest(let request):
            let inbound = InboundRequest.parse(frame: request, epoch: context.epoch, receivedAt: receivedAt)
            // A live duplicate of a request re-armed at the handshake. Already decided; decide nothing.
            guard !context.seenInbound.contains(inbound.id) else { return [] }
            return [.markSeen(inbound.id)] + effects(deciding: inbound)

        case .controlCancelRequest(let cancel):
            var effects: [Effect] = []
            if context.pendingInbound.contains(cancel.requestID) {
                effects.append(.clearPending(cancel.requestID))
                effects.append(.publish(.requestCancelled(cancel.requestID, context.epoch)))
            }
            effects.append(.cancelMCPTask(cancel.requestID))
            effects.append(.publish(.frame(frame, context.epoch)))
            return effects

        default:
            return [.publish(.frame(frame, context.epoch))]
        }
    }

    /// §6.3's decision, as effects. Separate from `effects(for:in:receivedAt:)` because the handshake
    /// takes this path too: a request the engine re-armed in the initialize response has already been
    /// parsed and marked seen, and must then be treated exactly like one arriving live.
    public func effects(deciding request: InboundRequest) -> [Effect] {
        switch policy.decide(request) {
        case .surface:
            return [.markPending(request), .publish(.request(request))]
        case .answer(let answer):
            let write = Effect.writeAnswer(request.id, answer, subtype: request.subtype)
            if case .error(let message) = answer { return [write, .publish(.policyAnswered(request, error: message))] }
            return [write, .recordPolicyAnswer(request.id, subtype: request.subtype)]
        case .leaveUnanswered:
            return [.markPending(request), .publish(.unansweredDialog(request))]
        case .routeToMCP:
            // Only an `mcp_message` can be routed; the policy returns this decision for nothing else.
            guard case .mcpMessage(let message) = request.payload else { return [] }
            if case .request = message.message { return [.routeToMCP(request, offReader: true)] }
            return [.routeToMCP(request, offReader: false)]
        }
    }
}
