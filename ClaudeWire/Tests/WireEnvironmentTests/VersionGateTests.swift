import XCTest
import AfleetCore
import WireEnvironment
import WireTestSupport

final class VersionGateTests: XCTestCase {
    private func env(_ variables: [String: String] = ["PATH": "/usr/bin:/bin"]) -> ResolvedEnvironment {
        ResolvedEnvironment(variables: variables, shell: "/bin/zsh", capturedAt: .init(), mode: .login)
    }
    private func gate(_ stdout: String, exit: Int32 = 0, timedOut: Bool = false, calls: ScriptedRunner.Recorder = .init()) -> VersionGate {
        VersionGate(runner: ScriptedRunner(outputs: [.init(stdout: Data(stdout.utf8), stderr: Data(), exitCode: exit, timedOut: timedOut)], calls: calls))
    }
    func testBaselineAndNewerAccepted() async {
        guard case .accepted(let v) = await gate("2.1.259 (Claude Code)\n").check(binary: URL(fileURLWithPath: "/x"), environment: env()) else { return XCTFail() }
        XCTAssertEqual(v.description, "2.1.259")
        guard case .accepted = await gate("2.2.0 (Claude Code)").check(binary: URL(fileURLWithPath: "/x"), environment: env()) else { return XCTFail() }
        guard case .accepted = await gate("3.0.0-beta.1 (Claude Code)").check(binary: URL(fileURLWithPath: "/x"), environment: env()) else { return XCTFail() }
    }
    func testOlderRefusedWithBothVersions() async {
        guard case .tooOld(let installed, let baseline) = await gate("2.1.257 (Claude Code)").check(binary: URL(fileURLWithPath: "/x"), environment: env()) else { return XCTFail() }
        XCTAssertEqual(installed.description, "2.1.257"); XCTAssertEqual(baseline.description, "2.1.259")
    }
    func testGarbageIsUnparseable() async {
        guard case .unparseable(let out) = await gate("command not found", exit: 127).check(binary: URL(fileURLWithPath: "/x"), environment: env()) else { return XCTFail() }
        XCTAssertEqual(out, "command not found")
    }
    /// A failed probe is not a version. Reading stdout without consulting `exitCode` or `timedOut` reports a
    /// broken or hung install as `.accepted` on the strength of whatever prefix it managed to emit, and hands
    /// the failure to the first spawn instead of to the gate that exists to catch it.
    func testAProbeThatFailedOrTimedOutIsNeverAVersion() async {
        guard case .unparseable(let failed) = await gate("2.1.259 (Claude Code)", exit: 1).check(binary: URL(fileURLWithPath: "/x"), environment: env()) else {
            return XCTFail("a probe that exited non-zero was read as a version")
        }
        XCTAssertEqual(failed, "2.1.259 (Claude Code)")
        guard case .unparseable = await gate("2.1.259 (Claude Code)", timedOut: true).check(binary: URL(fileURLWithPath: "/x"), environment: env()) else {
            return XCTFail("a probe that timed out was read as a version")
        }
        // And a probe that succeeded is still accepted, so the guard above cannot pass by refusing everything.
        guard case .accepted = await gate("2.1.259 (Claude Code)").check(binary: URL(fileURLWithPath: "/x"), environment: env()) else {
            return XCTFail("a clean probe was refused")
        }
    }
    /// The probe runs in the environment the launch will actually use. `claude` is commonly a launcher script
    /// with `#!/usr/bin/env node`; under the GUI's own PATH the probe can fail where the real launch, which
    /// runs under the resolved login-shell environment, would have worked.
    func testTheProbeRunsInTheResolvedEnvironmentNotTheHostProcessOne() async {
        let calls = ScriptedRunner.Recorder()
        let resolved = env(["PATH": "/opt/homebrew/bin:/usr/bin", "AFLEET_RESOLVED_MARKER": "1"])
        _ = await gate("2.1.259 (Claude Code)", calls: calls).check(binary: URL(fileURLWithPath: "/x"), environment: resolved)
        // Compared by key set, and reported by key set: the host process's own environment is what the bug
        // substituted, and printing it into a test log would put every secret in it there too.
        XCTAssertEqual(calls.environments.first.map { Set($0.keys) }, Set(resolved.variables.keys),
                       "the probe was given some other environment (\(calls.environments.first?.count ?? 0) variables)")
        XCTAssertEqual(calls.environments.first?["AFLEET_RESOLVED_MARKER"], "1")
    }
    func testAfleetVersionIsPinned() {
        XCTAssertEqual(ProtocolBaseline.afleetVersion, "0.1.0")
    }
    func testSemanticVersionOrdering() {
        XCTAssertLessThan(SemanticVersion(parsing: "2.1.9")!, SemanticVersion(parsing: "2.1.10")!)
        XCTAssertEqual(ProtocolBaseline.version, "2.1.259")
    }
}
