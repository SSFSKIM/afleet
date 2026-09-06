import Foundation
import XCTest

/// Contract X1: the `Afleet` app target depends on all four packages and on the platform, and
/// imports nothing else. The manifest is one half of that; this grep is the other, because a
/// manifest cannot say what a source file did not import.
final class ImportGraphTests: XCTestCase {

    /// Foundation, SwiftUI, AppKit, UserNotifications, Observation and OSLog are the platform;
    /// the four packages are what `project.yml` declares. `PanelHostAPI` is listed although the
    /// `Workbench` umbrella re-exports it, because a source file may import it directly and that
    /// is legal.
    private static let allowed: Set<String> = ["Foundation", "SwiftUI", "AppKit", "UserNotifications",
                                               "Observation", "OSLog", "AfleetCore", "ClaudeWire",
                                               "FleetKit", "Workbench", "PanelHostAPI"]

    /// `App/`, from this file's own location.
    private static var sources: URL {
        URL(filePath: #filePath)                     // .../AppTests/ImportGraphTests.swift
            .deletingLastPathComponent()             // .../AppTests
            .deletingLastPathComponent()             // the repository root
            .appending(path: "App")
    }

    func testEveryImportUnderAppIsInTheAllowedSet() throws {
        let (modules, files) = try Self.importedModules()
        XCTAssertGreaterThan(files, 0, "the grep found no Swift files at all")
        XCTAssertTrue(modules.isSubset(of: Self.allowed),
                      "imports outside the allowed set: \(modules.subtracting(Self.allowed).sorted())")
        // The floor: a grep that silently matched nothing would be a subset of anything.
        XCTAssertTrue(modules.isSuperset(of: ["SwiftUI", "FleetKit"]),
                      "the grep did not find the imports every file in this target has")
    }

    struct NoSources: Error, CustomStringConvertible {
        var description: String { "App could not be walked" }
    }

    /// Every module name imported anywhere under the app target, and how many files were read.
    static func importedModules() throws -> (modules: Set<String>, files: Int) {
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw NoSources()
        }
        var modules: Set<String> = []
        var files = 0
        // `import Foundation` and `@testable import X`. Spaces and tabs only, never `\s`: `\s` matches a newline,
        // so a pattern written with it runs on past the end of the line and captures the next line's first word.
        let expression = try NSRegularExpression(pattern: #"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+([A-Za-z_]\w*)"#,
                                                 options: [.anchorsMatchLines])
        for case let url as URL in enumerator {
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
