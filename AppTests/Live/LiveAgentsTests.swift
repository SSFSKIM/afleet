import Foundation
import SwiftUI
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.4 gate **G6**: the Agents tab over a real session under the scratch config home.
///
/// **How to run it.** `make live LIVE_ONLY=AfleetTests/LiveAgentsTests`. The switch is
/// `TEST_RUNNER_AFLEET_LIVE_CLI=1` and **not** `AFLEET_LIVE_CLI=1`: `xcodebuild` re-exports a
/// `TEST_RUNNER_`-prefixed variable into the test host with the prefix stripped, and an unprefixed
/// switch never reaches the host at all — a spelling that has cost this repository a green run that
/// asserted nothing more than once. `make live` sets both that and
/// `TEST_RUNNER_CLAUDE_CONFIG_DIR`, and it checks its preconditions **loudly**: a missing scratch
/// home, a missing `claude` on `PATH` and a home that reports no completed onboarding each exit 2
/// with the recovery written out, rather than passing while every test inside skips.
///
/// **The half that runs spends zero turns, and that is the design rather than a saving.** A channel
/// opened from its transcript files spawns nothing: the tree and the per-run transcript are read off
/// `subagents/agent-<id>.jsonl` and its `.meta.json` sidecar, which is what makes items 9's tree and
/// 50's transcript assertable at no cost and with no process. Nothing here sends a prompt and
/// nothing here reads `AFLEET_LIVE_CLI_TURNS`.
///
/// **The prompted half is blocked, not failed, and its turns are unspent.** Under this scratch
/// account an organisation policy refuses every turn before one is spent: the engine spawns,
/// handshakes and accepts the prompt, and the first assistant record is an API error saying the
/// organisation has disabled Claude subscription access for Claude Code. C6.2's G6 found it and
/// C6.3's G5 confirmed it; this leaf records it and does not spend a turn confirming a diagnosis
/// two leaves have already made. `testThePromptedHalfIsCarriedAsAManualWitness` states the cause and
/// the steps a person on a permitting account would take, and skips. Six budgeted turns, **zero
/// spent**.
///
/// **Nothing here writes under a config home** (X9). The scratch home is read — the witness with
/// `lstat(2)`, the trust document with `O_RDONLY | O_NOFOLLOW` — and the zero-turn half starts no
/// process at all, so the strongest available reading of the witness is the one it takes: nothing
/// under the home moved. afleet's own write roots are under a `TempTree`.
///
/// §11: no assertion and no printed line states a path, a title, a session id, a task id, an agent
/// id or an account name. What they state is counts and milliseconds.
final class LiveAgentsTests: XCTestCase {

    /// How long the tree is given to resolve from disk. A watchdog, not a threshold: the read is a
    /// directory walk and a decode, and the measurement is reported rather than asserted against.
    private static let treeBudget: Duration = .seconds(20)

    // MARK: - The half that runs

    /// **G6's zero-turn half (items 9 and 50): a session that already carries agent runs opens from
    /// disk, its tree resolves, and one run's transcript renders.**
    ///
    /// Every part of it is the app's own expression. The registry is the one `AppModel.bindWorkspace`
    /// builds, `open(_:)` is what the channel column performs on selection, `AgentRunRead` is what
    /// the tab derives, and `input(of:retainedBy:)` is what the transcript pane hands the renderer.
    /// Nothing is assembled here.
    ///
    /// **The discriminating half is that the runs come from the files.** No process is started, so a
    /// tree fed only by the wire resolves nothing and the assertion below fails — which is exactly
    /// what a channel opened from its files did before the sidecar source reached this path. The
    /// per-run rows are then asserted to be a **strict subset** of the channel's, because a filter
    /// that returned the whole channel would satisfy every "it drew something" assertion there is.
    func testASessionWithAgentRunsOpensItsTreeAndOneRunsTranscriptFromDisk() async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        XCTAssertGreaterThan(before.count, 0,
                             "the witness read \(before.count) file(s) under the config home, so it watched nothing")

        // 1. The app, launched over the scratch home exactly as it launches over any other.
        let tree = try TempTree()
        let environment = try await LiveForeignChannelTests.appEnvironment(configHome: home)
        var sequence = LaunchSequence(storeRoot: try tree.directory("store"),
                                      diagnosticsRoot: try tree.directory("logs"),
                                      resolveEnvironment: { environment })
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

        // 2. A listed session whose transcript directory already holds subagent files. The candidate
        //    set is read off the home rather than named here, so this suite carries no session id and
        //    no slug (§11); what it reports is how many candidates it found.
        let withRuns = Self.sessionsCarryingSubagents(under: home)
        let listed = await MainActor.run { () -> ChannelRow? in
            coordinator.model.allRows.first { withRuns.contains($0.id.description) }
        }
        guard let row = listed else {
            await workspace.fleet.shutdown()
            // **A skip only where the precondition is genuinely absent.** A home with no subagent
            // transcripts at all cannot run this gate; a home that has them and an app that lists
            // none of them is an indexing regression, and skipping on it turns a required gate into
            // a green run that asserted nothing — which is the failure this arm is guarded against.
            guard withRuns.isEmpty else {
                XCTFail("\(withRuns.count) session(s) under the scratch config home carry subagent transcripts "
                        + "and the app listed none of them")
                return
            }
            throw XCTSkip("the scratch config home holds no session whose transcript directory carries subagent files")
        }
        let key = ChannelKey(configHome: home, session: row.id)

        // 3. The open. No `perform(.open)`, no pty child, no prompt — the channel is opened from its
        //    files, which is the ordinary case for every archived and every foreign session.
        let registry = await MainActor.run { ChannelTimelineRegistry() }
        await MainActor.run { registry.attach(to: workspace) }
        let model = await MainActor.run { registry.model(for: key) }

        let clock = ContinuousClock()
        let start = clock.now
        let opening = Task { @MainActor in await model.open(row) }
        let resolved = try await LiveForeignChannelTests.poll(upTo: Self.treeBudget) { () -> Int? in
            await MainActor.run { () -> Int? in
                let count = model.timeline.agents?.nodes.count ?? 0
                return count > 0 ? count : nil
            }
        }
        let elapsed = start.duration(to: clock.now)
        await opening.value

        guard let runCount = resolved else {
            await MainActor.run { registry.release(key) }
            await workspace.fleet.shutdown()
            let failure = await MainActor.run { model.failure }
            XCTFail("a session whose files carry subagent transcripts resolved no run within "
                    + "\(LiveForeignChannelTests.ms(Self.treeBudget)) ms; the channel reports "
                    + "\(failure ?? "no failure of its own")")
            return
        }

        // 4. The tab's own read of that tree, and one run's transcript through the pane's own
        //    expression.
        let report = await MainActor.run { () -> Report in
            let pane = AgentsModel(channel: key,
                                   timelines: { [registry] key in registry.model(for: key).timeline },
                                   store: AgentSelectionStore())
            let read = pane.read
            var report = Report(runs: runCount, roots: read.roots.count)
            guard case .tree(let roots) = read.state, let first = roots.first else { return report }
            report.state = "tree"
            report.contents = roots.compactMap { read.content(of: $0) }.count
            report.deepest = roots.map { read.ancestors(of: $0).count }.max() ?? 0
            for id in roots { report.children += read.children(of: id).count }

            // The run whose transcript is opened: the first root that has rows of its own, so the
            // assertion is about a transcript rather than about which root the tree listed first.
            let candidates = [first] + read.children(of: first)
            let chosen = candidates.first { !pane.input(of: $0, retainedBy: nil).rows.isEmpty } ?? first
            let input = pane.input(of: chosen, retainedBy: nil)
            report.rows = input.rows.count
            report.channelRows = model.rows.count
            report.previewPassed = input.preview != nil
            for row in input.rows {
                if !TimelineRowKinds.claimed.contains(row.category) { report.unclaimed += 1 }
                if !ViewTree.values(of: PlaceholderRowView.self, in: TimelineRowKinds.view(for: row)).isEmpty {
                    report.placeholders += 1
                }
                if ViewTree.values(of: String.self, in: TimelineRowKinds.view(for: row)).isEmpty {
                    report.blank += 1
                }
            }
            return report
        }

        XCTAssertEqual(report.state, "tree",
                       "a channel whose files carry \(runCount) run(s) read a state other than a tree")
        XCTAssertGreaterThan(report.roots, 0, "the read resolved \(report.roots) root(s) from \(runCount) run(s)")
        XCTAssertEqual(report.contents, report.roots,
                       "\(report.roots - report.contents) of \(report.roots) root(s) drew no node content")
        XCTAssertGreaterThan(report.rows, 0,
                             "the chosen run's transcript is \(report.rows) row(s), so nothing rendered from disk")
        XCTAssertLessThan(report.rows, report.channelRows,
                          "one run's transcript is \(report.rows) of the channel's \(report.channelRows) row(s); a "
                          + "filter that returned the whole channel would pass every other assertion here")
        XCTAssertEqual(report.unclaimed, 0,
                       "\(report.unclaimed) of \(report.rows) transcript row(s) draw a kind no builder claims")
        XCTAssertEqual(report.placeholders, 0,
                       "\(report.placeholders) of \(report.rows) transcript row(s) are still a placeholder")
        XCTAssertEqual(report.blank, 0,
                       "\(report.blank) of \(report.rows) transcript row(s) drew no text at all")
        XCTAssertFalse(report.previewPassed,
                       "the pane handed a run the channel's streaming preview, which carries no agent attribution")

        // 5. Teardown, and the witness. Nothing was spawned, so the strongest reading is available:
        //    every changed path is still measured against the allowlist, and the expected answer is
        //    that nothing changed at all.
        await MainActor.run { registry.release(key) }
        await workspace.fleet.shutdown()

        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        let unattributed = ConfigHomeWitness.unattributed(difference)
        XCTAssertEqual(unattributed.count, 0,
                       "\(unattributed.count) changed path(s) under the config home are unattributed")

        print("""
        G6 the zero-turn half — the Agents tab over a real session, opened from its files
          sessions carrying subagent files . \(withRuns.count) on disk
          runs resolved ................... \(runCount), roots \(report.roots), nested children \(report.children)
          node contents drawn ............. \(report.contents) of \(report.roots) root(s)
          one run's transcript ............ \(report.rows) row(s) of the channel's \(report.channelRows), \
        placeholders \(report.placeholders), unclaimed \(report.unclaimed)
          time from open to a tree ........ \(LiveForeignChannelTests.ms(elapsed)) ms of the \
        \(LiveForeignChannelTests.ms(Self.treeBudget)) allowed
          config home ..................... \(difference.summary), unattributed \(unattributed.count)
          model turns ..................... 0
        """)
    }

    // MARK: - The half that is blocked

    /// **G6's prompted half (items 9, 49, 50, 51's positive path and 52), recorded blocked with its
    /// turns unspent.**
    ///
    /// It is not written as a running body on purpose. C6.2's G6 established that under this scratch
    /// account an organisation policy refuses every turn, and C6.3's G5 confirmed it; a body that
    /// spawned, prompted and then asserted against the refusal would spend nothing but would assert
    /// the policy rather than the feature, and a body written against turns nobody here has ever seen
    /// would be a test against this leaf's imagination of them. What the gate needs from this leaf is
    /// the record and the steps, and both are here.
    ///
    /// **The manual witness — what a person on a permitting account does, in order:**
    ///
    /// 1. `make live LIVE_ONLY=AfleetTests/LiveAgentsTests` with the scratch home onboarded, and
    ///    open a channel in a trusted directory through *Open*.
    /// 2. Prompt it to start a subagent and, from that one, a second — the two-step shape
    ///    `nested-depth-2` records. **Item 9**: the Agents tab shows two nodes, the second nested
    ///    under the first, each with its type, its own model badge and a live elapsed time.
    /// 3. While the inner run is working, use *Stop* on its node. **Item 49**: the node settles
    ///    stopped and the engine's own status says so; the action goes out as `StopTask` and nothing
    ///    else.
    /// 4. Open the finished run's node. **Item 50**: its transcript is that run's rows only, authored
    ///    by the agent type with the run's badge, and *Open transcript file* reaches the file the
    ///    tree names.
    /// 5. Use *Send message* on a completed run. **Item 51's positive path**: the row and the node
    ///    both show *Pending*, then *Relayed* when the main agent's `SendMessage` comes back, then
    ///    *Delivered* when the text reaches that run's own transcript — and **not** before.
    /// 6. Prompt a subagent into a tool that needs permission. **Item 52**: the card appears on the
    ///    subagent's node as well as in the channel, and answering it in either place settles both.
    ///
    /// Six turns budgeted across steps 2 to 6, **zero spent**, and the budget belongs to whoever
    /// runs this on an account that permits prompting. A failed item is re-run once and then recorded
    /// as a finding; nothing here is looped.
    func testThePromptedHalfIsCarriedAsAManualWitness() throws {
        try ScratchLiveGate.skipUnlessLive()
        throw XCTSkip("""
            G6's prompted half — items 9, 49, 50, 51's positive path and 52 — is blocked: this \
            scratch account's organisation policy refuses every model turn before one is spent, as \
            C6.2's G6 and C6.3's G5 both recorded. Six budgeted turns, zero spent. The steps a \
            person on a permitting account takes are written in this test's doc comment and are the \
            manual witness the gate is closed against.
            """)
    }

    // MARK: - Rig

    /// What the zero-turn half measured, gathered in one main-actor hop so the assertions below it
    /// are plain values. Counts only — it holds no id, no path and no drawn string (§11).
    private struct Report {
        var runs = 0
        var roots = 0
        var state = "not a tree"
        var contents = 0
        var children = 0
        var deepest = 0
        var rows = 0
        var channelRows = 0
        var previewPassed = false
        var unclaimed = 0
        var placeholders = 0
        var blank = 0
    }

    /// Every session id under `home/projects/` whose transcript directory holds subagent files.
    ///
    /// Read here rather than named, so this file carries no session id and no slug: what a report
    /// says is how many were found. A directory it cannot read is skipped rather than failing the
    /// walk, and nothing is opened — `contentsOfDirectory` and a name test are the whole of it.
    private static func sessionsCarryingSubagents(under home: URL) -> Set<String> {
        var found: Set<String> = []
        let projects = home.appending(path: "projects", directoryHint: .isDirectory)
        for slug in (try? FileManager.default.contentsOfDirectory(at: projects,
                                                                  includingPropertiesForKeys: nil)) ?? [] {
            for session in (try? FileManager.default.contentsOfDirectory(at: slug,
                                                                         includingPropertiesForKeys: nil)) ?? [] {
                let subagents = session.appending(path: "subagents", directoryHint: .isDirectory)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: subagents.path)) ?? []
                guard files.contains(where: { $0.hasPrefix("agent-") }) else { continue }
                found.insert(session.lastPathComponent)
            }
        }
        return found
    }
}
