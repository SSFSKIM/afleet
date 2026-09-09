import AppKit
import Foundation
import XCTest
@testable import Afleet

/// C6.1 Task 3: the frozen prefix, the live tail and the rate the model publishes at (child spec §4).
///
/// **What each of these would catch.** A split that falls inside an open fenced block and lexes the
/// fragment as prose — or, worse, drops the text either side of the fence; a tail parsed as markdown
/// on every delta; a publish per delta, which is the cost the whole of §4 exists to bound.
///
/// Every input is invented (§11). The answers are counts, characters and rendered attributes.
@MainActor
final class StreamingSplitTests: XCTestCase {

    private let markdown = MarkdownText()
    private let highlighter = CodeHighlighter()

    /// A row that has consumed one fragment, with the phases discarded.
    private func row(_ fragments: [String]) -> RenderedRow {
        var phases = RenderPhases()
        var row = RenderedRow(key: "row-under-test", source: "")
        row.settle(markdown: markdown, highlighter: highlighter)
        for fragment in fragments {
            row.append(fragment, markdown: markdown, highlighter: highlighter, phases: &phases)
        }
        return row
    }

    // MARK: - The open-fence re-prepend

    /// A prefix ending inside a fenced block keeps lexing as code, and nothing either side of the
    /// split is lost (parity §41.17).
    ///
    /// **Discriminating, twice.** The block boundary here — the blank line inside the code — falls
    /// inside an open fence. Pre-fix the whole closed prefix was replaced by the fence's opening line
    /// alone: the paragraph before the fence and the first line of code were dropped from both the
    /// settled blocks and the tail, so a streaming message silently lost text. And without the
    /// re-prepend at all the tail begins mid-program, which lexes as prose and flickers between code
    /// and text on every delta.
    func testTheSplitReprependsAnOpenFence() {
        let row = row(["An introduction.\n\n```swift\nlet x = 1\n\nlet y = 2"])

        XCTAssertTrue(row.tail.hasPrefix("```swift"),
                      "the tail begins with \(row.tail.prefix(8).count) character(s) that are not the fence's opening line")
        XCTAssertTrue(row.tail.contains("let x = 1") && row.tail.contains("let y = 2"),
                      "the \(row.tail.count)-character tail lost a line of the open fence")
        XCTAssertEqual(row.settled.count, 1,
                       "the prefix before the fence settled into \(row.settled.count) block(s)")
        XCTAssertTrue(row.settled.first?.string.contains("An introduction") ?? false,
                      "the paragraph before the fence was dropped by the split")
    }

    /// The tail is plain text and is never parsed (§4).
    func testTheTailIsNeverParsed() {
        let row = row(["A settled **paragraph**.\n\nA tail with **markdown** in it"])

        XCTAssertTrue(row.tail.contains("**markdown**"),
                      "the tail's \(row.tail.count) character(s) no longer hold their markdown delimiters")
        // The floor: a row that settled nothing would have an unparsed tail trivially.
        XCTAssertEqual(row.settled.count, 1,
                       "the closed block settled into \(row.settled.count) block(s)")
        let settled = row.settled.first ?? NSAttributedString(string: "")
        XCTAssertFalse(settled.string.contains("**"),
                       "the settled block kept its markdown delimiters, so it was not parsed")
        var bold = 0
        settled.enumerateAttribute(.font, in: NSRange(location: 0, length: settled.length)) { value, _, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { bold += 1 }
        }
        XCTAssertGreaterThanOrEqual(bold, 1, "the settled block has \(bold) bold run(s)")
    }

    // MARK: - Thirty hertz

    /// A burst inside one window is one publish, and a lone delta after quiet is one publish within
    /// the window (§4).
    ///
    /// **Discriminating.** Pre-fix the effects loop published on every delta, so this burst cost a
    /// hundred publishes — a hundred whole-timeline reads, a hundred table diffs and a hundred row
    /// reloads for one message's worth of text.
    func testThirtyHertzCoalescing() async {
        let counter = PublishCounter()
        let coalescer = PublishCoalescer { await counter.record() }

        for index in 0..<100 {
            coalescer.request()
            // A burst is not a tight loop: yielding lets the armed window run if it is going to.
            if index % 10 == 0 { await Task.yield() }
        }
        try? await Task.sleep(for: .milliseconds(120))
        let burst = await counter.count
        XCTAssertGreaterThanOrEqual(burst, 1, "a hundred deltas produced \(burst) publish(es)")
        XCTAssertLessThanOrEqual(burst, 4, "a hundred deltas inside one burst produced \(burst) publish(es)")

        // Quiet, then one delta: it publishes on the trailing edge and is not held for a burst that
        // never comes.
        let before = await counter.count
        let started = Date()
        coalescer.request()
        var published = false
        while Date().timeIntervalSince(started) < 0.5 {
            if await counter.count > before { published = true; break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(published, "a single delta after quiet produced no publish within the wait")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2,
                          "a single delta after quiet took \(Int(Date().timeIntervalSince(started) * 1000)) ms to publish")
    }

    // MARK: - The completed message

    /// A message that is no longer streaming is parsed in full: the boundary rule is the live
    /// tail's alone (§4).
    ///
    /// **Discriminating.** `MarkdownBody` is the one path every durable message row draws through,
    /// and it settled the message the way the streaming path settles a fragment — everything after
    /// the last blank line stayed an unparsed tail. A message ending in `**Done**` therefore showed
    /// its own asterisks for ever, with nothing left to arrive that would finalise it. The floor is
    /// the assertion that the prose before the boundary is still there, so a body that parsed
    /// nothing at all would not pass by dropping the tail instead.
    func testACompletedMessageIsParsedInFull() {
        let drawn = Self.completed("Working on it.\n\n**Done**")
        let rendered = drawn.blocks.joined()
        XCTAssertTrue(drawn.tail.isEmpty,
                      "a completed message kept a \(drawn.tail.count)-character tail unparsed")
        XCTAssertFalse(rendered.contains("**"),
                       "the completed message drew its own delimiters; \(rendered.count) character(s) were rendered")
        XCTAssertTrue(rendered.contains("Done"), "the completed message's last block was lost")
        XCTAssertTrue(rendered.contains("Working on it."),
                      "the completed message's first block was lost")
        XCTAssertTrue(drawn.isBold, "the completed message's last block was parsed but not emphasised")
    }

    /// What `MarkdownBody` draws for one source, reduced to what an assertion needs.
    ///
    /// `nonisolated`, and returning strings rather than the row: `RenderedRow` holds
    /// `NSAttributedString`s and is not `Sendable`, so the reduction happens where the row is built
    /// and only the answers cross back.
    nonisolated private static func completed(_ source: String) -> (blocks: [String], tail: String, isBold: Bool) {
        let row = MarkdownBody(key: "row-under-test", source: source).settled
        var bold = false
        for block in row.settled {
            let range = (block.string as NSString).range(of: "Done")
            guard range.location != NSNotFound else { continue }
            block.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont,
                   font.fontDescriptor.symbolicTraits.contains(.bold) { bold = true }
            }
        }
        return (row.settled.map(\.string), row.tail, bold)
    }
}

/// What a coalescer publishes into, for the rate assertion above.
private actor PublishCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
