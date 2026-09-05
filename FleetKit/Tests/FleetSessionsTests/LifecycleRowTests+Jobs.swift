import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// `foreignRecordGone` from the origin the parent's rule names rather than from the one state the table first
/// enumerated. The row is "the holder's record went away, so the session is nobody's"; a background job's roster
/// worker leaving is that fact as much as a terminal's registry record vanishing is.
///
/// The scenario is declared in `LifecycleRowTests.coverage` under this test's own name, so G1's gate sees it driven.
extension LifecycleRowTests {

    /// A channel afleet sent to the background, whose job then stops. The roster worker goes, nobody holds the
    /// session, and the channel is archived — recently active, because it was afleet's a moment ago — from which an
    /// ordinary send resumes it.
    ///
    /// Deliberate break: handle only `here == .foreignUsersTerminal` in `holdersChanged`'s record-gone branch → the
    /// channel stays `.backgroundJob` with no holder behind it and the send is refused `heldElsewhere`.
    func testABackgroundJobWhoseRosterWorkerGoesArchivesTheChannel() async throws {
        let rig = try Rig()
        let session = SessionID()
        let supervisor = rig.supervisor(session: session, isRecent: true, origin: .backgroundJob)
        try rig.files.writeJob(short: "jbg1", state: "working", sessionID: session,
                               pid: ScriptedHolderFiles.livePID)
        await rig.startObserver()
        try await rig.waitUntil(supervisor, "the job holder to be observed") { $0.observed.holders.count == 1 }
        rig.forgetTransitions()

        try rig.files.removeRosterWorker(short: "jbg1")
        await rig.clock.advance(by: .seconds(5))          // the observer's poll
        try await rig.waitUntil(supervisor, "the archived outcome") { $0.origin == .archived }

        XCTAssertEqual(rig.spawnCount, 0, "the record going away is not a reason to spawn")
        rig.assertObserved(try XCTUnwrap(Self.coverage[Self.testID()]))
        await rig.shutdown(); await rig.tearDown()
    }
}
