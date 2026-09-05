import XCTest
@testable import FleetSessions

final class LifecycleTableTests: XCTestCase {
    func testTheTableHasOneRowPerParentRowAndEveryRowHasAScenario() {
        // The parent's §7.4 table, in its order; its combined "handoff wait exceeds 10 s, or desired and observed disagree"
        // row is two rows here because the two are raised from different places and G1 must see both fire.
        let expected: Set<LifecycleTable.Row> = [
            .archivedRecentOpened, .archivedOlderOpened, .archivedOlderSent,
            .connectingClean, .connectingFoundHolder,
            .readyDormantEligible, .dormantSent, .dormantHolderAppeared,
            .terminateExhausted, .exitedNonZero, .capReached,
            .jobAdopt, .ownedSendToBackground, .ownedOpenInTerminal, .ownTabExited,
            .foreignRecordGone, .foreignSendRefused, .handoffTimedOut, .desiredObservedDisagree, .contendedSettled,
            .handoffPreempted,
        ]
        XCTAssertEqual(Set(LifecycleTable.Row.allCases), expected)
        XCTAssertEqual(Set(LifecycleTable.scenarios.map(\.row)), expected)
        // Deliberate break: drop every `.terminateExhausted` scenario -> the second assertion names it.
    }
    func testScenariosAreConcreteAndDistinct() {
        XCTAssertEqual(Set(LifecycleTable.scenarios).count, LifecycleTable.scenarios.count, "a duplicated scenario")
        // No `.any`: every scenario names the from-state it applies to, so coverage can demand each one.
    }
    func testTheTwoContendedEventsAndEveryTerminatingActionAreInTheTable() {
        XCTAssertTrue(LifecycleTable.scenarios.contains { $0.event == .handoffTimedOut })
        XCTAssertTrue(LifecycleTable.scenarios.contains { $0.event == .desiredObservedDisagree })
        let actions = Set(LifecycleTable.scenarios.compactMap { if case .terminateReturnedNil(let a) = $0.event { a } else { nil } })
        XCTAssertEqual(actions, Set(LifecycleTable.TerminatingAction.allCases))
        // Deliberate break: fold the disagreement into `.handoffTimedOut` -> the second assertion fails.
    }
    func testLookupReturnsEveryCandidateForAFromStateAndEvent() {
        let c = LifecycleTable.transitions(for: .holderAppeared, from: .dormant)
        XCTAssertEqual(Set(c.map(\.to)), [.foreignUsersTerminal, .backgroundJob])
        XCTAssertTrue(LifecycleTable.transitions(for: .opened, from: .ready).isEmpty)
    }
}
