import Foundation
import AppKit
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 7: what a paste or a drop is allowed to put on a message.
///
/// Every image here is drawn by this suite — a two-by-two bitmap written out in each format — and
/// nothing is read from disk or from a fixture (§11, X9). The over-cap arm is synthesised rather
/// than drawn: it is PNG magic bytes followed by filler, which is what the pass-through path
/// receives, and drawing eight megabytes of noise to say the same thing would spend seconds per run.
@MainActor
final class AttachmentTests: XCTestCase {

    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("b"))
    }

    private func makeModel(_ double: ComposerLifecycleDouble) -> ComposerModel {
        ComposerModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    /// A two-by-two bitmap in one of the formats the pasteboard offers.
    private func image(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 8, bitsPerPixel: 32),
                                "this machine could not allocate a 2x2 bitmap")
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.systemBlue, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: type, properties: [:]),
                             "this machine could not write the 2x2 bitmap in the requested format")
    }

    /// The base64 an attachment carries, decoded back to bytes.
    private func bytes(of attachment: ImageAttachment) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: attachment.base64), "the attachment's base64 does not decode")
    }

    // MARK: - Media types and conversion

    /// PNG and JPEG travel as they arrived; a format that is neither is converted to PNG.
    func testNonPNGOrJPEGImagesAreConvertedToPNG() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)

        let png = try image(.png)
        let tiff = try image(.tiff)
        XCTAssertEqual(ImageIntake.mediaType(of: png), "image/png", "the drawn PNG did not sniff as one")
        XCTAssertEqual(ImageIntake.mediaType(of: tiff), "image/tiff", "the drawn TIFF did not sniff as one")

        XCTAssertEqual(model.attach([png, tiff]), 2, "the tray took \(model.attachments.count) of 2 images")
        XCTAssertEqual(model.attachments.map(\.mediaType), ["image/png", "image/png"],
                       "an image arrived on the message as something other than PNG")
        XCTAssertEqual(try bytes(of: model.attachments[0]), png,
                       "the PNG was re-encoded rather than passed through, changing \(png.count) byte(s)")
        XCTAssertNotEqual(try bytes(of: model.attachments[1]), tiff,
                          "the TIFF travelled as it arrived, mislabelled as a PNG")
        XCTAssertEqual(ImageIntake.mediaType(of: try bytes(of: model.attachments[1])), "image/png",
                       "the converted image's bytes are not a PNG")
        XCTAssertNil(model.attachmentNote, "the tray refused something it took")
    }

    /// Bytes that are not an image are refused and counted, not attached and not dropped silently.
    func testSomethingThatIsNotAnImageIsRefusedWithANote() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)

        XCTAssertEqual(model.attach([Data("not an image at all".utf8)]), 0,
                       "the tray took \(model.attachments.count) non-image item(s)")
        XCTAssertEqual(model.attachments.count, 0, "the tray holds \(model.attachments.count) item(s)")
        XCTAssertNotNil(model.attachmentNote, "a refused item was dropped with nothing said")
    }

    // MARK: - The caps

    /// The two numbers the spec states, pinned.
    ///
    /// The arms below derive their counts from these constants, which is what keeps their failure
    /// messages honest — and is also why a mutation of either constant passes them. So the numbers
    /// themselves are asserted here, once: they are a design decision a reviewer argued with, not an
    /// implementation detail.
    func testTheCapsAreTheOnesTheSpecStates() {
        XCTAssertEqual(ImageIntake.maxImages, 8, "the image cap is \(ImageIntake.maxImages), not the 8 the spec states")
        XCTAssertEqual(ImageIntake.maxBytesEach, 8 * 1024 * 1024,
                       "the size cap is \(ImageIntake.maxBytesEach / (1024 * 1024)) MiB, not the 8 MiB the spec states")
    }

    /// Eight images on one message, and the ninth is refused inline.
    func testTheEighthImageIsTakenAndTheNinthIsRefused() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let png = try image(.png)

        let accepted = model.attach(Array(repeating: png, count: ImageIntake.maxImages + 1))

        XCTAssertEqual(accepted, ImageIntake.maxImages,
                       "the tray took \(accepted) image(s) of the \(ImageIntake.maxImages + 1) offered")
        XCTAssertEqual(model.attachments.count, ImageIntake.maxImages,
                       "the tray holds \(model.attachments.count) image(s)")
        let note = try XCTUnwrap(model.attachmentNote, "the image past the cap was refused with nothing said")
        XCTAssertTrue(note.contains("\(ImageIntake.maxImages)"),
                      "the note of \(note.count) character(s) does not state the cap")
    }

    /// An image larger than the per-image cap is refused, and one just under it is taken — so a tray
    /// that refused everything could not pass.
    func testAnImagePastTheByteCapIsRefusedAndOneUnderItIsTaken() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let magic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let under = magic + Data(count: ImageIntake.maxBytesEach - magic.count)
        let over = magic + Data(count: ImageIntake.maxBytesEach)
        XCTAssertEqual(under.count, ImageIntake.maxBytesEach, "the under-cap image is \(under.count) byte(s)")
        XCTAssertGreaterThan(over.count, ImageIntake.maxBytesEach, "the over-cap image is \(over.count) byte(s)")

        XCTAssertEqual(model.attach([under]), 1, "an image exactly at the cap was refused")
        XCTAssertNil(model.attachmentNote, "an image at the cap was refused with a note")
        XCTAssertEqual(model.attach([over]), 0, "an image past the cap was taken")
        XCTAssertEqual(model.attachments.count, 1, "the tray holds \(model.attachments.count) image(s), not 1")
        let note = try XCTUnwrap(model.attachmentNote, "the image past the cap was refused with nothing said")
        XCTAssertTrue(note.contains("\(ImageIntake.maxBytesEach / (1024 * 1024))"),
                      "the note of \(note.count) character(s) does not state the size cap")
    }

    /// The cap is applied **after** conversion, to the bytes that travel.
    func testTheByteCapIsAppliedToTheConvertedBytes() throws {
        let tiff = try image(.tiff)
        let candidate = try XCTUnwrap(ImageIntake.normalized(tiff), "the drawn TIFF did not normalize")
        XCTAssertEqual(candidate.byteCount, try bytes(of: candidate.attachment).count,
                       "the size the cap reads is not the size of the bytes that travel")
        XCTAssertNotEqual(candidate.byteCount, tiff.count,
                          "the converted image is byte-identical to the one that arrived, so this arm proves nothing")
    }

    // MARK: - What the message carries

    /// The attachments travel on the `UserInput` and are cleared when it is sent.
    func testAttachmentsTravelOnTheSentInputAndAreCleared() async throws {
        let double = ComposerLifecycleDouble()
        await double.alwaysSendPrompt(.success(UUID()))
        let model = makeModel(double)
        model.attach([try image(.png), try image(.tiff)])
        model.draft = "an invented message with pictures"

        await model.send()

        let prompts = await double.prompts
        XCTAssertEqual(prompts.count, 1, "one send produced \(prompts.count) prompt(s)")
        let input = try XCTUnwrap(prompts.first, "the send reached no prompt")
        XCTAssertEqual(input.images.count, 2, "the message carried \(input.images.count) image(s), not 2")
        XCTAssertEqual(input.images.map(\.mediaType), ["image/png", "image/png"],
                       "the message carried an image the engine was told the wrong type for")
        XCTAssertEqual(model.attachments.count, 0,
                       "\(model.attachments.count) image(s) stayed on the tray after the message that carried them")
        XCTAssertEqual(model.draft.count, 0, "the field kept \(model.draft.count) character(s) after a send")
    }

    /// A refused send keeps the images exactly as it keeps the words.
    func testARefusedSendKeepsTheAttachments() async throws {
        let double = ComposerLifecycleDouble()
        await double.alwaysSendPrompt(.failure(.busy(.spawn)))
        let model = makeModel(double)
        model.attach([try image(.png)])
        let typed = "an invented message with a picture"
        model.draft = typed

        await model.send()

        XCTAssertEqual(model.attachments.count, 1,
                       "a refused send left \(model.attachments.count) image(s) on the tray, not the 1 attached")
        XCTAssertEqual(model.draft.count, typed.count,
                       "a refused send left \(model.draft.count) of the \(typed.count) character(s) in the field")
    }

    /// The images the message carried leave the tray **by identity**, not by count.
    ///
    /// The tray stays live across the send's await: the user can remove a chip and attach another
    /// while the prompt is in flight. Dropping "the first N" then deletes whatever is now in front —
    /// a picture the user just attached and has not sent — while the sent one stays behind.
    ///
    /// Deliberate break: drop the first `images.count` attachments after the await → the new image is
    /// the one that disappears.
    func testOnlyTheImagesThatWereSentLeaveTheTray() async throws {
        let double = ComposerLifecycleDouble()
        await double.alwaysSendPrompt(.success(UUID()))
        await double.holdPerform()
        let model = makeModel(double)
        model.attach([try image(.png)])
        model.draft = "an invented message with a picture"

        let sending = Task { await model.send() }
        let reached = await settle { await double.prompts.count == 1 }
        XCTAssertTrue(reached, "the send never reached the prompt, so nothing happened across an await")

        model.removeAttachment(at: 0)
        let arrivedSince = try XCTUnwrap(ImageIntake.normalized(try image(.tiff)), "the drawn TIFF did not normalize")
        model.attachments.append(arrivedSince.attachment)
        await double.releasePerform()
        await sending.value

        XCTAssertEqual(model.attachments, [arrivedSince.attachment],
                       "the tray holds \(model.attachments.count) image(s); the one attached while the message was "
                       + "in flight was deleted in place of the one that travelled")
    }

    /// An image dropped from Finder arrives as a **file URL** and nothing else, and it still reaches
    /// the tray.
    ///
    /// The field registers `.fileURL` for drags, so this is the ordinary way a picture arrives from
    /// the Finder: the drag pasteboard carries a URL, not the bytes. An intake that only decodes
    /// representation bytes accepts the drop and attaches nothing.
    ///
    /// The file is drawn by this suite into a scratch directory of its own; nothing is read from a
    /// fixture or from any config home (§11, X9).
    ///
    /// Deliberate break: remove the URL arm from `attach(from:)` → the drop attaches nothing.
    func testAnImageDroppedAsAFileURLIsAttached() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "afleet-attachment-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "an-invented-picture.png")
        try image(.png).write(to: file)

        let board = NSPasteboard(name: NSPasteboard.Name("afleet.invented.file-url-drop"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        board.writeObjects([item])

        let accepted = model.attach(from: board)

        XCTAssertEqual(accepted, 1, "a Finder image offered only as a file URL produced \(accepted) attachment(s)")
        XCTAssertEqual(model.attachments.map(\.mediaType), ["image/png"],
                       "the dropped file did not arrive as the PNG it is")
        board.clearContents()
    }

    /// A dropped file that is not an image is refused, and so is one past the source bound — the
    /// floor under the arm above, so an intake that read every URL it was handed cannot pass.
    func testADroppedFileThatIsNotAnImageIsRefused() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "afleet-attachment-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "an-invented-note.txt")
        try Data("not an image at all".utf8).write(to: file)

        let board = NSPasteboard(name: NSPasteboard.Name("afleet.invented.file-url-drop-refused"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        board.writeObjects([item])

        XCTAssertEqual(model.attach(from: board), 0, "a dropped text file was attached as an image")
        XCTAssertEqual(model.attachments.count, 0, "the tray holds \(model.attachments.count) item(s)")
        board.clearContents()
    }

    /// A bounded wait for something the double answers.
    private func settle(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    /// A pasteboard carrying an image is read through the same intake, once per item even when the
    /// same image is offered under several types.
    func testAPasteboardImageIsAttachedOncePerItem() throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let board = NSPasteboard(name: NSPasteboard.Name("afleet.invented.attachment-tests"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(try image(.png), forType: .png)
        item.setData(try image(.tiff), forType: .tiff)
        board.writeObjects([item])

        let accepted = model.attach(from: board)

        XCTAssertEqual(accepted, 1, "one pasteboard item produced \(accepted) attachment(s)")
        XCTAssertEqual(model.attachments.count, 1, "the tray holds \(model.attachments.count) image(s)")
        board.clearContents()
    }
}
