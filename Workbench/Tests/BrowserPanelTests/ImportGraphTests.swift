import Foundation
import XCTest

/// Contract X1: `Workbench` may depend on `AfleetCore` and `FleetKit` and must never import
/// `ClaudeWire`. The manifest is one half of that; this grep is the other, because a manifest
/// cannot say what a source file did not import.
///
/// This walk covers `Sources/BrowserPanel` alone. Each leaf keeps a local walk over its own
/// sources; the package-wide walk over every Workbench target belongs to C7.1 as the manifest's
/// owner (composite W1, amended 2026-09-08 at C7.3's merge).
final class ImportGraphTests: XCTestCase {

    /// Foundation, the platform frameworks a panel draws with, and exactly the four modules this
    /// leaf's manifest region declares. `WebKit` is the panel; `Network` is not here — the
    /// loopback server the tests own lives in the test target, never in the module.
    private static let allowed: Set<String> = [
        "Foundation", "SwiftUI", "AppKit", "WebKit", "Observation", "OSLog",
        "AfleetCore", "FleetKit", "PanelHostAPI", "LinkRouting", "SourceControlCore",
    ]

    /// The package root, from this file's own location.
    private static var workbench: URL {
        URL(filePath: #filePath)                     // .../Workbench/Tests/BrowserPanelTests/ImportGraphTests.swift
            .deletingLastPathComponent()             // .../BrowserPanelTests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // .../Workbench
    }

    private static var sources: URL { workbench.appending(path: "Sources/BrowserPanel") }

    func testBrowserPanelImportsNothingFromClaudeWire() throws {
        let (modules, files) = try Self.importedModules(under: Self.sources)
        // A floor: an empty walk is a subset of anything, so a grep that read no files would
        // otherwise pass this test forever.
        XCTAssertGreaterThan(files, 0, "the walk found no Swift files at all")
        XCTAssertTrue(modules.isSubset(of: Self.allowed),
                      "imports outside the allowed set: \(modules.subtracting(Self.allowed).sorted())")
        // The second floor: a grep that matched no import at all must not pass either. It names
        // `PanelHostAPI` because that is the dependency this target's manifest region exists for —
        // a panel is a `PanelTab` or it is nothing — so the floor also proves the region is doing
        // something, which a floor on `Foundation` would not. It arrived at milestone 1, the
        // first milestone whose types name a member of X7; at milestone 0 the module was a
        // comment and the floor was `Foundation`.
        XCTAssertTrue(modules.contains("PanelHostAPI"),
                      "the walk matched no import at all")
    }

    struct NoSources: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) could not be walked" }
    }

    /// Every module name imported anywhere under `root`, and how many Swift files were read.
    static func importedModules(under root: URL) throws -> (modules: Set<String>, files: Int) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NoSources(path: root.lastPathComponent)
        }
        let urls = enumerator.compactMap { $0 as? URL }
        var modules: Set<String> = []
        var files = 0
        // `import Foundation` and `@preconcurrency import X`. Spaces and tabs only, never `\s`:
        // `\s` matches a newline, so a pattern written with it runs past the end of the line and
        // captures the next line's first word.
        let expression = try NSRegularExpression(pattern: #"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+([A-Za-z_]\w*)"#,
                                                 options: [.anchorsMatchLines])
        for url in urls {
            guard url.pathExtension == "swift" else { continue }
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                modules.insert(String(text[name]))
            }
        }
        return (modules, files)
    }
}
