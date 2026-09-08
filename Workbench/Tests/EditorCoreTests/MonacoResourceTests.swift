import Foundation
import XCTest

@testable import EditorCore

/// G1.3: the committed Monaco bundle is present in `Bundle.module`, stamped with the version this
/// leaf pinned, accompanied by its licence, and complete in the entry points the view loads.
///
/// The bundle is built by `Tools/build-monaco.sh` and committed whole; nothing here builds it, and
/// a tree without it fails every test in this file. The version is compared against a Swift
/// constant so a Monaco bump that forgets to re-run the script is a test failure and not a
/// runtime surprise.
final class MonacoResourceTests: XCTestCase {

    /// The pinned Monaco release. `VERSION` in the bundle must name exactly this.
    static let pinnedMonacoVersion = "0.56.0"

    /// The bundle's resource directory, as `.copy` lays it out: one directory named for its
    /// source directory, its internal layout preserved.
    private static func monacoDirectory() throws -> URL {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "monaco", withExtension: nil),
            "Bundle.module has no `monaco` resource directory; run Tools/build-monaco.sh"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "`monaco` resolved to a file, not a directory")
        return url
    }

    private static func contents(of name: String) throws -> String {
        let url = try monacoDirectory().appending(path: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing bundle file: \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 1. the stamp and the licence

    func testVersionStampNamesThePinnedMonacoVersion() throws {
        let version = try Self.contents(of: "VERSION")
        XCTAssertFalse(version.isEmpty, "VERSION is empty")

        let monacoLine = try XCTUnwrap(
            version.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("monaco-editor ") }),
            "VERSION names no monaco-editor line"
        )
        XCTAssertEqual(String(monacoLine), "monaco-editor \(Self.pinnedMonacoVersion)")

        XCTAssertTrue(
            version.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("bun ") }),
            "VERSION names no bun version"
        )
    }

    func testMonacoLicenceIsBesideTheBundleAndNamesMIT() throws {
        let licence = try Self.contents(of: "LICENSE")
        XCTAssertFalse(licence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "LICENSE is empty")
        XCTAssertTrue(licence.contains("MIT License"), "LICENSE does not name the MIT License")
    }

    // MARK: - 2. the entry points the view loads

    func testEveryEntryPointExists() throws {
        let directory = try Self.monacoDirectory()
        let entries = [
            "editor.js",
            "editor.worker.js",
            "ts.worker.js",
            "json.worker.js",
            "css.worker.js",
            "html.worker.js",
        ]
        let missing = entries.filter { !FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
        XCTAssertEqual(missing, [], "entry points missing from the bundle")
    }

    // MARK: - 3. cleanliness (G3's half that a filesystem can witness)

    func testBundleCarriesNoInstallOrCacheArtefacts() throws {
        let directory = try Self.monacoDirectory()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "could not enumerate the bundle directory"
        )

        // Names that mean an install directory or a package-manager cache was copied in whole.
        let forbiddenComponents: Set<String> = [
            "node_modules", ".bun", ".bun-cache", ".cache", ".work", "install-cache",
        ]
        let forbiddenNames: Set<String> = ["bun.lock", "bun.lockb", "package.json", "package-lock.json"]

        var offenders: [String] = []
        var fileCount = 0
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            let components = Set(relative.split(separator: "/").map(String.init))
            if !components.isDisjoint(with: forbiddenComponents) || forbiddenNames.contains(url.lastPathComponent) {
                offenders.append(relative)
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { fileCount += 1 }
        }

        XCTAssertEqual(offenders.sorted(), [], "generated or cache artefacts inside the committed bundle")
        XCTAssertGreaterThan(fileCount, 10, "the bundle is implausibly small for a split Monaco build")
    }
}
