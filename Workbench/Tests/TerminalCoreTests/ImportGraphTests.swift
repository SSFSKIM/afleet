import Foundation
import XCTest

/// Contract X1: TerminalCore cannot reach FleetKit or ClaudeWire, and no Workbench source
/// imports one of ClaudeWire's modules. The manifest is one half of that boundary; this
/// source walk is the other, because a manifest cannot say what a source file did not import.
final class ImportGraphTests: XCTestCase {
    private static let claudeWireModules: Set<String> = [
        "ClaudeWire",
        "WireFrames",
        "WireMCP",
        "WireEnvironment",
        "WireDiagnostics",
        "WireTransport",
        "WireTestSupport",
    ]

    private static let terminalCoreForbiddenModules = claudeWireModules.union(["FleetKit"])

    /// The package root, from this file's own location.
    private static var workbench: URL {
        URL(filePath: #filePath)                     // .../Workbench/Tests/TerminalCoreTests/ImportGraphTests.swift
            .deletingLastPathComponent()             // .../TerminalCoreTests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // .../Workbench
    }

    private static var terminalCoreSources: URL {
        workbench.appending(path: "Sources/TerminalCore")
    }

    private static var packageSources: URL {
        workbench.appending(path: "Sources")
    }

    func testTerminalCoreImportsNeitherFleetKitNorClaudeWire() {
        let scan = Self.importedModules(under: Self.terminalCoreSources)
        XCTAssertGreaterThanOrEqual(
            scan.filesRead,
            1,
            "TerminalCore scan read \(scan.filesRead) Swift files; expected at least 1"
        )
        XCTAssertEqual(
            scan.unreadableFiles,
            0,
            "TerminalCore scan could not read \(scan.unreadableFiles) Swift files"
        )

        let forbidden = scan.modules.intersection(Self.terminalCoreForbiddenModules)
        XCTAssertTrue(
            forbidden.isEmpty,
            "TerminalCore found \(forbidden.count) forbidden module imports: \(forbidden.sorted())"
        )
    }

    func testNoWorkbenchSourceImportsClaudeWire() {
        let scan = Self.importedModules(under: Self.packageSources)
        XCTAssertGreaterThanOrEqual(
            scan.directoriesVisited,
            10,
            "package source scan visited \(scan.directoriesVisited) directories; expected at least 10"
        )
        XCTAssertGreaterThanOrEqual(
            scan.filesRead,
            18,
            "package source scan read \(scan.filesRead) Swift files; expected at least 18"
        )
        XCTAssertEqual(
            scan.unreadableFiles,
            0,
            "package source scan could not read \(scan.unreadableFiles) Swift files"
        )

        let forbidden = scan.modules.intersection(Self.claudeWireModules)
        XCTAssertTrue(
            forbidden.isEmpty,
            "package source scan found \(forbidden.count) ClaudeWire module imports: \(forbidden.sorted())"
        )
    }

    private struct ImportScan {
        var modules: Set<String> = []
        var directoriesVisited = 0
        var filesRead = 0
        var unreadableFiles = 0
    }

    /// Every module name imported under `root`, together with floors that prove the source
    /// tree was reachable. Spaces and tabs only, never `\s`: `\s` matches a newline, so a
    /// pattern written with it can capture the next line's first word.
    private static func importedModules(under root: URL) -> ImportScan {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return ImportScan()
        }

        var scan = ImportScan()
        // `import Foundation`, `@testable import X`, and `@_exported import X`.
        let expression = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+([A-Za-z_]\w*)"#,
            options: [.anchorsMatchLines]
        )

        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                scan.directoriesVisited += 1
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                scan.unreadableFiles += 1
                continue
            }
            scan.filesRead += 1
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                scan.modules.insert(String(text[name]))
            }
        }
        return scan
    }
}
