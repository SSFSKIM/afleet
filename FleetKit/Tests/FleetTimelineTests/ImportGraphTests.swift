import Foundation
import XCTest
@testable import FleetTimeline

/// Contract X1, asserted rather than trusted: `FleetTimeline` depends on `Foundation`, `CryptoKit`, `AfleetCore` and
/// `ClaudeWire`, plus `CoreServices` in the one watcher file — and on nothing else. An import of AppKit, SwiftUI or a
/// sibling FleetKit target would make this target unusable to the ones that must build without a UI, and a new
/// dependency added by hand to `FleetKit/Package.swift` would take a file C4 owns out from under it.
final class ImportGraphTests: XCTestCase {

    /// `<repo>/`, from this file: FleetKit/Tests/FleetTimelineTests/ImportGraphTests.swift → up four.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static let allowed: Set<String> = ["Foundation", "CryptoKit", "AfleetCore", "ClaudeWire", "CoreServices"]
    /// The single file X1 lets reach for CoreServices, named relative to `Sources/FleetTimeline`.
    private static let coreServicesFile = "Index/TranscriptWatcher.swift"

    func testFleetTimelineImportsOnlyWhatX1Allows() throws {
        let sources = Self.repoRoot.appendingPathComponent("FleetKit/Sources/FleetTimeline", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
                                       "FleetKit/Sources/FleetTimeline is not enumerable")

        var byFile: [String: Set<String>] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(sources.standardizedFileURL.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            var modules: Set<String> = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.hasPrefix("import ") else { continue }
                // `import Foundation`, and also `import struct Foundation.Data`: the module is the first
                // dot-separated component of the last whitespace-separated token.
                guard let token = line.dropFirst(7).split(separator: " ").last,
                      let module = token.split(separator: ".").first else { continue }
                modules.insert(String(module))
            }
            if !modules.isEmpty { byFile[relative] = modules }
        }

        XCTAssertFalse(byFile.isEmpty, "no source file under FleetKit/Sources/FleetTimeline carried an import")

        let all = byFile.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        XCTAssertTrue(all.isSubset(of: Self.allowed),
                      "FleetTimeline imports outside X1: \(all.subtracting(Self.allowed).sorted())")

        let coreServicesUsers = byFile.filter { $0.value.contains("CoreServices") }.keys.sorted()
        XCTAssertEqual(coreServicesUsers, [Self.coreServicesFile],
                       "CoreServices belongs to the watcher alone")

        // The manifest is C4's file. C3 may add only between the two C3 marks; everything outside them must still be
        // `main`'s bytes. Cutting the region from both sides and comparing the remainder says exactly that.
        let manifest = Self.repoRoot.appendingPathComponent("FleetKit/Package.swift")
        let here = try String(contentsOf: manifest, encoding: .utf8)
        let onMain = try Self.gitShow("main:FleetKit/Package.swift")
        let mine = Self.outsideC3Region(here), theirs = Self.outsideC3Region(onMain)
        // Reported as line numbers and counts rather than as two manifests: the whole file in a failure message
        // buries the one line that moved.
        let firstDifference = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(mine.count, theirs.count)
        XCTAssertTrue(mine == theirs,
                      "FleetKit/Package.swift differs from main outside the C3 region: \(mine.count) lines here, "
                      + "\(theirs.count) on main, first difference at line \(firstDifference + 1) of the cut text")
    }

    /// Every line but those from the `C3 timeline group` mark through the `end of C3 group` mark, inclusive.
    private static func outsideC3Region(_ text: String) -> [String] {
        var out: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("// MARK: - C3 timeline group") { inside = true; continue }
            if trimmed.hasPrefix("// MARK: - end of C3 group") { inside = false; continue }
            if !inside { out.append(String(line)) }
        }
        return out
    }

    private static func gitShow(_ object: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path, "show", object]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureCorpus.Failure("git show \(object) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
