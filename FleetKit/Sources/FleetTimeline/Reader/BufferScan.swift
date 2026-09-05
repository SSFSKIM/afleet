import Foundation
import ClaudeWire

/// One pass over a head or tail buffer that locates every key of interest at once.
///
/// The engine's five substring helpers each scan the whole 64 KiB chunk, and the index calls them about a dozen times per
/// file. Done over a Swift `String` that is a dozen grapheme-aware passes over 64 KiB — measured at 19.8 ms per file, which
/// is the whole of gate G2's cold build. This type does the same work over the UTF-8 bytes: two `memchr` sweeps (one for
/// line ends, one for `"`), a byte compare against the caller's key list at each key-shaped quote pair, and nothing else
/// until a value is actually wanted. Strings are built for the handful of values that are returned.
///
/// **Behaviour is the helpers' behaviour, unchanged**, and this is the one implementation of it: `HeadTailReader`'s public
/// `String` helpers are wrappers around this type, so the tests that pin the engine's semantics pin this code.
///
/// The equivalence rests on one property of the bytes: a raw `"` never occurs inside a JSON string value, so the two quotes
/// that surround a key in any literal occurrence of `"key":"` are *consecutive* quotes in the buffer. Walking consecutive
/// quote pairs therefore finds exactly the occurrences `String.range(of:options:.literal)` finds. Line ends are `\n` bytes,
/// which cannot occur inside a UTF-8 multi-byte sequence, so byte lines are the same lines `split(separator: "\n")` yields.
struct BufferScan {
    /// One `"key":` occurrence. `valueAt` is the first byte of the value — the opening quote when `quoted` — after the
    /// colon and at most one space, which is the whole of the two spellings the engine's helpers accept.
    struct Hit {
        let quote: Int
        let line: Int
        let valueAt: Int
        let spaced: Bool
        let quoted: Bool
    }

    let bytes: [UInt8]
    /// Line `i` is `bytes[lineStart[i]..<lineEnd[i]]`; an empty line is kept, as `omittingEmptySubsequences: false` does.
    private let lineStart: [Int]
    private let lineEnd: [Int]
    /// The caller's keys, and the hits for each, in the caller's order. An array indexed by key position rather than a
    /// dictionary keyed by name: `"type"` alone occurs hundreds of times in a 64 KiB chunk, and hashing its name at each
    /// occurrence was measurable next to the scan itself.
    private let keys: [String]
    private let hits: [[Hit]]
    /// Every `"type":"…"` occurrence with a short value, by line — the prefilter `Ose`, `Ett` and the cleared-to-empty
    /// check each spell out as a `line.contains("\"type\":\"<t>\"")`, in both the unspaced and the spaced form.
    private let typeHits: [TypeHit]
    /// The lines already decoded, by line index. One line answers more than one field — the head's first record carries
    /// both the first prompt and the `cwd`, the tail's last `last-prompt` carries both the last prompt and the
    /// cleared-to-empty flag — and decoding a record twice was a third of the entry's cost. A reference box because the
    /// helpers are `let`-bound reads; the scan is built and used inside one task and is not shared.
    private let decoded = DecodedLines()

    final class DecodedLines {
        private var storage: [Int: [String: JSONValue]?] = [:]
        func object(_ line: Int, _ make: () -> [String: JSONValue]?) -> [String: JSONValue]? {
            if let known = storage[line] { return known }
            let value = make()
            storage[line] = value
            return value
        }
    }

    struct TypeHit { let line: Int; let value: Range<Int> }

    init(_ bytes: [UInt8], keys: [String]) {
        self.bytes = bytes
        self.keys = keys
        // `type` is answered from `typeHits` alone, so it is deliberately not accumulated as an ordinary key: it is by far
        // the most frequent key in a transcript line and every one of its occurrences would otherwise be an append into a
        // nested array.
        let typeIndex = keys.firstIndex(of: "type")
        // The key list as one contiguous blob plus a bucket per key-ending byte: at each `":` the candidates are the
        // handful whose last byte matches, compared with one `memcmp`, and no hashing happens in the loop. A key repeated
        // in `keys` is added once, at its first position, which is the position `hits(_:)` looks up.
        var patternBytes: [UInt8] = []
        var patterns: [(start: Int, length: Int, index: Int)] = []
        var buckets = [[Int]](repeating: [], count: 256)
        func add(_ key: String, _ index: Int) {
            let utf8 = Array(key.utf8)
            guard let last = utf8.last else { return }
            buckets[Int(last)].append(patterns.count)
            patterns.append((start: patternBytes.count, length: utf8.count, index: index))
            patternBytes.append(contentsOf: utf8)
        }
        for (index, key) in keys.enumerated() where keys.firstIndex(of: key) == index { add(key, index) }

        var starts: [Int] = [0]
        var ends: [Int] = []
        var found = [[Hit]](repeating: [], count: keys.count)
        var types: [TypeHit] = []

        bytes.withUnsafeBufferPointer { buffer in
            let count = buffer.count
            guard let base = buffer.baseAddress else { return }

            var at = 0
            while at < count, let hit = memchr(base + at, 0x0A, count - at) {
                let offset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                ends.append(offset)
                starts.append(offset + 1)
                at = offset + 1
            }
            ends.append(count)

            patternBytes.withUnsafeBufferPointer { pattern in
            buckets.withUnsafeBufferPointer { bucket in
            patterns.withUnsafeBufferPointer { meta in
            starts.withUnsafeBufferPointer { lines in
                // The sweep looks for `:` and steps back, rather than for every quote: a transcript line holds three to
                // four quotes per colon, and the colon is what every key ends at. A key's own bytes hold no quote, so
                // requiring a key immediately before the `":`, with its opening quote in front, admits exactly the
                // literal `"key":` occurrences a string search would find.
                var line = 0
                var from = 0
                while from < count {
                    guard let sought = memchr(base + from, 0x3A, count - from) else { break }
                    let colonAt = UnsafeRawPointer(sought) - UnsafeRawPointer(base)
                    from = colonAt + 1
                    let closeAt = colonAt - 1
                    guard closeAt > 0, base[closeAt] == 0x22 else { continue }
                    var index = -1
                    var openAt = 0
                    for candidate in bucket[Int(base[closeAt - 1])] {
                        let spec = meta[candidate]
                        let start = closeAt - spec.length
                        guard start > 0, base[start - 1] == 0x22,
                              memcmp(base + start, pattern.baseAddress! + spec.start, spec.length) == 0 else { continue }
                        index = spec.index
                        openAt = start - 1
                        break
                    }
                    guard index >= 0 else { continue }
                    while line + 1 < lines.count, openAt >= lines[line + 1] { line += 1 }
                    var value = closeAt + 2
                    var spaced = false
                    if value < count, base[value] == 0x20 { spaced = true; value += 1 }
                    let quoted = value < count && base[value] == 0x22
                    found[index].append(Hit(quote: openAt, line: line, valueAt: value, spaced: spaced, quoted: quoted))
                    // `type` is recorded twice: as an ordinary hit, because it is a key a caller may ask about like any
                    // other, and — when its value is a short quoted token — as a line marker, which is what the three
                    // line prefilters consult.
                    if index == typeIndex, quoted, value + 1 < count,
                       let end = memchr(base + value + 1, 0x22, count - value - 1) {
                        let endAt = UnsafeRawPointer(end) - UnsafeRawPointer(base)
                        if endAt - value - 1 <= 64 { types.append(TypeHit(line: line, value: (value + 1)..<endAt)) }
                    }
                }
            }
            }
            }
            }
        }

        self.lineStart = starts
        self.lineEnd = ends
        self.hits = found
        self.typeHits = types
    }

    private func hits(_ key: String) -> [Hit] {
        guard let index = keys.firstIndex(of: key) else { return [] }
        return hits[index]
    }

    // MARK: - The engine's helpers, over the pass

    /// `G1`: the first occurrence of `"key":"`, else the first of `"key": "` — the unspaced spelling wins even when it
    /// occurs later, and a spelling whose value has no closing quote falls through to the next, as the original does.
    func firstString(_ key: String) -> String? {
        let list = hits(key)
        for wantsSpace in [false, true] {
            guard let hit = list.first(where: { $0.quoted && $0.spaced == wantsSpace }) else { continue }
            guard let end = closingQuote(from: hit.valueAt + 1) else { continue }
            return HeadTailReader.unescape(string(hit.valueAt + 1, end))
        }
        return nil
    }

    /// `Gf`: the last occurrence by start offset across both spellings. A spelling is abandoned at the first value with no
    /// closing quote, which is what the original's `from = endIndex; break` does.
    func lastString(_ key: String) -> String? {
        let list = hits(key)
        var best: Hit?
        for wantsSpace in [false, true] {
            for hit in list where hit.quoted && hit.spaced == wantsSpace {
                guard let _ = closingQuote(from: hit.valueAt + 1) else { break }
                if best == nil || hit.quote > best!.quote { best = hit }
            }
        }
        guard let best, let end = closingQuote(from: best.valueAt + 1) else { return nil }
        return HeadTailReader.unescape(string(best.valueAt + 1, end))
    }

    /// `Ose`: scanning lines from the end, the first line carrying `"key":` and — when a type is given — a `"type":"<type>"`
    /// marker in either spelling, parsed as JSON, its string field `key`.
    func lastLineString(type: String?, key: String) -> String? {
        let marker = type.map { Array($0.utf8) }
        for line in linesCarrying(key).reversed() {
            if let marker, !self.line(line, carriesType: marker) { continue }
            guard let object = object(ofLine: line) else { continue }
            if let type, object["type"]?.stringValue != type { continue }
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    /// `VQ`: scanning lines from the start, the first line carrying `"key":` that parses to an object whose `key` is a string.
    func firstLineString(_ key: String) -> String? {
        for line in linesCarrying(key) {
            guard let object = object(ofLine: line) else { continue }
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    /// `Ett`: the first `user` line that is not a tool_result, not `isMeta`, not `isCompactSummary`, through `F5`.
    func firstPrompt() -> String {
        var commandFallback = ""
        let user = Array("user".utf8)
        var seen = -1
        for hit in typeHits where hit.line != seen && matches(hit.value, user) {
            seen = hit.line
            if carries(line: hit.line, "\"tool_result\"") { continue }
            if carries(line: hit.line, "\"isMeta\":true") || carries(line: hit.line, "\"isMeta\": true") { continue }
            if carries(line: hit.line, "\"isCompactSummary\":true") || carries(line: hit.line, "\"isCompactSummary\": true") { continue }
            guard let object = object(ofLine: hit.line) else { continue }
            if let prompt = HeadTailReader.prompt(from: object, commandFallback: &commandFallback) { return prompt }
        }
        return commandFallback
    }

    /// The last `last-prompt` line, cleared: a null `leafUuid` and an explicit `true`.
    func clearedToEmpty() -> Bool {
        let kind = Array("last-prompt".utf8)
        var lines: [Int] = []
        var seen = -1
        for hit in typeHits where hit.line != seen && matches(hit.value, kind) { seen = hit.line; lines.append(hit.line) }
        for line in lines.reversed() {
            guard let object = object(ofLine: line), object["type"]?.stringValue == "last-prompt" else { continue }
            guard case .null? = object["leafUuid"] else { return false }
            return object["explicit"]?.boolValue == true
        }
        return false
    }

    /// True when an `"isSidechain":true` comes before any `"isSidechain":false`. Both spellings, as the recordings are
    /// re-serialised with a space after the colon.
    func sidechain() -> Bool {
        var trueAt: Int?
        var falseAt: Int?
        let yes = Array("true".utf8), no = Array("false".utf8)
        for hit in hits("isSidechain") {
            if matches(hit.valueAt..<min(hit.valueAt + yes.count, bytes.count), yes) {
                if trueAt == nil || hit.quote < trueAt! { trueAt = hit.quote }
            } else if matches(hit.valueAt..<min(hit.valueAt + no.count, bytes.count), no) {
                if falseAt == nil || hit.quote < falseAt! { falseAt = hit.quote }
            }
        }
        guard let trueAt else { return false }
        guard let falseAt else { return true }
        return trueAt < falseAt
    }

    // MARK: - Small primitives

    /// The lines carrying `"key":`, ascending and without repeats — the set of lines the original's `line.contains(keyMark)`
    /// prefilter admits.
    private func linesCarrying(_ key: String) -> [Int] {
        var lines: [Int] = []
        for hit in hits(key) where lines.last != hit.line { lines.append(hit.line) }
        return lines
    }

    private func line(_ index: Int, carriesType marker: [UInt8]) -> Bool {
        for hit in typeHits where hit.line == index && matches(hit.value, marker) { return true }
        return false
    }

    private func matches(_ range: Range<Int>, _ marker: [UInt8]) -> Bool {
        guard range.count == marker.count else { return false }
        for (i, byte) in marker.enumerated() where bytes[range.lowerBound + i] != byte { return false }
        return true
    }

    /// A literal byte search inside one line — the per-line `contains` checks `Ett` makes, and nothing wider.
    private func carries(line index: Int, _ literal: String) -> Bool {
        let needle = Array(literal.utf8)
        let start = lineStart[index], end = lineEnd[index]
        guard end - start >= needle.count, !needle.isEmpty else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return needle.withUnsafeBufferPointer { pattern in
                memmem(base + start, end - start, pattern.baseAddress!, needle.count) != nil
            }
        }
    }

    /// The scan `G1`/`Gf` share: the next unescaped `"` at or after `from`.
    private func closingQuote(from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == 0x5C { i += 2; continue }
            if bytes[i] == 0x22 { return i }
            i += 1
        }
        return nil
    }

    private func string(_ from: Int, _ to: Int) -> String {
        guard from <= to, to <= bytes.count else { return "" }
        return String(decoding: bytes[from..<to], as: UTF8.self)
    }

    private func text(ofLine index: Int) -> String { string(lineStart[index], lineEnd[index]) }

    private func object(ofLine index: Int) -> [String: JSONValue]? {
        decoded.object(index) { HeadTailReader.object(text(ofLine: index)) }
    }
}
