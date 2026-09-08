import Foundation
import XCTest

@testable import EditorCore

/// The split Monaco build emits stylesheets that **no JavaScript in the bundle references**: a
/// `grep` for a `.css` specifier across all of the emitted JS files finds nothing. CSS therefore
/// arrives only if the bootstrap document asks for it, and two of the three stylesheets carry
/// content-hashed names (`tsMode-<hash>.css`, `freemarker2-<hash>.css`) that change at the next
/// Monaco bump.
///
/// So `Tools/build-monaco.sh` writes two generated artefacts beside the bundle it produces:
///
/// * `styles.json` — the manifest: every stylesheet bun emitted, sorted, as a JSON array. This is
///   the machine-readable source of truth, and what these tests assert against.
/// * `styles.css` — the same list as `@import` rules, which is what `bootstrap/index.html` links.
///   A stylesheet is the one loader that works under all three of S3's routes without a network
///   fetch: `@import` resolves relative to the importing stylesheet's own URL, so it is correct on
///   the custom scheme and under `loadFileURL` alike, while `fetch()` of a sibling `file:` URL is
///   refused by WebKit outright.
///
/// The failure these tests exist to catch is silent drift: a future Monaco emitting a fourth
/// stylesheet that nobody remembers to link, or a hashed name creeping back into the hand-written
/// document. Neither is visible at runtime as anything but slightly wrong colours.
final class MonacoStylesheetManifestTests: XCTestCase {

    /// The generated manifest, and the generated loader `index.html` links.
    static let manifestName = "styles.json"
    static let loaderName = "styles.css"

    private static func monacoDirectory() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "monaco", withExtension: nil),
            "Bundle.module has no `monaco` resource directory; run Tools/build-monaco.sh"
        )
    }

    /// Every `.css` file in the bundle directory *except* the loader the build script writes
    /// itself. The exclusion is the one name the script authors; everything else in this list came
    /// out of `bun build`, which is precisely the set the manifest has to name.
    private static func emittedStylesheets() throws -> [String] {
        let directory = try monacoDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0.hasSuffix(".css") && $0 != loaderName }
            .sorted()
    }

    private static func manifest() throws -> [String] {
        let url = try monacoDirectory().appending(path: manifestName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "the bundle carries no \(manifestName); re-run Tools/build-monaco.sh"
        )
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String], "\(manifestName) is not a JSON array of strings")
    }

    // MARK: - the manifest names what the build actually emitted

    func testManifestNamesEveryStylesheetTheBundleContains() throws {
        let manifest = try Self.manifest()
        let emitted = try Self.emittedStylesheets()

        XCTAssertFalse(emitted.isEmpty, "the bundle contains no stylesheets at all")
        XCTAssertEqual(
            manifest, emitted,
            "\(Self.manifestName) disagrees with the stylesheets in the bundle; re-run Tools/build-monaco.sh"
        )
        XCTAssertEqual(manifest, manifest.sorted(), "\(Self.manifestName) is not sorted, so it is not deterministic")
    }

    func testEveryNameTheManifestListsExists() throws {
        let directory = try Self.monacoDirectory()
        let missing = try Self.manifest().filter {
            !FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
        XCTAssertEqual(missing, [], "\(Self.manifestName) names files the bundle does not contain")
    }

    /// The loader is generated from the same list in the same run, so this can only fail if one of
    /// the two writes was changed without the other.
    func testLoaderImportsExactlyTheManifest() throws {
        let loader = try String(
            contentsOf: try Self.monacoDirectory().appending(path: Self.loaderName),
            encoding: .utf8
        )
        let imported = loader.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("@import \"") , line.hasSuffix("\";") else { return nil }
            return String(line.dropFirst(9).dropLast(2))
        }
        XCTAssertEqual(imported, try Self.manifest(), "\(Self.loaderName) does not import what \(Self.manifestName) names")
    }

    // MARK: - the document links the loader and hard-codes no hash

    func testBootstrapDocumentLinksTheGeneratedLoader() throws {
        let document = try String(
            contentsOf: try XCTUnwrap(EditorResources.bootstrapDocumentURL, "no bootstrap document in Bundle.module"),
            encoding: .utf8
        )
        XCTAssertTrue(
            document.contains("../monaco/\(Self.loaderName)"),
            "index.html does not link the generated stylesheet loader"
        )
    }

    func testBootstrapDocumentHardCodesNoContentHashedStylesheet() throws {
        let document = try String(
            contentsOf: try XCTUnwrap(EditorResources.bootstrapDocumentURL, "no bootstrap document in Bundle.module"),
            encoding: .utf8
        )
        // Any stylesheet whose name carries a build hash, spelled by the prefix bun gives it. A
        // literal here is a name that changes at the next Monaco bump and breaks silently.
        for hashedPrefix in ["tsMode-", "freemarker2-"] {
            XCTAssertFalse(
                document.contains(hashedPrefix),
                "index.html hard-codes the content-hashed stylesheet name \(hashedPrefix)…"
            )
        }
        // And the general form: every stylesheet the document actually links must be the
        // generated loader. Prose about `.css` in the comments is not a link, so this reads the
        // href values rather than the text.
        let hrefPattern = try NSRegularExpression(pattern: "href=\"([^\"]*)\"")
        let range = NSRange(document.startIndex..<document.endIndex, in: document)
        let linked = hrefPattern.matches(in: document, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: document) else { return nil }
            let value = String(document[valueRange])
            return value.hasSuffix(".css") ? value : nil
        }
        XCTAssertEqual(
            linked, ["../monaco/\(Self.loaderName)"],
            "index.html links a stylesheet other than the generated loader"
        )
    }
}
