import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Contract X4 and X7 as amended on 2026-09-05: the channel's read model and the recent-URL query C7's Browser
/// quick-open calls. Every assertion here is over `ChannelTimeline.items` — the same items the renderer reads — so
/// the query can never disagree with what the timeline shows. No fixture byte is compared against a literal: the one
/// fixture-driven test computes its expected set from the recording itself, and every other item is constructed from
/// our own types with invented identifiers (C3 constraints).
final class ChannelTimelineQueryTests: XCTestCase {

    // MARK: - The one fixture that carries a URL at all

    /// `dialog-refusal-fallback` is a **synthetic** fixture, not a recording of a live engine: no recorded fixture
    /// carries a URL in tool output, and this one carries its URL in assistant text, inside the refusal message's
    /// placeholder prose. So what this proves is extraction over that synthetic shape — an `assistant` frame whose
    /// text block names a URL in parentheses — reduced by the real `WireReducer` and read back through
    /// `ChannelTimeline.items`.
    ///
    /// The expected set is computed independently: a regex over the recording's own assistant text blocks, read
    /// straight from `frames.ndjson` and never through the reducer.
    func testSyntheticDialogAssistantTextYieldsItsURLs() throws {
        let fixture = try FixtureCorpus.named("dialog-refusal-fallback")
        XCTAssertTrue(fixture.synthetic, "this test is written against a synthetic fixture and says so")

        let reducer = try FixtureWireReplay.replay(fixture)
        let timeline = ChannelTimeline(durable: reducer.durable, overlay: reducer.overlay, preview: reducer.preview)
        let found = timeline.recentURLs(limit: 10)

        var expected: Set<String> = []
        var assistantTexts = 0
        for recorded in try fixture.frames() where recorded.direction == "out" {
            guard recorded.value["type"]?.stringValue == "assistant" else { continue }
            for block in recorded.value["message"]?["content"]?.arrayValue ?? [] {
                guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue else { continue }
                assistantTexts += 1
                expected.formUnion(Self.urlsByRegex(in: text))
            }
        }
        XCTAssertEqual(assistantTexts, 7, "the synthetic fixture's out-direction assistant text blocks")
        XCTAssertEqual(expected.count, 1, "the independent regex found the fixture's URL set: \(expected.sorted())")

        XCTAssertEqual(Set(found.map(\.url.absoluteString)), expected,
                       "recentURLs found exactly the URLs the recording's assistant text carries")
        // Two assistant frames carry the same URL, so the query must collapse them to one row with two sightings.
        XCTAssertEqual(found.count, 1, "the same URL in two assistant messages is one SeenURL")
        let only = try XCTUnwrap(found.first)
        XCTAssertNotEqual(only.firstSeen, only.lastSeen, "two different items mentioned it")
        let ids = timeline.items.map(\.id)
        let first = try XCTUnwrap(ids.firstIndex(of: only.firstSeen)), last = try XCTUnwrap(ids.firstIndex(of: only.lastSeen))
        XCTAssertLessThan(first, last, "firstSeen is the earlier item in `items` order")
    }

    // MARK: - Which kinds contribute

    /// Tool-result text and local-command output, on items the test constructs from our own types — a `ToolCallItem`
    /// and a `NotificationItem`. Neither pretends to be a recording; no fixture carries a URL in either place.
    func testToolResultAndLocalCommandOutputContribute() throws {
        let stringResult = Self.toolCall(key: "tool-1", at: 10,
                                         result: .string("Serving on https://example.test/dev-server\n"))
        let blockResult = Self.toolCall(key: "tool-2", at: 20,
                                        result: .array([.object(["type": .string("text"),
                                                                 "text": .string("see https://example.test/docs/page")])]))
        let wireNotification = Self.notification(key: "notif-1", at: 30, notificationKey: "local_command_output",
                                                 text: "opened https://example.test/from-wire", fileOnly: false)
        let fileNotification = Self.notification(key: "notif-2", at: 40, notificationKey: "local_command",
                                                 text: "opened https://example.test/from-file", fileOnly: true)
        // A notification of some other key must not contribute, or "local command output" would mean "any notice".
        let otherNotification = Self.notification(key: "notif-3", at: 50, notificationKey: "informational",
                                                  text: "see https://example.test/not-a-command", fileOnly: true)

        let timeline = ChannelTimeline(durable: DurableProjection(items: [stringResult, blockResult]),
                                       overlay: Overlay(notifications: [wireNotification, fileNotification, otherNotification]
                                        .compactMap { if case .notification(let n) = $0 { n } else { nil } }))
        XCTAssertEqual(Set(timeline.recentURLs(limit: 10).map(\.url.absoluteString)),
                       ["https://example.test/dev-server", "https://example.test/docs/page",
                        "https://example.test/from-wire", "https://example.test/from-file"],
                       "both tool-result spellings and both local-command spellings contribute, nothing else does")
    }

    /// The negative half of `URLSources.contributing`, written so it cannot pass trivially: the user message and the
    /// thinking block each carry a URL, and a contributing kind in the same timeline carries a third. Asserting only
    /// the two absences would pass over items that had no URL in them at all, so the third assertion proves the
    /// scanner ran over this very timeline.
    func testUserMessagesAndThinkingDoNotContribute() throws {
        let typed = URL(string: "https://example.test/typed-by-the-person")!
        let thought = URL(string: "https://example.test/inside-the-thinking")!
        let said = URL(string: "https://example.test/named-by-the-model")!

        let user = TimelineItem.userMessage(UserMessageItem(
            id: Self.id("user-1"), timestamp: Self.at(10), provenance: Self.provenance(),
            blocks: [try Self.textBlock("please read \(typed.absoluteString)")],
            text: "please read \(typed.absoluteString)"))
        let assistant = TimelineItem.assistantMessage(AssistantMessageItem(
            id: Self.id("assistant-1"), timestamp: Self.at(20), provenance: Self.provenance(),
            blocks: [try Self.thinkingBlock("I could open \(thought.absoluteString)"),
                     try Self.textBlock("look at \(said.absoluteString)")]))

        let timeline = ChannelTimeline(durable: DurableProjection(items: [user, assistant]))
        let found = Set(timeline.recentURLs(limit: 10).map(\.url))

        XCTAssertTrue(found.contains(said), "the assistant's text block is a contributing kind and its URL was found")
        XCTAssertFalse(found.contains(typed), "a URL the person typed is not a URL the channel showed")
        XCTAssertFalse(found.contains(thought), "a thinking block is not rendered and does not contribute")
        XCTAssertEqual(found, [said], "exactly one of the three URLs in this timeline contributes")
    }

    // MARK: - Ordering, de-duplication and the limit

    func testDeDuplicationAndMostRecentFirst() throws {
        let repeated = "https://example.test/repeated"
        let once = "https://example.test/once"
        let early = Self.assistant(key: "a-early", at: 10, text: "first mention of \(repeated)")
        let middle = Self.assistant(key: "a-middle", at: 20, text: "only mention of \(once)")
        let late = Self.assistant(key: "a-late", at: 30, text: "second mention of \(repeated)")

        let found = ChannelTimeline(durable: DurableProjection(items: [early, middle, late])).recentURLs(limit: 10)

        XCTAssertEqual(found.map(\.url.absoluteString), [repeated, once],
                       "one row per URL, ordered by the last item that mentioned each, most recent first")
        let row = try XCTUnwrap(found.first)
        XCTAssertEqual(row.firstSeen, early.id, "firstSeen is the earlier of the two items")
        XCTAssertEqual(row.firstSeenAt, Self.at(10))
        XCTAssertEqual(row.lastSeen, late.id, "lastSeen is the later of the two items")
        XCTAssertEqual(row.lastSeenAt, Self.at(30))
        let second = try XCTUnwrap(found.last)
        XCTAssertEqual(second.firstSeen, middle.id)
        XCTAssertEqual(second.firstSeen, second.lastSeen, "a URL seen once is its own first and last sighting")
    }

    func testLimit() throws {
        let items = (1...4).map { n in
            Self.assistant(key: "a-\(n)", at: Double(n) * 10, text: "see https://example.test/\(n)")
        }
        let timeline = ChannelTimeline(durable: DurableProjection(items: items))

        XCTAssertEqual(timeline.recentURLs(limit: 10).map(\.url.absoluteString),
                       ["https://example.test/4", "https://example.test/3",
                        "https://example.test/2", "https://example.test/1"])
        XCTAssertEqual(timeline.recentURLs(limit: 2).map(\.url.absoluteString),
                       ["https://example.test/4", "https://example.test/3"],
                       "the limit takes the most recent, not the first found")
        XCTAssertEqual(timeline.recentURLs(limit: 0), [], "a limit of zero asks for nothing")
    }

    /// A missing timestamp must mean one thing in this file, not two. `items` renders an item with no timestamp
    /// last — the newest position — so the query must return its URL first. `RecordReducer` yields a nil timestamp
    /// whenever a record carries none it can parse (unlike `WireReducer`, which falls back to the arrival instant),
    /// so this is a shape the durable half really produces.
    ///
    /// The second half pins the appearance-order tiebreak: two URLs last seen in the *same* item tie on recency by
    /// construction, and the scanner's preserved order is what breaks the tie. `Array.sorted` is not stable, so
    /// without a total comparator that order is not guaranteed to survive.
    func testUndatedItemsRankByRenderOrderAndTiesKeepAppearanceOrder() throws {
        let dated = Self.assistant(key: "a-dated", at: 10, text: "see https://example.test/dated")
        let undated = TimelineItem.assistantMessage(AssistantMessageItem(
            id: Self.id("a-undated"), timestamp: nil, provenance: Self.provenance(),
            blocks: [try Self.textBlock("see https://example.test/undated")]))

        let timeline = ChannelTimeline(durable: DurableProjection(items: [dated, undated]))
        XCTAssertEqual(timeline.items.map(\.id.key), ["a-dated", "a-undated"],
                       "an item with no timestamp renders last, which is the newest position")
        XCTAssertEqual(timeline.recentURLs(limit: 10).map(\.url.absoluteString),
                       ["https://example.test/undated", "https://example.test/dated"],
                       "the query agrees with the merge: the item rendered last is the most recent one")

        let together = Self.assistant(key: "a-together", at: 20,
                                      text: "first https://example.test/one then https://example.test/two")
        let both = ChannelTimeline(durable: DurableProjection(items: [together])).recentURLs(limit: 10)
        XCTAssertEqual(both.map(\.url.absoluteString), ["https://example.test/one", "https://example.test/two"],
                       "two URLs last seen in the same item keep the order the scanner found them in")
    }

    // MARK: - The scanner itself

    func testScannerTrimsTrailingPunctuationAndClosingBrackets() {
        func scan(_ text: String) -> [String] { URLScanner.urls(in: text).map(\.absoluteString) }

        XCTAssertEqual(scan("(https://example.test/a)."), ["https://example.test/a"],
                       "a closing bracket ends the URL and the sentence's full stop is trimmed")
        XCTAssertEqual(scan("see <https://example.test/b> now"), ["https://example.test/b"])
        XCTAssertEqual(scan("[https://example.test/c], and"), ["https://example.test/c"])
        XCTAssertEqual(scan("\"https://example.test/d\";"), ["https://example.test/d"])
        XCTAssertEqual(scan("'https://example.test/e'?"), ["https://example.test/e"])
        XCTAssertEqual(scan("http://example.test/f!"), ["http://example.test/f"], "http is scanned as well as https")
        XCTAssertEqual(scan("ends a sentence: https://example.test/g:"), ["https://example.test/g"])
        XCTAssertEqual(scan("https://example.test/h?q=1&r=2."), ["https://example.test/h?q=1&r=2"],
                       "only trailing sentence punctuation is trimmed, not punctuation inside a query")
        XCTAssertEqual(scan("a path that ends in a slash https://example.test/i/."), ["https://example.test/i/"],
                       "only `.,;:!?` are trimmed: a path's own trailing slash survives the sentence's full stop")

        XCTAssertEqual(scan("nothing here, and ftp://example.test/j is not scanned"), [])
        XCTAssertEqual(scan("a bare scheme https:// is dropped"), [], "a scheme with no body is not a URL")

        XCTAssertEqual(scan("https://example.test/k and again https://example.test/k"),
                       ["https://example.test/k", "https://example.test/k"],
                       "duplicates within one text are preserved: the caller de-duplicates")
        XCTAssertEqual(scan("https://example.test/second is after https://example.test/first only in wording; "
                            + "https://example.test/third"),
                       ["https://example.test/second", "https://example.test/first", "https://example.test/third"],
                       "order of appearance is preserved")
    }

    // MARK: - The merge

    func testItemsMergeOverlayByTimestamp() throws {
        let firstDurable = Self.assistant(key: "d-1", at: 10, text: "one")
        let secondDurable = Self.assistant(key: "d-2", at: 30, text: "two")
        let betweenCase = Self.notification(key: "o-between", at: 20, notificationKey: "informational",
                                            text: "between", fileOnly: true)
        let tieCase = Self.notification(key: "o-tie", at: 10, notificationKey: "informational",
                                        text: "tie", fileOnly: true)
        let overlay = Overlay(notifications: [betweenCase, tieCase].compactMap {
            if case .notification(let n) = $0 { n } else { nil }
        })

        let timeline = ChannelTimeline(durable: DurableProjection(items: [firstDurable, secondDurable]),
                                       overlay: overlay,
                                       preview: StreamingPreview(messageID: "msg-preview"))

        XCTAssertEqual(timeline.items.map(\.id.key),
                       ["d-1", "o-tie", "o-between", "d-2"],
                       "the overlay merges by timestamp, and a tie keeps the durable item first")
        XCTAssertEqual(timeline.items.count, timeline.durable.items.count + timeline.overlay.items.count,
                       "the merge neither drops nor invents an item; the preview contributes none")
        XCTAssertNotNil(timeline.preview, "the preview is held and deliberately not merged")
    }

    // MARK: - Construction helpers (our own types, invented identifiers)

    private static func stream() -> LogicalStream {
        LogicalStream(configHome: FileManager.default.temporaryDirectory.appendingPathComponent("afleet-channel-timeline"),
                      sessionID: SessionID(uuid: UUID(uuidString: "6a1c3d20-0000-4000-8000-0000000000c3")!),
                      name: .main)
    }
    private static func id(_ key: String) -> ItemID { ItemID(stream: stream(), key: key) }
    private static func provenance() -> Provenance { Provenance(stream: stream(), origin: .synthesised) }
    private static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_780_000_000 + seconds) }

    private static func assistant(key: String, at seconds: Double, text: String) -> TimelineItem {
        .assistantMessage(AssistantMessageItem(id: id(key), timestamp: at(seconds), provenance: provenance(),
                                               blocks: [(try? textBlock(text)) ?? .opaque(.null)]))
    }
    private static func toolCall(key: String, at seconds: Double, result: JSONValue) -> TimelineItem {
        .toolCall(ToolCallItem(id: id(key), timestamp: at(seconds), provenance: provenance(),
                               toolUseID: key, name: "Bash", rawInput: .object([:]), result: result, status: .completed))
    }
    private static func notification(key: String, at seconds: Double, notificationKey: String,
                                     text: String, fileOnly: Bool) -> TimelineItem {
        .notification(NotificationItem(id: id(key), timestamp: at(seconds), provenance: provenance(),
                                       key: notificationKey, text: text, level: "info", fileOnly: fileOnly))
    }

    /// A genuine `.text` block, built by decoding — `TextBlockFields`' memberwise initialiser is internal to `WireFrames`.
    private static func textBlock(_ text: String) throws -> ContentBlock {
        let value = JSONValue.object(["type": .string("text"), "text": .string(text)])
        return try JSONDecoder().decode(ContentBlock.self, from: try value.canonicalData())
    }
    private static func thinkingBlock(_ thinking: String) throws -> ContentBlock {
        let value = JSONValue.object(["type": .string("thinking"), "thinking": .string(thinking),
                                      "signature": .string("sig-invented")])
        return try JSONDecoder().decode(ContentBlock.self, from: try value.canonicalData())
    }

    /// The independent expectation for the fixture test: a regex, not `URLScanner`.
    private static func urlsByRegex(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "https?://[^\\s\"'<>)\\]]+")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            guard let matched = Range(match.range, in: text) else { continue }
            var candidate = String(text[matched])
            while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
            if !candidate.isEmpty, URL(string: candidate) != nil { out.insert(candidate) }
        }
        return out
    }
}
