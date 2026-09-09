import Foundation
import XCTest
import AfleetCore
import FleetKit
@testable import Afleet

/// Contract Y4's seam: chip to run
/// (`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md`, "Contract Y4 — chip to run").
///
/// The skeleton owes C6.1 two things — a seam whose default is installed in the composition root, so
/// the chip has something to call on every branch, and a seam that is genuinely replaceable, so
/// C6.4 changes one line and no call site. One test each.
@MainActor
final class AgentNavigationTests: XCTestCase {

    /// The composition root installs the no-op, which is where C6.4's implementation goes.
    func testTheNoOpNavigationIsInstalledInTheCompositionRoot() {
        let app = AppModel(registry: RowRegistry())
        XCTAssertTrue(app.agentNavigation is NoAgentNavigation,
                      "the chip's seam defaults to \(type(of: app.agentNavigation)), not the skeleton's no-op")
        // Calling it does nothing, which is the whole contract until C6.4 lands.
        app.agentNavigation.show(run: Self.run, in: Self.key)
    }

    /// Replacing it is one assignment, and the replacement is what the call reaches.
    func testAReplacementReceivesEveryNavigation() {
        let app = AppModel(registry: RowRegistry())
        let double = CountingNavigation()
        app.agentNavigation = double
        app.agentNavigation.show(run: Self.run, in: Self.key)
        XCTAssertEqual(double.calls.count, 1, "the installed navigation was not the one called")
        XCTAssertEqual(double.calls.first?.run, Self.run)
        XCTAssertEqual(double.calls.first?.key, Self.key)
    }

    /// What C6.1's chip test will use: a double that records the run and the channel it was asked for.
    @MainActor
    private final class CountingNavigation: AgentNavigating {
        private(set) var calls: [(run: AgentRunID, key: ChannelKey)] = []
        func show(run: AgentRunID, in key: ChannelKey) { calls.append((run, key)) }
    }

    /// An invented task id and channel — nothing here came off a transcript (§11).
    private static let run: AgentRunID = "task_d4d4d4d4"
    private static let key = ChannelKey(configHome: URL(fileURLWithPath: "/tmp/afleet-agent-nav/config-home"),
                                       session: SessionID("d4d4d4d4-4444-4444-8444-444444444444")!)
}
