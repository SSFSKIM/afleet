import XCTest
@testable import FleetSessions

/// G1's gate over the lifecycle table.
///
/// The scenario check is set equality in both directions: the union of every declared set in
/// `LifecycleRowTests.coverage` equals `LifecycleTable.scenarios`, so a row, a from-state or an outcome added to the
/// table without a test that drives it fails here, and a declared scenario the table does not contain fails too.
///
/// The method check runs one way only, key → test: every key in `coverage` must name a test method the suite has.
/// The reverse is deliberately not asserted. `LifecycleRowTests` carries test methods that are not row tests and
/// declare no scenarios of their own — `testTheExitThatFollowsADeliberateTerminationIsNotACrash`,
/// `testAReservationConfirmedAfterARekeyTakesTheResolvedKey`,
/// `testAHolderArrivingWhileASpawnIsInFlightIsLeftToTheOwnershipChecks`,
/// `testAJobTheListingDoesNotNameFailsTheHandoffAndLeavesNoOwnedChannelBehind`,
/// `testAttachAndLogsAreParallelPaneRequestsThatChangeNoOwnership` and
/// `testLogoutTerminatingAConnectingChannelLeavesItResting` — and a bidirectional check would fail on them.
final class LifecycleCoverageTests: XCTestCase {
    /// The gate: the union of every declared scenario set equals the table, both ways, and every declaring method exists.
    func testEveryScenarioInTheTableIsDeclaredByARowTest() {
        let declared = LifecycleRowTests.coverage.values.reduce(into: Set<LifecycleTable.Transition>()) { $0.formUnion($1) }
        let table = Set(LifecycleTable.scenarios)
        XCTAssertEqual(table.subtracting(declared), [], "scenarios in the table no test drives")
        XCTAssertEqual(declared.subtracting(table), [], "declared scenarios the table does not contain")
        // async test methods have no ObjC selector of their bare name, so match the suite's own names instead;
        // XCTest prints them as `-[Module.Class testFoo]`, and the keys are the bare names `testID()` produces
        let suiteNames = LifecycleRowTests.defaultTestSuite.tests.map(\.name)
        for name in LifecycleRowTests.coverage.keys {
            XCTAssertTrue(suiteNames.contains { $0.hasSuffix(" \(name)]") }, "coverage names a test that does not exist: \(name)")
        }
    }
}
