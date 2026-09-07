import Foundation
import XCTest
import AfleetCore
@testable import Afleet

/// G1e's entry conditions in one place: the environment flag, the scratch config home, the working
/// directory the child runs in, and the environment it is handed.
///
/// Nothing here writes under a config home (X9). The scratch `.claude.json` is **read** — through
/// `ClaudeJSONReader.read`, `O_RDONLY | O_NOFOLLOW`, so a symlinked document is refused rather than
/// followed out of the home — and a trust entry is never written. The one directory this may create
/// lies under `/private/tmp/afleet-fixtures/`, beside the config home and not inside it.
enum ScratchLiveGate {

    /// The one config home the live leg runs under.
    static let scratchHome = URL(filePath: "/tmp/afleet-fixtures/config-home")

    /// The prefix a directory must lie under to be considered. C4's rule, unchanged: the scratch
    /// fixtures live here, and nothing outside it is a directory this suite may create.
    static let scratchProjects = "/private/tmp/afleet-fixtures/"

    static func skipUnlessLive() throws {
        guard ProcessInfo.processInfo.environment["AFLEET_LIVE_CLI"] == "1" else {
            throw XCTSkip("set AFLEET_LIVE_CLI=1 to run against the installed CLI")
        }
        // The scratch home lives under `/tmp` and dies with every reboot, and `claude auth login`
        // stores credentials **without** setting `hasCompletedOnboarding` (C4's finding), so a home
        // that is merely logged in still sits on the theme picker and never registers anything.
        // The recovery is one interactive run by hand, which is what the message says.
        let configHome = ConfigHome(root: scratchHome, source: .environment)
        guard ClaudeJSONReader.hasCompletedOnboarding(in: configHome) else {
            throw XCTSkip("""
                the scratch config home under /tmp/afleet-fixtures reports no completed onboarding; \
                recover with one interactive run by hand under CLAUDE_CONFIG_DIR pointed at it
                """)
        }
    }

    // MARK: - The working directory

    /// The directories the scratch `.claude.json` already trusts, in a stable order.
    ///
    /// **A fresh temporary directory would be the wrong answer.** An interactive session in a
    /// directory the home has never trusted sits on the workspace-trust dialog *before* it writes a
    /// registry record, so the gate would fail on the engine doing exactly what it is designed to
    /// do — the same failure shape as an un-onboarded home sitting on the theme picker.
    ///
    /// `/tmp` is a symlink to `/private/tmp`, so the scratch config home lies under the prefix too.
    /// A stray trust entry naming the config home, or anything beneath it, would let this suite
    /// create directories inside a config home — the one thing this child must never do — so it is
    /// excluded **by code** here rather than by the fixture's good manners.
    ///
    /// Both sides are canonicalised through `CanonicalPath`, not through
    /// `URL.resolvingSymlinksInPath()`, and the difference is not cosmetic. Foundation rewrites a
    /// `/private/tmp/…` path to `/tmp/…` only when the result **exists**, so an entry naming a
    /// directory *inside* the config home that has not been created yet stays `/private/tmp/…` while
    /// the config home itself becomes `/tmp/…`, no prefix matches, and the exclusion fails open on
    /// exactly the path it exists to catch. `CanonicalPath.string` resolves as much of a path as
    /// exists and puts the rest back, which is the same fix `LaunchSequence.overlappingWriteRoot`
    /// already carries for the same reason. Found by this file's own test, against the ported rule.
    static func trustedDirectories(inDocument globalConfig: URL, excluding configHome: URL) -> [URL] {
        guard let data = ClaudeJSONReader.read(globalConfig),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = document["projects"] as? [String: Any]
        else { return [] }
        let home = CanonicalPath.string(configHome)
        return projects.compactMap { path, value -> String? in
            guard let entry = value as? [String: Any], entry["hasTrustDialogAccepted"] as? Bool == true,
                  path.hasPrefix(scratchProjects) else { return nil }
            let resolved = CanonicalPath.string(URL(filePath: path))
            guard resolved != home, !resolved.hasPrefix(home + "/") else { return nil }
            return path
        }.sorted().map { URL(filePath: $0) }
    }

    /// The trusted directory at `index`, created if the fixture named one that is gone.
    ///
    /// Creating it is a write under `/private/tmp`, never under a config home, and **no trust entry
    /// is ever written**: the directory is trusted already or it is not a candidate.
    static func trustedDirectory(_ index: Int = 0) throws -> URL {
        let candidates = trustedDirectories(inDocument: scratchHome.appending(path: ".claude.json"),
                                            excluding: scratchHome)
        guard index < candidates.count else {
            throw XCTSkip("the scratch config home trusts no directory at index \(index) under its fixtures root")
        }
        let directory = candidates[index]
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
