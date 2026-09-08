import Darwin
import Foundation
@testable import TerminalCore
import XCTest

final class PTYSpawnTests: XCTestCase {
    func testSpawnUsesRequestedWorkingDirectoryEnvironmentAndInput() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let variable = "AFLEET_CRAFTED_ORCHID"
        let value = "violet-signal"
        let script = """
        printf 'cwd=%s\\n' "$PWD"
        printf 'crafted=%s\\n' "$AFLEET_CRAFTED_ORCHID"
        IFS= read -r input
        printf 'input=%s\\n' "$input"
        printf 'g1a-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: script,
                environment: [variable: value]
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        try await process.write(Data("violet-signal\n".utf8))
        let output = try await PTYTestChild.output(from: process.events, until: "g1a-ready")
        let lines = Set(output.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("cwd=\(directory.path)"), "child reported the wrong working directory")
        XCTAssertTrue(lines.contains("crafted=\(value)"), "child reported the wrong crafted variable value")
        XCTAssertTrue(lines.contains("input=violet-signal"), "child did not receive bytes written to the pty")
    }

    func testSpawnInheritsNoEnvironment() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let sentinel = "AFLEET_PARENT_SENTINEL_CEDAR"
        let carriedOne = "AFLEET_REQUESTED_AMBER"
        let carriedTwo = "AFLEET_REQUESTED_LAPIS"
        setenv(sentinel, "set-in-parent", 1)
        defer { unsetenv(sentinel) }
        let script = """
        if [ "${AFLEET_PARENT_SENTINEL_CEDAR+x}" = x ]; then
          printf 'AFLEET_PARENT_SENTINEL_CEDAR=present\\n'
        else
          printf 'AFLEET_PARENT_SENTINEL_CEDAR=absent\\n'
        fi
        if [ "${AFLEET_REQUESTED_AMBER+x}" = x ]; then
          printf 'AFLEET_REQUESTED_AMBER=present\\n'
        else
          printf 'AFLEET_REQUESTED_AMBER=absent\\n'
        fi
        if [ "${AFLEET_REQUESTED_LAPIS+x}" = x ]; then
          printf 'AFLEET_REQUESTED_LAPIS=present\\n'
        else
          printf 'AFLEET_REQUESTED_LAPIS=absent\\n'
        fi
        environment_count=$(/usr/bin/env | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        printf 'environment-count=%s\\n' "$environment_count"
        printf 'g1b-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: script,
                environment: [carriedOne: "one", carriedTwo: "two"]
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(from: process.events, until: "g1b-ready")
        let tokens = Set(output.split(separator: "\n").map(String.init))

        XCTAssertTrue(
            tokens.contains("AFLEET_PARENT_SENTINEL_CEDAR=absent"),
            "AFLEET_PARENT_SENTINEL_CEDAR should print absent"
        )
        XCTAssertTrue(
            tokens.contains("AFLEET_REQUESTED_AMBER=present"),
            "AFLEET_REQUESTED_AMBER should print present"
        )
        XCTAssertTrue(
            tokens.contains("AFLEET_REQUESTED_LAPIS=present"),
            "AFLEET_REQUESTED_LAPIS should print present"
        )
        XCTAssertTrue(
            tokens.contains("environment-count=5"),
            "child environment entry count was not 5"
        )
    }

    func testSpawnCreatesControllingTerminal() async throws {
        // macOS posix_spawn currently acquires the controlling terminal even when O_NOCTTY
        // is passed through addopen, making that behavioral mutation impossible to observe.
        // This source trace is the substitute for a behavioral assertion on this platform.
        let workbench = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let spawnSource = try String(
            contentsOf: workbench.appending(path: "Sources/TerminalCore/PTY/Darwin+PTY.swift"),
            encoding: .utf8
        )
        let addOpenLines = spawnSource
            .split(separator: "\n")
            .filter { $0.contains("posix_spawn_file_actions_addopen") }
        XCTAssertEqual(addOpenLines.count, 1, "slave addopen trace count was not 1")
        guard let addOpenLine = addOpenLines.first else { return }
        XCTAssertTrue(addOpenLine.contains("O_RDWR"), "slave addopen did not carry O_RDWR")
        XCTAssertFalse(addOpenLine.contains("O_NOCTTY"), "slave addopen carried O_NOCTTY")

        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let script = """
        # On Darwin /dev/tty is a clone device, so resolve the session's controlling tty to
        # its underlying node before comparing that node's device and inode with fstat(0).
        if tty_name=$(/bin/ps -o tty= -p $$ | /usr/bin/tr -d ' ') &&
           [ -n "$tty_name" ] &&
           tty_identity=$(/usr/bin/stat -f '%d:%i' "/dev/$tty_name" 2>/dev/null) &&
           input_identity=$(/usr/bin/stat -f '%d:%i' 2>/dev/null) &&
           [ "$tty_identity" = "$input_identity" ]; then
          printf 'own-tty=present\\n'
        else
          printf 'own-tty=absent\\n'
        fi
        if /bin/stty size <&0 >/dev/null 2>&1; then
          printf 'stty=present\\n'
        else
          printf 'stty=absent\\n'
        fi
        printf 'g1d-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: script)
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(from: process.events, until: "g1d-ready")
        let tokens = Set(output.split(separator: "\n").map(String.init))
        let foregroundGroup = try await process.foregroundProcessGroup()

        XCTAssertTrue(
            tokens.contains("own-tty=present"),
            "the child's controlling terminal was not its own descriptor 0"
        )
        XCTAssertTrue(tokens.contains("stty=present"), "stty could not read descriptor 0")
        XCTAssertTrue(
            foregroundGroup == process.processIdentifier,
            "pty foreground group did not match the spawned session leader"
        )
    }

    func testMissingExecutableAndWorkingDirectoryThrowTypedErrors() throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let missingExecutable = PTYSpawnRequest(
            executable: directory.appending(path: "unmade-executable"),
            arguments: [],
            cwd: directory,
            environment: [:],
            size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
            terminal: TerminalDescription(term: "xterm-256color")
        )
        do {
            _ = try PTYProcess(spawning: missingExecutable)
            XCTFail("missing executable did not throw at spawn")
        } catch PTYError.executableUnavailable {
            // The typed boundary is the assertion.
        } catch {
            XCTFail("missing executable did not throw PTYError.executableUnavailable")
        }

        let missingDirectory = PTYSpawnRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            cwd: directory.appending(path: "unmade-directory"),
            environment: [:],
            size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
            terminal: TerminalDescription(term: "xterm-256color")
        )
        do {
            _ = try PTYProcess(spawning: missingDirectory)
            XCTFail("missing working directory did not throw at spawn")
        } catch PTYError.workingDirectoryUnavailable {
            // The typed boundary is the assertion.
        } catch {
            XCTFail("missing working directory did not throw PTYError.workingDirectoryUnavailable")
        }
    }

    func testSpawnedChildInheritsNoDescriptorBeyondItsTerminal() async throws {
        // Unlike the pty ends, this descriptor deliberately has no close-on-exec flag. It is
        // therefore closed only by POSIX_SPAWN_CLOEXEC_DEFAULT, whose behavior this test isolates.
        let inheritedCandidate = Darwin.open("/dev/null", O_RDONLY)
        guard inheritedCandidate >= 0 else {
            XCTFail("could not open the descriptor-isolation probe")
            return
        }
        defer { _ = Darwin.close(inheritedCandidate) }
        let descriptorFlags = fcntl(inheritedCandidate, F_GETFD)
        XCTAssertTrue(
            descriptorFlags != -1 && descriptorFlags & FD_CLOEXEC == 0,
            "the descriptor-isolation probe unexpectedly had FD_CLOEXEC"
        )

        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        // `[ -e ]` is a shell builtin, so the survey opens nothing of its own. It reports only
        // the candidate descriptor's number and never identifies what that descriptor refers to.
        let survey = """
        extra=
        if [ -e "/dev/fd/\(inheritedCandidate)" ]; then
          extra=" \(inheritedCandidate)"
        fi
        printf 'extra=[%s]\\n' "$extra"
        printf 'g1-descriptors-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: survey)
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(
            from: process.events,
            until: "g1-descriptors-ready"
        )
        let reported = output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("extra=") }
        XCTAssertEqual(
            reported,
            "extra=[]",
            "the child inherited an extra descriptor (numbers only): \(reported ?? "none")"
        )
    }

    func testPTYMasterIsNotInheritedBySpawnersOutsideThisLayer() async throws {
        // `POSIX_SPAWN_CLOEXEC_DEFAULT` only governs this layer's own spawns. Every other
        // spawner in the process inherits by default — an engine launch, a helper tool, a
        // library — so the descriptor flag has to carry the master on its own. A leaked master
        // is a terminal that never reaches end-of-file. The probe below is a plain `posix_spawn`
        // precisely because it asks for nothing: it is the ordinary spawner this layer cannot
        // configure.
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let pane = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: """
                printf 'hold-ready\\n'
                IFS= read -r hold
                """
            )
        )
        defer { PTYTestChild.terminateAndReap(pane) }
        _ = try await PTYTestChild.output(from: pane.events, until: "hold-ready")

        let reported = try PTYTestChild.plainlySpawnedOutput(script: """
        terminals=
        for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          if [ -t "$n" ]; then terminals="$terminals $n"; fi
        done
        printf 'terminals=[%s]\\n' "$terminals"
        """)
        XCTAssertEqual(
            reported,
            "terminals=[]",
            "a pty master reached an unrelated child (numbers only): \(reported)"
        )
    }

    func testSpawnedChildStartsWithDefaultSignalDispositions() async throws {
        // A SIG_IGN disposition survives exec and a shell keeps an inherited one ignored. This
        // process ignores SIGPIPE the way Foundation and XCTest do; the child must not.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }

        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        // fd 3 carries the writer's status out to the pty from inside the pipeline, whose own
        // stdout is the pipe under test.
        let script = """
        exec 3>&1
        { /bin/cat /dev/zero; printf 'writer=%s\\n' "$?" >&3; } | /usr/bin/head -c 1 >/dev/null
        printf 'g1-sigpipe-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: script)
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(from: process.events, until: "g1-sigpipe-ready")
        let tokens = Set(output.split(separator: "\n").map(String.init))
        XCTAssertTrue(
            tokens.contains("writer=\(128 + SIGPIPE)"),
            "the child's writer did not die of SIGPIPE, so an ignored disposition was inherited"
        )
    }

    func testLargeWriteDoesNotBlockTheActor() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        // Raw mode so the echo is byte-for-byte, then a deliberate stall: while the child is not
        // reading, the pty's input queue fills and the master refuses more. A blocking write
        // would hold the actor for the whole stall.
        let script = PTYTestChild.selfTerminating(after: 60, """
        /bin/stty raw -echo
        printf 'flood-ready\\r\\n'
        sleep 3
        exec /bin/cat
        """)
        let process = try PTYProcess(spawning: PTYTestChild.request(cwd: directory, script: script))
        defer { PTYTestChild.terminateAndReap(process) }

        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        let marker = Data("flood-ready\r\n".utf8)
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: marker) != nil
        }
        let prefixLength = recorder.snapshot.count

        let payload = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })
        let writer = Task { try await process.write(payload) }
        defer { writer.cancel() }

        // Long enough for the writer to reach the full pty, short enough to land inside the
        // child's stall: under a blocking write the actor is unreachable here.
        try await Task.sleep(for: .milliseconds(200))
        let group = try await PTYTestChild.withDeadline(seconds: 1) {
            try await process.foregroundProcessGroup()
        }
        XCTAssertEqual(
            group,
            process.processIdentifier,
            "the actor answered, but not with the spawned session's foreground group"
        )

        // A second caller arriving while the first is suspended mid-payload. Its byte never
        // occurs in the payload, so if the two writes interleave the echo says so exactly.
        let trailer = Data(repeating: 0xFF, count: 64)
        let follower = Task { try await process.write(trailer) }
        defer { follower.cancel() }

        try await PTYTestChild.withDeadline(seconds: 20) { try await writer.value }
        try await PTYTestChild.withDeadline(seconds: 20) { try await follower.value }
        let expected = payload + trailer
        try await PTYTestChild.waitUntil(seconds: 20) {
            recorder.snapshot.count >= prefixLength + expected.count
        }
        let echoed = recorder.snapshot.dropFirst(prefixLength).prefix(expected.count)
        XCTAssertEqual(
            Data(echoed),
            expected,
            "the bytes the child echoed back are not the bytes written, in order"
        )
    }

    func testWriteGateAdmitsQueuedCallersInActorEntryOrder() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let script = PTYTestChild.selfTerminating(after: 60, """
        /bin/stty raw -echo
        printf 'fifo-ready\\r\\n'
        sleep 3
        exec /bin/cat
        """)
        let process = try PTYProcess(spawning: PTYTestChild.request(cwd: directory, script: script))
        defer { PTYTestChild.terminateAndReap(process) }

        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        let marker = Data("fifo-ready\r\n".utf8)
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: marker) != nil
        }
        let prefixLength = recorder.snapshot.count

        let payload = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })
        let holder = Task { try await process.write(payload) }
        defer { holder.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        // The holder remains suspended against the stalled child. Let each following caller enter
        // the actor and join the gate before starting the next, so their queue order is explicit.
        let secondBytes = Data(repeating: 0xFD, count: 64)
        let second = Task { try await process.write(secondBytes) }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        let thirdBytes = Data(repeating: 0xFE, count: 64)
        let third = Task { try await process.write(thirdBytes) }
        defer { third.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        try await PTYTestChild.withDeadline(seconds: 20) { try await holder.value }
        try await PTYTestChild.withDeadline(seconds: 20) { try await second.value }
        try await PTYTestChild.withDeadline(seconds: 20) { try await third.value }

        let expected = payload + secondBytes + thirdBytes
        try await PTYTestChild.waitUntil(seconds: 20) {
            recorder.snapshot.count >= prefixLength + expected.count
        }
        let echoed = Data(recorder.snapshot.dropFirst(prefixLength).prefix(expected.count))
        XCTAssertEqual(echoed, expected, "queued writes reached the child out of order")
    }

    func testWriteGateAcquisitionIsCancellable() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let script = PTYTestChild.selfTerminating(after: 60, """
        /bin/stty raw -echo
        printf 'gate-ready\\r\\n'
        sleep 3
        exec /bin/cat
        """)
        let process = try PTYProcess(spawning: PTYTestChild.request(cwd: directory, script: script))
        defer { PTYTestChild.terminateAndReap(process) }

        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        let marker = Data("gate-ready\r\n".utf8)
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: marker) != nil
        }
        let prefixLength = recorder.snapshot.count

        // The holder fills the stalled pty and then suspends, still holding the gate.
        let payload = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })
        let holder = Task { try await process.write(payload) }
        defer { holder.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        // This caller can only be queued behind the holder. Its byte occurs nowhere in the
        // payload, so if cancellation is ignored the echo shows it as well.
        let abandoned = Task { try await process.write(Data(repeating: 0x41, count: 8)) }
        try await Task.sleep(for: .milliseconds(200))
        abandoned.cancel()

        // A queue that could only be left at the front would hold this for the whole stall.
        let leftTheQueue = try await PTYTestChild.withDeadline(seconds: 1) { () -> Bool in
            do {
                try await abandoned.value
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        XCTAssertTrue(leftTheQueue, "a cancelled caller did not leave the write queue")

        // The gate survives the departure: the holder finishes and a later caller is admitted.
        try await PTYTestChild.withDeadline(seconds: 20) { try await holder.value }
        let trailer = Data(repeating: 0xFF, count: 64)
        try await PTYTestChild.withDeadline(seconds: 20) { try await process.write(trailer) }

        let expected = payload + trailer
        try await PTYTestChild.waitUntil(seconds: 20) {
            recorder.snapshot.count >= prefixLength + expected.count
        }
        let echoed = Data(recorder.snapshot.dropFirst(prefixLength).prefix(expected.count))
        XCTAssertEqual(
            echoed,
            expected,
            "the cancelled caller's bytes reached the child, or the gate lost its order"
        )
    }

    func testTemporaryRootRuleRefusesEveryConfigHome() {
        // Entirely pure: invented paths, no directory created anywhere, so the rule can be wrong
        // without a test having written into a config home to discover it.
        let home = URL(filePath: "/invented/roots/quartzite")
        let configured = URL(filePath: "/invented/roots/juniper-home")
        let roots = PTYTestChild.configHomeRoots(
            homeDirectory: home,
            environment: ["CLAUDE_CONFIG_DIR": configured.path]
        )

        XCTAssertTrue(
            PTYTestChild.isForbidden(configured, roots: roots),
            "the configured config home was not refused"
        )
        XCTAssertTrue(
            PTYTestChild.isForbidden(configured.appending(path: "sessions"), roots: roots),
            "a path under the configured config home was not refused"
        )
        XCTAssertTrue(
            PTYTestChild.isForbidden(home.appending(path: ".claude").appending(path: "todos"), roots: roots),
            "a path under the default config home was not refused"
        )
        XCTAssertFalse(
            PTYTestChild.isForbidden(URL(filePath: "/invented/roots/quartzite/scratch"), roots: roots),
            "an ordinary path under the home directory was refused"
        )
        XCTAssertFalse(
            PTYTestChild.isForbidden(URL(filePath: "/invented/roots/juniper-home-elsewhere"), roots: roots),
            "a sibling sharing the config home's name prefix was refused"
        )
        XCTAssertFalse(
            PTYTestChild.configHomeRoots(homeDirectory: home, environment: [:])
                .contains(configured),
            "an unset CLAUDE_CONFIG_DIR still contributed a root"
        )
    }
}
