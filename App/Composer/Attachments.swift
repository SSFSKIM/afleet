import AppKit
import SwiftUI
import ClaudeWire

/// What the pasteboard and the drag pasteboard are allowed to put on a message (spec C6.2
/// *Attachments*, §6.6's image blocks).
///
/// **This is validation at a system boundary, which is the one place the simplicity rule asks for
/// it.** The pasteboard is user input of unbounded size and arbitrary format: a 60 MB screenshot
/// base64-encoded into a single stdin line is a real failure mode and not a hypothetical one, and a
/// format the engine does not accept is a message the model never sees. So the bytes are sniffed,
/// converted if they must be, and capped — and nothing downstream of here checks any of it again.
enum ImageIntake {

    /// The caps, from the spec: eight images on one message, 8 MiB each **after** conversion.
    /// After, because a small TIFF can become a large PNG and it is the bytes that travel that
    /// matter.
    static let maxImages = 8
    static let maxBytesEach = 8 * 1024 * 1024

    /// The most a dropped **file** is read from disk before it is decoded.
    ///
    /// A pasted image is already in memory; a dropped one is a path, and the bytes behind it are unbounded. The cap
    /// above is on what travels, which is not what a decoder is handed — a TIFF several times the size of its PNG is
    /// ordinary — so the source needs a bound of its own, and it is deliberately generous: too tight a bound would
    /// refuse pictures the message could have carried.
    static let maxSourceBytes = 64 * 1024 * 1024

    /// The two media types that travel as they arrived. Everything else this machine can decode is
    /// converted to PNG — the engine's image blocks carry `media_type`, and PNG is the lossless
    /// format every decoder here can write.
    static let passThrough: Set<String> = ["image/png", "image/jpeg"]

    /// An attachment and the size of the bytes it carries, so the cap is applied to what travels
    /// rather than to its base64 inflation.
    struct Candidate {
        var attachment: ImageAttachment
        var byteCount: Int
    }

    /// The media type of `data` from its own leading bytes.
    ///
    /// Sniffed rather than taken from the pasteboard's declared type: `NSPasteboard` will report a
    /// UTI for data it never inspected, and what the engine is told the bytes are has to be what
    /// they are. Nil for anything not recognised, which then goes through the decoder.
    static func mediaType(of data: Data) -> String? {
        func starts(with bytes: [UInt8]) -> Bool {
            guard data.count >= bytes.count else { return false }
            return Array(data.prefix(bytes.count)) == bytes
        }
        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if starts(with: [0x42, 0x4D]) { return "image/bmp" }
        return nil
    }

    /// One pasteboard item as something the engine can be handed: PNG and JPEG verbatim, anything
    /// else this machine can decode re-encoded as PNG.
    ///
    /// Nil for bytes that are not an image at all. Silently dropping those would be worse than
    /// saying so, which is why the caller counts them into its note.
    static func normalized(_ data: Data) -> Candidate? {
        if let type = mediaType(of: data), passThrough.contains(type) {
            return Candidate(attachment: ImageAttachment(mediaType: type, base64: data.base64EncodedString()),
                             byteCount: data.count)
        }
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return Candidate(attachment: ImageAttachment(mediaType: "image/png", base64: png.base64EncodedString()),
                         byteCount: png.count)
    }
}

extension ComposerModel {

    /// Attaches whatever of `items` the caps allow, in arrival order, and says inline what it would
    /// not take. Answers how many it took.
    ///
    /// Refusals are counted, never itemised: a note names how many images were refused and the cap
    /// they exceeded, and never a file name or a path (§11).
    @discardableResult
    func attach(_ items: [Data]) -> Int {
        var accepted = 0, pastImageCap = 0, pastByteCap = 0, undecodable = 0
        for data in items {
            guard attachments.count < ImageIntake.maxImages else { pastImageCap += 1; continue }
            guard let candidate = ImageIntake.normalized(data) else { undecodable += 1; continue }
            guard candidate.byteCount <= ImageIntake.maxBytesEach else { pastByteCap += 1; continue }
            attachments.append(candidate.attachment)
            accepted += 1
        }
        attachmentNote = Self.note(pastImageCap: pastImageCap, pastByteCap: pastByteCap, undecodable: undecodable)
        return accepted
    }

    /// The images on a pasteboard — a paste, or a drop, which arrives on a pasteboard of its own.
    ///
    /// Every item's data is read for each type the pasteboard offers and the first that sniffs or
    /// decodes as an image wins, so a screenshot offered as both TIFF and PNG is attached once.
    @discardableResult
    func attach(from pasteboard: NSPasteboard) -> Int {
        var items: [Data] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var took = false
            for type in item.types {
                guard let data = item.data(forType: type), ImageIntake.normalized(data) != nil else { continue }
                items.append(data)
                took = true
                break
            }
            // A Finder drop offers a **path** and no bytes at all, which is the ordinary way a picture arrives from
            // outside the app — the field registers `.fileURL` for exactly it. The file's own bytes then go through
            // the same sniff, conversion and cap as a pasted image; nothing here trusts the extension.
            guard !took, let data = Self.imageBytes(ofFileOn: item) else { continue }
            items.append(data)
        }
        return attach(items)
    }

    /// The bytes of the file a pasteboard item names, when that file is an image this machine can read.
    ///
    /// Nil for an item that names no file, for a file too large to be a decoder's input, and for one whose bytes are
    /// not an image — the last of which the caller counts into its note like any other undecodable item.
    private static func imageBytes(ofFileOn item: NSPasteboardItem) -> Data? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else {
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= ImageIntake.maxSourceBytes else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Drops the images that went with a message that was sent — **by identity, one occurrence each**.
    ///
    /// Not by count. The tray stays live across the send's await: a chip can be removed and another image attached
    /// while the prompt is in flight, and dropping "the first N" then deletes whatever is in front of the tray — a
    /// picture the user has attached and not sent — while the one that travelled stays behind. The same image
    /// attached twice is two entries and one send drops one of them.
    func dropAttachments(_ sent: [ImageAttachment]) {
        guard !sent.isEmpty else { return }
        for image in sent {
            guard let index = attachments.firstIndex(of: image) else { continue }
            attachments.remove(at: index)
        }
        if attachments.isEmpty { attachmentNote = nil }
    }

    /// One attachment removed by hand, from the tray.
    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    /// What the tray says about what it would not take. Nil when it took everything.
    static func note(pastImageCap: Int, pastByteCap: Int, undecodable: Int) -> String? {
        var parts: [String] = []
        if pastImageCap > 0 {
            parts.append("\(pastImageCap) image(s) beyond the \(ImageIntake.maxImages) one message carries")
        }
        if pastByteCap > 0 {
            parts.append("\(pastByteCap) image(s) larger than \(ImageIntake.maxBytesEach / (1024 * 1024)) MiB")
        }
        if undecodable > 0 { parts.append("\(undecodable) item(s) that are not an image") }
        guard !parts.isEmpty else { return nil }
        return "Not attached: " + parts.joined(separator: ", ") + "."
    }
}

/// The tray under the field: one chip per attached image, and the note about anything refused.
///
/// It counts and never names: an attachment is bytes on a pasteboard and has no file name to show,
/// and inventing one would be a title this leaf made up (§11).
struct AttachmentTrayView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = model.attachmentNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                        Button {
                            model.removeAttachment(at: index)
                        } label: {
                            Label("Image \(index + 1) (\(attachment.mediaType))", systemImage: "photo")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
