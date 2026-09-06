import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Cmd+K: the switcher's corpus, its ranking and its empty query (spec §4, §6).
///
/// Every identifier below is invented. No path, title or session id here comes from any real home
/// (§11), and nothing in this file reads or writes a config home.
@MainActor
final class QuickSwitcherTests: XCTestCase {

    /// The switcher searches the **whole listed index**, not the sidebar. A channel the thirty-day
    /// default has pushed out of every project section is still one query away.
    ///
    /// The discriminating clause is the pair: the *same model* reports the veteran absent from
    /// `sections` and present in `results`. A switcher built over `sections` — the obvious
    /// implementation, since that is what the sidebar draws — passes neither half.
    func testSwitcherSearchesChannelsOlderThanThirtyDays() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let fresh = Switcher.session(1)
        let veteran = Switcher.session(2)
        let browser = Switcher.browser(now: now, entries: [
            Switcher.entry(fresh, mtime: now.addingTimeInterval(-3600),
                           cwd: "/invented/questor-repo", title: "fresh planner"),
            Switcher.entry(veteran, mtime: now.addingTimeInterval(-400 * 86_400),
                           cwd: "/invented/questor-repo", title: "veteran planner"),
        ])
        let switcher = QuickSwitcherModel(browser: browser)

        // The floor: the sidebar is not empty, so "absent from sections" means absent rather than
        // "nothing was built".
        XCTAssertFalse(browser.sections.isEmpty, "the model built no sections to be absent from")
        let inSections = Set(browser.sections.flatMap(\.allRows).map(\.id))
        XCTAssertTrue(inSections.contains(fresh), "the recent channel is missing from the sidebar")
        XCTAssertFalse(inSections.contains(veteran), "the thirty-day default did not hide the veteran")
        XCTAssertEqual(browser.archived.map(\.id), [veteran])

        let results = switcher.results(for: "veteran")
        let sessions = Set(results.filter { $0.kind == .channel }.compactMap(\.session))
        XCTAssertFalse(sessions.isEmpty, "the switcher returned no channels at all")
        XCTAssertTrue(sessions.contains(veteran),
                      "a channel outside the thirty-day window was not searchable")
    }

    /// Ranking is by kind of match, not by recency. Two channels both contain the query; the one
    /// whose title *starts* with it comes first even though the other is the more recently active,
    /// which is what makes this a test of the scoring rather than of the sort's tie-break.
    func testFuzzyMatchRanksAPrefixAboveAnInfixMatch() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let prefix = Switcher.session(3)
        let infix = Switcher.session(4)
        let browser = Switcher.browser(now: now, entries: [
            Switcher.entry(prefix, mtime: now.addingTimeInterval(-7200),
                           cwd: "/invented/questor-repo", title: "alphacrest planner"),
            // Deliberately the newer of the two: a switcher that filtered on substring and sorted
            // by activity would put this one first.
            Switcher.entry(infix, mtime: now.addingTimeInterval(-60),
                           cwd: "/invented/questor-repo", title: "the alphacrest planner"),
        ])
        let switcher = QuickSwitcherModel(browser: browser)

        let channels = switcher.results(for: "alphacrest").filter { $0.kind == .channel }
        XCTAssertEqual(channels.count, 2, "the query did not find both channels")
        XCTAssertEqual(Set(channels.compactMap(\.session)), [prefix, infix])
        let prefixRow = try XCTUnwrap(channels.first { $0.session == prefix })
        let infixRow = try XCTUnwrap(channels.first { $0.session == infix })
        XCTAssertGreaterThan(infixRow.lastActivity, prefixRow.lastActivity,
                             "the infix channel is not the newer one, so recency could not have decided")
        XCTAssertEqual(channels.first?.session, prefix,
                       "an infix match outranked a prefix match")
        XCTAssertGreaterThan(prefixRow.score, infixRow.score)
    }

    /// All three kinds appear, each asserted by kind against a corpus holding at least one of each.
    func testSwitcherReturnsProjectsChannelsAndJobs() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let channel = Switcher.session(5)
        let lifecycle = LifecycleDouble()
        let browser = Switcher.browser(now: now, lifecycle: lifecycle, entries: [
            Switcher.entry(channel, mtime: now.addingTimeInterval(-120),
                           cwd: "/invented/questor-repo", title: "questor planner"),
        ])
        await lifecycle.setJobs([
            JobEntry(short: JobShort(rawValue: "qj1"), state: "running", kind: "bash",
                     sessionID: nil, cwd: nil, name: "questor sweep"),
        ])
        await browser.refreshBackground()
        XCTAssertEqual(browser.background.count, 1, "the roster the switcher searches is empty")

        let switcher = QuickSwitcherModel(browser: browser)
        let results = switcher.results(for: "questor")
        XCTAssertFalse(results.isEmpty)

        let projects = results.filter { $0.kind == .project }
        let channels = results.filter { $0.kind == .channel }
        let jobs = results.filter { $0.kind == .job }
        XCTAssertEqual(projects.map(\.title), ["questor-repo"])
        XCTAssertEqual(channels.compactMap(\.session), [channel])
        XCTAssertEqual(jobs.compactMap(\.job), [JobShort(rawValue: "qj1")])
        XCTAssertEqual(Set(results.map(\.kind)), Set(SwitcherResult.Kind.allCases),
                       "a kind the switcher is supposed to search is missing")
    }

    /// An empty query is not "show me the fleet". It is the ten most recently active channels, in
    /// that order, out of a corpus of three thousand.
    func testEmptyQueryReturnsRecentChannelsNotEverything() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let total = 3_000
        let entries = (0..<total).map { index in
            Switcher.entry(Switcher.session(1_000 + index),
                           mtime: now.addingTimeInterval(-Double(index) * 60),
                           cwd: "/invented/questor-repo",
                           title: "channel \(index)")
        }
        let browser = Switcher.browser(now: now, entries: entries)
        XCTAssertEqual(browser.allRows.count, total, "the corpus the query is meant not to return is wrong")

        let switcher = QuickSwitcherModel(browser: browser)
        let results = switcher.results(for: "")
        XCTAssertEqual(results.count, QuickSwitcherModel.emptyQueryLimit)
        XCTAssertLessThan(results.count, total)
        XCTAssertEqual(results.map(\.kind), Array(repeating: .channel, count: results.count))
        // `mtime` descends as the index rises, so the ten newest are indices 0…9 in order.
        XCTAssertEqual(results.compactMap(\.session),
                       (0..<QuickSwitcherModel.emptyQueryLimit).map { Switcher.session(1_000 + $0) })
    }
}

/// The switcher tests' invented corpus.
enum Switcher {

    /// A deterministic v4-shaped session id from an integer, so a three-thousand-row corpus is
    /// reproducible and no identifier in this file resembles a real one.
    static func session(_ index: Int) -> SessionID {
        SessionID(String(format: "%08x-0000-4000-8000-000000000000", index))!
    }

    static func entry(_ id: SessionID, mtime: Date, cwd: String, title: String) -> IndexEntry {
        IndexEntry(sessionID: id,
                   path: URL(fileURLWithPath: "/invented/config-home/projects/invented/\(id).jsonl"),
                   slug: "invented",
                   cwd: cwd,
                   title: title,
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   mtime: mtime,
                   size: 1,
                   entrypoint: nil,
                   isSidechain: false,
                   teamName: nil,
                   continuedIn: nil)
    }

    /// A browser painted from one restored snapshot. `now` is injected so the thirty-day split is a
    /// property of the fixture rather than of the day the suite runs.
    @MainActor
    static func browser(now: Date,
                        lifecycle: any LifecycleAPI = LifecycleDouble(),
                        entries: [IndexEntry]) -> FleetBrowserModel {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let model = FleetBrowserModel(lifecycle: lifecycle, configHome: home, now: { now })
        model.restore(from: IndexSnapshot(configHome: home, builtAt: now,
                                          entries: Dictionary(uniqueKeysWithValues: entries.map {
                                              ($0.sessionID, $0)
                                          })))
        return model
    }
}
