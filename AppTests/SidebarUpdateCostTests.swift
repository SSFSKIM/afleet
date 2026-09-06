import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// What a `ChannelState` costs the sidebar, and what it must still do.
///
/// Registering the fleet makes C4 seed every registered channel, so a launch against a real config
/// home delivers thousands of `ChannelState`s. Re-deriving every section for each of them, and
/// letting SwiftUI walk the whole row tree once per state, held the main thread at 100 percent for
/// as long as the drain lasted. These tests pin the two properties that fixed it — a state patches
/// one row instead of re-deriving, and a burst publishes once instead of once per state — **and**
/// the three correctness properties that must survive them.
///
/// Nothing here waits on a clock. The coalescing test is fulfilled by the model reaching the state
/// it is waiting for, through `whenChanged`, which the rebuild itself resumes.
///
/// Every identifier is invented and no config home is read or written.
@MainActor
final class SidebarUpdateCostTests: XCTestCase {

    // MARK: - Correctness first

    /// A state reaches the row it names and no other, and it reaches it through the patch path.
    ///
    /// Both halves matter: an index that wrote into the wrong slot would still show *an* origin
    /// somewhere, and the second clause is what says the cheap path is the one that ran.
    func testAStateChangesTheRowItNamesAndNoOtherThroughThePatchPath() throws {
        let rig = Rig(rows: 3)
        XCTAssertEqual(rig.model.allRows.count, 3, "the fixture painted nothing to patch")
        let before = rig.model.rebuildCount

        rig.model.apply(rig.state(1, origin: .owned(.ready)))

        XCTAssertEqual(rig.model.row(rig.session(1))?.originGlyph, .ready)
        XCTAssertNil(rig.model.row(rig.session(0))?.originGlyph, "an unrelated row picked up the origin")
        XCTAssertNil(rig.model.row(rig.session(2))?.originGlyph, "an unrelated row picked up the origin")
        XCTAssertEqual(rig.model.rebuildCount, before,
                       "a state that cannot move its row still re-derived every section")
        XCTAssertEqual(rig.model.publishCount, 1, "the state was not published at all")
    }

    /// The one thing a state *can* change about where a row lives is whether it is archived at all,
    /// and that still moves the row — through the full derivation, because the fast path refuses it.
    ///
    /// `ChannelRow.isArchived` is `state == nil && (!isRecent || cwd == nil)`, so an old row with no
    /// live half sits in `archived` and the same row with one belongs in a section. Without the
    /// fallback the row would be patched where it stood and the sidebar would keep a live channel
    /// in the dimmed list forever.
    func testAStateThatUnarchivesARowMovesItAndTakesTheFullDerivation() throws {
        let rig = Rig(rows: 1, ageInDays: 400)
        XCTAssertEqual(rig.model.archived.map(\.id), [rig.session(0)],
                       "the fixture row is not archived, so there is no move to test")
        XCTAssertTrue(rig.model.sections.isEmpty)
        let before = rig.model.rebuildCount

        rig.model.apply(rig.state(0, origin: .owned(.ready)))

        XCTAssertTrue(rig.model.archived.isEmpty, "the row stayed in the archive with a live process behind it")
        XCTAssertEqual(rig.model.sections.flatMap(\.allRows).map(\.id), [rig.session(0)])
        XCTAssertEqual(rig.model.row(rig.session(0))?.originGlyph, .ready)
        XCTAssertGreaterThan(rig.model.rebuildCount, before,
                             "a row that had to move was patched in place instead of re-derived")
    }

    /// A state for a session the listing policy did not list changes nothing a view can read, so it
    /// costs nothing.
    ///
    /// The trace is the assertion: `rebuildCount` and `publishCount` both stand still. On a real
    /// config home 2,669 of 13,250 seeded states were of this kind, and each one re-derived every
    /// section for a channel with no row to show for it.
    func testAStateForASessionWithNoRowPublishesNothing() throws {
        let rig = Rig(rows: 2)
        let stranger = SessionID("0000dead-0000-4000-8000-000000000000")!
        XCTAssertNil(rig.model.row(stranger), "the stranger has a row, so this tests the wrong thing")
        let rebuilds = rig.model.rebuildCount
        let publishes = rig.model.publishCount
        let painted = rig.model.allRows.map(\.id)

        rig.model.apply(rig.state(session: stranger, origin: .owned(.ready)))

        XCTAssertEqual(rig.model.rebuildCount, rebuilds, "a state with no row re-derived every section")
        XCTAssertEqual(rig.model.publishCount, publishes, "a state with no row published a change")
        XCTAssertEqual(rig.model.allRows.map(\.id), painted, "the painted set moved")

        // The floor: the same model does publish for a session that *does* have a row, so the two
        // assertions above are about the stranger and not about a model that publishes nothing.
        rig.model.apply(rig.state(0, origin: .owned(.ready)))
        XCTAssertGreaterThan(rig.model.publishCount, publishes)
    }

    // MARK: - The cost

    /// A burst of states arriving on `updates` publishes a handful of times, not once per state —
    /// and every one of them still lands.
    ///
    /// The wait is fulfilled by the model: `whenChanged` is resumed by the publish that makes the
    /// predicate true, so this test has no deadline and cannot be slow on a loaded machine. The
    /// last clause is the one that makes the first meaningful — a model that dropped states would
    /// publish beautifully few times and show nothing.
    func testABurstOnTheUpdatesStreamPublishesFarFewerTimesThanItHasStates() async throws {
        let count = 400
        let lifecycle = LifecycleDouble()
        let rig = Rig(rows: count, lifecycle: lifecycle)
        rig.model.startUpdates()
        defer { rig.model.stopUpdates() }
        XCTAssertEqual(rig.model.allRows.count, count)

        for index in 0..<count {
            lifecycle.emit(rig.state(index, origin: .owned(.ready)))
        }

        await rig.model.whenChanged { model in
            model.allRows.allSatisfy { $0.originGlyph == .ready }
        }

        // Every state landed.
        XCTAssertEqual(rig.model.ingestCount, count)
        XCTAssertEqual(rig.model.allRows.count, count)
        XCTAssertTrue(rig.model.allRows.allSatisfy { $0.originGlyph == .ready },
                      "a state was coalesced away instead of merged")
        // And the sidebar was rewritten a handful of times rather than once per state. The bound is
        // a fifth, which the measured ratio clears by two orders of magnitude — 87 publishes for
        // 13,250 states on a real config home — and which a one-publish-per-state model fails at
        // any corpus size.
        XCTAssertLessThan(rig.model.publishCount, count / 5,
                          "\(rig.model.publishCount) publishes for \(count) states")
        XCTAssertGreaterThan(rig.model.publishCount, 0, "nothing was published at all")
    }

    // MARK: - The fixture

    /// One project, `rows` channels in it, no live half until the test supplies one.
    @MainActor
    private struct Rig {
        let model: FleetBrowserModel
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)

        init(rows: Int, ageInDays: Int = 0, lifecycle: any LifecycleAPI = LifecycleDouble()) {
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let home = self.home
            let entries = (0..<rows).map { index in
                Switcher.entry(Self.session(index),
                               mtime: now.addingTimeInterval(-Double(ageInDays) * 86_400 - Double(index)),
                               cwd: "/invented/questor-repo",
                               title: "channel \(index)")
            }
            model = FleetBrowserModel(lifecycle: lifecycle, configHome: home, now: { now })
            model.restore(from: IndexSnapshot(configHome: home, builtAt: now,
                                              entries: Dictionary(uniqueKeysWithValues: entries.map {
                                                  ($0.sessionID, $0)
                                              })))
        }

        static func session(_ index: Int) -> SessionID { Switcher.session(9_000 + index) }
        func session(_ index: Int) -> SessionID { Self.session(index) }

        func state(_ index: Int, origin: ChannelOrigin) -> ChannelState {
            state(session: Self.session(index), origin: origin)
        }

        func state(session: SessionID, origin: ChannelOrigin) -> ChannelState {
            SidebarFixtures.state(ChannelKey(configHome: home, session: session), origin: origin)
        }
    }
}
