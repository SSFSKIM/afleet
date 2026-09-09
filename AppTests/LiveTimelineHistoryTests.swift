import Foundation
import SwiftUI
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Gate **G5**: opening a foreign session renders its **history** — items, not placeholders —
/// within five seconds of selection, under the scratch config home, with `ConfigHomeWitness`
/// reading zero unattributed changes.
///
/// **Zero model turns and zero dollars.** The child is resumed and sent no prompt, exactly as C5's
/// `LiveForeignChannelTests` does; `AFLEET_LIVE_CLI_TURNS` is read nowhere in this leaf. Any spend
/// would be a scope change that stops and reports rather than a test change. The four entry rules
/// the scratch home imposes — the onboarding state, the trusted working directory, the child's own
/// environment, the registry record — are C5's and are called rather than restated.
///
/// **Nothing here writes under a config home** (X9). The scratch home is read: the witness with
/// `lstat(2)`, the trust document with `O_RDONLY | O_NOFOLLOW`. afleet's own write roots are under a
/// `TempTree`. The only process that writes into the home is the `claude` this test spawns, which is
/// what the witness's allowlist is a claim about.
///
/// **This is the arm where the agent-run tree holds nothing**, and that is the ordinary case rather
/// than the edge: the tree is wire-fed, so a channel opened from its files — every archived channel
/// and every foreign session, which is most of what this app lists — resolves no run at all
/// (tracker 187 on `main`). G2 replays through the wire and therefore has runs to resolve; here
/// there are none, and an `Agent` call in the history renders its chip and does not navigate. The
/// two arms are asserted separately because a chip that navigated to a fabricated run id would land
/// C6.4 on a node that does not exist. What §9 calls a *nil* tree is a non-nil empty one at the tip;
/// see the assertion below and tracker 325.
///
/// §11: no assertion and no printed line states a path, a title, a session id or an account name.
/// What they state is counts and milliseconds.
final class LiveTimelineHistoryTests: XCTestCase {

    func testAForeignSessionsHistoryRendersWithinFiveSeconds() async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        let directory = try ScratchLiveGate.trustedDirectory()

        // 1. The app, launched over the scratch home exactly as it launches over any other.
        let tree = try TempTree()
        let environment = try await LiveForeignChannelTests.appEnvironment(configHome: home)
        let recorder = RecordingAppFleet.Log()
        var sequence = LaunchSequence(
            storeRoot: try tree.directory("store"),
            diagnosticsRoot: try tree.directory("logs"),
            resolveEnvironment: { environment },
            fleetFactory: { configHome, resolved, binary, store, diagnostics, capture in
                RecordingAppFleet(inner: LaunchSequence.makeFleet(configHome, resolved, binary, store, diagnostics,
                                                                 capture),
                                  log: recorder)
            })
        let box = LiveForeignChannelTests.ModelBox()
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }

        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the launch did not reach a workspace over the scratch home")
        let coordinator = try await MainActor.run { try XCTUnwrap(box.value, "the launch built no coordinator") }
        defer { Task { @MainActor in coordinator.stop() } }
        await coordinator.model.whenChanged { !$0.isProvisional && $0.allRows.count > 0 }

        // 2. A session the sidebar already lists, recorded in the directory the scratch home trusts.
        //    The engine resolves a transcript by its project directory, so the child has to be
        //    started where the session was recorded.
        let canonicalDirectory = CanonicalPath.string(directory)
        let target = await MainActor.run { () -> ChannelRow? in
            coordinator.model.allRows.first { row in
                guard let cwd = row.cwd else { return false }
                return CanonicalPath.string(cwd) == canonicalDirectory
            }
        }
        guard let listed = target else {
            await workspace.fleet.shutdown()
            throw XCTSkip("the scratch config home holds no listed transcript recorded in a trusted directory")
        }
        let session = listed.id
        let key = ChannelKey(configHome: home, session: session)

        // 3. The child, resumed and unprompted. The engine keeps the session id across `--resume`,
        //    so the row the sidebar already had is the row that turns live — the foreign-session
        //    scenario, with the one part afleet may not fabricate supplied by the corpus.
        let binary = workspace.binary
        let child = try PseudoTerminalChild(executable: binary,
                                            arguments: ["--resume", session.description],
                                            environment: LiveForeignChannelTests.childEnvironment(configHome: home,
                                                                                                  resolved: environment),
                                            cwd: directory)
        var stopped = false
        defer { if !stopped { child.stop() } }

        let childPID = child.pid
        let record = try await LiveForeignChannelTests.poll(upTo: .seconds(30)) {
            LiveForeignChannelTests.registryRecord(home: home, pid: childPID)
        }
        let seen = try XCTUnwrap(record,
                                 "the pty child wrote no registry record under sessions/ within thirty seconds")
        XCTAssertTrue(seen.sessionId == session.description,
                      "the record the fleet can see is not this test's own child's")

        // 4. Selection, and the clock. The registry is the app's own — `AppModel.bindWorkspace` makes
        //    this exact call — and `open(_:)` is what the channel column performs when a channel is
        //    selected. Nothing is pre-warmed: the model is built by the first ask, one line above the
        //    measurement.
        let registry = await MainActor.run { ChannelTimelineRegistry() }
        await MainActor.run { registry.attach(to: workspace) }
        let model = await MainActor.run { registry.model(for: key) }

        let clock = ContinuousClock()
        let start = clock.now
        let opening = Task { @MainActor in await model.open(listed) }
        let rendered = try await LiveForeignChannelTests.poll(upTo: .seconds(5)) { () -> Int? in
            await MainActor.run { () -> Int? in
                let drawn = TimelineListView.retained(model.rows, by: RetractionRegistry())
                return drawn.isEmpty ? nil : drawn.count
            }
        }
        let elapsed = start.duration(to: clock.now)
        await opening.value

        if rendered == nil {
            let failure = await MainActor.run { model.failure }
            XCTFail("no history within five seconds; the channel reports \(failure ?? "no failure of its own")")
        }
        let count = try XCTUnwrap(rendered, "no history within five seconds")
        XCTAssertLessThan(elapsed, .seconds(5),
                          "the history took \(LiveForeignChannelTests.ms(elapsed)) ms to render, not under 5000")
        XCTAssertGreaterThan(count, 0, "the list drew \(count) row(s), so the assertions below are vacuous")

        // 5. Items, not placeholders. Every row resolves to a kind this leaf claims, and none of them
        //    draws C5's placeholder — which is what the channel showed before this leaf and is the
        //    difference the gate is about. The view is taken from the registry's own switch rather
        //    than through the `AnyView` it erases to, because reflection cannot enter that box.
        let (unclaimed, placeholders, agentChips, navigable) = await MainActor.run {
            () -> (Int, Int, Int, Int) in
            let drawn = TimelineListView.retained(model.rows, by: RetractionRegistry())
            var unclaimed = 0
            var placeholders = 0
            for row in drawn {
                if !TimelineRowKinds.claimed.contains(row.category) { unclaimed += 1 }
                if !ViewTree.values(of: PlaceholderRowView.self, in: TimelineRowKinds.view(for: row)).isEmpty {
                    placeholders += 1
                }
            }
            // The nil-tree arm. The chip is built from the same context the list injects, with a
            // counting double behind the navigation seam.
            let navigation = CountingAgentNavigation()
            let context = InventedItems.context(agents: navigation,
                                                neighbourhood: TimelineNeighbourhood(items: model.timeline.items,
                                                                                     agents: model.timeline.agents),
                                                key: key)
            var chips = 0
            var canNavigate = 0
            for row in drawn {
                guard case .toolCall(let call) = row.item, call.name == "Agent" else { continue }
                chips += 1
                let content = AgentChip.content(for: call, in: context)
                // It renders: the title is what the reader sees, and it comes from the call itself.
                XCTAssertFalse(content.title.isEmpty, "an Agent chip on a treeless channel drew no title")
                if content.canNavigate { canNavigate += 1 }
            }
            XCTAssertEqual(navigation.calls, 0,
                           "a chip on a channel with no run tree navigated \(navigation.calls) time(s)")
            return (unclaimed, placeholders, chips, canNavigate)
        }
        XCTAssertEqual(unclaimed, 0, "\(unclaimed) of \(count) row(s) draw a kind no builder claims")
        XCTAssertEqual(placeholders, 0, "\(placeholders) of \(count) row(s) are still C5's placeholder")

        // 6. The arm this gate is the opposite of: a channel opened from its files has no tree, so a
        //    chip in its history renders and does not navigate. G2 covers the wire path, where a tree
        //    exists and the chip resolves a run id.
        //    **Corrected 2026-09-09 from this gate's own live run.** §9 and tracker 187 both say the
        //    tree is *nil* for a channel opened from its files. At the tip it is not: `StreamIngestion.open`
        //    builds the wire reducer unconditionally, so `agents` is a non-nil tree that holds no
        //    runs. The behaviour the chip depends on is unchanged — no node, no run id, no
        //    navigation — but a caller testing `agents == nil` to mean "no tree" is testing something
        //    that is never true. Tracker 325, and what is asserted here is the property that decides
        //    the chip.
        let runs = await MainActor.run { model.timeline.agents?.nodes.count }
        XCTAssertEqual(runs, 0,
                       "a channel opened from its files resolved \(runs.map(String.init) ?? "no tree at all") run(s); " +
                       "the tree is wire-fed and this channel has no wire")
        XCTAssertEqual(navigable, 0,
                       "\(navigable) of \(agentChips) Agent chip(s) on a treeless channel reported themselves able " +
                       "to navigate")

        // 7. This test's own child, ended by this test. Nothing else is signalled, and the trace says
        //    so: the app entered no path that stops, adopts or displaces a session.
        child.stop()
        stopped = true
        await MainActor.run { registry.release(key) }
        await workspace.fleet.shutdown()

        let performed = recorder.actions
        let terminating = performed.filter { RecordingAppFleet.terminating.contains($0) }
        XCTAssertTrue(terminating.isEmpty,
                      "the app entered \(terminating.count) termination path(s): \(terminating.sorted())")

        // 8. The witness. Every changed path is one a spawned `claude` writes, and the two families
        //    that carry an identity carry this child's.
        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        let attribution = ConfigHomeWitness.Attribution(childPID: childPID, session: session.description)
        let unattributed = ConfigHomeWitness.unattributed(difference, attribution: attribution)
        XCTAssertTrue(unattributed.isEmpty,
                      "\(unattributed.count) changed path(s) under the config home are unattributed")
        XCTAssertTrue(!difference.isEmpty, "the config home did not change at all, so the witness watched nothing")
        let narrowed = ConfigHomeWitness.unattributed(difference, against: ["projects/"])
        XCTAssertTrue(narrowed.count > 0, "a narrowed allowlist explained every path, so the check is vacuous")

        print("""
        G5 a foreign session's history, live and unprompted
          rows rendered ................ \(count), of which placeholders \(placeholders)
          agent chips .................. \(agentChips), navigable \(navigable)
          agent-run tree ............... \(runs ?? -1) run(s), as a file-opened channel's has
          time from selection .......... \(LiveForeignChannelTests.ms(elapsed)) ms of the 5000 allowed
          lifecycle actions performed .. \(performed.count), of which terminating \(terminating.count)
          config home .................. \(difference.summary), unattributed \(unattributed.count)
          model turns .................. 0
        """)
    }
}
