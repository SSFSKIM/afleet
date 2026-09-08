import Foundation
import XCTest
@testable import SourceControlCore

/// Gate G2: the runner passes the resolved environment and the cwd it was given, times out on a
/// child that blocks, surfaces a missing binary as a typed error, and treats a non-zero exit as
/// data rather than as a failure.
///
/// Assertion style throughout, and not a matter of taste: `XCTAssertEqual` prints both operands,
/// and every path in this suite is under the system temporary directory, which on macOS contains
/// the machine account's hash (§6.3, §11). So comparisons over runtime paths are made as
/// booleans with a written message, and no environment is ever dumped into a message — the
/// environment is asserted by variable *names*.
final class ToolRunnerTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    /// The environment a `git` invocation in this suite runs with. Exhaustive by construction:
    /// the runner passes exactly this dictionary, so anything absent here is absent from the
    /// child. `PATH` is the test process's because the machine's own `git` is the binary under
    /// test (D2: resolution scans the passed `PATH` and nothing else).
    private func gitEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": tree.root.path(percentEncoded: false),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    // MARK: - G2.1 the runner runs the binary the passed PATH resolves

    func testGitVersionRunsAndExitsZero() async throws {
        let output = try await ToolRunner().run(.git, arguments: ["--version"], cwd: tree.root,
                                                environment: gitEnvironment(), timeout: .seconds(30))
        XCTAssertEqual(output.exitCode, 0, "git --version did not exit zero")
        XCTAssertFalse(output.timedOut, "git --version reported a timeout")
        XCTAssertTrue(output.stdoutText.hasPrefix("git version"),
                      "stdout did not begin with the version banner")
    }

    // MARK: - G2.2 the cwd is the one the caller gave

    func testTheRunnerRunsInTheDirectoryItWasGiven() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "root commit", files: ["a.txt": "one\n"])
        let subdirectory = fixture.root.appending(path: "nested/deeper")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let output = try await ToolRunner().run(.git, arguments: ["rev-parse", "--show-toplevel"],
                                                cwd: subdirectory, environment: fixture.environment,
                                                timeout: .seconds(30))
        XCTAssertEqual(output.exitCode, 0, "git rev-parse --show-toplevel did not exit zero")
        let reported = URL(filePath: output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().standardizedFileURL
        let expected = fixture.root.resolvingSymlinksInPath().standardizedFileURL
        // A boolean, not `XCTAssertEqual`: both operands would be printed on failure and both are
        // temporary paths.
        XCTAssertTrue(reported.pathComponents == expected.pathComponents,
                      "git reported a different toplevel than the fixture's own root")
    }

    // MARK: - G2.3 the environment is exactly the one the caller gave, asserted by names

    /// The passed dictionary reaches the child: an invented author identity in it is the identity
    /// `git var GIT_AUTHOR_IDENT` reports.
    func testThePassedEnvironmentReachesTheChild() async throws {
        let invented = "Marisol Quintrell"
        let environment = gitEnvironment(extra: [
            "GIT_AUTHOR_NAME": invented,
            "GIT_AUTHOR_EMAIL": "marisol.quintrell@example.invalid",
        ])
        let output = try await ToolRunner().run(.git, arguments: ["var", "GIT_AUTHOR_IDENT"],
                                                cwd: tree.root, environment: environment,
                                                timeout: .seconds(30))
        XCTAssertEqual(output.exitCode, 0, "git var GIT_AUTHOR_IDENT did not exit zero")
        XCTAssertTrue(output.stdoutText.contains(invented),
                      "the author identity git reported is not the one named GIT_AUTHOR_NAME in the passed environment")
    }

    /// And nothing else reaches it. `GIT_AUTHOR_NAME` is set in the *test process's* own
    /// environment to a sentinel and left out of the passed dictionary; a runner that merged in
    /// its parent's environment — the mutation this test exists to kill — would have git report
    /// the sentinel. Asserted by name and by absence; the output itself is never printed, because
    /// git's fallback for a missing author name is the machine account's full name.
    func testTheTestProcessEnvironmentDoesNotReachTheChild() async throws {
        let sentinel = "Halvard Ossenbrink"
        setenv("GIT_AUTHOR_NAME", sentinel, 1)
        defer { unsetenv("GIT_AUTHOR_NAME") }
        XCTAssertEqual(ProcessInfo.processInfo.environment["GIT_AUTHOR_NAME"], sentinel,
                       "the sentinel was not set in the test process's environment")

        var environment = gitEnvironment(extra: ["GIT_AUTHOR_EMAIL": "halvard@example.invalid"])
        environment["GIT_AUTHOR_NAME"] = nil
        XCTAssertFalse(environment.keys.contains("GIT_AUTHOR_NAME"),
                       "the passed environment still carries the variable named GIT_AUTHOR_NAME")

        let output = try await ToolRunner().run(.git, arguments: ["var", "GIT_AUTHOR_IDENT"],
                                                cwd: tree.root, environment: environment,
                                                timeout: .seconds(30))
        XCTAssertFalse(output.stdoutText.contains(sentinel),
                       "git reported the sentinel author name, so the child inherited the test process's environment")
        XCTAssertFalse(output.stderrTail.contains(sentinel),
                       "the sentinel author name appeared on stderr, so the child inherited the test process's environment")
    }

    // MARK: - G2.4 a missing binary is a typed error

    func testAMissingBinaryIsBinaryNotFound() async throws {
        let empty = try tree.directory("no-binaries-here")
        let environment = ["PATH": empty.path(percentEncoded: false)]
        XCTAssertNil(ToolRunner.resolve(.gh, in: environment)?.lastPathComponent,
                     "resolve found a gh on a PATH holding no binaries")
        do {
            _ = try await ToolRunner().run(.gh, arguments: ["--version"], cwd: tree.root,
                                           environment: environment, timeout: .seconds(5))
            XCTFail("running gh on a PATH holding no gh did not throw")
        } catch let error as ToolError {
            // Safe to compare: the case carries a tool name and no path.
            XCTAssertEqual(error, .binaryNotFound(tool: .gh), "the wrong ToolError was thrown")
        }
    }

    // MARK: - G2.5 the timeout, against a child that provably blocks

    /// The timeout is a property of the process layer, not of `git`, so this reaches the internal
    /// executable-taking form and blocks on `/bin/sleep`. The duration is an unusual number so
    /// that the liveness check afterwards names this child and no other sleeping process on the
    /// machine.
    func testAChildThatBlocksIsTimedOutAndKilled() async throws {
        let marker = "31.415926"
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await ToolRunner().run(executable: URL(filePath: "/bin/sleep"),
                                                arguments: [marker], cwd: tree.root,
                                                environment: [:], timeout: .milliseconds(300))
        let elapsed = clock.now - started

        XCTAssertTrue(output.timedOut, "a child that blocked past its budget was not reported as timed out")
        // The budget plus the runner's two 500 ms graces plus a wide margin for a loaded machine.
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        XCTAssertTrue(elapsedMilliseconds >= 300,
                      "the call returned before the budget could have expired")
        XCTAssertTrue(elapsedMilliseconds < 5_000,
                      "the call did not settle inside the budget plus grace; it took \(elapsedMilliseconds) ms")

        // The child is gone: `pgrep -f` over the marker duration matches nothing. Exit 1 is
        // pgrep's documented "no process matched".
        let survivors = try await ToolRunner().run(executable: URL(filePath: "/usr/bin/pgrep"),
                                                   arguments: ["-f", "sleep \(marker)"], cwd: tree.root,
                                                   environment: [:], timeout: .seconds(10))
        XCTAssertEqual(survivors.exitCode, 1, "pgrep still matched the timed-out child after the runner settled")
    }

    // MARK: - G2.6 a non-zero exit is data, not an exception

    func testANonZeroExitIsReturnedRatherThanThrown() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "root commit", files: ["a.txt": "one\n"])
        let output = try await ToolRunner().run(.git,
                                                arguments: ["rev-parse", "--verify", "nonexistent-ref"],
                                                cwd: fixture.root, environment: fixture.environment,
                                                timeout: .seconds(30))
        XCTAssertNotEqual(output.exitCode, 0, "git verified a ref that does not exist")
        XCTAssertFalse(output.timedOut, "the failing command was reported as timed out")
        XCTAssertFalse(output.stderrTail.isEmpty, "git said nothing on stderr about the missing ref")
    }
}
