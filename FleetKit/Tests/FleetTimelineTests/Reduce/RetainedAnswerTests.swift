import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// A settlement that arrives **before** the request it settles (scalpel-1#3).
///
/// Activity and `StreamIngestion` consume separate subscriptions of the same event stream, so the
/// order in which a `decisionAnswered` signal and the `control_request` frame it answers reach the
/// reducer is not fixed. Dropping a signal for an id the reducer has not seen left the request
/// opening as `.pending` afterwards — a card asking a question the host had already answered, which
/// is the state §6.4 exists to forbid.
///
/// Every identifier here is invented and nothing is read from disk: the reducer is driven with
/// values this file constructs.
final class RetainedAnswerTests: XCTestCase {

    // MARK: - Support

    /// A reducer over an invented stream. `TempTree` supplies the config-home-shaped root so that
    /// no path here can name a real config home (X9), and nothing in this suite writes to it.
    private func reducer(_ tree: TempTree) -> WireReducer {
        WireReducer(stream: LogicalStream(configHome: tree.root,
                                          sessionID: SessionID(uuid: UUID()),
                                          name: .main),
                    slug: "-invented-project")
    }

    /// A `can_use_tool` request for `AskUserQuestion`, which folds to a `.question` decision.
    /// Schema-shaped and hand-built: no recorded byte reaches this file.
    private func request(_ id: String) -> InboundRequest {
        let frame = ControlRequestFrame(requestID: RequestID(rawValue: id), request: .object([
            "subtype": .string("can_use_tool"),
            "tool_name": .string("AskUserQuestion"),
            "input": .object([:]),
            "tool_use_id": .string("toolu_invented_\(id)"),
        ]))
        return InboundRequest.parse(frame: frame, epoch: .first, receivedAt: .now)
    }

    private let moment = Date(timeIntervalSince1970: 0)

    // MARK: - The tests

    /// The discriminating clause: settlement first, then the frame. Before the retention the second
    /// half of this test found a `.pending` card, because `setDecision` returned at once for an id
    /// the overlay did not hold and nothing remembered the answer.
    func testASettlementBeforeTheRequestIsAppliedWhenTheRequestArrives() throws {
        let tree = try TempTree()
        var reducer = reducer(tree)
        let inbound = request("afleet-invented-request-0001")

        let early = reducer.apply(.decisionAnswered(inbound.id, outcome: .answered(summary: "option-b")),
                                  at: moment)
        XCTAssertEqual(early.count, 0,
                       "\(early.count) changes were published for a request nothing has opened")

        _ = reducer.apply(.request(inbound), at: moment)

        XCTAssertEqual(reducer.overlay.decisions[inbound.id]?.state, .answered(outcome: "option-b"),
                       "the request opened without the settlement that preceded it")
    }

    /// And the retention is spent by the request it belongs to: a card the user reopens — a second
    /// request carrying the same id — is pending again rather than born answered.
    func testARetainedSettlementIsSpentByTheRequestItSettles() throws {
        let tree = try TempTree()
        var reducer = reducer(tree)
        let inbound = request("afleet-invented-request-0002")

        _ = reducer.apply(.decisionAnswered(inbound.id, outcome: .allowed), at: moment)
        _ = reducer.apply(.request(inbound), at: moment)
        XCTAssertEqual(reducer.overlay.decisions[inbound.id]?.state, .answered(outcome: "allowed"))

        _ = reducer.apply(.request(inbound), at: moment)
        XCTAssertEqual(reducer.overlay.decisions[inbound.id]?.state, .pending,
                       "a spent settlement was applied a second time")
    }

    /// A process that went away takes its unmatched settlements with it: the ids belong to the
    /// exited process's requests, and a new process's ids are its own.
    func testProcessExitDropsRetainedSettlements() throws {
        let tree = try TempTree()
        var reducer = reducer(tree)
        let inbound = request("afleet-invented-request-0003")

        _ = reducer.apply(.decisionAnswered(inbound.id, outcome: .allowed), at: moment)
        _ = reducer.apply(.processReplaced(ProcessEpoch.first.next()), at: moment)
        _ = reducer.apply(.request(inbound), at: moment)

        XCTAssertEqual(reducer.overlay.decisions[inbound.id]?.state, .pending,
                       "a settlement survived the process whose request it answered")
    }

    /// The retention is bounded. Signals for requests that never arrive — a cancelled channel, a
    /// process that died mid-turn — would otherwise accumulate for the life of the fold, so the
    /// oldest is dropped past the limit and the newest are the ones that still apply.
    func testTheRetentionIsBoundedAndDropsTheOldest() throws {
        let tree = try TempTree()
        var reducer = reducer(tree)
        let limit = WireReducer.retainedAnswerLimit
        let oldest = request("afleet-invented-request-oldest")
        _ = reducer.apply(.decisionAnswered(oldest.id, outcome: .allowed), at: moment)
        for index in 0..<limit {
            _ = reducer.apply(.decisionAnswered(RequestID(rawValue: "afleet-invented-filler-\(index)"),
                                                outcome: .allowed), at: moment)
        }
        let newest = request("afleet-invented-filler-\(limit - 1)")

        _ = reducer.apply(.request(oldest), at: moment)
        _ = reducer.apply(.request(newest), at: moment)

        XCTAssertEqual(reducer.overlay.decisions[oldest.id]?.state, .pending,
                       "a settlement past the retention limit was still held")
        XCTAssertEqual(reducer.overlay.decisions[newest.id]?.state, .answered(outcome: "allowed"),
                       "the newest settlement was dropped instead of the oldest")
    }
}
