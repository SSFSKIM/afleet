import XCTest
import WireFrames
@testable import FleetSessions

final class DormantEligibilityTests: XCTestCase {
    func base() -> DormantEligibility.Input {
        .init(turnRunning: false, pendingDecisions: 0, queuedInput: 0, mirror: [], lastTaskFrameAge: nil, heartbeatInterval: .seconds(30), wedged: false)
    }
    func entry(_ id: String, running: Bool, armed: Bool = false) -> MirrorEntryStandIn { .init(taskID: id, isRunning: running, isArmed: armed, isBackground: true) }
    func testAllFiveConditionsClearMeansEligible() { XCTAssertTrue(DormantEligibility.evaluate(base()).isEligible) }
    func testEachConditionAloneBlocks() {
        var i = base(); i.turnRunning = true; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.turnRunning))
        i = base(); i.pendingDecisions = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.pendingDecision))
        i = base(); i.queuedInput = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.queuedInput))
        i = base(); i.mirror = [entry("t1", running: true)]; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskRunning("t1")))
    }
    /// The boundary cases Task 11 repeats over C3's real mirror; the two tests must agree case for case.
    func testTheMirrorBoundaryCases() {
        var i = base(); i.mirror = [entry("t1", running: false, armed: true)]
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskArmed("t1")))                       // armed blocks
        i = base(); i.mirror = [entry("t1", running: true)]; i.lastTaskFrameAge = .seconds(31)
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskStateUncertain("t1")))              // running and stale is uncertainty
        i = base(); i.mirror = [entry("t1", running: true)]; i.lastTaskFrameAge = .seconds(29)
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskRunning("t1")))                     // running and fresh is a running task
        i = base(); i.mirror = []; i.lastTaskFrameAge = .seconds(3_600)
        XCTAssertTrue(DormantEligibility.evaluate(i).isEligible)                                          // an old frame with nothing running or armed is history
        i = base(); i.mirror = [entry("t0", running: false)]; i.lastTaskFrameAge = .seconds(3_600)
        XCTAssertTrue(DormantEligibility.evaluate(i).isEligible)                                          // a completed entry is history too
        // Deliberate break: make any stale frame uncertain regardless of the mirror -> the fourth case blocks and a channel
        // that finished a task an hour ago never reaps.
    }
    func testAWedgedChannelIsNeverEligible() {
        var i = base(); i.wedged = true; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.wedged))
        // Deliberate break: remove the wedged check -> eligible, and the cap in Task 5 would evict a ghost.
    }
}
