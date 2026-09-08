import Foundation
import XCTest
import AfleetCore
import FleetKit
@testable import Afleet

/// The Background list against X5's roster signal (tracker entry 77, C5 review F6).
///
/// Before this, the list was loaded once and afterwards only by afleet's own Adopt and Stop. A job started from a
/// terminal, and any job that changed state on its own, stayed invisible until the next launch. `updates` cannot
/// close that: it is keyed by channel and an exec job has no session. The one route left was to re-poll `jobs()`,
/// which runs `agents --json` and boots the CLI — so the count of `jobs()` calls is asserted here as flatly as the
/// contents of the list.
///
/// Every identifier below is invented; nothing here reads or writes a config home (§11).
@MainActor
final class BackgroundRosterTests: XCTestCase {

    private static let home = URL(filePath: "/invented/config-home")

    /// The finding itself: a job that appeared outside afleet reaches the list, and the list did not go back to the
    /// CLI to learn it.
    func testAnExecJobPublishedAfterTheSnapshotAppearsWithoutASecondJobsCall() async throws {
        let lifecycle = LifecycleDouble()
        let browser = FleetBrowserModel(lifecycle: lifecycle, configHome: Self.home)
        defer { browser.stopUpdates() }

        await browser.refreshBackground()
        XCTAssertEqual(browser.background, [], "the snapshot the sidebar loads at launch")

        let job = Self.job("jexec7", state: "working")
        lifecycle.emitJobs([job])
        await Self.until(browser, "the published exec job never reached the Background list") {
            $0.background.map(\.short) == [job.short]
        }

        XCTAssertNil(browser.background.first?.sessionID, "an exec job carries no session")
        let calls = await lifecycle.jobsCalls
        XCTAssertEqual(calls, 1, "the list went back to jobs() — and so to `agents --json` — for what it was told")
    }

    /// A job changing state is a change to the row, not to the membership of the list. It is the case the
    /// channel-keyed stream comes closest to covering and still cannot: nothing about a job's own state text is a
    /// `ChannelState`.
    func testAJobChangingStateIsPatchedInPlace() async throws {
        let lifecycle = LifecycleDouble()
        await lifecycle.setJobs([Self.job("jturn2", state: "working")])
        let browser = FleetBrowserModel(lifecycle: lifecycle, configHome: Self.home)
        defer { browser.stopUpdates() }

        await browser.refreshBackground()
        XCTAssertEqual(browser.background.map(\.state), ["working"])

        lifecycle.emitJobs([Self.job("jturn2", state: "blocked")])
        await Self.until(browser, "the job's new state never reached the row") {
            $0.background.map(\.state) == ["blocked"]
        }

        XCTAssertEqual(browser.background.map(\.short.rawValue), ["jturn2"], "the row moved instead of being patched")
        let calls = await lifecycle.jobsCalls
        XCTAssertEqual(calls, 1, "a state change cost a second roster read")
    }

    /// The subscription is installed **before** the snapshot is taken, which is the ordering C5 adopted everywhere:
    /// a roster published in the window between the two must not be the one the sidebar misses. The double answers
    /// `jobs()` with the older roster on purpose, so a model that subscribed afterwards ends up showing it.
    func testARosterPublishedDuringTheInitialSnapshotIsNotLost() async throws {
        let lifecycle = LifecycleDouble()
        let arrived = Self.job("jrace3", state: "working")
        await lifecycle.setJobs([])
        let browser = FleetBrowserModel(lifecycle: lifecycle, configHome: Self.home)
        defer { browser.stopUpdates() }

        lifecycle.emitJobs([arrived])
        await browser.refreshBackground()

        await Self.until(browser, "a roster published before the snapshot returned was lost") {
            $0.background.map(\.short) == [arrived.short]
        }
    }

    // MARK: - Support

    private static func job(_ short: String, state: String) -> JobEntry {
        JobEntry(short: JobShort(rawValue: short), state: state, kind: "bg",
                 sessionID: nil, cwd: nil, name: nil)
    }

    /// Waits on the model's own change signal, with a hang guard well above what these waits take.
    private static func until(_ model: FleetBrowserModel, _ message: String,
                              _ predicate: @escaping @MainActor (FleetBrowserModel) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let reached = XCTestExpectation(description: message)
        let watcher = Task { @MainActor in
            await model.whenChanged(predicate)
            reached.fulfill()
        }
        let outcome = await XCTWaiter().fulfillment(of: [reached], timeout: LaunchFixtures.hangGuard)
        watcher.cancel()
        if outcome != .completed { XCTFail(message, file: file, line: line) }
    }
}
