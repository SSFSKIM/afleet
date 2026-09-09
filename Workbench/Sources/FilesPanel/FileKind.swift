import Foundation
import SourceControlCore

/// What a path is, and which surface opens it (spec Design §4).
///
/// The decision is a pure function of the file's name, its size and its leading bytes, which is
/// what lets G2's headless half assert it. The order is fixed: **the size cap first**, because a
/// working tree holds files nobody meant to open and the panel reads a file whole to hand Monaco a
/// string; then the **extension**, because it is what the user named the file; then the **leading
/// bytes**, which are the tie-break for a file with no extension and the *veto* for a claimed one.
///
/// The veto is the half a pure-extension decision gets wrong: a `.png` whose first bytes are not a
/// PNG signature is not handed to `NSImage` to fail inside a view, it is refused here and drawn as
/// the panel-local state §10 asks for.
public enum FileKind: Equatable, Sendable {
    case code(language: String)
    case markdown
    case image
    case pdf
    case media
    case quickLook
    case binary

    /// The cap, above which the file is not read at all.
    ///
    /// It is C7.3's own retained-output cap rather than a second number, for the reason C7.3
    /// recorded on `GitDiff.workingTreeFile`: both sides of a diff and the buffer behind an
    /// editor are the same class of whole-file read. The editor's practical limit is far below
    /// this and is the human's to observe, not this leaf's to guess.
    public static let maximumReadableBytes = ToolRunner.defaultOutputLimitBytes

    /// How much of the file the signature and text tests look at.
    static let sniffedByteCount = 64

    /// The decision. `maximumBytes` is a parameter so a test can exercise the cap without
    /// building a file the size of the default.
    public static func of(url: URL, maximumBytes: Int = FileKind.maximumReadableBytes) -> FileKind {
        guard let size = regularFileSize(url), size <= maximumBytes else { return .binary }

        let claimed = claim(for: url)
        switch claimed {
        case .some(let kind) where kind == .image || kind == .pdf || kind == .media:
            // The veto: a claimed container must carry its own signature.
            guard let bytes = leadingBytes(url, count: sniffedByteCount),
                  signature(of: bytes) == kind else { return .binary }
            return kind
        case .some(let kind):
            return kind
        case .none:
            // No name-based claim: the bytes decide. A known signature wins; otherwise a
            // text-looking prefix opens in the editor and anything else is opaque.
            guard let bytes = leadingBytes(url, count: sniffedByteCount) else { return .binary }
            if let sniffed = signature(of: bytes) { return sniffed }
            if size == 0 { return .code(language: MonacoLanguage.fallback) }
            return isText(bytes) ? .code(language: MonacoLanguage.fallback) : .binary
        }
    }

    // MARK: - The name

    /// What the file's name claims it is, or `nil` when the name says nothing.
    private static func claim(for url: URL) -> FileKind? {
        let name = url.lastPathComponent.lowercased()
        if MonacoLanguage.filenameMap[name] != nil { return .code(language: MonacoLanguage.id(for: url)) }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if mediaExtensions.contains(ext) { return .media }
        if quickLookExtensions.contains(ext) { return .quickLook }
        if ext == "txt" { return .code(language: MonacoLanguage.fallback) }
        if let language = MonacoLanguage.extensionMap[ext] { return .code(language: language) }
        return nil
    }

    /// The markdown extensions the bundle registers, minus `.mdx`, which is its own language and
    /// stays in the editor.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdtxt", "mdtext",
    ]

    /// Every extension here has a signature in `signature(of:)`; the veto would otherwise refuse
    /// a legitimate file for want of a test.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "ico", "heic", "heif",
    ]

    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "m4a", "mov", "3gp", "mp3", "wav", "aif", "aiff", "aac",
        "flac", "ogg", "oga", "ogv", "mkv", "webm", "avi", "caf",
    ]

    /// What macOS previews and this panel does not draw itself.
    static let quickLookExtensions: Set<String> = [
        "rtf", "rtfd", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "epub", "ics", "vcf",
    ]

    // MARK: - The bytes

    /// The signature family the leading bytes carry, or `nil` for none. Only the three families
    /// the veto and the extensionless tie-break need are distinguished.
    static func signature(of bytes: [UInt8]) -> FileKind? {
        func has(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + prefix.count else { return false }
            return Array(bytes[offset..<(offset + prefix.count)]) == prefix
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { has(Array(text.utf8), at: offset) }

        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .image }   // PNG
        if has([0xFF, 0xD8, 0xFF]) { return .image }                                  // JPEG
        if ascii("GIF87a") || ascii("GIF89a") { return .image }
        if ascii("BM") { return .image }                                              // BMP
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .image }  // TIFF
        if has([0x00, 0x00, 0x01, 0x00]) { return .image }                            // ICO
        if ascii("RIFF") && ascii("WEBP", at: 8) { return .image }

        if ascii("%PDF-") { return .pdf }

        if ascii("ftyp", at: 4) {
            // ISO base media: MP4, MOV, M4A, 3GP, and HEIC/HEIF, which are images.
            let brand = String(decoding: bytes.count >= 12 ? bytes[8..<12] : [], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return .image }
            return .media
        }
        if ascii("RIFF") && (ascii("WAVE", at: 8) || ascii("AVI ", at: 8)) { return .media }
        if ascii("FORM") && (ascii("AIFF", at: 8) || ascii("AIFC", at: 8)) { return .media }
        if ascii("OggS") || ascii("fLaC") || ascii("caff") || ascii("ID3") { return .media }
        if has([0x1A, 0x45, 0xDF, 0xA3]) { return .media }                            // Matroska, WebM
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE6 == 0xE2 { return .media }  // MPEG audio, ADTS
        return nil
    }

    /// A UTF-8-valid, control-character-free prefix is text. A NUL is the usual first sign that a
    /// file is not, and it is what an extensionless binary trips over here.
    static func isText(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        for byte in bytes where byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F {
            return false
        }
        // A prefix cut mid-sequence is not a decoding failure, so validity is judged on the
        // longest whole-scalar prefix rather than on the raw window.
        return String(bytes: bytes.dropLast(trailingPartialSequenceLength(bytes)), encoding: .utf8) != nil
    }

    /// How many bytes at the end of the window belong to a UTF-8 sequence the window cut short.
    private static func trailingPartialSequenceLength(_ bytes: [UInt8]) -> Int {
        var back = 0
        while back < 3, back < bytes.count {
            let byte = bytes[bytes.count - 1 - back]
            if byte & 0x80 == 0 { return 0 }                       // ASCII: nothing is pending
            if byte & 0xC0 == 0xC0 {                                // a lead byte
                let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
                return back + 1 < needed ? back + 1 : 0
            }
            back += 1
        }
        return 0
    }

    // MARK: - The file

    /// The size of a regular file, or `nil` for anything that is not one (a directory, a device,
    /// a broken link). `stat(2)` follows the link, which is what "what does this path name" means
    /// for a decision the user made by clicking a row.
    private static func regularFileSize(_ url: URL) -> Int? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(info.st_size)
    }

    private static func leadingBytes(_ url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count) else { return nil }
        return Array(data)
    }
}
