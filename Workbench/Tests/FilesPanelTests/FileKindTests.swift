import XCTest
import AppKit
import CoreGraphics
import EditorCore
import SourceControlCore
@testable import FilesPanel

/// T2's five groups: the viewer decision (spec Design §4) and the language map checked against
/// the committed Monaco bundle (spec Design §2).
///
/// Every file this suite looks at is one it created under `FileManager.default.temporaryDirectory`;
/// `open(2)` on the user's content directories is TCC-gated on this machine, and no assertion
/// message below names a path.
final class FileKindTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filespanel-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Group 1: the item-25 corpus

    func testItem25CorpusNamesItsViewer() throws {
        let markdown = try write("notes.md", Data("# a heading\n\nand a line.\n".utf8))
        let png = try write("pixel.png", Self.pngBytes())
        let pdf = try write("page.pdf", Self.singlePagePDFBytes())
        let mp4 = try write("clip.mp4", Self.mp4ContainerBytes())
        let wav = try write("tone.wav", Self.wavBytes())
        let source = try write("sample.swift", Data("struct Sample {}\n".utf8))

        XCTAssertEqual(FileKind.of(url: markdown), .markdown, "a .md names the markdown viewer")
        XCTAssertEqual(FileKind.of(url: png), .image, "a real PNG names the image viewer")
        XCTAssertEqual(FileKind.of(url: pdf), .pdf, "a real single-page PDF names the PDF viewer")
        XCTAssertEqual(FileKind.of(url: mp4), .media, "an MP4 container names the media viewer")
        XCTAssertEqual(FileKind.of(url: wav), .media, "a WAV names the media viewer")
        XCTAssertEqual(FileKind.of(url: source), .code(language: "swift"), "a UTF-8 source file names the editor")
    }

    // MARK: - Group 2: the veto

    func testClaimedImageWithoutTheSignatureIsNotAnImage() throws {
        let liar = try write("claimed.png", Data("this is not a PNG at all\n".utf8))
        XCTAssertEqual(FileKind.of(url: liar), .binary,
                       "an extension-only decision would call this an image; the bytes veto it")

        let truncated = try write("cut.png", Self.pngBytes().prefix(4))
        XCTAssertEqual(FileKind.of(url: truncated), .binary, "a truncated PNG is not an image")

        let fakePDF = try write("claimed.pdf", Data(repeating: 0x7f, count: 64))
        XCTAssertEqual(FileKind.of(url: fakePDF), .binary, "a claimed PDF without the header is vetoed")

        let fakeMedia = try write("claimed.mp4", Data("plain words, no container box\n".utf8))
        XCTAssertEqual(FileKind.of(url: fakeMedia), .binary, "a claimed container without a box is vetoed")
    }

    // MARK: - Group 3: the extensionless tie-break

    func testExtensionlessFilesAreDecidedByTheirLeadingBytes() throws {
        let text = try write("LICENCE", Data("Permission is granted, free of charge.\n".utf8))
        XCTAssertEqual(FileKind.of(url: text), .code(language: "plaintext"),
                       "an extensionless UTF-8 text file opens in the editor as plaintext")

        var bytes = Data()
        var seed: UInt64 = 0x5eed
        for _ in 0..<512 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        bytes[0] = 0x00                      // a NUL in the prefix is what "not text" means
        let opaque = try write("blob", bytes)
        XCTAssertEqual(FileKind.of(url: opaque), .binary, "an extensionless file of non-text bytes is binary")

        let named = try write("Dockerfile", Data("FROM scratch\n".utf8))
        XCTAssertEqual(FileKind.of(url: named), .code(language: "dockerfile"),
                       "a well-known extensionless name is decided by its name")
    }

    // MARK: - Group 4: the cap

    func testAFileAboveTheCapIsRefusedWithoutBeingRead() throws {
        XCTAssertEqual(FileKind.maximumReadableBytes, ToolRunner.defaultOutputLimitBytes,
                       "the cap is the runner's own retained-output cap, not a second number")

        let text = try write("wide.txt", Data(repeating: 0x41, count: 4096))
        XCTAssertEqual(FileKind.of(url: text, maximumBytes: 1_000_000), .code(language: "plaintext"),
                       "under the cap the decision is the normal one")
        XCTAssertEqual(FileKind.of(url: text, maximumBytes: 1024), .binary,
                       "above the cap the decision is refused rather than read")

        // Sparse, so the real cap is exercised without the bytes existing.
        let huge = root.appendingPathComponent("sparse.png", isDirectory: false)
        FileManager.default.createFile(atPath: huge.path, contents: Self.pngBytes())
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(FileKind.maximumReadableBytes) + 1)
        try handle.close()
        XCTAssertEqual(FileKind.of(url: huge), .binary,
                       "a claimed image above the cap is refused before its signature is consulted")
    }

    // MARK: - Group 5: the language map against the committed bundle

    func testEveryMappedLanguageIsRegisteredByTheCommittedBundle() throws {
        let registrations = try Self.bundleRegistrations()
        // Named unconditionally, not only on failure: a parse that found nothing has to be
        // visible in the log rather than passing every check below vacuously.
        print("[G2] parsed \(registrations.count) language registrations from the committed Monaco bundle")
        XCTAssertGreaterThanOrEqual(registrations.count, 80,
                                    "parsed \(registrations.count) language registrations from the committed bundle")
        for expected in ["markdown", "swift", "typescript", "json"] {
            XCTAssertNotNil(registrations[expected], "the parse found the \(expected) registration")
        }

        var byExtension: [String: Set<String>] = [:]
        for (id, extensions) in registrations {
            for ext in extensions { byExtension[ext.lowercased(), default: []].insert(id) }
        }

        let ids = Set(registrations.keys)
        var unregisteredIDs: Set<String> = []
        var disagreeingExtensions: Set<String> = []

        for (ext, id) in MonacoLanguage.extensionMap {
            if !ids.contains(id) { unregisteredIDs.insert(id) }
            guard let bundleIDs = byExtension["." + ext] else { disagreeingExtensions.insert(ext); continue }
            if !bundleIDs.contains(id) { disagreeingExtensions.insert(ext) }
        }
        for (name, id) in MonacoLanguage.filenameMap {
            if !ids.contains(id) { unregisteredIDs.insert(id) }
            // The bundle keys a leading-dot well-known name as an "extension", so those are
            // checked against the same table; a name without a dot (Dockerfile) is ours alone.
            if name.hasPrefix("."), let bundleIDs = byExtension[name], !bundleIDs.contains(id) {
                disagreeingExtensions.insert(name)
            }
        }

        XCTAssertTrue(unregisteredIDs.isEmpty,
                      "\(unregisteredIDs.count) emitted language ids are not registered by the bundle: \(unregisteredIDs.sorted())")
        XCTAssertTrue(disagreeingExtensions.isEmpty,
                      "\(disagreeingExtensions.count) mapped extensions disagree with the bundle: \(disagreeingExtensions.sorted())")

        XCTAssertEqual(MonacoLanguage.id(for: URL(fileURLWithPath: "/tmp/a/b.swift")), "swift")
        XCTAssertEqual(MonacoLanguage.id(for: URL(fileURLWithPath: "/tmp/a/b.UNKNOWNEXT")), "plaintext",
                       "an unmapped extension is plaintext, which is what Monaco would have inferred")
        XCTAssertEqual(MonacoLanguage.id(for: URL(fileURLWithPath: "/tmp/a/Dockerfile")), "dockerfile")
        XCTAssertEqual(MonacoLanguage.id(for: URL(fileURLWithPath: "/tmp/a/b.MD")), "markdown",
                       "the extension is matched lowercased")
    }

    // MARK: - The bundle parse

    /// Every `{id:"…", …, extensions:[…]}` registration in the committed Monaco bundle.
    ///
    /// The intervening-key alternation is load-bearing: `swift` registers its `aliases` between
    /// `id` and `extensions`, so a pattern that demands the two be adjacent silently loses it
    /// (and with it the one extension this repository is written in).
    private static func bundleRegistrations() throws -> [String: Set<String>] {
        let directory = try XCTUnwrap(EditorResources.monacoDirectoryURL, "the committed Monaco bundle is reachable")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".js") }
        XCTAssertFalse(names.isEmpty, "the bundle directory holds script chunks to parse")

        let pattern = #"id:"([A-Za-z0-9_.+-]+)"(?:,[a-zA-Z]+:(?:\[[^\]]*\]|"[^"]*"|[A-Za-z0-9_$]+))*?,extensions:\[([^\]]*)\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let quoted = try NSRegularExpression(pattern: #""([^"]+)""#)

        var out: [String: Set<String>] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: whole) {
                guard let idRange = Range(match.range(at: 1), in: text),
                      let listRange = Range(match.range(at: 2), in: text) else { continue }
                let id = String(text[idRange])
                let list = String(text[listRange])
                var extensions: Set<String> = []
                for inner in quoted.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
                    if let r = Range(inner.range(at: 1), in: list) { extensions.insert(String(list[r])) }
                }
                out[id, default: []].formUnion(extensions)
            }
        }
        return out
    }

    // MARK: - Corpus

    @discardableResult
    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    /// A genuine 1×1 PNG, encoded by the system rather than typed out.
    private static func pngBytes() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 4, bitsPerPixel: 32)!
        rep.setColor(.white, atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    /// A genuine single-page PDF, drawn by Core Graphics.
    private static func singlePagePDFBytes() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// An `ftyp` box: the first box of every ISO base media container, which is the thing the
    /// decision reads. Written out by hand rather than encoded, so the suite needs no muxer.
    private static func mp4ContainerBytes() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(contentsOf: Array("ftypisom".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        data.append(contentsOf: Array("isomiso2".utf8))
        data.append(Data(repeating: 0, count: 16))
        return data
    }

    /// A valid RIFF/WAVE header over a few samples of silence.
    private static func wavBytes() -> Data {
        let samples = Data(repeating: 0, count: 64)
        var data = Data(Array("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples.count).littleEndian) { Array($0) })
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(44100).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(88200).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(samples.count).littleEndian) { Array($0) })
        data.append(samples)
        return data
    }
}
