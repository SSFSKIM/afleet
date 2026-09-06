import Foundation
import XCTest

/// Contract X1 and the reason X7 has the shape it has: `PanelHostAPI` — and through it the whole
/// Workbench package — names no type defined in `ClaudeWire`. The manifest is one half of that;
/// this grep is the other, because a manifest cannot say what a source file did not import.
final class ImportGraphTests: XCTestCase {

    /// Foundation and SwiftUI are the platform; `AfleetCore` and `FleetKit` are what the
    /// manifest allows. `ClaudeWire` and its four Wire modules are absent by design.
    private static let allowed: Set<String> = ["Foundation", "SwiftUI", "AfleetCore", "FleetKit"]

    /// The package root, from this file's own location.
    private static var workbench: URL {
        URL(filePath: #filePath)                     // .../Workbench/Tests/PanelHostAPITests/ImportGraphTests.swift
            .deletingLastPathComponent()             // .../PanelHostAPITests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // .../Workbench
    }

    private static var sources: URL { workbench.appending(path: "Sources/PanelHostAPI") }

    /// The consumer fixture, asserted on as a single file rather than as a tree.
    private static var consumerTab: URL {
        workbench.appending(path: "Tests/PanelHostAPITests/ConsumerTab.swift")
    }

    func testPanelHostAPIImportsNothingFromClaudeWire() throws {
        let (modules, files) = try Self.importedModules(under: Self.sources)
        XCTAssertGreaterThan(files, 0, "the grep found no Swift files at all")
        XCTAssertTrue(modules.isSubset(of: Self.allowed),
                      "imports outside the allowed set: \(modules.subtracting(Self.allowed).sorted())")
        // The floor: a grep that silently matched nothing would be a subset of anything.
        XCTAssertTrue(modules.contains("FleetKit"),
                      "the grep did not find the FleetKit import this target certainly has")
    }

    /// `ConsumerTab.swift` claims in its header that a panel tab can be written importing
    /// `PanelHostAPI` and `SwiftUI` and nothing else. Without this, that claim would live only in
    /// the comment: the walk above covers `Sources/PanelHostAPI` and would stay green if the
    /// fixture grew an `import FleetKit` — or an `import ClaudeWire`, which as this target has
    /// demonstrated compiles. Equality, not subset, for the same reason the `Mirror` test uses it:
    /// the whole point is that nothing else is there.
    func testTheConsumerTabImportsPanelHostAPIAndSwiftUIAndNothingElse() throws {
        let (modules, files) = try Self.importedModules(under: Self.consumerTab)
        XCTAssertEqual(files, 1, "the walk did not read the consumer fixture")
        XCTAssertEqual(modules, ["PanelHostAPI", "SwiftUI"],
                       "the consumer fixture's import set changed")
    }

    struct NoSources: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) could not be walked" }
    }

    /// Every module name imported anywhere under `root`, and how many files were read. `root` is a
    /// directory to walk or a single Swift file to read.
    static func importedModules(under root: URL) throws -> (modules: Set<String>, files: Int) {
        let urls: [URL]
        if root.pathExtension == "swift" {
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw NoSources(path: root.lastPathComponent)
            }
            urls = [root]
        } else {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw NoSources(path: root.lastPathComponent)
            }
            urls = enumerator.compactMap { $0 as? URL }
        }
        var modules: Set<String> = []
        var files = 0
        // `import Foundation` and `@testable import X`. Spaces and tabs only, never `\s`: `\s` matches a newline,
        // so a pattern written with it runs on past the end of the line and captures the next line's first word.
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
