import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Where `.claude.json` is, which is not where the whole app assumed it was.
///
/// The engine resolves the document as `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")` and
/// the config home as `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")`. Two different expressions:
/// they name the same directory only when the variable is set. Every test that existed before this
/// one built its scratch home the `CLAUDE_CONFIG_DIR` way, so the ordinary installation — variable
/// unset, config home `~/.claude`, document at `~/.claude.json` one level up — was the untested
/// half, and the app looked for a file that has never existed there.
///
/// Both derivations are asserted here, and the `.default` one carries the clause that discriminates:
/// a document sitting *inside* a default config home must **not** satisfy the gate, because reading
/// it would mean the resolution had simply stopped caring which layout it was in.
///
/// Every path below is invented and lives under the temporary directory.
final class GlobalConfigLocationTests: XCTestCase {

    /// `CLAUDE_CONFIG_DIR` unset: the document is the config home's sibling.
    func testADefaultConfigHomeReadsTheDocumentBesideItAndNotInsideIt() throws {
        let temp = try TempTree()
        let home = try temp.directory("invented-home")
        let configHome = ConfigHome(root: home.appending(path: ".claude", directoryHint: .isDirectory),
                                    source: .default)

        XCTAssertEqual(configHome.globalConfig.path,
                       home.appending(path: ".claude.json").path,
                       "the resolved document is not the config home's sibling")

        // The wrong location alone does not satisfy the gate. Written first, so the assertion below
        // cannot pass by reading it.
        _ = try temp.file("invented-home/.claude/.claude.json", #"{"hasCompletedOnboarding": true}"#)
        XCTAssertFalse(ClaudeJSONReader.hasCompletedOnboarding(in: configHome),
                       "a document inside a default config home was read as though it were the global one")

        _ = try temp.file("invented-home/.claude.json",
                          #"{"hasCompletedOnboarding": true, "projects": {"/invented/repo-a": {}, "/invented/repo-b": {}}}"#)
        XCTAssertTrue(ClaudeJSONReader.hasCompletedOnboarding(in: configHome),
                      "the document beside a default config home was not read")

        // The sidebar's project order comes off the same resolved location, so it is asserted on
        // the same fixture rather than trusted to have been threaded correctly.
        let order = ClaudeProjects.order(globalConfig: configHome.globalConfig)
        XCTAssertEqual(order, ["/invented/repo-a", "/invented/repo-b"])
    }

    /// `CLAUDE_CONFIG_DIR` set: the document is inside the directory the variable names. The other
    /// direction, without which a resolution that always looked one level up would pass the test
    /// above and break every installation that does set the variable.
    func testAnEnvironmentConfigHomeReadsTheDocumentInsideItAndNotBesideIt() throws {
        let temp = try TempTree()
        let root = try temp.directory("invented-config-dir")
        let configHome = ConfigHome(root: root, source: .environment)

        XCTAssertEqual(configHome.globalConfig.path,
                       root.appending(path: ".claude.json").path,
                       "the resolved document is not inside the named config directory")

        _ = try temp.file(".claude.json", #"{"hasCompletedOnboarding": true}"#)
        XCTAssertFalse(ClaudeJSONReader.hasCompletedOnboarding(in: configHome),
                       "a document outside the named config directory was read as though it were the global one")

        _ = try temp.file("invented-config-dir/.claude.json",
                          #"{"hasCompletedOnboarding": true, "projects": {"/invented/repo-c": {}}}"#)
        XCTAssertTrue(ClaudeJSONReader.hasCompletedOnboarding(in: configHome),
                      "the document inside the named config directory was not read")
        XCTAssertEqual(ClaudeProjects.order(globalConfig: configHome.globalConfig), ["/invented/repo-c"])
    }
}
