import XCTest
import AfleetCore
@testable import FleetSessions

/// Pure: no files, no processes. The resolver classifies each holder by its own evidence and then applies the
/// parent's precedence — owned, foreign, job, archived.
final class OriginResolverTests: XCTestCase {
    private let home = URL(filePath: "/scratch/home")

    private func key(_ session: SessionID) -> ChannelKey { ChannelKey(configHome: home, session: session) }

    private func holder(_ session: SessionID, sources: Set<Holder.Source>, jobShort: String? = nil,
                        isOwnChild: Bool = false, presence: ForeignPresence? = nil) -> Holder {
        Holder(pid: 4242, sessionID: session, sources: sources, kind: "interactive", entrypoint: "cli",
               jobShort: jobShort, isOwnChild: isOwnChild, presence: presence)
    }

    func testAHolderMergedFromARegistryRecordAndARosterEntryIsABackgroundJob() {
        let session = SessionID()
        let merged = holder(session, sources: [.registry, .roster], jobShort: "j00001")
        XCTAssertTrue(merged.isJob)
        let (origin, _) = OriginResolver.resolve(key: key(session), ownedState: nil, holders: [merged],
                                                 pendingHatch: false)
        XCTAssertEqual(origin, .backgroundJob)

        // The same holder without the roster's evidence is exactly what a TUI in the user's terminal looks like.
        let terminal = holder(session, sources: [.registry], jobShort: nil)
        XCTAssertFalse(terminal.isJob)
        let (foreign, _) = OriginResolver.resolve(key: key(session), ownedState: nil, holders: [terminal],
                                                  pendingHatch: false)
        XCTAssertEqual(foreign, .foreignLive(.usersTerminal))

        // Precedence: a session held by both a terminal and a job is foreign.
        let (both, _) = OriginResolver.resolve(key: key(session), ownedState: nil, holders: [merged, terminal],
                                               pendingHatch: false)
        XCTAssertEqual(both, .foreignLive(.usersTerminal))

        // Nothing holds it.
        let (archived, presence) = OriginResolver.resolve(key: key(session), ownedState: nil, holders: [],
                                                          pendingHatch: false)
        XCTAssertEqual(archived, .archived)
        XCTAssertEqual(presence, .unknown)
    }

    func testAPendingHatchNamesTheHostAsOurOwnTerminalTab() {
        let session = SessionID()
        let (origin, _) = OriginResolver.resolve(key: key(session), ownedState: nil,
                                                 holders: [holder(session, sources: [.registry])], pendingHatch: true)
        XCTAssertEqual(origin, .foreignLive(.ownTerminalTab))
    }

    /// A holder that is ours while no supervisor owns the channel is Contended, not foreign live.
    func testAnOwnChildHolderWithNoSupervisorIsContended() {
        let session = SessionID()
        let (origin, _) = OriginResolver.resolve(key: key(session), ownedState: nil,
                                                 holders: [holder(session, sources: [.registry], isOwnChild: true)],
                                                 pendingHatch: false)
        XCTAssertEqual(origin, .owned(.contended))
    }

    func testPresenceComesFromTheHoldersRecordAndFromTheSupervisorsTurnState() {
        let session = SessionID()
        let busy = holder(session, sources: [.registry], presence: ForeignPresence(status: "busy"))
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: nil, holders: [busy],
                                              pendingHatch: false).1, .busy)
        let waiting = holder(session, sources: [.registry],
                             presence: ForeignPresence(status: "waiting", waitingFor: "permission"))
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: nil, holders: [waiting],
                                              pendingHatch: false).1, .waiting(for: "permission"))
        // Every headless holder says nothing about itself.
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: nil,
                                              holders: [holder(session, sources: [.registry])],
                                              pendingHatch: false).1, .unknown)

        let owned = OwnedView(state: .ready, turnRunning: true, pendingDecisions: 0)
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: owned, holders: [],
                                              pendingHatch: false).0, .owned(.ready))
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: owned, holders: [],
                                              pendingHatch: false).1, .busy)
        let asking = OwnedView(state: .ready, turnRunning: true, pendingDecisions: 1)
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: asking, holders: [],
                                              pendingHatch: false).1, .waiting(for: nil))
        let quiet = OwnedView(state: .ready)
        XCTAssertEqual(OriginResolver.resolve(key: key(session), ownedState: quiet, holders: [],
                                              pendingHatch: false).1, .idle)
    }
}
