import Foundation
import XCTest
@testable import FleetSessions

/// The trusted-directory selector, held up against the one shape it exists to refuse: a trust entry naming a path
/// beneath the config home.
///
/// Runs on every checkout — no CLI, no `AFLEET_LIVE_CLI`, no engine. It does need real `/private/tmp` paths: the
/// bug it pins is Foundation's `resolvingSymlinksInPath()` rewriting `/private/tmp/X` to `/tmp/X` only when `X`
/// exists, so an entry naming a directory that does not exist yet keeps its `/private/tmp` spelling while the
/// config home, which does exist, loses it — and no prefix matches. A temporary directory under `/var/folders`
/// has no such symlink and would not discriminate.
///
/// The root created here is a plain directory used as a path string. No process is ever pointed at it as a config
/// home; nothing is written under the real one.
final class LiveGateTrustSelectorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(filePath: "/private/tmp/afleet-selector-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "config-home"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "invented-trusted"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testTheSelectorRefusesEveryEntryAtOrBeneathTheConfigHome() throws {
        let base = root.path(percentEncoded: false)
        let home = root.appending(path: "config-home")
        let document = try write(projects: [
            "\(base)/invented-trusted": true,
            "\(base)/invented-untrusted": false,
            "/private/tmp/invented-outside-root": true,
            "\(home.path(percentEncoded: false))": true,
            "\(home.path(percentEncoded: false))/projects/invented-slug": true,
        ])

        let selected = LiveGate.trustedDirectories(inDocument: document, underRoot: "\(base)/", excluding: home)

        // The floor first: a selector that returned nothing would satisfy every exclusion below and prove none.
        XCTAssertFalse(selected.isEmpty, "the selector returned no candidate at all, so it proves no exclusion")
        // Both sides are built off the assertion line: `base` is this test's temporary root, so neither the
        // operands nor the message may carry it (tracker 75, §6.3).
        let paths = selected.map { $0.path(percentEncoded: false) }
        let wanted = ["\(base)/invented-trusted"]
        XCTAssertTrue(paths == wanted,
                      "expected exactly 1 candidate under the test's own root, got \(selected.count)")
    }

    func testAnEmptyProjectsMapYieldsNoCandidate() throws {
        let document = try write(projects: [:])
        let selected = LiveGate.trustedDirectories(inDocument: document, underRoot: "\(root.path(percentEncoded: false))/",
                                                   excluding: root.appending(path: "config-home"))
        XCTAssertEqual(selected.count, 0, "expected 0 candidates, got \(selected.count)")
    }

    /// A `.claude.json`-shaped document under the test's own root, holding only invented identifiers.
    private func write(projects: [String: Bool]) throws -> URL {
        let entries = projects.mapValues { ["hasTrustDialogAccepted": $0] }
        let data = try JSONSerialization.data(withJSONObject: ["projects": entries])
        let file = root.appending(path: "invented-global-config.json")
        try data.write(to: file)
        return file
    }
}
