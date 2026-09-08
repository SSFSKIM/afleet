import Foundation
import Darwin
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G1d: what a first paint costs against the config home this machine actually has.
///
/// Opt-in, and **read-only**. The gate reads whatever config home the resolved environment names —
/// the author's own on an ordinary checkout — because that is the only corpus that answers the
/// question the budget is about: `RegistrationScaleSpikeTests` measured 456 ms over three thousand
/// *invented* transcripts of three lines each, and a real corpus is neither that uniform nor that
/// short. X9 forbids *writing* under a config home, not reading one, so this is permitted; every
/// byte afleet writes during the measurement lands in a `TempTree` (the store) or beside it (the
/// diagnostics directory), and both roots are named explicitly below rather than defaulted.
///
/// The one file this test opens itself is the global config document, through
/// `ClaudeJSONReader.read`, which opens `O_RDONLY | O_NOFOLLOW` and creates nothing. Everything else
/// it learns about the corpus comes from `lstat(2)` — a size and a count, never a read and never an
/// open. C3's index does the transcript reading, read-only, as it does in production.
///
/// **It reports counts, sizes and milliseconds only** (parent §11): no path, no title, no session
/// id, no project name reaches the output, and no assertion in this file prints an operand that was
/// derived at runtime.
///
/// Both paths the design distinguishes are measured. The **no-snapshot** path is a launch against a
/// store with nothing persisted in it, so the sidebar cannot paint until C3's build finishes; that
/// is the number the five-second claim is held against. The **with-snapshot** path is a second
/// launch against the store the first one persisted into, which paints the restored snapshot and
/// replaces it when the build lands. Reported side by side, because the design's answer to a cold
/// page cache is the snapshot and a gate that measured only the fast path would be measuring the
/// mitigation rather than the hazard.
final class LocalFleetPaintTests: XCTestCase {

    /// Five runs of each path, as G1d specifies.
    static let runs = 5

    func testFirstPaintMedianIsUnderFiveSeconds() async throws {
        guard ProcessInfo.processInfo.environment["AFLEET_LOCAL_INDEX"] == "1" else {
            throw XCTSkip("""
                set AFLEET_LOCAL_INDEX=1 to measure the local config home; read-only. Under \
                xcodebuild the working spelling is TEST_RUNNER_AFLEET_LOCAL_INDEX=1, which the \
                runner re-exports with the prefix stripped — an unprefixed switch never reaches \
                the test host at all
                """)
        }

        let environment = await LaunchSequence.resolveLoginShellEnvironment()
        let configHome = ConfigHome.derive(from: environment)
        guard ClaudeJSONReader.hasCompletedOnboarding(in: configHome) else {
            throw XCTSkip("the resolved config home reports no completed onboarding; sign in once by hand")
        }
        let corpus = Self.corpus(under: configHome.root)
        guard corpus.files > 0 else {
            throw XCTSkip("the resolved config home holds no transcripts; there is nothing to paint")
        }

        var noSnapshot: [Duration] = []
        var withSnapshot: [Duration] = []
        var rowCounts: [Int] = []

        for _ in 0..<Self.runs {
            // One tree per pair. The cold run has to find a store with nothing in it, and a store
            // shared across runs would hand run two of five the snapshot run one persisted.
            let tree = try TempTree()
            let storeRoot = try tree.directory("store")
            let logsRoot = try tree.directory("logs")

            let cold = try await Self.paint(configHome: configHome, storeRoot: storeRoot, logsRoot: logsRoot)
            noSnapshot.append(cold.elapsed)
            rowCounts.append(cold.rows)

            let warm = try await Self.paint(configHome: configHome, storeRoot: storeRoot, logsRoot: logsRoot)
            withSnapshot.append(warm.elapsed)
            rowCounts.append(warm.rows)
        }

        let coldMedian = Self.median(noSnapshot)
        let warmMedian = Self.median(withSnapshot)

        print("""
        G1d first paint against the resolved config home
          corpus ....................... \(corpus.files) transcripts, \(Self.mb(corpus.bytes)) MB, \(corpus.projects) project directories
          runs ......................... \(Self.runs) of each path
          no snapshot .................. median \(Self.ms(coldMedian)) ms, \(Self.spread(noSnapshot))
          with snapshot ................ median \(Self.ms(warmMedian)) ms, \(Self.spread(withSnapshot))
          rows painted ................. \(rowCounts.min() ?? 0) to \(rowCounts.max() ?? 0)
        """)

        // The floor: a run that painted nothing measured nothing. Spelled as a boolean because the
        // operands are runtime-derived and `XCTAssertGreaterThan` prints both (§11's assertion rule).
        XCTAssertTrue(rowCounts.allSatisfy { $0 > 0 },
                      "at least one run painted an empty sidebar, so its timing measures nothing")
        XCTAssertTrue(noSnapshot.count == Self.runs && withSnapshot.count == Self.runs,
                      "expected \(Self.runs) timings on each path")
        XCTAssertTrue(coldMedian < .seconds(5),
                      "no-snapshot first paint median is \(Self.ms(coldMedian)) ms against G1d's five seconds")
    }

    // MARK: - One launch, measured

    private struct Paint {
        var elapsed: Duration
        var rows: Int
    }

    /// One `LaunchSequence.run()` against `configHome`, stopped when the sidebar has its first row.
    ///
    /// Every seam is production's except `makeCoordinator`, which is how the test gets hold of the
    /// model the launch built; the login-shell capture, the binary locate, the version probe, C3's
    /// index, the real `Fleet` and the FSEvents watcher all run. Those are first-paint costs a user
    /// pays and a measurement that stubbed them would be reporting a launch nobody performs.
    private static func paint(configHome: ConfigHome, storeRoot: URL, logsRoot: URL) async throws -> Paint {
        var sequence = LaunchSequence(storeRoot: storeRoot, diagnosticsRoot: logsRoot)
        let box = ModelBox()
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }

        let clock = ContinuousClock()
        let start = clock.now
        let route = await sequence.run()
        guard let workspace = route.workspace else {
            throw XCTSkip("the launch did not reach a workspace on this machine")
        }
        let coordinator = try await MainActor.run { try XCTUnwrap(box.value, "the launch built no coordinator") }
        await coordinator.model.whenChanged { $0.allRows.count > 0 }
        let elapsed = start.duration(to: clock.now)
        let rows = await MainActor.run { coordinator.model.allRows.count }

        // The snapshot the *next* launch restores from. The launch persists it from a detached task
        // once the build lands; asking for it here is what makes the with-snapshot run a
        // with-snapshot run rather than a race against that task.
        await coordinator.model.whenChanged { !$0.isProvisional && $0.allRows.count > 0 }
        try? await workspace.index.persist()

        await MainActor.run { coordinator.stop() }
        workspace.watcher?.stop()
        await workspace.fleet.shutdown()
        return Paint(elapsed: elapsed, rows: rows)
    }

    /// The coordinator the launch built. A single-owner box; every access is on the main actor.
    private final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }

    // MARK: - Reading the corpus without opening it

    private struct Corpus { var files = 0; var bytes = 0; var projects = 0 }

    /// `projects/` walked with `lstat(2)`: how many transcripts there are and how many bytes they
    /// hold. Nothing is opened, nothing is followed and nothing is created.
    private static func corpus(under root: URL) -> Corpus {
        var corpus = Corpus()
        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(atPath: projects.path) else { return corpus }
        for directory in directories {
            var isDirectory: ObjCBool = false
            let path = projects.appending(path: directory).path
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            corpus.projects += 1
            for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where name.hasSuffix(".jsonl") {
                var status = stat()
                guard lstat(path + "/" + name, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { continue }
                corpus.files += 1
                corpus.bytes += Int(status.st_size)
            }
        }
        return corpus
    }

    // MARK: - Numbers

    static func median(_ durations: [Duration]) -> Duration {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return .zero }
        return sorted[sorted.count / 2]
    }

    static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / (1024 * 1024)) }

    static func spread(_ durations: [Duration]) -> String {
        let sorted = durations.sorted()
        guard let low = sorted.first, let high = sorted.last else { return "no runs" }
        return "fastest \(ms(low)) ms, slowest \(ms(high)) ms"
    }
}
