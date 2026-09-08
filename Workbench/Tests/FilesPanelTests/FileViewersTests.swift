// The native surfaces of spec Design §4, at the two seams a headless test can see: the block
// structure the markdown viewer renders, and the identity the preview views reload on.
//
// Every file these tests build lives under `FileManager.default.temporaryDirectory`, and every
// assertion names a count, a set or a shape — never a path and never a buffer (§6.3, §11).
import Foundation
import PDFKit
import XCTest
@testable import FilesPanel

@MainActor
final class FileViewersTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afleet-c7.5-viewers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - 1. Markdown is rendered as blocks, not as one run of prose

    /// Item 25 asks for a `.md` to open in its *native viewer*. A parse that keeps only inline
    /// syntax gives a heading, a list, a quote and a fence the shape of a paragraph, so what this
    /// asserts is the block sequence the renderer draws from — what a test can see, rather than
    /// how it looks.
    func testTheBlockSequenceOfADocumentWithEveryBlockKind() {
        let document = """
        # Title

        Some *text*.

        - one
        - two

        > a quote

        ```swift
        let x = 1
        ```
        """

        XCTAssertEqual(MarkdownViewer.blocks(of: document), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text*."),
            .list(ordered: false, items: ["one", "two"]),
            .quote("a quote"),
            .code("let x = 1"),
        ], "the document did not parse into its blocks")
    }

    /// A fence is verbatim: nothing inside it is read as structure.
    func testAFenceIsVerbatim() {
        let document = """
        ```
        # not a heading
        - not a list
        ```
        """

        XCTAssertEqual(MarkdownViewer.blocks(of: document),
                       [.code("# not a heading\n- not a list")],
                       "structure was read inside a fence")
    }

    /// An ordered list is one block, and its markers are not part of its items.
    func testAnOrderedListIsOneBlock() {
        XCTAssertEqual(MarkdownViewer.blocks(of: "1. first\n2. second\n"),
                       [.list(ordered: true, items: ["first", "second"])])
    }

    // MARK: - 2. A preview reloads when the bytes at the same URL change

    /// The agent edits the file that is open in a preview. The path does not move, so a view that
    /// compares URLs keeps the old render; what it compares has to be something that changes when
    /// the contents do.
    func testAPDFPreviewReloadsWhenTheContentsChange() throws {
        let target = root.appendingPathComponent("paper.pdf")
        try Self.pdf(pages: 1).write(to: target)

        let view = PDFViewer(url: target, revision: "one").makeView()
        XCTAssertEqual(view.document?.pageCount, 1, "the premise did not hold: nothing was loaded")

        try Self.pdf(pages: 3).write(to: target)
        PDFViewer(url: target, revision: "two").load(into: view)

        XCTAssertEqual(view.document?.pageCount, 3, "the preview kept the render of the old bytes")
    }

    /// The same rule for the other two native previews, at the identity they reload on: the
    /// player's item and Quick Look's preview are replaced when the revision moves, and are left
    /// alone when it does not.
    func testTheMediaAndQuickLookPreviewsReloadOnTheRevisionAndNotOnTheURL() throws {
        let media = root.appendingPathComponent("clip.wav")
        try Data("RIFF".utf8).write(to: media)
        let mediaView = MediaViewer(url: media, revision: "one").makeView()
        let firstPlayer = mediaView.player
        XCTAssertNotNil(firstPlayer, "the premise did not hold: nothing was played")
        MediaViewer(url: media, revision: "one").load(into: mediaView)
        XCTAssertTrue(mediaView.player === firstPlayer, "an unchanged revision replaced the player")
        MediaViewer(url: media, revision: "two").load(into: mediaView)
        XCTAssertFalse(mediaView.player === firstPlayer, "a changed revision kept the old player")

        let document = root.appendingPathComponent("notes.rtf")
        try Data("{\\rtf1}".utf8).write(to: document)
        let quickLook = QuickLookViewer(url: document, revision: "one").makeView()
        XCTAssertEqual(quickLook.loadCount, 1, "the premise did not hold: nothing was previewed")
        QuickLookViewer(url: document, revision: "one").load(into: quickLook)
        XCTAssertEqual(quickLook.loadCount, 1, "an unchanged revision reloaded the preview")
        QuickLookViewer(url: document, revision: "two").load(into: quickLook)
        XCTAssertEqual(quickLook.loadCount, 2, "a changed revision did not reload the preview")
    }

    /// A PDF of `pages` blank pages, built in memory: the bytes are this test's own.
    private static func pdf(pages: Int) throws -> Data {
        let document = PDFDocument()
        for index in 0..<pages { document.insert(PDFPage(), at: index) }
        guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
