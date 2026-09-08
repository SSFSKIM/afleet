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
        let passedEmail = "halvard@example.invalid"
        // `setenv` is not thread-safe against a concurrent `getenv`, and `Process` reads the
        // environment when it spawns. This is safe only because XCTest runs the tests of one
        // class serially on one thread; if this suite ever moves to swift-testing, whose default
        // is parallel, this mutation has to become a child process's environment instead.
        setenv("GIT_AUTHOR_NAME", sentinel, 1)
        defer { unsetenv("GIT_AUTHOR_NAME") }
        XCTAssertEqual(ProcessInfo.processInfo.environment["GIT_AUTHOR_NAME"], sentinel,
                       "the sentinel was not set in the test process's environment")

        var environment = gitEnvironment(extra: ["GIT_AUTHOR_EMAIL": passedEmail])
        environment["GIT_AUTHOR_NAME"] = nil
        XCTAssertFalse(environment.keys.contains("GIT_AUTHOR_NAME"),
                       "the passed environment still carries the variable named GIT_AUTHOR_NAME")

        let output = try await ToolRunner().run(.git, arguments: ["var", "GIT_AUTHOR_IDENT"],
                                                cwd: tree.root, environment: environment,
                                                timeout: .seconds(30))
        // Two absence assertions alone can pass without the child having run at all: on a machine
        // whose account has no full name, git's fallback for a missing author name fails and it
        // exits 128 with an empty stdout, which contains no sentinel either. So the exit code and
        // one positive floor come first. The floor is the invented address that *is* in the passed
        // dictionary — leak-free, and it establishes in one assertion that the child ran and read
        // the environment it was handed.
        XCTAssertEqual(output.exitCode, 0, "git var GIT_AUTHOR_IDENT did not exit zero")
        XCTAssertTrue(output.stdoutText.contains(passedEmail),
                      "the identity git reported does not carry the address named GIT_AUTHOR_EMAIL in the passed environment, so the child did not read it")
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

    // MARK: - R6/F1 a child that floods the pipe cannot starve the timeout

    /// The timeout, the `SIGKILL` escalation and the settlement all run on the *same* serial queue
    /// as the pipe drains. A drain that keeps reading while data keeps arriving therefore owns that
    /// queue for as long as the child keeps writing, and while it does, none of the three can run:
    /// the budget passes unobserved, nothing signals the child, and the accumulated output grows
    /// without a bound. A tool that produces continuously — or an inherited helper holding the
    /// pipe — is enough, and `git` has both (a hook streaming progress, a pager, a credential
    /// helper).
    ///
    /// `/bin/dd` from `/dev/zero` is that producer in its plainest form, and *finite* on purpose:
    /// an endless one would hang this test rather than fail it. It offers 1 GiB as fast as the
    /// reader will take them, far more than the budget can consume, so a child that ran to
    /// completion here would be a child the runner never signalled.
    ///
    /// **What this test does not do**, and the reason `PipeDrain` is tested directly below. It
    /// passes with the drain unbounded too. Measured over five producer shapes — one `dd` at 64 KiB,
    /// 1 MiB and 4 MiB blocks, and four and eight of them at once — the timeout fired within 13 ms
    /// of its deadline every time, because this machine's drain consumes about 3 GB/s and no
    /// user-space producer keeps a 64 KiB pipe fed at that rate: the loop reaches `EAGAIN` between
    /// events and hands the queue back by accident rather than by design. So this is a floor —
    /// a flooding child is still killed — and not the discriminator for R6/F1.
    ///
    /// Byte counts, never bytes: nothing here prints a path or a payload (§6.3, §11).
    func testAChildFloodingItsPipeIsStillTimedOutAndKilled() async throws {
        let blockSize = 65_536, blocks = 16_384         // 1 GiB
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await ToolRunner().run(executable: URL(filePath: "/bin/dd"),
                                                arguments: ["if=/dev/zero", "bs=\(blockSize)",
                                                            "count=\(blocks)"],
                                                cwd: tree.root, environment: [:],
                                                timeout: .milliseconds(50))
        let elapsed = clock.now - started
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        XCTAssertTrue(output.timedOut,
                      "a child that flooded its pipe past the budget was not reported as timed out")
        XCTAssertTrue(elapsedMilliseconds < 5_000,
                      "the call did not settle inside the budget plus grace; it took \(elapsedMilliseconds) ms")
        XCTAssertTrue(output.stdout.count < blockSize * blocks,
                      "the whole 1 GiB arrived, so the child ran to completion instead of being killed at its budget")
    }

    // MARK: - R6/F1 one pass over a descriptor is bounded

    /// The property the runner actually depends on: **one readable event does a bounded amount of
    /// work**. The timeout, the `SIGKILL` escalation and the settlement share one serial queue with
    /// the drains, so a pass that reads while data keeps arriving is time in which none of them can
    /// run, and the accumulated output grows with nothing to stop it.
    ///
    /// Demonstrated against a descriptor that *always* has more to give rather than against a
    /// flooding child, and that is the point: a regular file never says `EAGAIN`, so the unbounded
    /// loop's only exit is end-of-file. No producer, no scheduling race, and the same read loop.
    func testOneDrainPassStopsAtItsBoundOnADescriptorThatAlwaysHasMore() throws {
        let available = 8 * 1024 * 1024
        let fd = try openScratchFile(ofSize: available)
        defer { close(fd) }

        var taken = 0
        let outcome = PipeDrain.pass(fd) { taken += $0.count }

        XCTAssertEqual(outcome, .open, "a pass that stopped at its bound reported the descriptor closed")
        XCTAssertTrue(taken > 0, "the pass read nothing at all")
        XCTAssertTrue(taken <= PipeDrain.bytesPerPass,
                      "one pass took \(taken) bytes from a descriptor holding \(available); it does not yield the queue between passes")
    }

    /// And the bound loses nothing: passes repeated until the descriptor reports itself closed
    /// deliver every byte. A bound that dropped the tail would be a runner that returns a truncated
    /// `git` listing under load, which is worse than the defect it fixes.
    func testRepeatedDrainPassesDeliverEveryByteAndThenReportTheDescriptorClosed() throws {
        let available = 8 * 1024 * 1024
        let fd = try openScratchFile(ofSize: available)
        defer { close(fd) }

        var taken = 0, passes = 0
        var outcome = PipeDrain.Outcome.open
        while outcome == .open, passes < 1_000 {
            outcome = PipeDrain.pass(fd) { taken += $0.count }
            passes += 1
        }

        XCTAssertEqual(outcome, .closed, "the descriptor was never reported closed")
        XCTAssertEqual(taken, available, "the passes together delivered a different number of bytes than the descriptor held")
        XCTAssertTrue(passes >= available / PipeDrain.bytesPerPass,
                      "\(passes) pass(es) covered \(available) bytes, so a pass is not bounded")
    }

    /// The two other outcomes, which the bound must not disturb: a pipe with nothing in it right
    /// now is *open* — the reader comes back when the source fires again — while a pipe whose
    /// writer is gone is *closed*, which is what cancels the source and closes the descriptor.
    func testADrainPassReadsAnEmptyPipeAsOpenAndAWriterlessOneAsClosed() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }

        var taken = 0
        XCTAssertEqual(PipeDrain.pass(fd) { taken += $0.count }, .open,
                       "a pipe that is merely empty was reported closed")
        XCTAssertEqual(taken, 0, "a pass over an empty pipe appended bytes")

        try pipe.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(PipeDrain.pass(fd) { taken += $0.count }, .closed,
                       "a pipe whose only writer has gone was not reported closed")
        XCTAssertEqual(taken, 5, "the writer's last bytes did not arrive with the end of the pipe")
    }

    /// A file of `size` zero bytes inside the scratch tree, opened for reading. The descriptor is
    /// returned rather than the path: nothing in this suite prints one (§6.3, §11).
    private func openScratchFile(ofSize size: Int) throws -> Int32 {
        let url = tree.root.appending(path: "readable-\(UUID().uuidString)")
        try Data(count: size).write(to: url, options: .atomic)
        let fd = open(url.path(percentEncoded: false), O_RDONLY)
        XCTAssertTrue(fd >= 0, "the scratch file could not be opened for reading")
        return fd
    }

    /// The integration half of the bound, and the property a bounded drain could plausibly break:
    /// a child whose output is many times one pass still arrives **whole**. The re-arm is what
    /// carries it — the readable event fires again while the descriptor still holds data — and if
    /// it did not, this is where a `git` listing would come back truncated.
    func testAChildsOutputArrivesWholeWhenItIsManyPassesLong() async throws {
        let blockSize = 65_536, blocks = 128            // 8 MiB, eight passes' worth
        let output = try await ToolRunner().run(executable: URL(filePath: "/bin/dd"),
                                                arguments: ["if=/dev/zero", "bs=\(blockSize)",
                                                            "count=\(blocks)"],
                                                cwd: tree.root, environment: [:],
                                                timeout: .seconds(30))
        XCTAssertEqual(output.exitCode, 0, "the producer did not exit zero")
        XCTAssertFalse(output.timedOut, "a producer well inside its budget was reported as timed out")
        XCTAssertEqual(output.stdout.count, blockSize * blocks,
                       "the drain delivered a different number of bytes than the child wrote")
    }

    // MARK: - G2.6 a non-zero exit is data, not an exception

    func testANonZeroExitIsReturnedRatherThanThrown() async throws {
        let fixture = try await GitFixture(tree)
        _ = try await fixture.commit(message: "root commit", files: ["a.txt": "one\n"])
        let output = try await ToolRunner().run(.git,
                                                arguments: ["rev-parse", "--verify", "nonexistent-ref"],
                                                cwd: fixture.root, environment: fixture.environment,
                                                timeout: .seconds(30))
        // The exact code, not merely "not zero": `-1` is the runner's own sentinel for a child it
        // settled without observing an exit, and a not-zero assertion is satisfied by exactly the
        // observation defect this runner exists to avoid. `git rev-parse --verify` on a ref that
        // does not resolve exits 128 (git 2.55.0, measured).
        XCTAssertEqual(output.exitCode, 128,
                       "git rev-parse --verify on a missing ref did not exit with git's own 128")
        XCTAssertFalse(output.timedOut, "the failing command was reported as timed out")
        XCTAssertFalse(output.stderrTail.isEmpty, "git said nothing on stderr about the missing ref")
    }

    // MARK: - R1/W1 a spawn that fails releases the descriptors it opened

    /// Foundation's `Process.run()` does not close the pipes it was handed when the spawn fails,
    /// and the termination handler installed at construction closes a `ToolJob -> process ->
    /// handler -> ToolJob` cycle that nothing else breaks. Both together are four descriptors and
    /// one job per failed call — and this path is not exotic: a panel polling `git` in a directory
    /// the user has deleted takes it on every refresh.
    ///
    /// Descriptors are counted, never named: the assertion reports a count and no path (§6.3, §11).
    func testAFailedSpawnDoesNotLeakDescriptors() async throws {
        let missing = tree.root.appending(path: "no-such-executable")
        // One failure before the baseline, so any one-time allocation on the failure path is
        // already charged and does not read as a leak.
        await expectSpawnFailure(executable: missing)
        let before = Self.openDescriptorCount()
        for _ in 0..<20 { await expectSpawnFailure(executable: missing) }
        let leaked = Self.openDescriptorCount() - before
        XCTAssertTrue(leaked <= 4,
                      "20 failed spawns left \(leaked) descriptors open; the failure path does not close the pipes")
    }

    private func expectSpawnFailure(executable: URL) async {
        do {
            _ = try await ToolRunner().run(executable: executable, arguments: [], cwd: tree.root,
                                           environment: [:], timeout: .seconds(5))
            XCTFail("spawning a path that holds no executable did not throw")
        } catch let error as ToolError {
            guard case .spawnFailed = error else {
                return XCTFail("a failed spawn threw something other than .spawnFailed")
            }
        } catch {
            XCTFail("a failed spawn threw an error that is not a ToolError")
        }
    }

    /// How many descriptors this process holds open right now, from `/dev/fd`, which the kernel
    /// synthesises per process. Not `getdtablesize`, which reports the limit rather than the use.
    private static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    // MARK: - R1/W3 settlement is the child's exit, and the last write is not lost

    /// A grandchild that inherited stdout and outlives its parent — a pager, a credential helper,
    /// a hook that backgrounds something — holds the write end of the pipe open after the child
    /// itself is gone. `/bin/sh -c 'sleep 5 & echo done'` is that in miniature: measured on this
    /// machine the child exits at ~0.00 s while end-of-file on stdout arrives at ~5.01 s, five
    /// seconds apart.
    ///
    /// A runner that keyed settlement to end-of-file rather than to the exit returns five seconds
    /// late, and this test fails it: mutated that way, the call took 5,010 ms (ledger, R1).
    ///
    /// It does *not* discriminate the other half of the exit path, the final non-blocking pass over
    /// each pipe, and nothing here claims it does. With `drainRemaining()` emptied this test still
    /// passes, and so does every construction tried against it — a delayed write, a write before
    /// the delay, a write landing with the exit. The reason is structural rather than incidental:
    /// the readable event goes from the kernel straight to this queue, while the exit travels
    /// through Foundation's own reaper before it is posted here, so the read is always enqueued
    /// first and the final pass finds the pipe already empty. The pass is defence for the case
    /// where that ordering does not hold — a loaded queue, another platform — and its triggering
    /// condition is not reachable from a black-box test. Recorded as tech debt rather than left as
    /// an unfalsifiable claim.
    func testAGrandchildHoldingStdoutOpenDoesNotDelaySettlement() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await ToolRunner().run(executable: URL(filePath: "/bin/sh"),
                                                arguments: ["-c", "sleep 5 & echo done"],
                                                cwd: tree.root, environment: [:],
                                                timeout: .seconds(30))
        let elapsed = clock.now - started
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        XCTAssertEqual(output.exitCode, 0, "the shell did not exit zero")
        XCTAssertFalse(output.timedOut, "a child that exited immediately was reported as timed out")
        XCTAssertEqual(output.stdoutText, "done\n", "the child's write is missing from the result")
        XCTAssertTrue(elapsedMilliseconds < 1_000,
                      "the call took \(elapsedMilliseconds) ms for a child that exits at once, so settlement is waiting on end-of-file rather than on the exit")
    }

    // MARK: - R1/M4 a directory named like the tool is not the tool

    /// Every directory carries the execute bit, so `isExecutableFile(atPath:)` is true for a
    /// directory named `git` — and a `PATH` component holding one would resolve, then fail at
    /// spawn with `.spawnFailed` where the honest answer is that the passed `PATH` holds no git.
    func testADirectoryNamedLikeTheToolIsNotResolved() async throws {
        let component = try tree.directory("path-component")
        _ = try tree.directory("path-component/git")
        let environment = ["PATH": component.path(percentEncoded: false)]
        // A boolean, not `XCTAssertNil`: the operand a failing `XCTAssertNil` prints is the
        // resolved candidate, which is a temporary path (§6.3, §11).
        XCTAssertTrue(ToolRunner.resolve(.git, in: environment) == nil,
                      "resolve accepted a directory named git as an executable")
        do {
            _ = try await ToolRunner().run(.git, arguments: ["--version"], cwd: tree.root,
                                           environment: environment, timeout: .seconds(5))
            XCTFail("running git on a PATH whose only git is a directory did not throw")
        } catch let error as ToolError {
            XCTAssertEqual(error, .binaryNotFound(tool: .git), "the wrong ToolError was thrown")
        }
    }

    /// The other side of the same check, and the trap in it: `URLResourceKey.isRegularFileKey` is
    /// lstat-shaped, so a symlink to a regular file reads as *not* regular. A Homebrew `git` is
    /// exactly that symlink, so a regular-file check on the unresolved candidate would refuse the
    /// machine's own git and take every fixture test in this suite with it.
    func testASymlinkToAnExecutableStillResolves() async throws {
        let component = try tree.directory("linked-path-component")
        let real = try tree.file("real-tool/gh", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: real.path(percentEncoded: false))
        try FileManager.default.createSymbolicLink(at: component.appending(path: "gh"),
                                                   withDestinationURL: real)
        let environment = ["PATH": component.path(percentEncoded: false)]
        XCTAssertTrue(ToolRunner.resolve(.gh, in: environment) != nil,
                      "resolve refused a symlink pointing at an executable regular file")
    }
}
