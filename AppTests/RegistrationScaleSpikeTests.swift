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
