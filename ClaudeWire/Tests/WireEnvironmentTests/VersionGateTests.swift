import XCTest
import WireEnvironment

final class VersionGateTests: XCTestCase {
    private func gate(_ stdout: String, exit: Int32 = 0) -> VersionGate {
        VersionGate(runner: ScriptedRunner(outputs: [.init(stdout: Data(stdout.utf8), stderr: Data(), exitCode: exit, timedOut: false)], calls: .init()))
    }
    func testBaselineAndNewerAccepted() async {
        guard case .accepted(let v) = await gate("2.1.259 (Claude Code)\n").check(binary: URL(fileURLWithPath: "/x")) else { return XCTFail() }
        XCTAssertEqual(v.description, "2.1.259")
        guard case .accepted = await gate("2.2.0 (Claude Code)").check(binary: URL(fileURLWithPath: "/x")) else { return XCTFail() }
        guard case .accepted = await gate("3.0.0-beta.1 (Claude Code)").check(binary: URL(fileURLWithPath: "/x")) else { return XCTFail() }
    }
    func testOlderRefusedWithBothVersions() async {
        guard case .tooOld(let installed, let baseline) = await gate("2.1.257 (Claude Code)").check(binary: URL(fileURLWithPath: "/x")) else { return XCTFail() }
        XCTAssertEqual(installed.description, "2.1.257"); XCTAssertEqual(baseline.description, "2.1.259")
    }
    func testGarbageIsUnparseable() async {
        guard case .unparseable(let out) = await gate("command not found", exit: 127).check(binary: URL(fileURLWithPath: "/x")) else { return XCTFail() }
        XCTAssertEqual(out, "command not found")
    }
    func testAfleetVersionIsPinned() {
        XCTAssertEqual(ProtocolBaseline.afleetVersion, "0.1.0")
    }
    func testSemanticVersionOrdering() {
        XCTAssertLessThan(SemanticVersion(parsing: "2.1.9")!, SemanticVersion(parsing: "2.1.10")!)
        XCTAssertEqual(ProtocolBaseline.version, "2.1.259")
    }
}
