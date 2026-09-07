import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The fleet fans every published `HolderSet` to every supervisor, and each supervisor narrows it to its own
/// session. `updates` is "every transition, coalesced per channel", so a channel whose *own* narrowed view did not
/// change has nothing to say about a holder that appeared somewhere else: publishing there turns one holder change
/// into one published state per registered channel, for the life of the process.
///
/// Deliberate break: make the no-transition `publish()` calls in `holdersChanged` unconditional again → the
/// unchanged channel publishes on every fan-out and both tests fail.
final class HolderFanOutTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    private func newRig() throws -> Rig {
        let rig = try Rig()
        rigs.append(rig)
        return rig
    }

    private func holder(_ session: SessionID, pid: Int32) -> Holder {
        Holder(pid: pid, sessionID: session, sources: [.registry], kind: "interactive", entrypoint: "cli")
    }

    private func set(_ holders: [Holder]) -> HolderSet { HolderSet(holders: holders, observedAt: Date()) }

    /// A holder change on one channel's session costs the other channel nothing.
    func testAHolderChangeElsewherePublishesNothingOnAChannelWhoseOwnViewDidNotMove() async throws {
        let rig = try newRig()
        let sessionA = SessionID(), sessionB = SessionID()
        let channelA = rig.supervisor(session: sessionA, isRecent: true, records: false)
        let channelB = rig.supervisor(session: sessionB, isRecent: true, records: false)

        let first = set([holder(sessionA, pid: 91_001)])
        await channelA.holdersChanged(first)
        await channelB.holdersChanged(first)
        let publishedA = await channelA.publishedCount
        let publishedB = await channelB.publishedCount
        let originA = await channelA.state.origin
        let observedB = await channelB.state.observed.holders
        XCTAssertEqual(originA, .foreignLive(.usersTerminal), "A's own holder is A's business")
        XCTAssertEqual(observedB, [], "B's narrowed view was empty and stayed empty")

        // A's holder is replaced by another one; B's (empty) view is untouched by both sets.
        let second = set([holder(sessionA, pid: 91_002)])
        await channelA.holdersChanged(second)
        await channelB.holdersChanged(second)

        let afterA = await channelA.publishedCount
        let afterB = await channelB.publishedCount
        XCTAssertGreaterThan(afterA, publishedA, "A's own holders changed")
        XCTAssertEqual(afterB, publishedB,
                       "B's narrowed view did not change, so B has no transition and nothing to publish")
    }

    /// The same holders read a second time are a fresh `observedAt` and nothing else. A timestamp is not a
    /// transition.
    func testTheSameHolderSetReadTwicePublishesOnce() async throws {
        let rig = try newRig()
        let sessionA = SessionID(), sessionB = SessionID()
        let channelA = rig.supervisor(session: sessionA, isRecent: true, records: false)
        let channelB = rig.supervisor(session: sessionB, isRecent: true, records: false)
        let holders = [holder(sessionA, pid: 91_003)]

        await channelA.holdersChanged(set(holders))
        await channelB.holdersChanged(set(holders))
        let publishedA = await channelA.publishedCount
        let publishedB = await channelB.publishedCount
        let stampA = await channelA.state.observed.observedAt

        // The observer re-read: identical holders, a later stamp.
        await channelA.holdersChanged(set(holders))
        await channelB.holdersChanged(set(holders))

        let afterA = await channelA.publishedCount
        let afterB = await channelB.publishedCount
        let laterStampA = await channelA.state.observed.observedAt
        XCTAssertEqual(afterA, publishedA, "nothing about A changed but the stamp")
        XCTAssertEqual(afterB, publishedB, "and B never had a holder at all")
        XCTAssertGreaterThan(laterStampA, stampA, "the stamp is still refreshed on every call")
    }
}
