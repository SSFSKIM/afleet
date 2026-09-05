import Foundation
import ClaudeWire

/// The picker's read, exactly (2.1.258 `ihe`, line 13803; `od = 65536`): the first and last 64 KiB and the stat.
public struct HeadTail: Sendable, Hashable { public var mtime: Date; public var size: Int64; public var head: String; public var tail: String }
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
        guard let head = chunkText(fd, at: 0), !head.isEmpty else { return nil }
        let tailStart = max(0, size - Int64(Self.chunk))
        let tail = tailStart > 0 ? (chunkText(fd, at: tailStart) ?? "") : head
        let mtime = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return HeadTail(mtime: mtime, size: size, head: head, tail: tail)
    }

    /// One 64 KiB chunk decoded as UTF-8 with replacement, the way `Buffer.toString("utf8")` decodes a chunk that may
    /// have cut a multi-byte sequence in half.
    private func chunkText(_ fd: Int32, at offset: Int64) -> String? {
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        let n = buffer.withUnsafeMutableBytes { Foundation.pread(fd, $0.baseAddress!, Self.chunk, off_t(offset)) }
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }

    // MARK: - The engine's substring helpers (2.1.258, lines 13341-13424 and 13464)

    /// `G1`: first occurrence of `"key":"…"` (or `"key": "…"`) anywhere in `text`, JSON-unescaped.
    /// The two spellings are tried in that order — the unspaced one wins even when it occurs later, as the engine's does.
    public static func firstString(_ text: String, key: String) -> String? {
        for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
            guard let found = text.range(of: pattern, options: .literal) else { continue }
            if let end = closingQuote(text, from: found.upperBound) { return unescape(String(text[found.upperBound..<end])) }
        }
        return nil
    }

    /// `Gf`: last occurrence, JSON-unescaped. "Last" is by start offset across both spellings, not by spelling order.
    public static func lastString(_ text: String, key: String) -> String? {
        var best: String?
        var bestStart: String.Index?
        for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
            var from = text.startIndex
            while let found = text.range(of: pattern, options: .literal, range: from..<text.endIndex) {
                guard let end = closingQuote(text, from: found.upperBound) else { from = text.endIndex; break }
                if bestStart == nil || found.lowerBound > bestStart! {
                    best = unescape(String(text[found.upperBound..<end])); bestStart = found.lowerBound
                }
                from = text.index(after: end)
            }
        }
        return best
    }

    /// `Ose` (which is `V` with its arguments swapped): scanning lines from the end, the first line that contains `"key":`
    /// and — when a type is given — the literal `"type":"<type>"`, parsed as JSON, its string field `key`.
    /// That type prefilter is written unspaced only: a line spelled `"type": "<type>"` never matches, engine and here alike.
    public static func lastLineString(_ text: String, type: String?, key: String) -> String? {
        let typeMark = type.map { "\"type\":\"\($0)\"" }
        let keyMark = "\"\(key)\":"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            guard line.contains(keyMark), typeMark.map({ line.contains($0) }) ?? true else { continue }
            guard let object = object(String(line)) else { continue }
            if let type, object["type"]?.stringValue != type { continue }
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    /// `VQ`: scanning lines from the start, the first line containing `"key":` that parses to an object whose `key` is a string.
    public static func firstLineString(_ text: String, key: String) -> String? {
        let keyMark = "\"\(key)\":"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains(keyMark), let object = object(String(line)) else { continue }
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    /// `Ett`: the first `user` line that is not a tool_result, not `isMeta`, not `isCompactSummary`; its content string or
    /// first usable text block, run through the engine's `F5` — a `<command-name>` is remembered as a fallback, a
    /// `<bash-input>` becomes `! <command>`, an opening XML tag or an interruption notice is skipped, and anything longer
    /// than 200 UTF-16 units is truncated with an ellipsis. `""` when nothing qualifies.
    public static func firstPrompt(_ head: String) -> String {
        var commandFallback = ""
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"") else { continue }
            if line.contains("\"tool_result\"") { continue }
            if line.contains("\"isMeta\":true") || line.contains("\"isMeta\": true") { continue }
            if line.contains("\"isCompactSummary\":true") || line.contains("\"isCompactSummary\": true") { continue }
            guard let object = object(String(line)) else { continue }
            if let prompt = prompt(from: object, commandFallback: &commandFallback) { return prompt }
        }
        return commandFallback
    }

    // MARK: - `F5` and the small string primitives it needs

    /// `F5` (chunk-bpk2rz0h). Returns nil when this record yields no prompt; `commandFallback` keeps the first
    /// `<command-name>` seen, which `Ett` returns when no record yields anything better.
    private static func prompt(from object: [String: JSONValue], commandFallback: inout String) -> String? {
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
            var text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let name = between(text, "<command-name>", "</command-name>") {
                if commandFallback.isEmpty { commandFallback = name }
                continue
            }
            if let command = between(text, "<bash-input>", "</bash-input>") {
                return "! " + command.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if skipsAsMarkup(text) { continue }
            if text.utf16.count > 200 { text = truncate(text, 200).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}" }
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

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open, options: .literal), let end = text.range(of: close, options: .literal, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The engine's `le`: a prefix of `n` UTF-16 units that never ends on a lone high surrogate.
    private static func truncate(_ text: String, _ limit: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > limit, limit > 0 else { return text }
        var prefix = Array(units[0..<limit])
        if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
        return String(decoding: prefix, as: UTF16.self)
    }

    /// The engine's `gdr`: only a value carrying a backslash is JSON-unescaped, and a failure returns it untouched.
    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data("\"\(text)\"".utf8)), let s = value.stringValue else { return text }
        return s
    }

    /// The scan `G1`/`Gf` share: the next unescaped `"` at or after `from`.
    private static func closingQuote(_ text: String, from: String.Index) -> String.Index? {
        var i = from
        while i < text.endIndex {
            if text[i] == "\\" {
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if text[i] == "\"" { return i }
            i = text.index(after: i)
        }
        return nil
    }

    private static func object(_ line: String) -> [String: JSONValue]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
        return value.objectValue
    }
}
