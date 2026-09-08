import Foundation
import XCTest

@testable import EditorCore

/// The `afleet-editor` scheme handler's decidable half: which file a request path names, and
/// what MIME type it is served with.
///
/// `MonacoEditorView` itself is deliberately untested here — a web view in a package test buys a
/// slow test that proves WebKit works, and S3 is its verification (spec Design §6). What is
/// tested is the logic that can be wrong in a way nothing else would notice: a traversal that
/// gets served, or a module script served as `application/octet-stream`, which WebKit refuses.
///
/// The root used below is a temporary directory, not the real bundle, so these tests state the
/// rule rather than the layout of whatever Monaco version happens to be committed.
final class EditorResourceLocatorTests: XCTestCase {

    private var root: URL!
    private var locator: EditorResourceLocator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditorResourceLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("monaco"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try Data("// editor".utf8).write(to: root.appendingPathComponent("monaco/editor.js"))
        try Data("<!DOCTYPE html>".utf8).write(to: root.appendingPathComponent("bootstrap/index.html"))
        locator = EditorResourceLocator(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        locator = nil
        try super.tearDownWithError()
    }

    /// The canonical form the resolver produces, for comparison: `/var` on macOS is a symlink to
    /// `/private/var`, so a raw string comparison against `root.path` would fail for a reason
    /// that has nothing to do with the rule under test.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - 1. resolution inside the root

    func testResolvesAPathInsideTheRoot() throws {
        let url = try locator.existingFileURL(forRequestPath: "/monaco/editor.js")
        XCTAssertEqual(url.path, canonical(root.appendingPathComponent("monaco/editor.js").path))
    }

    func testLeadingSlashAndRedundantSeparatorsAreEquivalent() throws {
        let plain = try locator.fileURL(forRequestPath: "/bootstrap/index.html")
        let noisy = try locator.fileURL(forRequestPath: "//bootstrap///./index.html")
        XCTAssertEqual(plain, noisy)
    }

    func testPercentEncodingIsDecodedBeforeResolution() throws {
        let url = try locator.fileURL(forRequestPath: "/monaco/editor%2Ejs")
        XCTAssertEqual(url.path, canonical(root.appendingPathComponent("monaco/editor.js").path))
    }

    func testAPathInsideTheRootThatNamesNothingIsNotFound() {
        XCTAssertThrowsError(try locator.existingFileURL(forRequestPath: "/monaco/absent.js")) { error in
            XCTAssertEqual(error as? EditorResourceLocator.Failure, .notFound)
        }
    }

    func testADirectoryIsRefusedRatherThanRead() {
        XCTAssertThrowsError(try locator.existingFileURL(forRequestPath: "/monaco")) { error in
            XCTAssertEqual(error as? EditorResourceLocator.Failure, .notFound)
        }
    }

    func testAnEmptyPathIsRefused() {
        for path in ["", "/", "///", "/./"] {
            XCTAssertThrowsError(try locator.fileURL(forRequestPath: path), "accepted \(path)") { error in
                XCTAssertEqual(error as? EditorResourceLocator.Failure, .emptyPath, "for \(path)")
            }
        }
    }

    // MARK: - 2. the containment rule — a traversal fails closed

    /// The rule this file exists for. Each spelling below is refused, and the assertion is on
    /// the refusal and not merely on "did not return the secret", because a resolver that threw
    /// `notFound` for a path that *does* exist outside the root would be a pass by accident.
    func testTraversalOutOfTheRootIsRefused() throws {
        // A real file outside the root, so a resolver that escaped would succeed rather than
        // fail on the filesystem. It is a sibling of the root, in the same temporary directory.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("EditorResourceLocatorTests-outside-\(UUID().uuidString).js")
        try Data("// outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let escapes = [
            "/../\(outside.lastPathComponent)",
            "/monaco/../../\(outside.lastPathComponent)",
            "/../../../../../../etc/passwd",
            "/%2e%2e/\(outside.lastPathComponent)",
            "/monaco/%2E%2E/%2E%2E/\(outside.lastPathComponent)",
            "/..",
        ]

        for path in escapes {
            XCTAssertThrowsError(try locator.fileURL(forRequestPath: path), "served \(path)") { error in
                XCTAssertEqual(error as? EditorResourceLocator.Failure, .escapesRoot, "for \(path)")
            }
        }
    }

    /// A traversal that stays inside is refused too. It is never a legitimate request from the
    /// bundle, and narrowing the rule to escaping traversals only buys a second way to be wrong.
    func testAnInnocentTraversalIsAlsoRefused() {
        XCTAssertThrowsError(try locator.fileURL(forRequestPath: "/monaco/../bootstrap/index.html")) { error in
            XCTAssertEqual(error as? EditorResourceLocator.Failure, .escapesRoot)
        }
    }

    /// A symlink inside the bundle pointing out of it is the traversal the component scan cannot
    /// see; the containment check after canonicalisation is what catches it.
    func testASymlinkLeadingOutOfTheRootIsRefused() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("EditorResourceLocatorTests-target-\(UUID().uuidString).js")
        try Data("// outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("monaco/escape.js")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try locator.fileURL(forRequestPath: "/monaco/escape.js")) { error in
            XCTAssertEqual(error as? EditorResourceLocator.Failure, .escapesRoot)
        }
    }

    func testAPathContainingNULIsRefused() {
        XCTAssertThrowsError(try locator.fileURL(forRequestPath: "/monaco/editor.js\u{0}/../../etc/passwd")) { error in
            XCTAssertEqual(error as? EditorResourceLocator.Failure, .escapesRoot)
        }
    }

    // MARK: - 3. MIME types

    /// The four the committed bundle actually contains. Getting one wrong is not subtle: WebKit
    /// refuses a module script that is not JavaScript and drops a stylesheet that is not
    /// `text/css`, and the editor simply never comes up.
    func testMIMETypesOfTheBundlesOwnFileKinds() {
        let expected: [String: String] = [
            "monaco/editor.js": "text/javascript",
            "monaco/ts.worker.js": "text/javascript",
            "monaco/editor.css": "text/css",
            "monaco/codicon-ce529ykc.ttf": "font/ttf",
            "bootstrap/index.html": "text/html",
        ]
        for (path, mimeType) in expected {
            XCTAssertEqual(
                EditorResourceLocator.mimeType(for: URL(fileURLWithPath: path)),
                mimeType,
                "wrong MIME type for \(path)"
            )
        }
    }

    func testAnUnknownExtensionIsServedAsOpaqueBytesRatherThanRefused() {
        XCTAssertEqual(
            EditorResourceLocator.mimeType(for: URL(fileURLWithPath: "monaco/mystery.bin")),
            "application/octet-stream"
        )
        XCTAssertEqual(
            EditorResourceLocator.mimeType(for: URL(fileURLWithPath: "monaco/no-extension")),
            "application/octet-stream"
        )
    }

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(EditorResourceLocator.mimeType(for: URL(fileURLWithPath: "a/B.JS")), "text/javascript")
        XCTAssertEqual(EditorResourceLocator.mimeType(for: URL(fileURLWithPath: "a/B.TTF")), "font/ttf")
    }

    func testTextTypesCarryAnEncodingAndBinaryTypesDoNot() {
        XCTAssertEqual(EditorResourceLocator.textEncodingName(forMIMEType: "text/javascript"), "utf-8")
        XCTAssertEqual(EditorResourceLocator.textEncodingName(forMIMEType: "text/css"), "utf-8")
        XCTAssertEqual(EditorResourceLocator.textEncodingName(forMIMEType: "application/json"), "utf-8")
        XCTAssertNil(EditorResourceLocator.textEncodingName(forMIMEType: "font/ttf"))
        XCTAssertNil(EditorResourceLocator.textEncodingName(forMIMEType: "application/octet-stream"))
    }

    // MARK: - 4. the real bundle, through the same rule

    /// One check that the rule and the committed layout agree: the entry points the view loads
    /// resolve through the locator built on `Bundle.module`'s own root.
    func testTheCommittedBundleResolvesThroughTheSameRule() throws {
        let root = try XCTUnwrap(EditorResources.resourceRootURL, "Bundle.module has no resource root")
        let bundleLocator = EditorResourceLocator(root: root)
        for path in ["/bootstrap/index.html", "/bootstrap/bridge.js", "/monaco/editor.js", "/monaco/editor.worker.js"] {
            XCTAssertNoThrow(try bundleLocator.existingFileURL(forRequestPath: path), "unresolvable: \(path)")
        }
    }
}
