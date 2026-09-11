import AfleetCore
import FleetKit
import Foundation
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The two mappings of spec Design §3, on their own. They are pure, so they are asserted without
/// a pty: everything a pane does with them is downstream of these two answers being right.
final class PaneSpawnTests: XCTestCase {
    private let size = TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480)
    private let terminal = TerminalDescription(
        term: "xterm-ghostty",
        terminfoDirectory: URL(filePath: "/invented/renderer-database")
    )

    private func request(purpose: PanePurpose) -> PaneRequest {
        PaneRequest(
            executable: URL(filePath: "/invented/bin/claude"),
            arguments: ["--resume", "afleet-invented-session"],
            cwd: URL(filePath: "/invented/workspace/jade"),
            environment: ["AFLEET_PANE_JADE": "carried-value", "PATH": "/usr/bin:/bin"],
            purpose: purpose
        )
    }

    func testSpawnRequestCarriesEveryRequestFieldUnchanged() {
        let request = request(purpose: .command)

        let spawn = PaneSpawn.spawnRequest(for: request, size: size, terminal: terminal)

        XCTAssertEqual(spawn.executable, request.executable, "executable was not passed through")
        XCTAssertEqual(spawn.arguments, request.arguments, "arguments were not passed through")
        XCTAssertEqual(spawn.cwd, request.cwd, "cwd was not passed through")
        // X11: C4 composed this environment; the panel merges nothing into it.
        XCTAssertEqual(
            Set(spawn.environment.keys),
            Set(request.environment.keys),
            "the panel changed the set of names C4 composed"
        )
        // §6.3: the comparison is total but the message is not the environment. `XCTAssertEqual`
        // would print both dictionaries on failure, which is the one thing an environment
        // assertion may never do.
        XCTAssertTrue(
            spawn.environment == request.environment,
            "rewritten=\(Set(request.environment.keys).filter { spawn.environment[$0] != request.environment[$0] }.sorted().joined(separator: ","))"
        )
        XCTAssertEqual(spawn.size, size, "the surface's grid was not the spawn size")
        XCTAssertEqual(spawn.terminal, terminal, "the surface's terminal description was not used")
    }

    // One assertion per purpose, and not one loop over a table: a mapping that answered `.report`
    // for everything has to fail on a named case rather than on a count.

    func testHatchPaneTakesTheReportPolicy() {
        let spawn = PaneSpawn.spawnRequest(
            for: request(purpose: .hatch(SessionID())),
            size: size,
            terminal: terminal
        )
        XCTAssertEqual(spawn.stopPolicy, .report, "hatch=wrong-stop-policy")
    }

    /// §6.11's trust review takes the hatch's policy: it is the user's own interactive `claude`, so a
    /// Ctrl+Z is a job they suspended on purpose and the pane offers *Continue* rather than hanging
    /// the child up.
    func testTrustReviewPaneTakesTheReportPolicy() {
        let spawn = PaneSpawn.spawnRequest(
            for: request(purpose: .trustReview(SessionID())),
            size: size,
            terminal: terminal
        )
        XCTAssertEqual(spawn.stopPolicy, .report, "trustReview=wrong-stop-policy")
    }

    func testAttachPaneTakesTheDetachPolicy() {
        let spawn = PaneSpawn.spawnRequest(
            for: request(purpose: .attach(JobShort(rawValue: "jd7"))),
            size: size,
            terminal: terminal
        )
        XCTAssertEqual(spawn.stopPolicy, .detach, "attach=wrong-stop-policy")
    }

    func testLogsPaneTakesTheReportPolicy() {
        let spawn = PaneSpawn.spawnRequest(
            for: request(purpose: .logs(JobShort(rawValue: "jd7"))),
            size: size,
            terminal: terminal
        )
        XCTAssertEqual(spawn.stopPolicy, .report, "logs=wrong-stop-policy")
    }

    func testShellPaneTakesTheReportPolicy() {
        let spawn = PaneSpawn.spawnRequest(for: request(purpose: .shell), size: size, terminal: terminal)
        XCTAssertEqual(spawn.stopPolicy, .report, "shell=wrong-stop-policy")
    }

    func testCommandPaneTakesTheReportPolicy() {
        let spawn = PaneSpawn.spawnRequest(for: request(purpose: .command), size: size, terminal: terminal)
        XCTAssertEqual(spawn.stopPolicy, .report, "command=wrong-stop-policy")
    }

    /// The request is echoed by value, `id` included. This is the only assertion that catches a
    /// panel that re-mints a `UUID` on the way out: C4 matches an exit by `request.id` and
    /// discards one it is not waiting on *silently*, so a fresh id is a hatch whose channel stays
    /// released for ever and never a visible failure.
    func testExitEchoesTheRequestIncludingItsIdentifier() {
        let request = request(purpose: .hatch(SessionID()))
        let observedAt = Date(timeIntervalSince1970: 1_757_000_000)

        let exit = PaneSpawn.exit(of: request, termination: .exited(code: 3), at: observedAt)

        XCTAssertTrue(exit.request == request, "request=not-echoed-by-value")
        XCTAssertTrue(exit.request.id == request.id, "id=re-minted")
        XCTAssertEqual(exit.observedAt, observedAt, "the observation moment was not carried")
    }

    func testExitCarriesTheExitCodeOfAnExitedChild() {
        let request = request(purpose: .command)
        let exit = PaneSpawn.exit(of: request, termination: .exited(code: 3), at: Date())
        XCTAssertEqual(exit.code, 3, "exited=wrong-pane-exit-code")
    }

    func testExitCarriesTheLossyStatusOfASignalledChild() {
        let request = request(purpose: .command)
        let exit = PaneSpawn.exit(of: request, termination: .signalled(signal: 9), at: Date())
        XCTAssertEqual(exit.code, 128 + 9, "signalled=wrong-pane-exit-code")
    }
}
