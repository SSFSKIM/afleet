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

        // Either bound, and since R7/1b ordinarily the cap: 64 MiB arrives well inside a 50 ms
        // budget on this machine, so the flood now reaches the retained-output cap before the
        // timer fires and the runner ends it for that instead. The property under test is
        // unchanged and is neither of the two names — it is that the queue was **not starved**, so
        // that a bound could fire at all. The budget's own discriminator is the sleeping child
        // above, which produces nothing and can only be ended by the timer.
        XCTAssertTrue(output.timedOut || output.outputLimitBytes != nil,
                      "a child that flooded its pipe past the budget was neither timed out nor ended at the cap")
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

    // MARK: - R7/1b the retained output is bounded, not merely the drain

    /// `PipeDrain.bytesPerPass` bounds one *pass*; it does not bound what the pass keeps. The two
    /// are different properties and only the first was held: the pass returns the queue to the
    /// timer every mebibyte — which is what keeps a flooding child killable — while the
    /// accumulated `Data` grows for as long as the child writes. A `git cat-file blob` on a large
    /// tracked file is the ordinary way there, and it exhausts memory long before the budget
    /// matters, so the timeout is not the bound.
    ///
    /// The cap is injected here rather than met at its 64 MiB default, so the producer runs in a
    /// moment. Byte counts, never bytes (§6.3, §11).
    func testAChildThatOutrunsTheRetainedOutputCapIsEndedByIt() async throws {
        let limit = 1024 * 1024
        let offered = 64 * 1024 * 1024
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await ToolRunner(outputLimitBytes: limit)
            .run(executable: URL(filePath: "/bin/dd"),
                 arguments: ["if=/dev/zero", "bs=1048576", "count=64"],
                 cwd: tree.root, environment: [:], timeout: .seconds(30))
        let elapsed = clock.now - started
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        XCTAssertEqual(output.outputLimitBytes, limit,
                       "a child that offered \(offered) bytes against a cap of \(limit) did not report the cap")
        XCTAssertTrue(output.stdout.count <= limit,
                      "the runner retained \(output.stdout.count) bytes against a cap of \(limit)")
        XCTAssertTrue(elapsedMilliseconds < 10_000,
                      "the call took \(elapsedMilliseconds) ms, so the child was not ended at the cap")
        XCTAssertThrowsError(try output.requireCompleted(tool: .git, timeout: .seconds(30)),
                             "an output that reached the cap was reported as complete") { error in
            guard case ToolError.outputLimitExceeded(let tool, let limitBytes) = error else {
                return XCTFail("the cap produced an error other than .outputLimitExceeded")
            }
            XCTAssertEqual(tool, .git)
            XCTAssertEqual(limitBytes, limit, "the error named a different cap than the runner's")
        }
    }

    /// And the cap does not disturb an ordinary read: a child well under it is untouched, so the
    /// test above is a refusal of something rather than of everything.
    func testAChildWellUnderTheCapIsUnaffectedByIt() async throws {
        let output = try await ToolRunner(outputLimitBytes: 1024 * 1024)
            .run(executable: URL(filePath: "/bin/dd"),
                 arguments: ["if=/dev/zero", "bs=65536", "count=4"],
                 cwd: tree.root, environment: [:], timeout: .seconds(30))
        XCTAssertNil(output.outputLimitBytes, "a child well under the cap reported reaching it")
        XCTAssertEqual(output.stdout.count, 4 * 65_536, "the drain delivered a different count")
        XCTAssertNoThrow(try output.requireCompleted(tool: .git, timeout: .seconds(30)))
    }

    // MARK: - R7/1c the timeout ends the process tree, not only the direct child

    /// `git` starts descendants — a pager, a credential helper, a hook that backgrounds something —
    /// and the escalation that follows a timeout reaches only the direct child's pid, so a
    /// descendant that does not stop for `SIGTERM` outlives the whole call.
    ///
    /// The child is that shape in miniature: it backgrounds a shell that ignores `SIGTERM` and
    /// sleeps, then `exec`s a sleeper of its own, so the direct child *is* the second sleeper and
    /// the deaf one is a grandchild in the same process group. The discriminator is deliberately
    /// the deaf grandchild and not merely a backgrounded one, because it is only there that the two
    /// runners differ: measured here, `Process.terminate()` signals the whole group — NSTask puts
    /// its child in a group of its own and documents `terminate()` as reaching "all of its
    /// subtasks" — so a grandchild that stops for `SIGTERM` dies either way. What no version of
    /// this reaches is the `SIGKILL` that follows, which is addressed to one pid and is skipped
    /// entirely once the direct child has been reaped.
    ///
    /// The duration is an unusual number so that the survivor check names this test's processes and
    /// nothing else on the machine.
    func testATimedOutChildsDeafDescendantIsKilledWithIt() async throws {
        let marker = "27.182818"
        let deafGrandchild = "/bin/sh -c 'trap \"\" TERM; /bin/sleep \(marker)'"
        let output = try await ToolRunner()
            .run(executable: URL(filePath: "/bin/sh"),
                 arguments: ["-c", "\(deafGrandchild) & exec /bin/sleep \(marker)"],
                 cwd: tree.root, environment: [:], timeout: .milliseconds(300))
        XCTAssertTrue(output.timedOut, "the child that blocked past its budget was not timed out")

        let survivors = try await survivorCount(matching: "sleep \(marker)", within: .seconds(2))
        XCTAssertEqual(survivors, 0,
                       "\(survivors) process(es) of the timed-out child's tree were still running two seconds after the runner settled")
    }

    // MARK: - R7/1d cancelling the awaiting task ends the child

    /// Without a cancellation handler the child, its descriptors and its accumulated output live
    /// on until it exits or the whole budget expires, however long ago the panel stopped wanting
    /// the answer — a refresh the user scrolled past, a channel that closed. Cancellation takes the
    /// same path a timeout takes, and the call reports it as `.cancelled` rather than as a result.
    func testCancellingTheAwaitingTaskEndsTheChildAndThrowsCancelled() async throws {
        let marker = "16.180339"
        // The cwd is lifted out of the test case before the task closes over it: `TempTree` is not
        // `Sendable` and a closure capturing `self` here is a data race the compiler refuses.
        let cwd = tree.root
        let running = Task {
            try await ToolRunner().run(executable: URL(filePath: "/bin/sleep"), arguments: [marker],
                                       cwd: cwd, environment: [:], timeout: .seconds(120))
        }
        try await waitUntilRunning(matching: "sleep \(marker)")

        let clock = ContinuousClock()
        let started = clock.now
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("a cancelled run returned a result instead of reporting the cancellation")
        } catch let error as ToolError {
            XCTAssertEqual(error, .cancelled(tool: .git), "the wrong ToolError was thrown")
        }
        let elapsed = clock.now - started
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        XCTAssertTrue(elapsedMilliseconds < 10_000,
                      "the cancelled call took \(elapsedMilliseconds) ms to return; it waited out the child")

        let survivors = try await survivorCount(matching: "sleep \(marker)", within: .seconds(2))
        XCTAssertEqual(survivors, 0,
                       "\(survivors) process(es) survived the cancelled call two seconds after it returned")
    }

    // MARK: - the final wave: a cancelled call starts nothing

    /// Cancellation was handled *around* the spawn and not before it, so a task cancelled before
    /// the call was ever entered — a panel refresh the user scrolled past while it queued — still
    /// launched the executable, ran whatever it starts, and then killed what it had just started.
    ///
    /// The call parks on a sleep first, which a cancelled task returns from at once, so the run
    /// below is entered by a task that is already cancelled rather than by one racing the cancel.
    ///
    /// **What is asserted, and why it is the elapsed time.** A child spawned and immediately
    /// signalled usually dies before it can do anything observable — the `SIGTERM` reaches it
    /// while the kernel is still `exec`ing it — so a marker file the child would write cannot
    /// discriminate on its own, and it is checked here only as the second half. What a spawn
    /// always costs is the **teardown**: a job with a child in it goes through `SIGTERM`, a grace,
    /// `SIGKILL` and a second grace before it settles, which is a second of wall clock. A call
    /// that started nothing has nothing to tear down and returns in milliseconds. The bound is
    /// generous against the second the escalation takes.
    ///
    /// What would have to be true for this to fail: the spawn happening before the state of the
    /// task is asked.
    func testAnAlreadyCancelledCallSpawnsNothing() async throws {
        let marker = tree.root.appending(path: "the-child-that-should-not-run").path(percentEncoded: false)
        let cwd = tree.root
        let call = Task {
            try? await Task.sleep(for: .seconds(3600))
            // The child ignores `SIGTERM` before it acts, so if it ever reaches its own first line
            // the marker is there to find.
            return try await ToolRunner().run(executable: URL(filePath: "/bin/sh"),
                                              arguments: ["-c", "trap '' TERM; /usr/bin/touch '\(marker)'"],
                                              cwd: cwd, environment: [:], timeout: .seconds(30))
        }
        let clock = ContinuousClock()
        let started = clock.now
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("an already-cancelled call returned a result")
        } catch let error as ToolError {
            guard case .cancelled(let tool) = error else {
                return XCTFail("an already-cancelled call threw something other than .cancelled")
            }
            XCTAssertEqual(tool, .git)
        }
        let elapsed = clock.now - started
        let elapsedMilliseconds = Int(elapsed.components.seconds) * 1_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        XCTAssertTrue(elapsedMilliseconds < 300,
                      "the cancelled call took \(elapsedMilliseconds) ms, which is a child being "
                      + "signalled and escalated rather than a call that started nothing")

        // And nothing the child would have done was done.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "an already-cancelled call spawned its child")
    }

    // MARK: - the final wave: the cause is whichever came first

    /// The timeout begins a termination and the child gets a grace period, and a child that floods
    /// *during* that grace reached the retained-output cap — which `requireCompleted` reports
    /// **before** the timeout. The call was then reported as an output overrun when what actually
    /// happened is that it outlived its budget, which is a different thing for a panel to say and
    /// a different thing for a user to do about.
    ///
    /// The child is that shape exactly: it sleeps past its budget, and its `SIGTERM` handler — a
    /// handler rather than an ignore, so that the disposition is not inherited by the sleep it is
    /// waiting on — floods stdout with far more than the injected cap.
    ///
    /// What would have to be true for this to fail: the cap being latched after a termination has
    /// begun.
    func testAChildThatFloodsAfterItsDeadlineIsReportedAsTimedOut() async throws {
        let budget = Duration.milliseconds(500)
        let limit = 1024
        let output = try await ToolRunner(outputLimitBytes: limit)
            .run(executable: URL(filePath: "/bin/sh"),
                 arguments: ["-c", "trap 'exec /bin/dd if=/dev/zero bs=65536 count=8 2>/dev/null' TERM;"
                             + " /bin/sleep 30"],
                 cwd: tree.root, environment: [:], timeout: budget)

        XCTAssertTrue(output.timedOut, "the child that outlived its budget was not timed out")
        XCTAssertNil(output.outputLimitBytes,
                     "a flood that arrived after the deadline was recorded as the cause")
        XCTAssertThrowsError(try output.requireCompleted(tool: .git, timeout: budget),
                             "a child that outlived its budget was reported as complete") { error in
            guard case ToolError.timedOut = error else {
                return XCTFail("the reported cause was not the timeout that came first")
            }
        }
    }

    // MARK: - C6.2's merge review: the escalation is owed to the group, not to the caller

    /// **A budget that expires inside the grace still kills the group.** `SIGTERM` ends the leader
    /// while a descendant that ignores it survives; the caller can then be answered — by the budget,
    /// which reaps an exited leader and settles — *before* the `SIGKILL` the termination owed the
    /// group is due. An escalation conditioned on `settled` skips it and leaves that descendant on
    /// the machine, having reported the command as stopped.
    ///
    /// The ordering is arranged rather than raced: the grace is four seconds and the budget two, so
    /// the settlement provably lands inside the escalation window. `timedOut` being false is the
    /// proof that the cancellation, not the budget, began the termination.
    func testABudgetExpiringInsideTheGraceStillKillsTheGroup() async throws {
        let work = try tree.directory("grace-work")
        let pidFile = work.appending(path: "descendant-pid")
        // `trap "" TERM` sets the disposition to *ignore*, which survives the `exec` that follows it,
        // so nothing short of `SIGKILL` ends this descendant. The leader keeps its own default
        // disposition and dies on the first signal, which is what separates the two facts.
        let job = ToolJob(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", "/bin/sh -c 'trap \"\" TERM; exec /bin/sleep 30' & "
                                      + "printf '%s' \"$!\" > '\(pidFile.path(percentEncoded: false))'; wait"],
                          cwd: work, environment: ["PATH": "/usr/bin:/bin"],
                          outputLimitBytes: ToolRunner.defaultOutputLimitBytes,
                          grace: .seconds(4))
        try job.start()
        let settlement = Settlement()
        job.finish(timeout: .seconds(2)) { output in Task { await settlement.mark(output) } }
        guard let descendant = try await recordedPID(in: pidFile, within: 20) else {
            job.cancel()
            return XCTFail("the command recorded no descendant to probe")
        }
        defer { _ = kill(descendant, SIGKILL) }

        // The termination begins here; its escalation is due four seconds later, and the budget
        // expires two seconds from now — inside it.
        job.cancel()

        guard let output = try await settled(settlement, within: 80) else {
            return XCTFail("the cancelled call had not settled 8 second(s) later")
        }
        XCTAssertFalse(output.timedOut,
                       "the budget expired before the cancellation, so this arm did not put the two in the order it tests")
        let ended = try await died(descendant, within: 80)
        XCTAssertTrue(ended,
                      "the call's descendant outlived the escalation the cancellation owed its group")
    }

    /// **A final drain that overruns the cap still ends the group.** A `git` that exits leaving a
    /// hook's descendant on its stdout is reaped by the exit handler, and the settlement that follows
    /// takes one last pass over the pipe. When *that* pass is the one that fills the cap, the call
    /// reports an output-limited stop — and a termination that refuses to begin because the call has
    /// settled, or refuses to signal because the leader has been reaped, reports a stop that never
    /// happened.
    ///
    /// The ordering is arranged rather than raced: `finish` is called only after the leader has
    /// exited and the descendant has written, so there is no drain in place before the last one and
    /// the whole capture happens inside settlement. `outputLimitBytes` being set is the proof the
    /// arrangement held.
    func testAFinalDrainOverrunStillEndsTheGroup() async throws {
        let work = try tree.directory("drain-work")
        let pidFile = work.appending(path: "descendant-pid")
        let cap = 4096
        let burst = 2 * cap
        // The leader exits at once; the descendant writes twice the cap into the inherited pipe and
        // then holds its write end open, ignoring `SIGTERM` throughout.
        let job = ToolJob(executable: URL(filePath: "/bin/sh"),
                          arguments: ["-c", "/bin/sh -c 'trap \"\" TERM; "
                                      + "/bin/dd if=/dev/zero bs=\(burst) count=1 2>/dev/null | /usr/bin/tr \"\\0\" a; "
                                      + "exec /bin/sleep 30' & "
                                      + "printf '%s' \"$!\" > '\(pidFile.path(percentEncoded: false))'; exit 0"],
                          cwd: work, environment: ["PATH": "/usr/bin:/bin"],
                          outputLimitBytes: cap)
        try job.start()
        guard let descendant = try await recordedPID(in: pidFile, within: 20) else {
            job.cancel()
            return XCTFail("the command recorded no descendant to probe")
        }
        defer { _ = kill(descendant, SIGKILL) }
        // The leader has exited and been reaped, and the burst is sitting in the pipe with nobody
        // draining it. Everything the call captures, it captures in the last pass.
        try await Task.sleep(for: .milliseconds(500))

        let settlement = Settlement()
        job.finish(timeout: .seconds(30)) { output in Task { await settlement.mark(output) } }

        guard let output = try await settled(settlement, within: 60) else {
            return XCTFail("the call had not settled 6 second(s) after its last drain")
        }
        XCTAssertEqual(output.outputLimitBytes, cap,
                       "the last pass did not overrun the cap, so this arm did not test the settlement it exists for")
        XCTAssertEqual(output.stdout.count, cap,
                       "the call retained \(output.stdout.count) byte(s) against a cap of \(cap)")
        let ended = try await died(descendant, within: 80)
        XCTAssertTrue(ended,
                      "the call reported an output-limited stop and left the command's descendant on the machine")
    }

    /// The pid the command wrote down, waited for a tenth of a second at a time. The pid itself is
    /// never printed.
    private func recordedPID(in file: URL, within attempts: Int) async throws -> pid_t? {
        for _ in 0..<attempts {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Whether `pid` is gone, polled a tenth of a second at a time.
    private func died(_ pid: pid_t, within attempts: Int) async throws -> Bool {
        for _ in 0..<attempts {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    /// What the job settled with, polled a tenth of a second at a time.
    private func settled(_ settlement: Settlement, within attempts: Int) async throws -> ToolOutput? {
        for _ in 0..<attempts {
            if let output = await settlement.output { return output }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await settlement.output
    }

    /// Blocks until `pattern` matches a running process, so that a cancellation lands on a child
    /// that exists. `pgrep` exits 1 when nothing matched, which is its documented "no match".
    private func waitUntilRunning(matching pattern: String,
                                  within limit: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if try await pgrepExitCode(pattern) == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the child never appeared; the test's premise did not hold")
    }

    /// 0 once nothing matches `pattern` any more, polled until `limit`; 1 while something still
    /// does. A count and never a listing: a process line would carry a temporary path (§6.3, §11).
    private func survivorCount(matching pattern: String, within limit: Duration) async throws -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if try await pgrepExitCode(pattern) == 1 { return 0 }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await pgrepExitCode(pattern) == 1 ? 0 : 1
    }

    private func pgrepExitCode(_ pattern: String) async throws -> Int32 {
        try await ToolRunner().run(executable: URL(filePath: "/usr/bin/pgrep"),
                                   arguments: ["-f", pattern], cwd: tree.root,
                                   environment: [:], timeout: .seconds(10)).exitCode
    }

}

/// What one `ToolJob` handed back, for a test that drives the job directly rather than through
/// `ToolRunner.run`.
private actor Settlement {
    private(set) var output: ToolOutput?
    func mark(_ output: ToolOutput) { self.output = output }
}
