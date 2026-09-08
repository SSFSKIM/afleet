import Foundation
import XCTest

/// Contract X1: TerminalCore cannot reach FleetKit or ClaudeWire, and no Workbench source,
/// spike, or test imports one of ClaudeWire's modules. The manifest is one half of that
/// boundary; this source walk is the other, because a manifest cannot say what a Swift file
/// did not import.
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

    private static var terminalCoreSources: ScanRoot {
        ScanRoot(
            name: "TerminalCore",
            url: workbench.appending(path: "Sources/TerminalCore")
        )
    }

    private static var packageRoots: [ScanRoot] {
        ["Sources", "Spikes", "Tests"].map {
            ScanRoot(name: $0, url: workbench.appending(path: $0))
        }
    }

    func testTerminalCoreImportsNeitherFleetKitNorClaudeWire() {
        let scan = Self.importedModules(under: [Self.terminalCoreSources])
        XCTAssertGreaterThanOrEqual(
            scan.filesRead,
            1,
            "TerminalCore scan read \(scan.filesRead) Swift files; expected at least 1"
        )
        XCTAssertTrue(
            scan.rootsNotWalked.isEmpty,
            "TerminalCore scan could not walk \(scan.rootsNotWalked.count) roots: \(scan.rootsNotWalked.sorted())"
        )
        XCTAssertTrue(
            scan.directoriesWithoutSwiftFiles.isEmpty,
            "TerminalCore scan found \(scan.directoriesWithoutSwiftFiles.count) immediate directories with no Swift files read: \(scan.directoriesWithoutSwiftFiles)"
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

    func testNoWorkbenchSwiftFileImportsClaudeWire() {
        let scan = Self.importedModules(under: Self.packageRoots)
        let expectedRoots: Set<String> = ["Sources", "Spikes", "Tests"]
        let missingRoots = expectedRoots.subtracting(scan.rootsWalked)
        let unexpectedRoots = scan.rootsWalked.subtracting(expectedRoots)
        XCTAssertTrue(
            missingRoots.isEmpty && unexpectedRoots.isEmpty,
            "package scan walked \(scan.rootsWalked.count) roots; missing \(missingRoots.sorted()), unexpected \(unexpectedRoots.sorted())"
        )
        XCTAssertTrue(
            scan.rootsNotWalked.isEmpty,
            "package scan could not walk \(scan.rootsNotWalked.count) roots: \(scan.rootsNotWalked.sorted())"
        )
        XCTAssertTrue(
            scan.directoriesWithoutSwiftFiles.isEmpty,
            "package scan found \(scan.directoriesWithoutSwiftFiles.count) immediate directories with no Swift files read: \(scan.directoriesWithoutSwiftFiles)"
        )
        XCTAssertEqual(
            scan.unreadableFiles,
            0,
            "package scan could not read \(scan.unreadableFiles) Swift files"
        )
        XCTAssertGreaterThan(
            scan.importStatementsMatched,
            0,
            "package scan matched \(scan.importStatementsMatched) import statements; expected more than 0"
        )

        let knownModules: Set<String> = ["AfleetCore", "Foundation"]
        let missingKnownModules = knownModules.subtracting(scan.modules)
        XCTAssertTrue(
            missingKnownModules.isEmpty,
            "package scan missed \(missingKnownModules.count) known module imports: \(missingKnownModules.sorted())"
        )

        let forbidden = scan.modules.intersection(Self.claudeWireModules)
        XCTAssertTrue(
            forbidden.isEmpty,
            "package scan found \(forbidden.count) ClaudeWire module imports: \(forbidden.sorted())"
        )
    }

    func testDeclarationImportsCaptureTheOwningModule() {
        let source = [
            "import struct " + "FleetKit.PaneRequest",
            "import class " + "ClaudeWire.Session",
        ].joined(separator: "\n")
        let parsed = Self.importedModules(in: source, matching: Self.importExpression())
        XCTAssertEqual(
            parsed.statementsMatched,
            2,
            "declaration import parser matched \(parsed.statementsMatched) statements; expected 2"
        )

        let expected: Set<String> = ["FleetKit", "ClaudeWire"]
        let missing = expected.subtracting(parsed.modules)
        let unexpected = parsed.modules.subtracting(expected)
        XCTAssertTrue(
            missing.isEmpty && unexpected.isEmpty,
            "declaration import parser found \(parsed.modules.count) modules; missing \(missing.sorted()), unexpected \(unexpected.sorted())"
        )
    }

    private struct ScanRoot {
        let name: String
        let url: URL
    }

    private struct ParsedImports {
        var modules: Set<String> = []
        var statementsMatched = 0
    }

    private struct ImportScan {
        var modules: Set<String> = []
        var importStatementsMatched = 0
        var rootsWalked: Set<String> = []
        var rootsNotWalked: Set<String> = []
        var swiftFilesReadByDirectory: [String: Int] = [:]
        var filesRead = 0
        var unreadableFiles = 0

        var directoriesWithoutSwiftFiles: [String] {
            swiftFilesReadByDirectory
                .filter { $0.value == 0 }
                .map(\.key)
                .sorted()
        }
    }

    private static func importExpression() -> NSRegularExpression {
        // `import Foundation`, `@testable import X`, `@_exported import X`, and
        // declaration imports such as `import struct FleetKit.PaneRequest`.
        try! NSRegularExpression(
            pattern: #"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*"#,
            options: [.anchorsMatchLines]
        )
    }

    private static func importedModules(
        in text: String,
        matching expression: NSRegularExpression
    ) -> ParsedImports {
        var parsed = ParsedImports()
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let name = Range(match.range(at: 1), in: text) else { continue }
            parsed.statementsMatched += 1
            parsed.modules.insert(String(text[name]))
        }
        return parsed
    }

    /// Every module name imported under `roots`, together with evidence that each root and
    /// immediate target directory contributed readable Swift source. Spaces and tabs only,
    /// never `\s`: `\s` matches a newline, so it can capture the next line's first word.
    private static func importedModules(under roots: [ScanRoot]) -> ImportScan {
        let fileManager = FileManager.default
        let expression = importExpression()
        var scan = ImportScan()

        for root in roots {
            guard let immediateEntries = try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: nil
            ) else {
                scan.rootsNotWalked.insert(root.name)
                continue
            }
            scan.rootsWalked.insert(root.name)

            for entry in immediateEntries {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    scan.swiftFilesReadByDirectory["\(root.name)/\(entry.lastPathComponent)"] = 0
                }
            }

            for case let url as URL in enumerator {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    scan.unreadableFiles += 1
                    continue
                }
                scan.filesRead += 1

                let relativeComponents = url.pathComponents.dropFirst(root.url.pathComponents.count)
                if let immediateDirectory = relativeComponents.first {
                    let key = "\(root.name)/\(immediateDirectory)"
                    if scan.swiftFilesReadByDirectory[key] != nil {
                        scan.swiftFilesReadByDirectory[key, default: 0] += 1
                    }
                }

                let parsed = importedModules(in: text, matching: expression)
                scan.importStatementsMatched += parsed.statementsMatched
                scan.modules.formUnion(parsed.modules)
            }
        }
        return scan
    }
}
