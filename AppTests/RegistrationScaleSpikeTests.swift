import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Spike S-C5-2: what does registering every listed channel cost at the local corpus's scale?
///
/// The design registers eagerly over every listed entry, and each registration builds one
/// `ChannelSupervisor` actor plus one detached holder-seeding task. The author's config home holds
/// about three thousand transcripts, so the question is whether three thousand actors and three
/// thousand detached tasks fit inside G1d's five-second first paint with bounded memory.
///
/// It is skipped unless `AFLEET_SPIKE_C5_2=1`. `xcodebuild` does not forward the shell's environment
/// to the test host, so the variable is passed as `TEST_RUNNER_AFLEET_SPIKE_C5_2=1`, which the runner
/// re-exports with the prefix stripped. It stays committed so the measurement is reproducible rather
/// than a number in a document.
///
/// Nothing here reads or writes a real config home: the three thousand transcripts are invented and
/// live under a `TempTree` (X9, §11).
final class RegistrationScaleSpikeTests: XCTestCase {

    /// The corpus the parent's §3 names.
    static let transcriptCount = 3_000

    func testRegisteringThreeThousandChannels() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AFLEET_SPIKE_C5_2"] == "1",
                          "spike S-C5-2 runs only under AFLEET_SPIKE_C5_2=1")

        let tree = try TempTree()
        let home = try ScratchConfigHome(tree: tree)
        let projectCount = 40

        // 1. Three thousand invented transcripts across forty projects, half of them inside the
        //    thirty-day window and half outside it, so the recency branch is exercised at scale.
        let writing = ContinuousClock().measure {
            for n in 0..<Self.transcriptCount {
                let session = Self.session(n)
                let age: TimeInterval = n.isMultiple(of: 2) ? 3600 : 60 * 24 * 3600
                try? home.write(ScratchConfigHome.Transcript(
                    session: session,
                    slug: "invented-project-\(n % projectCount)",
                    cwd: "/invented/project-\(n % projectCount)",
                    mtime: Date().addingTimeInterval(-age)))
            }
        }

        // 2. C3's index over them.
        let index = home.index()
        let buildClock = ContinuousClock()
        let buildStart = buildClock.now
        let snapshot = try await index.build()
        let buildElapsed = buildStart.duration(to: buildClock.now)
        XCTAssertEqual(snapshot.entries.count, Self.transcriptCount, "the spike's corpus did not land")

        // 3. A real `Fleet` over the same home, started the way the composition root starts it.
        let store = try FileStateStore(baseDirectory: try tree.directory("store"), configHomes: [home.root])
        let fleet = Fleet(configHome: home.configHome,
                          environment: ResolvedEnvironment(variables: ["HOME": tree.root.path, "PATH": "/usr/bin:/bin"],
                                                           shell: "/bin/zsh", capturedAt: Date(), mode: .login),
                          binary: tree.root.appending(path: "claude-that-never-runs"),
                          store: store,
                          diagnosticsDirectory: try tree.directory("logs"))
        await fleet.start()

        let baseline = Self.residentBytes()

        // 4. The measurement the spike exists for: registration of every listed entry.
        let listing = ChannelRegistrar.listed(snapshot, configHome: home.configHome.root)
        let registerClock = ContinuousClock()
        let registerStart = registerClock.now
        let report = await ChannelRegistrar.register(listing, into: fleet, now: Date())
        let registerElapsed = registerStart.duration(to: registerClock.now)

        // 5. And the thing the user actually waits for: a populated sidebar.
        let lifecycle = LifecycleDouble()
        let paintClock = ContinuousClock()
        let paintStart = paintClock.now
        let rowCount = await MainActor.run { () -> Int in
            let model = FleetBrowserModel(lifecycle: lifecycle, configHome: home.configHome.root)
            model.restore(from: snapshot)
            return model.allRows.count
        }
        let paintElapsed = paintStart.duration(to: paintClock.now)

        let peakAtPaint = Self.peakResidentBytes()
        let afterRegistration = Self.residentBytes()

        // 6. `Fleet.build` seeds each new supervisor's holders in a **detached** task, so the cost of
        //    three thousand registrations is not all inside the call that made them. Two seconds of
        //    settling, then the peak again: this is the number that says whether the detached work
        //    behind an eager registration is bounded.
        try await Task.sleep(for: .seconds(2))
        let peakSettled = Self.peakResidentBytes()
        let residentSettled = Self.residentBytes()

        await fleet.shutdown()

        // Counts, durations and sizes only — never a path, a title or a session id (§11).
        print("""
        S-C5-2 registration at scale
          transcripts written .......... \(Self.transcriptCount) across \(projectCount) projects in \(Self.ms(writing)) ms
          index build .................. \(snapshot.entries.count) entries in \(Self.ms(buildElapsed)) ms
          listed ....................... \(listing.rows.count) rows
          registered ................... \(report.registered) (recent \(report.recent), skipped without cwd \(report.skippedWithoutCWD)) in \(Self.ms(registerElapsed)) ms
          model populated .............. \(rowCount) rows in \(Self.ms(paintElapsed)) ms
          resident before registration . \(Self.mb(baseline)) MB
          resident after registration .. \(Self.mb(afterRegistration)) MB
          peak resident at paint ....... \(Self.mb(peakAtPaint)) MB
          resident after 2 s settle .... \(Self.mb(residentSettled)) MB
          peak resident after settle ... \(Self.mb(peakSettled)) MB
          first paint (build+register+model) \(Self.ms(buildElapsed + registerElapsed + paintElapsed)) ms
        """)

        XCTAssertEqual(report.registered, listing.rows.count)
        XCTAssertEqual(rowCount, listing.rows.count)
        XCTAssertGreaterThan(listing.rows.count, 0, "the spike measured an empty listing")
    }

    /// First paint through the **real launch path**, which the measurement above did not cover.
    ///
    /// The first version of this spike constructed the index, the fleet and the model by hand. That
    /// is the right shape for isolating registration's cost, and it is the wrong shape for a
    /// first-paint number: it skipped `LaunchSequence.run()` entirely, and with it the read of
    /// `<configHome>/.claude.json` that the coordinator makes for section order — which on a config
    /// home of ordinary size was two seconds of main-actor work nobody had measured. This runs the
    /// sequence itself, over the same three thousand transcripts and over a `.claude.json` sized
    /// like a real one, and stops the clock when the sidebar has every row.
    ///
    /// Four seams are stubbed and none of them is registration or indexing: the login-shell
    /// environment capture, the binary locate, the version probe and the sign-in read. The first is
    /// a real launch cost and belongs to the composition root rather than to this spike; the other
    /// three are milliseconds. Everything the child owns runs for real.
    func testFirstPaintThroughTheLaunchSequence() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AFLEET_SPIKE_C5_2"] == "1",
                          "spike S-C5-2 runs only under AFLEET_SPIKE_C5_2=1")

        let tree = try TempTree()
        let home = try ScratchConfigHome(tree: tree)
        let projectCount = 40
        for n in 0..<Self.transcriptCount {
            let age: TimeInterval = n.isMultiple(of: 2) ? 3600 : 60 * 24 * 3600
            try home.write(ScratchConfigHome.Transcript(
                session: Self.session(n),
                slug: "invented-project-\(n % projectCount)",
                cwd: "/invented/project-\(n % projectCount)",
                mtime: Date().addingTimeInterval(-age)))
        }

        // A `.claude.json` the size the review measured against: 306 projects, about half a megabyte.
        let claudeJSON = try Self.writeLargeClaudeJSON(at: home.root, projects: 306)

        let binary = tree.root.appending(path: "claude-that-never-runs")
        let environment = LaunchFixtures.environment(home: tree.root, configHome: home.root)
        let storeRoot = try tree.directory("store")
        let logsRoot = try tree.directory("logs")

        let sequence = LaunchSequence(
            storeRoot: storeRoot,
            diagnosticsRoot: logsRoot,
            resolveEnvironment: { environment },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 257)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: LaunchSequence.makeTranscriptIndex,
            fleetFactory: LaunchSequence.makeFleet,
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })

        let box = ModelBox()
        var configured = sequence
        configured.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }

        let clock = ContinuousClock()
        let start = clock.now
        let route = await configured.run()
        let returned = start.duration(to: clock.now)
        guard route.workspace != nil else { return XCTFail("the launch did not reach a workspace") }

        let found = await MainActor.run { box.value }
        let coordinator = try XCTUnwrap(found)
        let wanted = Self.transcriptCount
        await coordinator.model.whenChanged { $0.allRows.count >= wanted }
        let painted = start.duration(to: clock.now)

        // And the ordering inputs, which land off the critical path.
        //
        // This waited on `!sections.isEmpty` until the re-review pointed out that sections are
        // non-empty from the very first rebuild, so the wait returned at once and measured nothing —
        // an instrument whose stated purpose was fiction, the third in this suite. `hasGrouping` is
        // set by `updateGrouping`, which is the call the detached read ends in, so the wait now ends
        // when the thing it names has actually happened and the elapsed time is a number rather than
        // a coincidence.
        await coordinator.model.whenChanged { $0.hasGrouping }
        let ordered = start.duration(to: clock.now)
        let sections = await MainActor.run { coordinator.model.sections.count }
        let rows = await MainActor.run { coordinator.model.allRows.count }
        let peak = Self.peakResidentBytes()

        await MainActor.run { coordinator.stop() }
        await route.workspace?.fleet.shutdown()

        print("""
        S-C5-2 first paint through LaunchSequence.run()
          transcripts .................. \(Self.transcriptCount) across \(projectCount) projects
          .claude.json ................. \(claudeJSON) bytes, 306 projects
          run() returned ............... \(Self.ms(returned)) ms
          sidebar fully painted ........ \(rows) rows in \(Self.ms(painted)) ms
          sections ..................... \(sections)
          project order + grouping ..... applied at \(Self.ms(ordered)) ms
          peak resident ................ \(Self.mb(peak)) MB
        """)

        XCTAssertEqual(rows, wanted)
        XCTAssertGreaterThan(sections, 0, "the launch painted no sections")
        XCTAssertLessThan(painted, .seconds(5), "first paint took \(Self.ms(painted)) ms against G1d's five seconds")
    }

    /// A `.claude.json` of realistic size and shape, written into the scratch home.
    @discardableResult
    static func writeLargeClaudeJSON(at root: URL, projects: Int) throws -> Int {
        var entries: [String] = []
        for n in 0..<projects {
            let filler = String(repeating: "invented-", count: 150)
            entries.append(#""/invented/project-\#(n)":{"hasTrustDialogAccepted":true,"exampleFiles":["\#(filler)"]}"#)
        }
        let text = #"{"hasCompletedOnboarding":true,"projects":{"# + entries.joined(separator: ",") + "}}"
        let data = Data(text.utf8)
        try data.write(to: root.appending(path: ".claude.json"))
        return data.count
    }

    /// A single-owner box for the coordinator the launch built; every access is on the main actor.
    final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }

    // MARK: - Helpers

    /// A deterministic invented session id per index. No identifier here comes from a real home.
    static func session(_ n: Int) -> SessionID {
        let tail = String(format: "%012x", n)
        return SessionID("5c520000-0000-4000-8000-\(tail)")!
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }

    static func residentBytes() -> UInt64 { taskInfo()?.resident_size ?? 0 }
    static func peakResidentBytes() -> UInt64 { taskInfo()?.resident_size_max ?? 0 }

    private static func taskInfo() -> mach_task_basic_info? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
