import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The Activity query is a pure function over channel states, C3's mirror and the recent frames of each channel.
///
/// Every frame here is composed in the test with invented identifiers rather than lifted from a recording: the
/// shapes are the protocol's, the bytes are the test's own (root `CLAUDE.md`, spec §11).
final class ActivityQueryTests: XCTestCase {

    private let home = URL(filePath: "/tmp/afleet-activity-home")

    private func key(_ session: SessionID = SessionID()) -> ChannelKey {
        ChannelKey(configHome: home, session: session)
    }

    private func state(_ key: ChannelKey, decisions: [PendingDecision] = [],
                       systemItem: SystemItem? = nil) -> ChannelState {
        ChannelState(key: key, origin: .owned(.ready), desired: .owned,
                     observed: HolderSet(holders: [], observedAt: Date()),
                     identity: .known(key.session), systemItem: systemItem,
                     pendingDecisions: decisions, lastActivity: Date())
    }

    private func decision(_ id: String, _ subtype: String, at seconds: Double) -> PendingDecision {
        PendingDecision(id: RequestID(rawValue: id), subtype: subtype, epoch: .first,
                        askedAt: Date(timeIntervalSince1970: seconds))
    }

    /// One frame, decoded from the object the test composed, so what the query reads is what the decoder produces.
    private func frame(_ object: [String: Any]) throws -> Frame {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let frame = FrameDecoder.decode(line: data)
        if case .opaque(let opaque) = frame {
            XCTFail("the composed frame did not decode: \(String(describing: opaque.reason))")
        }
        return frame
    }

    private func result(uuid: String, isError: Bool, subtype: String = "success",
                        permissionDenials: [[String: Any]]? = nil) throws -> Frame {
        var object: [String: Any] = ["type": "result", "subtype": subtype, "duration_ms": 1, "is_error": isError,
                                     "num_turns": 1, "total_cost_usd": 0, "uuid": uuid,
                                     "session_id": "00000000-0000-4000-8000-00000000aaaa"]
        if let permissionDenials { object["permission_denials"] = permissionDenials }
        return try frame(object)
    }

    private func rateLimit(uuid: String, info: [String: Any]) throws -> Frame {
        try frame(["type": "rate_limit_event", "rate_limit_info": info, "uuid": uuid,
                   "session_id": "00000000-0000-4000-8000-00000000aaaa"])
    }

    private func authStatus(uuid: String, error: String?) throws -> Frame {
        var object: [String: Any] = ["type": "auth_status", "isAuthenticating": false, "output": [],
                                     "uuid": uuid, "session_id": "00000000-0000-4000-8000-00000000aaaa"]
        if let error { object["error"] = error }
        return try frame(object)
    }

    private func permissionDenied(uuid: String, tool: String) throws -> Frame {
        try frame(["type": "system", "subtype": "permission_denied", "tool_name": tool,
                   "tool_use_id": "toolu_aaa", "message": "denied", "uuid": uuid,
                   "session_id": "00000000-0000-4000-8000-00000000aaaa"])
    }

    private func taskNotification(uuid: String, task: String, status: String) throws -> Frame {
        try frame(["type": "system", "subtype": "task_notification", "task_id": task, "status": status,
                   "output_file": "", "summary": "", "uuid": uuid,
                   "session_id": "00000000-0000-4000-8000-00000000aaaa"])
    }

    private func notification(uuid: String, text: String) throws -> Frame {
        try frame(["type": "system", "subtype": "notification", "key": "k", "text": text, "priority": "normal",
                   "uuid": uuid, "session_id": "00000000-0000-4000-8000-00000000aaaa"])
    }

    // MARK: - Decisions

    /// `ChannelState.pendingDecisions` is the source, one row per entry, in ask order.
    func testTwoPendingDecisionsOnOneChannelBecomeTwoRowsInAskOrder() {
        let k = key()
        let first = decision("req-1", "can_use_tool", at: 10)
        let second = decision("req-2", "hook_callback", at: 20)
        let rows = ActivityQuery.rows(states: [state(k, decisions: [first, second])], mirrors: [:], recent: [:])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.kind), [.decision(first.id), .decision(second.id)])
        XCTAssertEqual(rows.map(\.key), [k, k])
        XCTAssertEqual(rows.map(\.text), ["can_use_tool", "hook_callback"])
        XCTAssertEqual(rows.compactMap(\.itemUUID), [], "a decision is not a transcript item")
    }

    // MARK: - Results, denials and notifications

    func testAFailedResultAndItsPermissionDenialsEachBecomeARow() throws {
        let k = key()
        let failed = try result(uuid: "uuid-result-1", isError: true, subtype: "error_during_execution",
                                permissionDenials: [["tool_name": "Bash"]])
        let rows = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [failed]])

        XCTAssertEqual(rows.map(\.kind), [.failedResult, .permissionDenied])
        XCTAssertEqual(rows.map(\.itemUUID), ["uuid-result-1", "uuid-result-1"])
        XCTAssertEqual(rows[0].text, "error_during_execution")
        XCTAssertEqual(rows[1].text, "Bash")
    }

    func testASystemPermissionDeniedAndANotificationEachBecomeARow() throws {
        let k = key()
        let denied = try permissionDenied(uuid: "uuid-denied", tool: "Write")
        let note = try notification(uuid: "uuid-note", text: "the hook says hello")
        let rows = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [denied, note]])

        XCTAssertEqual(rows.map(\.kind), [.permissionDenied, .notification])
        XCTAssertEqual(rows.map(\.itemUUID), ["uuid-denied", "uuid-note"])
        XCTAssertEqual(rows[0].text, "Write")
        XCTAssertEqual(rows[1].text, "the hook says hello")
    }

    func testACleanResultProducesNoRow() throws {
        let k = key()
        let clean = try result(uuid: "uuid-ok", isError: false)
        XCTAssertEqual(ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [clean]]), [])
    }

    // MARK: - Rate limits

    /// `status` alone decides. An allowed window whose *overage* was rejected because the organisation disabled it
    /// is not a refusal of anything the user asked for, and rendering it as one would tell them they had been cut
    /// off mid-turn when they had not.
    func testAnAllowedWindowWithARejectedOverageIsABannerAndNeverARefusal() throws {
        let k = key()
        let event = try rateLimit(uuid: "uuid-rate-1",
                                  info: ["status": "allowed", "overageStatus": "rejected",
                                         "overageDisabledReason": "org_level_disabled"])
        let rows = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [event]])

        XCTAssertEqual(rows.map(\.kind), [.rateLimitInfo])
        XCTAssertFalse(rows.contains { $0.kind == .rateLimitRefused }, "the overage status is not the status")
        XCTAssertEqual(rows[0].itemUUID, "uuid-rate-1")
        XCTAssertEqual(rows[0].text, "allowed")
    }

    func testARejectedStatusIsARefusal() throws {
        let k = key()
        let event = try rateLimit(uuid: "uuid-rate-2",
                                  info: ["status": "rejected", "overageStatus": "rejected",
                                         "overageDisabledReason": "out_of_credits"])
        let rows = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [event]])
        XCTAssertEqual(rows.map(\.kind), [.rateLimitRefused])
        XCTAssertEqual(rows[0].text, "rejected")
    }

    // MARK: - Auth

    func testAnAuthStatusErrorRaisesARowAndAHealthyOneClearsIt() throws {
        let k = key()
        let broken = try authStatus(uuid: "uuid-auth-1", error: "token expired")
        let healthy = try authStatus(uuid: "uuid-auth-2", error: nil)

        let raised = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [broken]])
        XCTAssertEqual(raised.map(\.kind), [.authProblem])
        XCTAssertEqual(raised[0].itemUUID, "uuid-auth-1")
        XCTAssertEqual(raised[0].text, "token expired")

        let cleared = ActivityQuery.rows(states: [state(k)], mirrors: [:], recent: [k: [broken, healthy]])
        XCTAssertEqual(cleared, [], "a healthy auth_status clears the channel's auth rows")
    }

    // MARK: - Agent runs

    func testARunningMirrorEntryAndAFailedTaskNotificationEachBecomeARow() throws {
        let k = key()
        let running = MirrorEntryStandIn(taskID: "task-running", isRunning: true, isBackground: true)
        let armed = MirrorEntryStandIn(taskID: "task-armed", isRunning: false, isArmed: true, isBackground: false)
        let failed = try taskNotification(uuid: "uuid-task-1", task: "task-failed", status: "failed")
        let completed = try taskNotification(uuid: "uuid-task-2", task: "task-done", status: "completed")

        let rows = ActivityQuery.rows(states: [state(k)], mirrors: [k: [running, armed]],
                                      recent: [k: [failed, completed]])

        XCTAssertEqual(rows.map(\.kind), [.agentFailed("task-failed"), .agentRunning("task-running")])
        XCTAssertEqual(rows[0].itemUUID, "uuid-task-1")
        XCTAssertNil(rows[1].itemUUID, "a mirror entry is not a transcript item")
        XCTAssertEqual(rows[1].text, "task-running")
    }

    // MARK: - System items

    /// Every `SystemItem` has an arm, the fork's identity deadline included: the channel is left with no process and
    /// the offer to reopen, and Activity is where the user finds it.
    func testEverySystemItemBecomesARow() {
        let crashed = key(); let wedgedKey = key(); let forked = key()
        let trace = EscalationTrace(steps: ["sigterm", "sigkill"], pid: 4242, epoch: .first)
        let rows = ActivityQuery.rows(
            states: [state(crashed, systemItem: .crashed(exit: .code(2, stderrTail: ""), reopenOffered: true)),
                     state(wedgedKey, systemItem: .wedged(trace, reopenOffered: true)),
                     state(forked, systemItem: .forkIdentityTimedOut(exit: .signal(9, stderrTail: ""),
                                                                     reopenOffered: true))],
            mirrors: [:], recent: [:])

        XCTAssertEqual(rows.map(\.key), [crashed, wedgedKey, forked])
        XCTAssertEqual(rows.map(\.kind), [.systemItem(.crashed(exit: .code(2, stderrTail: ""), reopenOffered: true)),
                                          .systemItem(.wedged(trace, reopenOffered: true)),
                                          .systemItem(.forkIdentityTimedOut(exit: .signal(9, stderrTail: ""),
                                                                            reopenOffered: true))])
        XCTAssertEqual(rows.map(\.text), ["crashed", "wedged", "forkIdentityTimedOut"])
    }

    // MARK: - Several channels

    func testRowsCarryTheirOwnChannelKeyAcrossChannels() throws {
        let a = key(), b = key()
        let denial = try permissionDenied(uuid: "uuid-a", tool: "Bash")
        let rows = ActivityQuery.rows(states: [state(a, decisions: [decision("r", "can_use_tool", at: 1)]),
                                               state(b)],
                                      mirrors: [:], recent: [b: [denial]])
        XCTAssertEqual(rows.map(\.key), [a, b])
        XCTAssertEqual(rows.map(\.kind), [.decision(RequestID(rawValue: "r")), .permissionDenied])
    }
}
