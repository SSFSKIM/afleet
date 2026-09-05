import Foundation
import ClaudeWire

/// The picker's read, exactly (2.1.258 `ihe`, line 13803; `od = 65536`): the first and last 64 KiB and the stat.
public struct HeadTail: Sendable, Hashable {
    public var mtime: Date
    public var size: Int64
    /// The two chunks as they were read. The bytes are the storage, not the `String`s: building a `String` from 128 KiB
    /// of UTF-8 validates it up front, and every scan over the result is then grapheme-aware. The index scans the bytes
    /// (`BufferScan`) and decodes only the field values it returns; `head` and `tail` stay for a caller that wants text.
    public var headBytes: [UInt8]
    public var tailBytes: [UInt8]
    /// One 64 KiB chunk decoded as UTF-8 with replacement, the way `Buffer.toString("utf8")` decodes a chunk that may
    /// have cut a multi-byte sequence in half.
    public var head: String { String(decoding: headBytes, as: UTF8.self) }
    public var tail: String { String(decoding: tailBytes, as: UTF8.self) }
    public init(mtime: Date, size: Int64, headBytes: [UInt8], tailBytes: [UInt8]) {
        self.mtime = mtime; self.size = size; self.headBytes = headBytes; self.tailBytes = tailBytes
    }
    public init(mtime: Date, size: Int64, head: String, tail: String) {
        self.init(mtime: mtime, size: size, headBytes: Array(head.utf8), tailBytes: Array(tail.utf8))
    }
}
public protocol HeadTailReading: Sendable { func read(_ url: URL) throws -> HeadTail? }
public struct HeadTailReader: HeadTailReading {
    public static let chunk = 65_536
    public init() {}

    /// nil for anything that is not a readable regular file, and for an empty one — `ihe` returns null on a zero-byte
    /// read and swallows every error, so this does too. The tail read starts at `max(0, size - 64 KiB)`; when that is 0
    /// the tail *is* the head, byte for byte, as the engine's `u = o` does.
    public func read(_ url: URL) throws -> HeadTail? {
        var openErrno: Int32 = 0
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { openErrno = ENOENT; return -1 }
            let d = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if d < 0 { openErrno = errno }
            return d
        }
        guard fd >= 0 else { _ = openErrno; return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int64(info.st_size)
        let wanted = size > 0 && size < Int64(Self.chunk) ? Int(size) : Self.chunk
        guard let head = chunkBytes(fd, at: 0, upTo: wanted), !head.isEmpty else { return nil }
        let tailStart = max(0, size - Int64(Self.chunk))
        let tail = tailStart > 0 ? (chunkBytes(fd, at: tailStart, upTo: Self.chunk) ?? []) : head
        let mtime = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return HeadTail(mtime: mtime, size: size, headBytes: head, tailBytes: tail)
    }

    /// One 64 KiB chunk, exactly the bytes `pread` returned and no more. The storage is left uninitialised until `pread`
    /// fills it: zeroing 64 KiB twice per file was the single largest allocation cost in the cold build's profile.
    private func chunkBytes(_ fd: Int32, at offset: Int64, upTo wanted: Int) -> [UInt8]? {
        var read = 0
        let buffer = [UInt8](unsafeUninitializedCapacity: max(1, wanted)) { storage, count in
            read = Foundation.pread(fd, storage.baseAddress!, wanted, off_t(offset))
            count = max(0, read)
        }
        return read >= 0 ? buffer : nil
    }

    // MARK: - The engine's substring helpers (2.1.258, lines 13341-13424 and 13464)

    /// Each helper is one `BufferScan` over the text's UTF-8. `BufferScan` carries the semantics and the comments that
    /// pin them to the bundle; these five entry points are what a caller holding a `String` uses, and what the tests
    /// that pin the engine's behaviour drive. The index path scans the read's bytes directly and never builds the text.

    /// `G1`: first occurrence of `"key":"` (or `"key": "`) anywhere in `text`, JSON-unescaped.
    public static func firstString(_ text: String, key: String) -> String? {
        BufferScan(Array(text.utf8), keys: [key]).firstString(key)
    }

    /// `Gf`: last occurrence, JSON-unescaped.
    public static func lastString(_ text: String, key: String) -> String? {
        BufferScan(Array(text.utf8), keys: [key]).lastString(key)
    }

    /// `Ose` (which is `V` with its arguments swapped): scanning lines from the end, the first line that contains `"key":`
    /// and — when a type is given — a `"type":"<type>"` marker, parsed as JSON, its string field `key`.
    ///
    /// One deliberate, bounded divergence from the engine: `V`'s substring prefilter is written unspaced only
    /// (`"type":"<type>"`, bundle line 13402), so it never matches a line spelled `"type": "<type>"`. The committed
    /// recordings are re-serialised with that space, so the engine's literal would find nothing in them. Both spellings
    /// are accepted here, exactly as `G1`/`Gf` already accept both. The widening cannot produce a false positive: this
    /// is only a prefilter, and the post-parse guard reproduces the engine's own `u.type === r` check (line 13405).
    /// It cannot produce a false negative on real engine bytes either, being a strict superset of the engine's literal.
    public static func lastLineString(_ text: String, type: String?, key: String) -> String? {
        BufferScan(Array(text.utf8), keys: [key, "type"]).lastLineString(type: type, key: key)
    }

    /// `VQ`: scanning lines from the start, the first line containing `"key":` that parses to an object whose `key` is a string.
    public static func firstLineString(_ text: String, key: String) -> String? {
        BufferScan(Array(text.utf8), keys: [key]).firstLineString(key)
    }

    /// `Ett`: the first `user` line that is not a tool_result, not `isMeta`, not `isCompactSummary`; its content string or
    /// first usable text block, run through the engine's `F5` — a `<command-name>` is remembered as a fallback, a
    /// `<bash-input>` becomes `! <command>`, an opening XML tag or an interruption notice is skipped, and anything longer
    /// than 200 UTF-16 units is truncated with an ellipsis. `""` when nothing qualifies.
    public static func firstPrompt(_ head: String) -> String {
        BufferScan(Array(head.utf8), keys: ["type"]).firstPrompt()
    }

    // MARK: - `F5` and the small string primitives it needs

    /// `F5` (chunk-bpk2rz0h). Returns nil when this record yields no prompt; `commandFallback` keeps the first
    /// `<command-name>` seen, which `Ett` returns when no record yields anything better.
    static func prompt(from object: [String: JSONValue], commandFallback: inout String) -> String? {
        guard object["type"]?.stringValue == "user" else { return nil }
        if object["isMeta"]?.boolValue == true || object["isCompactSummary"]?.boolValue == true { return nil }
        guard let message = object["message"]?.objectValue else { return nil }
        var texts: [String] = []
        guard let content = message["content"] else { return nil }
        switch content {
        case .string(let text): texts.append(text)
        case .array(let blocks):
            for block in blocks {
                guard let fields = block.objectValue else { continue }
                if fields["type"]?.stringValue == "tool_result" { return nil }
                if fields["type"]?.stringValue == "text", let text = fields["text"]?.stringValue { texts.append(text) }
            }
        default: return nil
        }
        for raw in texts {
            var text = newlinesAsSpaces(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let name = between(text, "<command-name>", "</command-name>") {
                if commandFallback.isEmpty { commandFallback = name }
                continue
            }
            if let command = between(text, "<bash-input>", "</bash-input>") {
                return "! " + command.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if skipsAsMarkup(text) { continue }
            if utf16Longer(text, than: 200) { text = truncate(text, 200).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}" }
            return text
        }
        return nil
    }

    /// The engine's `oIn`: an opening lowercase XML-ish tag at the head of the text, or an interruption notice.
    private static func skipsAsMarkup(_ text: String) -> Bool {
        if text.hasPrefix("[Request interrupted by user"), text.contains("]") { return true }
        var rest = Substring(text)
        while let first = rest.first, first == " " || first == "\t" || first == "\n" || first == "\r" { rest = rest.dropFirst() }
        guard rest.first == "<" else { return false }
        var name = rest.dropFirst()
        guard let initial = name.first, initial.isLowercase, initial.isLetter, initial.isASCII else { return false }
        name = name.dropFirst()
        while let c = name.first, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" { name = name.dropFirst() }
        guard let terminator = name.first else { return false }
        return terminator == ">" || terminator == " " || terminator == "\t" || terminator == "\n" || terminator == "\r"
    }

    /// `replacingOccurrences(of: "\n", with: " ")`, over UTF-8. `U+000A` is one UTF-16 unit and one ASCII byte and can
    /// be no part of any other character, so replacing the byte is the same replacement NSString makes — including on a
    /// `\r\n`, where a `Character`-level replacement would differ.
    private static func newlinesAsSpaces(_ text: String) -> String {
        guard text.utf8.contains(0x0A) else { return text }
        return String(decoding: text.utf8.map { $0 == 0x0A ? 0x20 : $0 }, as: UTF8.self)
    }

    /// The text between two ASCII markers, over UTF-8. A literal ASCII needle occurs at the same places in the bytes as
    /// `range(of:options:.literal)` finds it, and both cuts land on ASCII bytes, so the slice is the same string — at a
    /// fraction of the cost of two CFString searches over a prompt that can be tens of kilobytes.
    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        var subject = text
        subject.makeContiguousUTF8()
        let opening = Array(open.utf8), closing = Array(close.utf8)
        let found: String?? = subject.utf8.withContiguousStorageIfAvailable { buffer -> String? in
            guard let base = buffer.baseAddress, !opening.isEmpty, !closing.isEmpty else { return nil }
            guard let start = memmem(base, buffer.count, opening, opening.count) else { return nil }
            let from = UnsafeRawPointer(start) - UnsafeRawPointer(base) + opening.count
            guard from <= buffer.count, let end = memmem(base + from, buffer.count - from, closing, closing.count) else { return nil }
            let to = UnsafeRawPointer(end) - UnsafeRawPointer(base)
            return String(decoding: UnsafeBufferPointer(rebasing: buffer[from..<to]), as: UTF8.self)
        }
        return found ?? nil
    }

    /// `text.utf16.count > limit`, stopping as soon as it is known. Counting a whole large prompt's UTF-16 units builds
    /// the string's breadcrumb cache, which showed up in the cold build's profile; the answer here is the same one.
    private static func utf16Longer(_ text: String, than limit: Int) -> Bool {
        var units = 0
        for scalar in text.unicodeScalars {
            units += scalar.value > 0xFFFF ? 2 : 1
            if units > limit { return true }
        }
        return false
    }

    /// The engine's `le`: a prefix of `n` UTF-16 units that never ends on a lone high surrogate.
    private static func truncate(_ text: String, _ limit: Int) -> String {
        // Only the first `limit + 1` units are needed to answer both questions, and taking them by iteration keeps a long
        // prompt from building the string's UTF-16 breadcrumb cache.
        let units = Array(text.utf16.prefix(limit + 1))
        guard units.count > limit, limit > 0 else { return text }
        var prefix = Array(units[0..<limit])
        if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
        return String(decoding: prefix, as: UTF16.self)
    }

    /// The engine's `gdr`: only a value carrying a backslash is JSON-unescaped, and a failure returns it untouched.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data("\"\(text)\"".utf8)), let s = value.stringValue else { return text }
        return s
    }

    static func object(_ line: String) -> [String: JSONValue]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
        return value.objectValue
    }
}
