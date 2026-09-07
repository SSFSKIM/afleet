import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The fleet browser's model: the listing join, the two index feeds, the `ChannelState` join and the
/// two refusals a row has to explain.
@MainActor
final class SidebarModelTests: XCTestCase {

    // MARK: - The listing join, over a real config home and a real index

    /// Exactly five of seven transcripts become rows, compared as sets **in both directions** so an
    /// extra row fails as loudly as a missing one, with the expected set asserted non-empty first.
    func testListedSetEqualsTheExpectedSetInBothDirections() async throws {
        let corpus = try await Corpus.standard()
        let expected = Set([corpus.ordinaryA, corpus.ordinaryB, corpus.ordinaryC,
                            corpus.teammate, corpus.sdkCLI])
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(corpus.snapshot.entries.count, 7, "the scratch home did not hold seven transcripts")

        let listed = Set(corpus.model.allRows.map(\.id))
        XCTAssertEqual(listed, expected)
        XCTAssertEqual(listed.count, 5)
        XCTAssertTrue(expected.isSubset(of: listed), "a listed transcript is missing from the sidebar")
        XCTAssertTrue(listed.isSubset(of: expected), "the sidebar listed a transcript nothing lists")
    }

    /// A row's absence is attributable. The verdicts the model recorded name the rule that decided.
    func testEachExclusionNamesTheRuleThatDecidedIt() async throws {
        let corpus = try await Corpus.standard()
        let sidechain = try XCTUnwrap(corpus.model.decisions[corpus.sidechain])
        XCTAssertEqual(sidechain.rule, "sidechain")
        XCTAssertEqual(sidechain.exclusionReason, .sidechain)

        let continued = try XCTUnwrap(corpus.model.decisions[corpus.continued])
        XCTAssertEqual(continued.rule, "continued-in")
        XCTAssertEqual(continued.exclusionReason, .continuedIn(corpus.ordinaryA.description))
    }

    /// C4's rule order is deliberate: `own-sdk-cli` fires **before** `sidechain`, so afleet's own
    /// sessions are listed even when the transcript flags them. Reordering the two rules in a local
    /// copy of `ListingPolicy` is what demonstrates this failing.
    func testAnSDKCLITranscriptIsListedEvenWhenFlaggedSidechain() async throws {
        let home = try ScratchConfigHome()
        let session = SidebarFixtures.session("a")
        try home.write(.init(session: session, entrypoint: "sdk-cli", isSidechain: true))
        let snapshot = try await home.index().build()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(snapshot.entries[session]).isSidechain,
                      "the transcript did not carry the sidechain flag the test is about")

        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home.configHome.root)
        model.restore(from: snapshot)
        XCTAssertEqual(model.allRows.map(\.id), [session])
        XCTAssertEqual(model.decisions[session]?.rule, "own-sdk-cli")
    }

    /// A teammate's transcript is listed and read-only: the row offers no owned action.
    func testTeammateTranscriptIsListedReadOnly() async throws {
        let corpus = try await Corpus.standard()
        let row = try XCTUnwrap(corpus.model.row(corpus.teammate))
        XCTAssertEqual(row.mode, .readOnly(.teammate))
        XCTAssertEqual(row.readOnlyReason, .teammate)
        XCTAssertFalse(row.offersOwnedActions)
        XCTAssertEqual(corpus.model.decisions[corpus.teammate]?.rule, "teammate")

        // The floor: an owned row in the same model does offer them, so the assertion above is
        // discriminating rather than a property every row happens to have.
        let owned = try XCTUnwrap(corpus.model.row(corpus.ordinaryA))
        XCTAssertTrue(owned.offersOwnedActions)
    }

    // MARK: - The `ChannelState` join

    /// Ruling 3, tracker entry 21's closer. A restored row carries **no** origin glyph at all; one
    /// arrives only with a `ChannelState`, and only for the channel that state names.
    ///
    /// The first clause is the discriminating one: a model that remembered an origin across launches
    /// would pass a test that only checked the second.
    func testOriginGlyphComesFromChannelStateAndNeverFromTheSnapshot() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let first = SidebarFixtures.session("b")
        let second = SidebarFixtures.session("c")
        let snapshot = SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(first, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
            SidebarFixtures.entry(second, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
        ])
        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home)
        model.restore(from: snapshot)

        XCTAssertEqual(model.allRows.count, 2, "the restore painted nothing to assert about")
        for row in model.allRows {
            XCTAssertNil(row.originGlyph, "a restored row carried an origin no ChannelState supplied")
            XCTAssertNil(row.origin)
        }

        model.apply(SidebarFixtures.state(ChannelKey(configHome: home, session: first),
                                          origin: .owned(.ready)))
        XCTAssertEqual(model.row(first)?.originGlyph, .ready)
        XCTAssertNil(model.row(second)?.originGlyph, "an unrelated row picked up another channel's origin")
    }

    // MARK: - The delta feed

    /// All three of `added`, `updated` and `removed` change the model, each asserted separately.
    func testIndexDeltaAddsUpdatesAndRemovesRows() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let staying = SidebarFixtures.session("d")
        let leaving = SidebarFixtures.session("e")
        let arriving = SidebarFixtures.session("f")
        let now = Date()

        var entries: [SessionID: IndexEntry] = [
            staying: SidebarFixtures.entry(staying, configHome: home, cwd: "/invented/project-alpha",
                                           mtime: now, title: "before"),
            leaving: SidebarFixtures.entry(leaving, configHome: home, cwd: "/invented/project-alpha",
                                           mtime: now),
        ]
        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home)
        model.restore(from: IndexSnapshot(configHome: home, builtAt: now, entries: entries))
        XCTAssertEqual(Set(model.allRows.map(\.id)), [staying, leaving])
        XCTAssertEqual(model.row(staying)?.title, "before")

        entries[arriving] = SidebarFixtures.entry(arriving, configHome: home, cwd: "/invented/project-beta",
                                                  mtime: now)
        entries[staying] = SidebarFixtures.entry(staying, configHome: home, cwd: "/invented/project-alpha",
                                                 mtime: now, title: "after")
        entries[leaving] = nil

        await model.apply(IndexDelta(added: [arriving], updated: [staying], removed: [leaving])) { entries[$0] }

        XCTAssertNotNil(model.row(arriving), "`added` did not add a row")
        XCTAssertEqual(model.row(staying)?.title, "after", "`updated` did not refresh the row")
        XCTAssertNil(model.row(leaving), "`removed` did not drop the row")
        XCTAssertEqual(Set(model.allRows.map(\.id)), [staying, arriving])
    }

    /// An index delta that changes nothing does not re-derive the fleet.
    ///
    /// `TranscriptIndex.update` returns an empty delta whenever every candidate reconciled to
    /// `.skipped` and every subagent-only change left `hasSubagents` where it was — which is the
    /// ordinary shape of a session writing agent transcripts under a directory the index notes but
    /// never descends. Those arrive at the watcher's rate for as long as the subagent runs, and
    /// each one used to rebuild every row and every section on the main actor for a set of rows
    /// that is byte-identical before and after.
    ///
    /// The pair is the discriminating clause: the same model holds its rebuild count across the
    /// empty delta and raises it across the non-empty one, so "it rebuilt nothing" cannot pass by
    /// the model having stopped rebuilding at all.
    func testAnEmptyIndexDeltaDoesNotRebuildTheFleet() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let present = SidebarFixtures.session("2")
        let now = Date()
        let entries: [SessionID: IndexEntry] = [
            present: SidebarFixtures.entry(present, configHome: home, cwd: "/invented/project-alpha",
                                           mtime: now, title: "before"),
        ]
        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home)
        model.restore(from: IndexSnapshot(configHome: home, builtAt: now, entries: entries))
        XCTAssertEqual(model.allRows.count, 1, "the fixture painted no row to hold steady")

        let settled = model.rebuildCount
        await model.apply(IndexDelta(durationMs: 3)) { entries[$0] }
        XCTAssertEqual(model.rebuildCount, settled,
                       "an empty delta re-derived the fleet")
        XCTAssertEqual(model.allRows.count, 1, "the empty delta changed the rows it carried nothing about")

        await model.apply(IndexDelta(updated: [present])) { entries[$0] }
        XCTAssertGreaterThan(model.rebuildCount, settled,
                             "a non-empty delta did not re-derive, so the count proves nothing")
    }

    /// Minor 3: a snapshot that dropped the selected session drops the selection with it. A
    /// selection pointing at a session with no row is a sidebar holding a reference it cannot draw.
    func testASnapshotThatDropsTheSelectedSessionClearsTheSelection() async throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let staying = SidebarFixtures.session("a")
        let leaving = SidebarFixtures.session("8")
        let now = Date()
        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home)
        model.apply(SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(staying, configHome: home, cwd: "/invented/project-alpha", mtime: now),
            SidebarFixtures.entry(leaving, configHome: home, cwd: "/invented/project-alpha", mtime: now),
        ]))
        model.select(leaving)
        XCTAssertEqual(model.selected, leaving)

        model.apply(SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(staying, configHome: home, cwd: "/invented/project-alpha", mtime: now),
        ]))
        XCTAssertNil(model.selected, "the selection survived the snapshot that dropped its session")

        // The floor: a selection whose session is still in the snapshot is left alone.
        model.select(staying)
        model.apply(SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(staying, configHome: home, cwd: "/invented/project-alpha", mtime: now),
        ]))
        XCTAssertEqual(model.selected, staying, "a still-listed selection was cleared")
    }

    // MARK: - The two refusals

    /// `busy` becomes a banner naming the operation, and **the surface never retries**: the double
    /// records exactly one call. The call count is the discriminating clause.
    func testBusyIsSurfacedAndNeverRetried() async throws {
        let (model, lifecycle, row) = try makeOneRow()
        await lifecycle.always(.failure(LifecycleError.busy(.spawn)))

        await model.perform(.open, on: row)

        let banner = try XCTUnwrap(model.row(row.id)?.banner, "busy produced no banner")
        XCTAssertEqual(banner.operation, .spawn)
        XCTAssertTrue(banner.text.contains("spawn"), "the banner did not name the operation: \(banner.text)")
        let calls = await lifecycle.performCount
        XCTAssertEqual(calls, 1, "the surface retried a busy channel \(calls - 1) time(s)")
    }

    /// `notEligible` names the blocker — a running background task by id — rather than "not now".
    func testNotEligibleNamesItsBlocker() async throws {
        let (model, lifecycle, row) = try makeOneRow()
        await lifecycle.always(.failure(LifecycleError.notEligible(.taskRunning("t-invented-1"))))

        await model.perform(.reap, on: row)

        let banner = try XCTUnwrap(model.row(row.id)?.banner, "notEligible produced no banner")
        XCTAssertEqual(banner.blocker, .taskRunning("t-invented-1"))
        XCTAssertTrue(banner.text.contains("t-invented-1"),
                      "the banner did not name the blocking task: \(banner.text)")
        XCTAssertFalse(banner.text.lowercased().contains("not now"))
        let calls = await lifecycle.performCount
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Support

    private func makeOneRow() throws -> (FleetBrowserModel, LifecycleDouble, ChannelRow) {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let session = SidebarFixtures.session("9")
        let lifecycle = LifecycleDouble()
        let model = FleetBrowserModel(lifecycle: lifecycle, configHome: home)
        model.restore(from: SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(session, configHome: home, cwd: "/invented/project-alpha", mtime: Date()),
        ]))
        let row = try XCTUnwrap(model.row(session), "the model painted no row to act on")
        XCTAssertNil(row.banner)
        return (model, lifecycle, row)
    }

    /// Seven invented transcripts in one scratch home, read back through a real `TranscriptIndex`, so
    /// the listing join is exercised against C3's own parser rather than against hand-made entries.
    struct Corpus {
        let home: ScratchConfigHome
        let snapshot: IndexSnapshot
        let model: FleetBrowserModel
        let ordinaryA: SessionID
        let ordinaryB: SessionID
        let ordinaryC: SessionID
        let teammate: SessionID
        let sdkCLI: SessionID
        let sidechain: SessionID
        let continued: SessionID

        @MainActor
        static func standard() async throws -> Corpus {
            let home = try ScratchConfigHome()
            try home.writeClaudeJSON(projects: ["/invented/project-alpha"])
            let ordinaryA = SidebarFixtures.session("1")
            let ordinaryB = SidebarFixtures.session("2")
            let ordinaryC = SidebarFixtures.session("3")
            let teammate = SidebarFixtures.session("4")
            let sdkCLI = SidebarFixtures.session("5")
            let sidechain = SidebarFixtures.session("6")
            let continued = SidebarFixtures.session("7")

            for session in [ordinaryA, ordinaryB, ordinaryC] {
                try home.write(.init(session: session))
            }
            try home.write(.init(session: teammate, teamName: "invented-team"))
            try home.write(.init(session: sdkCLI, entrypoint: "sdk-cli"))
            try home.write(.init(session: sidechain, isSidechain: true))
            try home.write(.init(session: continued, continuedIn: ordinaryA))

            let snapshot = try await home.index().build()
            let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home.configHome.root)
            model.restore(from: snapshot)
            return Corpus(home: home, snapshot: snapshot, model: model,
                          ordinaryA: ordinaryA, ordinaryB: ordinaryB, ordinaryC: ordinaryC,
                          teammate: teammate, sdkCLI: sdkCLI, sidechain: sidechain, continued: continued)
        }
    }
}
