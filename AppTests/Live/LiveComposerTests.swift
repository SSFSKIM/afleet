import Foundation
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 gate **G6**, the half that runs: a real engine answers the composer's `@` completion, and
/// the config home is witnessed across the spawn.
///
/// **Zero model turns, and that is the whole design of this file, not a saving.** `file_suggestions`
/// is a control request: the engine answers it out of its own index without a model, so item 12's
/// `@` arm is a real live assertion at no cost. Nothing here sends a prompt.
///
/// **The prompted half of G6 is blocked, not failed** (2026-09-08). Under the scratch home an
/// account policy refuses every turn: the engine spawns, handshakes and accepts the prompt, and the
/// first assistant record is an API error saying the organisation has disabled Claude subscription
/// access for Claude Code — one `result` frame, zero cost, no permission card. C6.3's run found it
/// with a `result` frame. Items 2, 8 and 12's turns are therefore recorded as blocked, all four
/// budgeted turns are unspent, and this leaf does not retry and does not spend a turn confirming a
/// diagnosis another leaf already made.
///
/// **Nothing here writes under a config home** (X9). The scratch home is read — the witness with
/// `lstat(2)`, the trust document with `O_RDONLY | O_NOFOLLOW` — and the only process that writes
/// into it is the `claude` afleet spawns, which is exactly what the witness's allowlist is a claim
/// about. afleet's own two write roots are under a `TempTree`, and the one file this test creates
/// lies in the already-trusted fixtures directory under `/private/tmp`.
final class LiveComposerTests: XCTestCase {

    /// Item 12's `@` arm, live and with **zero** turns, plus the recursive config-home witness on the
    /// same spawn.
    func testTheEngineAnswersFileSuggestionsAndNothingUnattributedIsWritten() async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        let directory = try ScratchLiveGate.trustedDirectory()

        // A file for the engine's index to find, in a directory the scratch home already trusts.
        // Never under a config home; `ScratchLiveGate` excludes such a directory by code.
        let marker = "invented-mention-target-\(ProcessInfo.processInfo.processIdentifier).txt"
        let markerURL = directory.appending(path: marker)
        try "an invented file, for one `@` completion\n".write(to: markerURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        // 1. The app, launched over the scratch home exactly as it launches over any other.
        let tree = try TempTree()
        let environment = try await Self.appEnvironment(configHome: home)
        var sequence = LaunchSequence(storeRoot: try tree.directory("store"),
                                      diagnosticsRoot: try tree.directory("logs"),
                                      resolveEnvironment: { environment })
        let box = ModelBox()
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

        // 2. A channel the sidebar already lists, recorded in the trusted directory — the engine
        //    resolves a transcript by its project directory, so the resumed child has to start there.
        let canonical = CanonicalPath.string(directory)
        let target = await MainActor.run { () -> ChannelRow? in
            coordinator.model.allRows.first { row in
                guard let cwd = row.cwd, row.offersOwnedActions else { return false }
                return CanonicalPath.string(cwd) == canonical
            }
        }
        guard let row = target else {
            await workspace.fleet.shutdown()
            throw XCTSkip("the scratch config home lists no ownable transcript recorded in a trusted directory")
        }
        let key = row.key

        // 3. The spawn. `--resume`, no prompt: the engine handshakes and waits. Zero turns.
        _ = try await workspace.fleet.perform(.open, on: key)
        let ready = try await Self.poll(upTo: .seconds(45)) { () -> ChannelState? in
            guard let state = await workspace.fleet.state(of: key), state.origin == .owned(.ready) else { return nil }
            return state
        }
        guard let readyState = ready else {
            await workspace.fleet.shutdown()
            let origin = await workspace.fleet.state(of: key)?.origin
            throw XCTSkip("the channel did not reach ready within 45 s; it was \(String(describing: origin))")
        }
        let childPID = readyState.observed.holders.first(where: \.isOwnChild)?.pid

        // 4. The gate: the composer's own `@` path, through X5, against a real engine.
        let composer = await MainActor.run {
            ComposerModel(key: key, lifecycle: workspace.fleet, surface: ChannelSurfaceState())
        }
        let stem = String(marker.prefix(marker.count - 4))
        await MainActor.run { composer.draft = "look at @\(stem)" }
        await composer.requestFileSuggestions(stem)
        let suggestions = await MainActor.run { composer.fileSuggestions }

        XCTAssertGreaterThan(suggestions.count, 0,
                             "the engine answered file_suggestions with \(suggestions.count) path(s) for a "
                             + "\(stem.count)-character query naming a file in its own working directory")
        XCTAssertTrue(suggestions.contains { $0.contains(stem) },
                      "none of the \(suggestions.count) suggestion(s) names the file the query asked for")

        // 5. This test's own channel, ended by this test.
        _ = try? await workspace.fleet.perform(.reap, on: key)
        await workspace.fleet.shutdown()

        // 6. The witness, read recursively and attributed against this child. Not an empty diff: a
        //    resumed session legitimately writes its registry record and refreshes `.claude.json`,
        //    and demanding emptiness would fail the gate on the engine doing what the scenario needs.
        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        let attribution = childPID.map { ConfigHomeWitness.Attribution(childPID: $0, session: key.session.description) }
        let unattributed = ConfigHomeWitness.unattributed(difference, attribution: attribution)
        XCTAssertEqual(unattributed.count, 0,
                       "\(unattributed.count) changed path(s) under the config home are unattributed: \(unattributed)")
        XCTAssertFalse(difference.isEmpty, "the config home did not change at all, so the witness watched nothing")

        // The proof the comparison discriminates, from the same reading rather than a second spawn.
        let narrowed = ConfigHomeWitness.unattributed(difference, against: ["projects/"])
        XCTAssertGreaterThan(narrowed.count, 0, "a narrowed allowlist explained every path, so the check is vacuous")

        print("""
        G6 the zero-turn half
          file suggestions ............. \(suggestions.count) path(s) for a \(stem.count)-character query
          config home .................. \(difference.summary), unattributed \(unattributed.count)
          model turns .................. 0 (items 2, 8 and 12's turns blocked by account policy)
        """)
    }

    // MARK: - Rig

    /// The login shell's environment with `CLAUDE_CONFIG_DIR` pointed at the scratch home.
    private static func appEnvironment(configHome: URL) async throws -> ResolvedEnvironment {
        let resolved = await LaunchSequence.resolveLoginShellEnvironment()
        var variables = resolved.variables
        variables["CLAUDE_CONFIG_DIR"] = configHome.path(percentEncoded: false)
        return ResolvedEnvironment(variables: variables, shell: resolved.shell,
                                   capturedAt: resolved.capturedAt, mode: resolved.mode)
    }

    /// Polls `body` every 100 ms until it answers or `deadline` passes.
    private static func poll<T: Sendable>(upTo deadline: Duration,
                                          _ body: @Sendable () async -> T?) async throws -> T? {
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < deadline {
            if let value = await body() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await body()
    }

    /// The coordinator the launch built. A single-owner box; every access is on the main actor.
    private final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }
}
