import AppKit
import Foundation
import XCTest
@testable import Afleet

/// C6.1 Task 3: the markdown pipeline and the highlighter behind it (child spec §5, §6).
///
/// **What each of these would catch.** Raw HTML passed through instead of drawn as characters; a
/// single tilde read as strikethrough where the engine reads it as text; a table row wider than its
/// header quietly losing its last cell; a table drawn as preformatted text; a cache that parses the
/// same block twice, or one that returns the same block for every key; a grammar dropped by a pin
/// bump; highlighting on the main thread; highlighting an open fence.
///
/// Every input here is invented (§11). Nothing asserts over an `ItemID` or anything holding one:
/// the answers are rendered characters, attribute runs and counts.
final class MarkdownRenderingTests: XCTestCase {

    // MARK: - Helpers

    private func build(_ source: String, highlighter: CodeHighlighter = CodeHighlighter()) -> NSAttributedString {
        var phases = RenderPhases()
        return MarkdownText.build(source, highlighter: highlighter, phases: &phases)
    }

    /// How many attribute runs an attributed string has.
    private func runs(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { _, _, _ in count += 1 }
        return count
    }

    /// The distinct foreground colours a highlighted block ended up with.
    private func colours(_ text: NSAttributedString) -> Int {
        var seen: Set<String> = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let colour = value as? NSColor { seen.insert(colour.description) }
        }
        return seen.count
    }

    /// Whether any run of this string is struck through.
    private func isStruckThrough(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let style = value as? Int, style != 0 { found = true }
        }
        return found
    }

    /// How many distinct table cells the string's paragraph styles describe. Zero for text that is
    /// not a table, which is the whole of the difference this suite asserts on.
    private func tableCells(_ text: NSAttributedString) -> Int {
        var seen: Set<ObjectIdentifier> = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for block in style.textBlocks where block is NSTextTableBlock { seen.insert(ObjectIdentifier(block)) }
        }
        return seen.count
    }

    /// Waits, with a deadline, for a condition a detached task fulfils. Returns whether it was met,
    /// so the caller asserts the outcome rather than discarding the wait.
    private func wait(upTo seconds: Double, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - Raw HTML

    /// A `<script>` in model text is drawn as characters, and is never passed through.
    ///
    /// **Discriminating.** Against the pre-fix walk an `HTMLBlock` fell to the default arm, whose
    /// plain-text projection of a node with no children is the empty string: the tag was not passed
    /// through — it was absent from the rendered text entirely, which is the same defect wearing the
    /// opposite face. Parity §41.17 names raw HTML as the one row a GUI must not copy from the
    /// terminal, and "silently dropped" is not what escaping means either.
    func testRawHTMLIsEscaped() {
        let rendered = build("before\n\n<script>alert(1)</script>\n\nafter <b>bold</b> text")
        XCTAssertTrue(rendered.string.contains("<script>alert(1)</script>"),
                      "the HTML block did not reach the reader as characters; \(rendered.length) character(s) were rendered")
        XCTAssertTrue(rendered.string.contains("<b>") && rendered.string.contains("</b>"),
                      "the inline HTML tags were not drawn as characters")
        // The floor: a renderer that emitted its input verbatim and parsed nothing would pass the
        // two assertions above, so the prose around the tags has to have been rendered too.
        XCTAssertTrue(rendered.string.contains("before") && rendered.string.contains("after"),
                      "the prose around the HTML was lost; \(rendered.length) character(s) were rendered")
    }

    // MARK: - The two reproducible `marked` overrides

    /// The two overrides of parity §41.17 that survive the parser, and the native table beside them.
    ///
    /// **Discriminating on both halves.** Pre-fix, `swift-markdown` reads `~one~` as strikethrough
    /// exactly as it reads `~~two~~` — the engine's vendored `marked` does not — and cmark silently
    /// truncates a row wider than its header to the header's width, so the third cell of a wide row
    /// disappeared with nothing said. The engine bails such a table to a paragraph, and a dropped
    /// cell is worse than an ugly one.
    func testSingleTildeIsNotStrikethroughAndAWideRowBailsToAParagraph() {
        let single = build("a ~one~ b")
        XCTAssertTrue(single.string.contains("~one~"),
                      "a single tilde was consumed as a delimiter; the run reads \(single.length) character(s)")
        XCTAssertFalse(isStruckThrough(single), "a single tilde struck its text through")

        let double = build("a ~~two~~ b")
        XCTAssertFalse(double.string.contains("~~"), "a double tilde left its delimiters in the text")
        XCTAssertTrue(isStruckThrough(double), "a double tilde did not strike its text through")

        // A row wider than its header bails the whole table to a paragraph: the cell that cmark
        // would have dropped is in the rendered text, and no table structure was built.
        let wide = build("| a | b |\n| - | - |\n| 1 | 2 | 3 |\n")
        XCTAssertTrue(wide.string.contains("3"),
                      "the wide row's last cell was dropped; \(wide.length) character(s) were rendered")
        XCTAssertEqual(tableCells(wide), 0,
                       "the wide table built \(tableCells(wide)) table cell(s) instead of bailing to a paragraph")

        // The floor, and §5's "tables are native": a well-formed table is a real table and not
        // preformatted text, or the assertion above would pass against a renderer with no tables at
        // all.
        let table = build("| a | b |\n| - | - |\n| 1 | 2 |\n")
        XCTAssertEqual(tableCells(table), 4,
                       "a two-by-two table built \(tableCells(table)) table cell(s)")
        XCTAssertFalse(table.string.contains("|"),
                       "the table drew its own source pipes, which is the preformatted rendering §5 replaces")
        // And the row draws it as one: a table block takes the TextKit path, because SwiftUI's
        // `Text` drops the paragraph styles the cells live in.
        XCTAssertTrue(TimelineTextMeasure.holdsATable(table), "the table block does not read as a table to the row")
        XCTAssertFalse(TimelineTextMeasure.holdsATable(wide), "the bailed table still reads as a table to the row")
        XCTAssertGreaterThan(TimelineTextMeasure.height(of: table, width: 320), 0,
                             "the table laid out to no height at 320 points")
    }

    /// The third override cannot be reproduced, and this is where that is written down.
    ///
    /// The engine disables link reference definitions entirely, so `[text][id]` reaches the terminal
    /// as literal characters. `swift-markdown` resolves the definition before the tree exists, so
    /// afleet renders a link. The divergence is in afleet's favour and is asserted here rather than
    /// hidden, so a reader who notices the difference finds a test instead of a surprise.
    func testLinkReferenceDefinitionsDiverge() {
        let rendered = build("[text][id] follows\n\n[id]: https://example.invalid/page")
        XCTAssertFalse(rendered.string.contains("[text][id]"),
                       "the reference link rendered literally, which is the terminal's behaviour and not this renderer's")
        XCTAssertTrue(rendered.string.contains("text"),
                      "the reference link's label was lost; \(rendered.length) character(s) were rendered")
        var linkRuns = 0
        rendered.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let colour = value as? NSColor, colour == NSColor.linkColor { linkRuns += 1 }
        }
        XCTAssertGreaterThanOrEqual(linkRuns, 1, "the resolved reference drew \(linkRuns) link run(s)")
    }

    // MARK: - The cache

    /// One parse per content, and one per *distinct* content.
    ///
    /// The second half is the floor: a "cache" that answered every key with one constant string
    /// would pass the first half and fail here.
    func testMarkdownIsParsedOncePerContent() {
        let markdown = MarkdownText()
        let highlighter = CodeHighlighter()
        var phases = RenderPhases()
        let source = "A paragraph with **emphasis** in it."
        for _ in 0..<8 { _ = markdown.attributed(source, highlighter: highlighter, phases: &phases) }
        XCTAssertEqual(markdown.parseCount, 1,
                       "eight renders of one content cost \(markdown.parseCount) parse(s)")

        for index in 0..<8 {
            _ = markdown.attributed("Paragraph number \(index).", highlighter: highlighter, phases: &phases)
        }
        XCTAssertEqual(markdown.parseCount, 9,
                       "eight distinct contents cost \(markdown.parseCount - 1) parse(s) beyond the first")
    }

    // MARK: - The highlighter

    /// **This is the test that replaces trusting the README.** The resolved package highlights the
    /// languages this app claims it does, and a pin bump that drops a grammar fails here loudly
    /// rather than showing a reader unhighlighted code.
    func testHighlightKitCoversTheLanguagesWeClaim() async {
        let samples: [String: String] = [
            "swift": "let x = 1 // a comment\nfunc f() -> Int { return x }",
            "python": "def f(a):\n    # a comment\n    return \"s\"",
            "typescript": "interface A { b: string }\nconst c: A = { b: \"x\" };",
            "javascript": "function f(a) { return \"x\" + a; } // a comment",
            "json": "{ \"a\": 1, \"b\": [true, null] }",
            "bash": "if [ -f x ]; then echo \"hi\"; fi # a comment",
            "ruby": "def f(a)\n  # a comment\n  puts \"x\"\nend",
            "csharp": "public class A { // a comment\n  int b = 1;\n}",
            "sql": "SELECT a FROM t WHERE b = 'x';",
            "yaml": "# a comment\na: 1\nb: \"x\"\n",
            "rust": "fn main() { let x = \"s\"; } // a comment",
            "go": "func main() { s := \"x\" } // a comment",
            "java": "public class A { int b = 1; } // a comment",
            "php": "<?php function f($a) { return \"x\"; } ?>",
            "lua": "local function f(a) return \"x\" end -- a comment",
        ]
        let claimed: Set<String> = ["swift", "python", "typescript", "javascript", "json", "bash", "ruby",
                                    "csharp", "sql", "yaml", "rust", "go", "java", "php", "lua"]
        // Two-directional: the samples are exactly the claim, so a language quietly dropped from
        // either side is a failure rather than a shorter loop.
        XCTAssertEqual(Set(samples.keys), claimed,
                       "the samples cover \(samples.count) language(s) against \(claimed.count) claimed")

        let highlighter = CodeHighlighter()
        await highlighter.warm(samples.map { (code: $0.value, language: $0.key) })
        for (language, code) in samples {
            let styled = highlighter.styled(code: code, language: language)
            XCTAssertGreaterThanOrEqual(runs(styled), 2,
                                        "\(language) produced \(runs(styled)) attribute run(s) over a \(code.count)-character sample")
            XCTAssertGreaterThanOrEqual(colours(styled), 2,
                                        "\(language) produced \(colours(styled)) distinct colour(s) over a \(code.count)-character sample")
        }
    }

    /// A fence tagged with a language no grammar covers is monospaced text, not empty and not a
    /// crash. This is the fallback §6 says is the ordinary path and not a rainy-day branch.
    func testAnUnknownLanguageFallsBackToPlainMonospaced() {
        let highlighter = CodeHighlighter()
        let code = "++>>[.]<<--"
        let styled = highlighter.styled(code: code, language: "a-language-with-no-grammar")
        XCTAssertEqual(styled.string, code,
                       "the fallback rendered \(styled.length) character(s) of a \(code.count)-character block")
        XCTAssertEqual(runs(styled), 1, "the fallback produced \(runs(styled)) attribute run(s), not one")
        let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName,
                       "the fallback is not the monospaced face a code block is drawn in")
        XCTAssertEqual(highlighter.highlightRequests, 0,
                       "an unknown language asked the grammar set for \(highlighter.highlightRequests) highlight(s)")
    }

    /// **A trace assertion, and stated as one:** the property is *where* the highlighter's body
    /// runs, and no assertion over the string it returns can see that. So the work records the
    /// thread it ran on and this reads the counts back. The dangerous path — highlighting on the
    /// main thread while a message streams — is asserted never to have been entered.
    func testHighlightingNeverRunsOnTheMainThread() async {
        let highlighter = CodeHighlighter()
        _ = highlighter.styled(code: "let x = 1\nlet y = x + 1", language: "swift")
        let ran = await wait(upTo: 5) { highlighter.offMainHighlights + highlighter.mainThreadHighlights > 0 }
        XCTAssertTrue(ran, "no highlight ran within the wait; \(highlighter.highlightRequests) were requested")
        XCTAssertEqual(highlighter.mainThreadHighlights, 0,
                       "\(highlighter.mainThreadHighlights) highlight(s) ran on the main thread")
        XCTAssertGreaterThanOrEqual(highlighter.offMainHighlights, 1,
                                    "\(highlighter.offMainHighlights) highlight(s) ran off the main thread")
    }

    /// An open fenced block asks for no highlight; the closing fence asks for exactly one (§6).
    ///
    /// Highlighting a fragment that is still growing is the per-delta cost §4 exists to avoid, and
    /// it also mis-lexes: the fragment is not a program yet.
    func testHighlightingWaitsForTheClosingFence() {
        let markdown = MarkdownText()
        let highlighter = CodeHighlighter()
        var phases = RenderPhases()
        var row = RenderedRow(key: "row-under-test", source: "")
        row.settle(markdown: markdown, highlighter: highlighter)

        row.append("```swift\nlet x = 1\n", markdown: markdown, highlighter: highlighter, phases: &phases)
        XCTAssertEqual(highlighter.highlightRequests, 0,
                       "an open fence asked for \(highlighter.highlightRequests) highlight(s)")
        // The floor: a row that consumed nothing would also request nothing.
        XCTAssertTrue(row.tail.contains("let x = 1"),
                      "the open fence's \(row.tail.count)-character tail does not hold what was appended")

        row.append("```\n\nafter", markdown: markdown, highlighter: highlighter, phases: &phases)
        XCTAssertEqual(highlighter.highlightRequests, 1,
                       "the closing fence asked for \(highlighter.highlightRequests) highlight(s)")
    }
}
