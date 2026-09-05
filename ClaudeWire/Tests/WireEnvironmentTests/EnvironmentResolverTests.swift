import XCTest
import AfleetCore
import WireEnvironment
import WireTestSupport

private func env(_ pairs: [String], banner: String = "", sentinel: Bool = true) -> Data {
    var d = Data(banner.utf8)
    if sentinel { d += Data("__AFLEET_ENV__\0".utf8) }
    for p in pairs { d += Data(p.utf8); d.append(0) }
    return d
}

final class EnvironmentResolverTests: XCTestCase {
    func testInteractiveLoginCaptureWithBannerAndPathFirst() async throws {
        let rec = ScriptedRunner.Recorder()
        let runner = ScriptedRunner(outputs: [.init(stdout: env(["PATH=/opt/homebrew/bin:/usr/bin", "HOME=/Users/x", "SHELL=/bin/zsh"], banner: "Welcome!\nno newline banner"), stderr: Data(), exitCode: 0, timedOut: false)], calls: rec)
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.mode, .interactiveLogin)
        XCTAssertEqual(r.variables["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(r.path.first, "/opt/homebrew/bin")
        XCTAssertEqual(rec.invocations.first, ["-l", "-i", "-c", "printf \"__AFLEET_ENV__\\0\"; /usr/bin/env -0"])
    }
    func testConfigDirFirstAfterBannerSurvives() async throws {
        let runner = ScriptedRunner(outputs: [.init(stdout: env(["CLAUDE_CONFIG_DIR=/tmp/cfg", "PATH=/usr/bin"], banner: "banner"), stderr: Data(), exitCode: 0, timedOut: false)], calls: .init())
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.variables["CLAUDE_CONFIG_DIR"], "/tmp/cfg")
    }
    func testMissingSentinelFallsThroughToLoginThenProcess() async throws {
        let rec = ScriptedRunner.Recorder()
        let runner = ScriptedRunner(outputs: [
            .init(stdout: env(["PATH=/x"], sentinel: false), stderr: Data(), exitCode: 0, timedOut: false),     // interactive: no sentinel
            .init(stdout: Data(), stderr: Data(), exitCode: 0, timedOut: true),                                // login: timed out
        ], calls: rec)
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(1))
        XCTAssertEqual(r.mode, .processFallback)
        XCTAssertEqual(rec.invocations.count, 2)
        XCTAssertEqual(rec.invocations[1].prefix(2), ["-l", "-c"])
        XCTAssertEqual(r.variables["PATH"], ProcessInfo.processInfo.environment["PATH"])
    }
    func testNonZeroExitRetriesLoginOnly() async throws {
        let runner = ScriptedRunner(outputs: [
            .init(stdout: Data(), stderr: Data("zsh: bad rc".utf8), exitCode: 1, timedOut: false),
            .init(stdout: env(["PATH=/login/bin"]), stderr: Data(), exitCode: 0, timedOut: false),
        ], calls: .init())
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.mode, .login); XCTAssertEqual(r.variables["PATH"], "/login/bin")
    }
    func testOnlyAssignmentTokensAreKept() async throws {
        let runner = ScriptedRunner(outputs: [.init(stdout: env(["GOOD=1", "not an assignment", "9BAD=2", "ALSO_GOOD=a=b", "PATH=/x"]), stderr: Data(), exitCode: 0, timedOut: false)], calls: .init())
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.variables, ["GOOD": "1", "ALSO_GOOD": "a=b", "PATH": "/x"])
    }
    func testSentinelWithNoAssignmentsFallsThrough() async throws {
        let rec = ScriptedRunner.Recorder()
        let runner = ScriptedRunner(outputs: [.init(stdout: env([], banner: "truncated"), stderr: Data(), exitCode: 0, timedOut: false)], calls: rec)
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.mode, .processFallback)
        XCTAssertEqual(rec.invocations.count, 2)
    }
    /// A capture without PATH would silently degrade binary lookup while still claiming success.
    func testCaptureWithoutPathFallsThrough() async throws {
        let rec = ScriptedRunner.Recorder()
        let runner = ScriptedRunner(outputs: [.init(stdout: env(["HOME=/Users/x", "SHELL=/bin/zsh"]), stderr: Data(), exitCode: 0, timedOut: false)], calls: rec)
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.mode, .processFallback)
        XCTAssertEqual(rec.invocations.count, 2)
    }
    /// The rule is `^[A-Za-z_][A-Za-z0-9_]*=`: Unicode letters and Unicode digits are not variable names.
    func testNonASCIINamesAreRejected() async throws {
        let runner = ScriptedRunner(outputs: [.init(stdout: env(["P\u{00C4}TH=/bad", "A\u{0660}=/bad", "PATH=/good"]), stderr: Data(), exitCode: 0, timedOut: false)], calls: .init())
        let r = await EnvironmentResolver(runner: runner).resolve(shell: "/bin/zsh", timeout: .seconds(5))
        XCTAssertEqual(r.variables, ["PATH": "/good"])
    }
}
