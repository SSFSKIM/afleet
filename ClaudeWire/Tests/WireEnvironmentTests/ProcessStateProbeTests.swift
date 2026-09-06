import XCTest
import Darwin
@testable import WireEnvironment

/// The three states the probe has to tell apart, each reached deterministically: `posix_spawn` puts a child
/// under this test's own control, and `waitid` with `WNOWAIT` waits for it to exit *without* collecting its
/// status, which is a zombie by definition and needs no sleep to arrive at.
///
/// Foundation's `Process` is deliberately not used: it reaps its own children, so it can never produce the
/// middle state.
final class ProcessStateProbeTests: XCTestCase {
    private func spawn(_ command: String) throws -> pid_t {
        var pid: pid_t = 0
        let argv: [String] = ["/bin/sh", "-c", command]
        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        defer { for p in pointers where p != nil { free(p) } }
        let rc = posix_spawn(&pid, "/bin/sh", nil, nil, &pointers, nil)
        try XCTSkipUnless(rc == 0, "posix_spawn failed with \(rc)")
        return pid
    }
    /// Reaps, so nothing this test spawns is left behind.
    private func reap(_ pid: pid_t) { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
    /// Blocks until the child exits, leaving the status uncollected.
    private func waitLeavingZombie(_ pid: pid_t) {
        var info = siginfo_t()
        _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
    }

    func testALiveChildIsReportedAlive() throws {
        let pid = try spawn("sleep 30")
        defer { kill(pid, SIGKILL); reap(pid) }
        let state = probeProcessState(pid)
        XCTAssertEqual(state.liveness, .alive, "\(state)")
        XCTAssertEqual(state.pid, pid)
        XCTAssertEqual(state.name, "sh")
    }

    /// The state `kill(pid, 0)` cannot see: it succeeds here exactly as it does for a live process.
    func testAnUnreapedExitedChildIsReportedZombie() throws {
        let pid = try spawn("exit 0")
        defer { reap(pid) }
        waitLeavingZombie(pid)
        XCTAssertEqual(kill(pid, 0), 0, "kill(pid, 0) still succeeds for a zombie, which is why it cannot answer")
        let state = probeProcessState(pid)
        XCTAssertEqual(state.liveness, .zombie, "\(state)")
    }

    func testAReapedChildIsReportedGone() throws {
        let pid = try spawn("exit 0")
        reap(pid)
        let state = probeProcessState(pid)
        XCTAssertEqual(state.liveness, .gone, "\(state)")
        XCTAssertEqual(state.name, "")
    }
}
