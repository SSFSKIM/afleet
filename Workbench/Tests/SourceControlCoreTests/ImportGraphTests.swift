import Foundation
import XCTest

/// Contract X1: `Workbench` may depend on `AfleetCore` and `FleetKit` and must never import
/// `ClaudeWire`. The manifest is one half of that; this grep is the other, because a manifest
/// cannot say what a source file did not import.
///
/// Ledger D12: this walk covers `Sources/SourceControlCore` alone. C5 owns the equivalent walk
/// over `Sources/PanelHostAPI` and its fence, and the package-wide walk over every Workbench
/// target belongs to C7.1 as the manifest's owner (the architect's ruling at the gate). A leaf
/// ships the local one either way.
final class ImportGraphTests: XCTestCase {

    /// Foundation is the platform; `AfleetCore` is what this leaf's manifest region allows.
    /// `ClaudeWire` and its Wire modules are absent by design — D1 is the reason this target
    /// carries its own process runner instead.
    private static let allowed: Set<String> = ["Foundation", "AfleetCore"]

    /// The package root, from this file's own location.
    private static var workbench: URL {
        URL(filePath: #filePath)                     // .../Workbench/Tests/SourceControlCoreTests/ImportGraphTests.swift
            .deletingLastPathComponent()             // .../SourceControlCoreTests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // .../Workbench
    }

    private static var sources: URL { workbench.appending(path: "Sources/SourceControlCore") }

    func testSourceControlCoreImportsNothingFromClaudeWire() throws {
        let (modules, files) = try Self.importedModules(under: Self.sources)
        // A floor: an empty walk is a subset of anything, so a grep that read no files would
        // otherwise pass this test forever.
        XCTAssertGreaterThan(files, 0, "the walk found no Swift files at all")
        XCTAssertTrue(modules.isSubset(of: Self.allowed),
                      "imports outside the allowed set: \(modules.subtracting(Self.allowed).sorted())")
        // The second floor: a grep that matched no import at all must not pass either. It names
        // `AfleetCore` rather than `Foundation` from milestone 5 onward, because that is when
        // the dependency this target's manifest region declares first genuinely arrives —
        // `GitDiff` maps `DiffRef.Base`. A floor on `Foundation` would still hold in a target
        // that had quietly stopped depending on anything; a floor on the *declared dependency*
        // also proves the manifest region is doing something.
        XCTAssertTrue(modules.contains("AfleetCore"),
                      "the walk did not find the AfleetCore import this target's manifest region declares")
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
        // `import Foundation` and `@testable import X`. Spaces and tabs only, never `\s`: `\s`
        // matches a newline, so a pattern written with it runs past the end of the line and
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
