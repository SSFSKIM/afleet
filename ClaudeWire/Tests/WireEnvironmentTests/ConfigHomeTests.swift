import XCTest
import AfleetCore
import WireEnvironment

final class ConfigHomeTests: XCTestCase {
    private func env(_ v: [String: String]) -> ResolvedEnvironment { .init(variables: v, shell: "/bin/zsh", capturedAt: .init(), mode: .login) }
    func testDefaultIsHomeDotClaude() {
        let h = ConfigHome.derive(from: env(["HOME": "/Users/x"]))
        XCTAssertEqual(h.root.path, "/Users/x/.claude"); XCTAssertEqual(h.source, .default); XCTAssertNil(h.projectDirName)
    }
    func testEnvironmentSourceWithTildeAndProjectDirName() {
        let h = ConfigHome.derive(from: env(["HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "~/cfg//sub/", "CLAUDE_CODE_PROJECT_DIR_NAME": "proj"]))
        XCTAssertEqual(h.root.path, "/Users/x/cfg/sub"); XCTAssertEqual(h.source, .environment); XCTAssertEqual(h.projectDirName, "proj")
    }
    func testProjectDirNameIgnoredWithoutConfigDir() {
        let h = ConfigHome.derive(from: env(["HOME": "/Users/x", "CLAUDE_CODE_PROJECT_DIR_NAME": "proj"]))
        XCTAssertNil(h.projectDirName)
    }
    func testEmptyConfigDirCountsAsUnset() {
        XCTAssertEqual(ConfigHome.derive(from: env(["HOME": "/Users/x", "CLAUDE_CONFIG_DIR": ""])).source, .default)
    }
}
