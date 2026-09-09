import Foundation
import XCTest

/// Contract W1, the other half of the package-wide walk in `ImportGraphTests`: every non-system
/// module a target's sources import must name a dependency the manifest declares *for that
/// target*. SwiftPM makes a transitive module visible whether or not the target asked for it, so
/// a target can compile today against an edge W1's table never granted, and the manifest reads as
/// a boundary it is not enforcing. Test targets are held to the same rule as sources: a test that
/// names a type from a module its target does not depend on is the same undeclared edge.
///
/// The manifest is read through `swift package dump-package`, never by matching `Package.swift`
/// as text: the file is a Swift program whose dependency lists are built from constants, and a
/// regex over it would answer about the source rather than about the package.
final class DeclaredEdgeTests: XCTestCase {
    /// Modules that belong to the platform rather than to the package graph. No manifest edge
    /// can declare one, so an import of one is never a finding. Listed rather than inferred —
    /// an inferred rule ("anything the package does not define") would exempt exactly the
    /// undeclared edges this test exists to find.
    private static let systemModules: Set<String> = [
        "AVKit",
        "AppKit",
        "CoreFoundation",
        "CoreGraphics",
        "CoreServices",
        "Combine",
        "CryptoKit",
        "Darwin",
        "Dispatch",
        "Foundation",
        "JavaScriptCore",
        "Network",
        "OSLog",
        "Observation",
        "ObjectiveC",
        "PDFKit",
        "QuartzCore",
        "QuickLookUI",
        "Security",
        "Swift",
        "SwiftUI",
        "Synchronization",
        "System",
        "Testing",
        "UniformTypeIdentifiers",
        "WebKit",
        "XCTest",
        "os",
    ]

    /// The package root, from this file's own location.
    private static var workbench: URL {
        URL(filePath: #filePath)                     // .../Workbench/Tests/TerminalCoreTests/DeclaredEdgeTests.swift
            .deletingLastPathComponent()             // .../TerminalCoreTests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // .../Workbench
    }

    func testEveryImportNamesADeclaredDependency() throws {
        let targets = try Self.manifestTargets()
        XCTAssertGreaterThan(
            targets.count,
            0,
            "the manifest dump described \(targets.count) targets; expected more than 0"
        )

        var targetsWithoutSourceDirectory: [String] = []
        var targetsWithoutSwiftFiles: [String] = []
        var unreadableFiles = 0
        var importStatementsMatched = 0
        var undeclared: [String] = []

        for target in targets.sorted(by: { $0.name < $1.name }) {
            let directory = Self.workbench.appending(path: target.sourcePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                targetsWithoutSourceDirectory.append("\(target.name) (\(target.sourcePath))")
                continue
            }

            let scan = Self.importedModules(under: directory, excluding: target.excluded)
            unreadableFiles += scan.unreadableFiles
            importStatementsMatched += scan.statementsMatched
            // A C-family target has no Swift file and no imports to check; a Swift target with
            // none read is a walk that silently found nothing.
            if scan.swiftFilesRead == 0 && !target.isCFamily {
                targetsWithoutSwiftFiles.append(target.name)
            }

            let reachable = scan.modules
                .subtracting(Self.systemModules)
                .subtracting([target.name])
            for module in reachable.subtracting(target.dependencies).sorted() {
                undeclared.append("\(target.name) imports \(module)")
            }
        }

        XCTAssertTrue(
            targetsWithoutSourceDirectory.isEmpty,
            "\(targetsWithoutSourceDirectory.count) targets have no source directory: \(targetsWithoutSourceDirectory)"
        )
        XCTAssertTrue(
            targetsWithoutSwiftFiles.isEmpty,
            "\(targetsWithoutSwiftFiles.count) Swift targets contributed no readable source file: \(targetsWithoutSwiftFiles)"
        )
        XCTAssertEqual(
            unreadableFiles,
            0,
            "the per-target walk could not read \(unreadableFiles) source files"
        )
        XCTAssertGreaterThan(
            importStatementsMatched,
            0,
            "the per-target walk matched \(importStatementsMatched) import statements; expected more than 0"
        )
        XCTAssertTrue(
            undeclared.isEmpty,
            "\(undeclared.count) imports name no dependency the manifest declares for the "
                + "importing target: \(undeclared)"
        )
    }

    /// The walk is only evidence if it reads the C7.1 target it stands next to; a manifest whose
    /// target names stopped matching the directories on disk would otherwise pass silently.
    func testTheManifestDumpNamesTheTargetsOnDisk() throws {
        let names = Set(try Self.manifestTargets().map(\.name))
        let expected: Set<String> = ["TerminalCore", "TerminalCoreTests", "Workbench"]
        let missing = expected.subtracting(names)
        XCTAssertTrue(
            missing.isEmpty,
            "the manifest dump missed \(missing.count) known targets: \(missing.sorted())"
        )
    }

    // MARK: - the manifest

    private struct ManifestTarget {
        let name: String
        let dependencies: Set<String>
        let sourcePath: String
        let excluded: Set<String>
        let isCFamily: Bool
    }

    private static func manifestTargets() throws -> [ManifestTarget] {
        let json = try dumpPackage()
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let rawTargets = root["targets"] as? [[String: Any]] else {
            throw ManifestError.unexpectedShape("no `targets` array in the dump")
        }

        return try rawTargets.map { raw in
            guard let name = raw["name"] as? String, let type = raw["type"] as? String else {
                throw ManifestError.unexpectedShape("a target with no name or type")
            }
            var dependencies: Set<String> = []
            for entry in raw["dependencies"] as? [[String: Any]] ?? [] {
                // `byName` and `target` name a target in this package; `product` names a product
                // of another package, whose module carries the product's name for every
                // dependency this package declares.
                for key in ["byName", "target", "product"] {
                    if let value = entry[key] as? [Any], let first = value.first as? String {
                        dependencies.insert(first)
                    }
                }
            }
            let declaredPath = raw["path"] as? String
            let defaultRoot = type == "test" ? "Tests" : "Sources"
            return ManifestTarget(
                name: name,
                dependencies: dependencies,
                sourcePath: declaredPath ?? "\(defaultRoot)/\(name)",
                excluded: Set(raw["exclude"] as? [String] ?? []),
                // A target with no Swift file of its own: this package's C shim. `dump-package`
                // reports it as `regular`, so the fact is taken from the directory, which is
                // what "has no Swift source" means anyway.
                isCFamily: !hasSwiftFile(under: workbench.appending(path: declaredPath ?? "\(defaultRoot)/\(name)"))
            )
        }
    }

    private enum ManifestError: Error, CustomStringConvertible {
        case unexpectedShape(String)
        case dumpFailed(Int32, String)

        var description: String {
            switch self {
            case let .unexpectedShape(detail): "swift package dump-package: \(detail)"
            case let .dumpFailed(status, output): "swift package dump-package exited \(status): \(output)"
            }
        }
    }

    /// `swift package dump-package`, into a scratch directory of its own so the dump never
    /// contends with the `.build` the test process is running out of. `dump-package` loads the
    /// manifest and resolves nothing, so it cannot rewrite `Package.resolved`.
    private static func dumpPackage() throws -> Data {
        let scratch = URL.temporaryDirectory.appending(path: "workbench-dump-\(UUID().uuidString)")
        let out = scratch.appending(path: "dump.json")
        let err = scratch.appending(path: "dump.err")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "swift", "package", "dump-package",
            "--package-path", workbench.path,
            "--scratch-path", scratch.appending(path: "build").path,
        ]
        process.currentDirectoryURL = workbench
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: out)) ?? Data()
        guard process.terminationStatus == 0, !data.isEmpty else {
            let message = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
            throw ManifestError.dumpFailed(process.terminationStatus, message)
        }
        return data
    }

    // MARK: - the walk

    private struct ImportScan {
        var modules: Set<String> = []
        var statementsMatched = 0
        var swiftFilesRead = 0
        var unreadableFiles = 0
    }

    private static func hasSwiftFile(under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" { return true }
        return false
    }

    /// Spaces and tabs only, never `\s`, for the reason `ImportGraphTests` records: `\s` matches
    /// a newline and can capture the next line's first word.
    private static func importExpression() -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: #"^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*"#,
            options: [.anchorsMatchLines]
        )
    }

    private static func importedModules(under directory: URL, excluding excluded: Set<String>) -> ImportScan {
        let expression = importExpression()
        var scan = ImportScan()
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return scan
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            if excluded.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                scan.unreadableFiles += 1
                continue
            }
            scan.swiftFilesRead += 1
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                scan.statementsMatched += 1
                scan.modules.insert(String(text[name]))
            }
        }
        return scan
    }
}
