import Foundation
import XCTest
import ClaudeWire
@testable import FleetTimeline

/// The byte scan against the implementation it replaced, over invented strings.
///
/// `BufferScan` re-expresses five engine helpers and two record flags that used to be written with Swift `String`
/// searches. The corpus tests prove the *result* on real recordings, but every recording is ASCII-clean, short-valued
/// and unescaped, so none of them enters a branch where bytes and characters could part company. This file holds the
/// branches that could: a value past the 200-UTF-16-unit truncation, a truncation cut that would split a surrogate
/// pair, escaped quotes and backslashes, an unterminated value, non-ASCII bytes beside a key and across a truncation
/// boundary, both separator spellings, the `<command-name>` fallback, `<bash-input>`, the XML skip, the interruption
/// notice, and the two flags no corpus test reaches at all.
///
/// Every case is asserted twice: against `Reference`, which is the implementation as it stood at `835a8d2` copied
/// verbatim (so equality is literally "behaviour did not change"), and — for the cases where the expected answer can be
/// written down — against that answer, so the pair cannot agree on a wrong result.
///
/// Every byte here is invented. No fixture is read, no config home is touched, and the session ids are made up.
final class BufferScanEquivalenceTests: XCTestCase {

    // MARK: - The inputs

    /// An `aiTitle` of 260 ASCII units, past the 200-unit truncation.
    private static let longTitle = String(repeating: "abcdefghij", count: 26)
    /// 198 units of ASCII then a non-BMP character: the 200-unit cut falls between its two UTF-16 units.
    private static let surrogateAtTheCut = String(repeating: "x", count: 198) + "\u{1F600}" + String(repeating: "y", count: 40)
    /// 199 units of ASCII then the same character: the cut falls after its first unit.
    private static let surrogateAcrossTheCut = String(repeating: "x", count: 199) + "\u{1F600}" + String(repeating: "y", count: 40)

    private static func userLine(_ text: String, spaced: Bool = false) -> String {
        let separator = spaced ? "\": \"" : "\":\""
        return "{\"type\(separator)user\", \"uuid\": \"11111111-2222-3333-4444-555555555555\", "
            + "\"message\": {\"role\": \"user\", \"content\": " + text + "}}"
    }

    private static func cases() -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        out.append(("empty", ""))
        out.append(("blank lines only", "\n\n\n"))
        out.append(("unspaced separators", #"{"type":"user","cwd":"/invented/one","gitBranch":"main","isSidechain":true}"#))
        out.append(("spaced separators", #"{"type": "user", "cwd": "/invented/two", "gitBranch": "topic", "isSidechain": false}"#))
        out.append(("both spellings, unspaced later", #"{"aiTitle": "spaced first"}"# + "\n" + #"{"aiTitle":"unspaced later"}"#))
        out.append(("escaped quote in the value", #"{"aiTitle":"a \"quoted\" title","cwd":"/invented/three"}"#))
        out.append(("escaped backslash before the closing quote", #"{"aiTitle":"trailing slash \\","cwd":"/invented/four"}"#))
        out.append(("a key spelled inside a string value", #"{"summary":"the text \"cwd\":\"/decoy\" inside","cwd":"/invented/five"}"#))
        out.append(("unterminated value", #"{"aiTitle":"never closed"# ))
        out.append(("non-ASCII beside a key", #"{"summary":"안녕 곰 🐻","aiTitle":"제목","cwd":"/invented/여섯"}"#))
        out.append(("non-ASCII value with an escape", #"{"aiTitle":"곰 \"인용\" 곰"}"#))
        out.append(("long value past the truncation", "{\"aiTitle\":\"\(longTitle)\"}"))
        out.append(("two lines, later aiTitle wins", #"{"aiTitle":"first"}"# + "\n" + #"{"aiTitle":"second"}"#))
        out.append(("relocated on the last line", #"{"type":"user","cwd":"/invented/before"}"# + "\n"
                    + #"{"type": "relocated", "relocatedCwd": "/invented/after"}"#))
        out.append(("relocated is not the last line", #"{"type": "relocated", "relocatedCwd": "/invented/after"}"# + "\n"
                    + #"{"type":"user","cwd":"/invented/before"}"#))
        out.append(("a relocatedCwd on a line of another type", #"{"type":"tag","relocatedCwd":"/invented/wrong"}"#))
        out.append(("torn first line", #"gment":"of a record"}"# + "\n" + #"{"type":"user","cwd":"/invented/seven"}"#))
        out.append(("invalid json on the carrying line", #"{"cwd":"/invented/eight",}"#))
        out.append(("cwd not a string", #"{"cwd":123}"# + "\n" + #"{"cwd":"/invented/nine"}"#))
        out.append(("isSidechain false first", #"{"isSidechain": false}"# + "\n" + #"{"isSidechain":true}"#))
        out.append(("isSidechain true first, spaced", #"{"isSidechain": true}"# + "\n" + #"{"isSidechain":false}"#))
        out.append(("isSidechain absent", #"{"type":"user"}"#))
        out.append(("cleared last-prompt", #"{"type":"last-prompt","leafUuid":null,"explicit":true}"#))
        out.append(("cleared last-prompt, spaced", #"{"type": "last-prompt", "leafUuid": null, "explicit": true}"#))
        out.append(("last-prompt with a leaf", #"{"type":"last-prompt","leafUuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","explicit":true}"#))
        out.append(("last-prompt not explicit", #"{"type":"last-prompt","leafUuid":null,"explicit":false}"#))
        out.append(("a later last-prompt overrides an earlier", #"{"type":"last-prompt","leafUuid":null,"explicit":true}"# + "\n"
                    + #"{"type":"last-prompt","leafUuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#))
        out.append(("plain prompt", userLine(#""hello from an invented record""#)))
        out.append(("prompt with newlines", userLine(#""first line\nsecond line""#)))
        out.append(("command-name fallback only", userLine(#""<command-name>/invented-command</command-name>""#)))
        out.append(("command-name then a real prompt", userLine(#""<command-name>/invented-command</command-name>""#) + "\n"
                    + userLine(#""the real prompt""#)))
        out.append(("bash input", userLine(#""<bash-input>ls -la</bash-input>""#)))
        out.append(("xml block skipped", userLine(#""<local-command-stdout>ignored</local-command-stdout>""#)))
        out.append(("interruption notice skipped", userLine(#""[Request interrupted by user for tool use]""#)))
        out.append(("tool result skipped", userLine(#"[{"type":"tool_result","content":"ignored"}]"#)))
        out.append(("isMeta skipped", #"{"type":"user","isMeta":true,"message":{"content":"meta"}}"# + "\n"
                    + userLine(#""after the meta record""#)))
        out.append(("blocks with a text block", userLine(#"[{"type":"text","text":"from a block"}]"#)))
        out.append(("long prompt past the truncation", userLine("\"\(longTitle)\"")))
        out.append(("truncation cut at a surrogate pair", userLine("\"\(surrogateAtTheCut)\"")))
        out.append(("truncation cut across a surrogate pair", userLine("\"\(surrogateAcrossTheCut)\"")))
        out.append(("spaced type marker", userLine(#""spaced type marker""#, spaced: true)))
        out.append(("no user record at all", #"{"type":"assistant","message":{"content":"no"}}"#))
        return out.map { (name: $0.0, text: $0.1) }
    }

    private static let keys = ["aiTitle", "customTitle", "summary", "agentName", "gitBranch", "cwd",
                               "lastPrompt", "relocatedCwd", "tag", "continuedInSessionId", "isSidechain",
                               "type", "aKeyNoInputCarries"]

    // MARK: - The comparison

    func testEveryHelperAgreesWithTheImplementationItReplaced() throws {
        for (name, text) in Self.cases() {
            for key in Self.keys {
                XCTAssertEqual(HeadTailReader.firstString(text, key: key), Reference.firstString(text, key: key),
                               "firstString(\(key)) differs on: \(name)")
                XCTAssertEqual(HeadTailReader.lastString(text, key: key), Reference.lastString(text, key: key),
                               "lastString(\(key)) differs on: \(name)")
                XCTAssertEqual(HeadTailReader.firstLineString(text, key: key), Reference.firstLineString(text, key: key),
                               "firstLineString(\(key)) differs on: \(name)")
                for type in [nil, "user", "relocated", "last-prompt", "tag", "continued-in", "a-type-no-input-carries"] {
                    XCTAssertEqual(HeadTailReader.lastLineString(text, type: type, key: key),
                                   Reference.lastLineString(text, type: type, key: key),
                                   "lastLineString(type: \(type ?? "nil"), \(key)) differs on: \(name)")
                }
            }
            XCTAssertEqual(HeadTailReader.firstPrompt(text), Reference.firstPrompt(text), "firstPrompt differs on: \(name)")
            let bytes = Array(text.utf8)
            XCTAssertEqual(BufferScan(bytes, keys: ["isSidechain"]).sidechain(), Reference.sidechain(text),
                           "sidechain differs on: \(name)")
            XCTAssertEqual(BufferScan(bytes, keys: ["type"]).clearedToEmpty(), Reference.clearedToEmpty(text),
                           "clearedToEmpty differs on: \(name)")
        }
    }

    // MARK: - The answers written down, so the pair cannot agree on a wrong one

    func testTheAnswersThemselves() throws {
        let byName = Dictionary(uniqueKeysWithValues: Self.cases().map { ($0.name, $0.text) })
        func text(_ name: String) throws -> String { try XCTUnwrap(byName[name]) }

        XCTAssertEqual(HeadTailReader.firstString(try text("escaped quote in the value"), key: "aiTitle"), "a \"quoted\" title")
        XCTAssertEqual(HeadTailReader.firstString(try text("escaped backslash before the closing quote"), key: "aiTitle"),
                       "trailing slash \\")
        XCTAssertEqual(HeadTailReader.firstString(try text("escaped backslash before the closing quote"), key: "cwd"), "/invented/four")
        XCTAssertEqual(HeadTailReader.firstString(try text("a key spelled inside a string value"), key: "cwd"), "/invented/five",
                       "an escaped `\"cwd\":\"` inside a value is not a key")
        XCTAssertNil(HeadTailReader.firstString(try text("unterminated value"), key: "aiTitle"))
        XCTAssertEqual(HeadTailReader.lastString(try text("both spellings, unspaced later"), key: "aiTitle"), "unspaced later")
        XCTAssertEqual(HeadTailReader.firstString(try text("both spellings, unspaced later"), key: "aiTitle"), "unspaced later",
                       "the unspaced spelling wins even though it occurs later")
        XCTAssertEqual(HeadTailReader.firstString(try text("non-ASCII beside a key"), key: "aiTitle"), "제목")
        XCTAssertEqual(HeadTailReader.firstString(try text("non-ASCII beside a key"), key: "cwd"), "/invented/여섯")
        XCTAssertEqual(HeadTailReader.firstString(try text("non-ASCII value with an escape"), key: "aiTitle"), "곰 \"인용\" 곰")

        XCTAssertEqual(HeadTailReader.lastLineString(try text("relocated on the last line"), type: "relocated", key: "relocatedCwd"),
                       "/invented/after")
        XCTAssertEqual(HeadTailReader.lastLineString(try text("a relocatedCwd on a line of another type"), type: "relocated",
                                                     key: "relocatedCwd"), nil, "the type guard survives the prefilter")
        XCTAssertEqual(HeadTailReader.firstLineString(try text("cwd not a string"), key: "cwd"), "/invented/nine",
                       "a line whose cwd is not a string is passed over, not returned")
        XCTAssertEqual(HeadTailReader.firstLineString(try text("torn first line"), key: "cwd"), "/invented/seven")

        XCTAssertEqual(HeadTailReader.firstPrompt(try text("plain prompt")), "hello from an invented record")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("prompt with newlines")), "first line second line")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("command-name fallback only")), "/invented-command")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("command-name then a real prompt")), "the real prompt")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("bash input")), "! ls -la")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("xml block skipped")), "")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("interruption notice skipped")), "")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("tool result skipped")), "")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("isMeta skipped")), "after the meta record")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("blocks with a text block")), "from a block")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("spaced type marker")), "spaced type marker")
        XCTAssertEqual(HeadTailReader.firstPrompt(try text("no user record at all")), "")

        // The truncation: 200 UTF-16 units and an ellipsis, and never a lone surrogate.
        let long = HeadTailReader.firstPrompt(try text("long prompt past the truncation"))
        XCTAssertEqual(long.utf16.count, 201, "200 units and the ellipsis")
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
        XCTAssertEqual(long, String(Self.longTitle.prefix(200)) + "\u{2026}")
        let atCut = HeadTailReader.firstPrompt(try text("truncation cut at a surrogate pair"))
        XCTAssertEqual(atCut, String(repeating: "x", count: 198) + "\u{1F600}" + "\u{2026}",
                       "the pair fits inside the 200 units and survives whole")
        XCTAssertEqual(atCut.utf16.count, 201)
        let acrossCut = HeadTailReader.firstPrompt(try text("truncation cut across a surrogate pair"))
        XCTAssertEqual(acrossCut, String(repeating: "x", count: 199) + "\u{2026}",
                       "the cut would have split the pair, so the lone high surrogate is dropped")
        XCTAssertEqual(acrossCut.utf16.count, 200)
        XCTAssertFalse(acrossCut.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) },
                       "no lone surrogate survives the cut")

        XCTAssertTrue(BufferScan(Array(try text("isSidechain true first, spaced").utf8), keys: ["isSidechain"]).sidechain())
        XCTAssertFalse(BufferScan(Array(try text("isSidechain false first").utf8), keys: ["isSidechain"]).sidechain())
        XCTAssertFalse(BufferScan(Array(try text("isSidechain absent").utf8), keys: ["isSidechain"]).sidechain())
        XCTAssertTrue(BufferScan(Array(try text("cleared last-prompt").utf8), keys: ["type"]).clearedToEmpty())
        XCTAssertTrue(BufferScan(Array(try text("cleared last-prompt, spaced").utf8), keys: ["type"]).clearedToEmpty())
        XCTAssertFalse(BufferScan(Array(try text("last-prompt with a leaf").utf8), keys: ["type"]).clearedToEmpty())
        XCTAssertFalse(BufferScan(Array(try text("last-prompt not explicit").utf8), keys: ["type"]).clearedToEmpty())
        XCTAssertFalse(BufferScan(Array(try text("a later last-prompt overrides an earlier").utf8), keys: ["type"]).clearedToEmpty(),
                       "the last such line decides")
    }

    // MARK: - `type` is a key like any other

    /// The scan records `"type"` both as a line marker and as an ordinary hit. Without the second, four public entry
    /// points would answer `nil` for the one key a caller is most likely to ask about.
    func testTypeIsAnswerableAsAnOrdinaryKey() throws {
        let text = #"{"type":"user","cwd":"/invented/ten"}"# + "\n" + #"{"type": "last-prompt", "leafUuid": null}"#
        XCTAssertEqual(HeadTailReader.firstString(text, key: "type"), "user")
        XCTAssertEqual(HeadTailReader.lastString(text, key: "type"), "last-prompt")
        XCTAssertEqual(HeadTailReader.firstLineString(text, key: "type"), "user")
        XCTAssertEqual(HeadTailReader.lastLineString(text, type: nil, key: "type"), "last-prompt")
        XCTAssertEqual(HeadTailReader.lastLineString(text, type: "last-prompt", key: "type"), "last-prompt",
                       "the key and the type prefilter may be the same key")
        XCTAssertEqual(Reference.lastString(text, key: "type"), "last-prompt")
    }

    // MARK: - The reference: the implementation as it stood at 835a8d2, copied verbatim

    /// Copied from `Reader/HeadTailReader.swift` and `Index/TranscriptIndex.swift` at commit `835a8d2`, with only the
    /// access levels changed. It is the oracle, not a second opinion: equality with it is the statement that the byte
    /// rewrite changed no behaviour.
    enum Reference {
        /// `G1`: first occurrence of `"key":"…"` (or `"key": "…"`) anywhere in `text`, JSON-unescaped.
        /// The two spellings are tried in that order — the unspaced one wins even when it occurs later, as the engine's does.
        static func firstString(_ text: String, key: String) -> String? {
            for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
                guard let found = text.range(of: pattern, options: .literal) else { continue }
                if let end = closingQuote(text, from: found.upperBound) { return unescape(String(text[found.upperBound..<end])) }
            }
            return nil
        }

        /// `Gf`: last occurrence, JSON-unescaped. "Last" is by start offset across both spellings, not by spelling order.
        static func lastString(_ text: String, key: String) -> String? {
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
        /// and — when a type is given — a `"type":"<type>"` marker, parsed as JSON, its string field `key`.
        ///
        /// One deliberate, bounded divergence from the engine: `V`'s substring prefilter is written unspaced only
        /// (`"type":"<type>"`, bundle line 13402), so it never matches a line spelled `"type": "<type>"`. The committed
        /// recordings are re-serialised with that space, so the engine's literal would find nothing in them. Both spellings
        /// are accepted here, exactly as `G1`/`Gf` already accept both. The widening cannot produce a false positive: this
        /// is only a prefilter, and the post-parse guard below reproduces the engine's own `u.type === r` check (line 13405).
        /// It cannot produce a false negative on real engine bytes either, being a strict superset of the engine's literal.
        static func lastLineString(_ text: String, type: String?, key: String) -> String? {
            let typeMarks = type.map { ["\"type\":\"\($0)\"", "\"type\": \"\($0)\""] }
            let keyMark = "\"\(key)\":"
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
                guard line.contains(keyMark), typeMarks.map({ marks in marks.contains { line.contains($0) } }) ?? true else { continue }
                guard let object = object(String(line)) else { continue }
                if let type, object["type"]?.stringValue != type { continue }
                if let value = object[key]?.stringValue { return value }
            }
            return nil
        }

        /// `VQ`: scanning lines from the start, the first line containing `"key":` that parses to an object whose `key` is a string.
        static func firstLineString(_ text: String, key: String) -> String? {
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
        static func firstPrompt(_ head: String) -> String {
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
        static func skipsAsMarkup(_ text: String) -> Bool {
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

        static func between(_ text: String, _ open: String, _ close: String) -> String? {
            guard let start = text.range(of: open, options: .literal), let end = text.range(of: close, options: .literal, range: start.upperBound..<text.endIndex) else { return nil }
            return String(text[start.upperBound..<end.lowerBound])
        }

        /// The engine's `le`: a prefix of `n` UTF-16 units that never ends on a lone high surrogate.
        static func truncate(_ text: String, _ limit: Int) -> String {
            let units = Array(text.utf16)
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

        /// The scan `G1`/`Gf` share: the next unescaped `"` at or after `from`.
        static func closingQuote(_ text: String, from: String.Index) -> String.Index? {
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

        static func object(_ line: String) -> [String: JSONValue]? {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return nil }
            return value.objectValue
        }

        /// True when the head carries an `"isSidechain":true` before any `"isSidechain":false`. Both spellings of the
        /// separator are accepted, because the committed recordings are re-serialised with a space after the colon.
        static func sidechain(_ head: String) -> Bool {
            func firstOffset(_ value: String) -> Int? {
                ["\"isSidechain\":\(value)", "\"isSidechain\": \(value)"]
                    .compactMap { head.range(of: $0, options: .literal).map { head.distance(from: head.startIndex, to: $0.lowerBound) } }
                    .min()
            }
            guard let trueAt = firstOffset("true") else { return false }
            guard let falseAt = firstOffset("false") else { return true }
            return trueAt < falseAt
        }

        /// The last `last-prompt` line in the tail, cleared: a null `leafUuid` and an explicit `true`.
        static func clearedToEmpty(_ tail: String) -> Bool {
            let marks = ["\"type\":\"last-prompt\"", "\"type\": \"last-prompt\""]
            for line in tail.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
                guard marks.contains(where: { line.contains($0) }) else { continue }
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let object = value.objectValue, object["type"]?.stringValue == "last-prompt" else { continue }
                guard case .null? = object["leafUuid"] else { return false }
                return object["explicit"]?.boolValue == true
            }
            return false
        }
    }
}
