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

    /// The link destinations the rendered text carries, as strings. Strings rather than URLs, so a
    /// failure prints one invented destination and not a URL's whole description.
    private func destinations(_ text: NSAttributedString) -> [String] {
        var found: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { found.append(url.relativeString) }
            if let string = value as? String { found.append(string) }
        }
        return found
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
            let styled = highlighter.styling(code: code, language: language).text
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
        let styled = highlighter.styling(code: code, language: "a-language-with-no-grammar").text
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
        _ = highlighter.styling(code: "let x = 1\nlet y = x + 1", language: "swift")
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

    // MARK: - Breaks and links

    /// A soft break is a space and a hard break is a newline — in prose, inside emphasis, and inside
    /// a heading (§5).
    ///
    /// **Discriminating.** `SoftBreak` and `LineBreak` are childless nodes, so the walk's plain-text
    /// projection of both was the empty string: two words either side of a wrapped line were
    /// concatenated into one, and a hard break was deleted outright. The engine renders with
    /// `breaks` off, which makes a soft break a space and not a newline — so both halves are
    /// asserted, or a renderer that turned every break into a newline would pass half of this.
    func testBreaksKeepTheWhitespaceTheyStandFor() {
        let soft = build("alpha\nbeta")
        XCTAssertTrue(soft.string.contains("alpha beta"),
                      "a soft break did not render as a space; \(soft.length) character(s) were rendered")

        let hard = build("alpha  \nbeta")
        XCTAssertTrue(hard.string.contains("alpha\nbeta"),
                      "a hard break did not render as a newline; \(hard.length) character(s) were rendered")
        XCTAssertFalse(hard.string.contains("alphabeta"), "a hard break was deleted rather than drawn")

        // Inside emphasis and inside a heading, which take the plain-text projection rather than the
        // inline walk: the same childless nodes, the same defect, two more paths.
        let strong = build("**alpha\nbeta**")
        XCTAssertTrue(strong.string.contains("alpha beta"),
                      "a soft break inside emphasis was dropped; \(strong.length) character(s) were rendered")
        let heading = build("alpha\nbeta\n===")
        XCTAssertTrue(heading.string.contains("alpha beta"),
                      "a soft break inside a heading was dropped; \(heading.length) character(s) were rendered")
    }

    /// A labelled link carries its destination, so the row has something to activate (§5).
    ///
    /// **Discriminating.** Pre-fix the link branch emitted the label, the font and the link colour
    /// and nothing else: the destination was discarded at the walk, so no attribute on the rendered
    /// text named where the link went and no activation could route it anywhere. The floor is the
    /// label beside it — a renderer that attached a destination and lost the text would be no more
    /// usable than one that did the reverse.
    func testALinkCarriesItsDestination() {
        let rendered = build("see [the page](https://example.invalid/page) now")
        XCTAssertEqual(destinations(rendered), ["https://example.invalid/page"],
                       "the link's destination reached the reader as \(destinations(rendered))")
        XCTAssertTrue(rendered.string.contains("the page"),
                      "the link's label was lost; \(rendered.length) character(s) were rendered")
        XCTAssertFalse(rendered.string.contains("https://"),
                       "the destination was drawn as text rather than carried as an attribute")

        // A path destination is carried exactly as written: resolving it needs the channel's cwd,
        // which the content-keyed cache must never see.
        let path = build("open [the file](docs/invented/notes.md) please")
        XCTAssertEqual(destinations(path), ["docs/invented/notes.md"],
                       "a relative destination reached the reader as \(destinations(path))")
    }

    // MARK: - The cache behind the highlighter

    /// A block that settled while its highlight was cold is rebuilt once the fill lands (§6).
    ///
    /// **Discriminating.** `styled` returns plain monospaced text on a cold request and fills behind
    /// the caller, and the markdown cache used to keep that plain fallback for ever: the fill landed
    /// in the highlighter's own cache and every later render of that block read the stale markdown
    /// entry instead, so a fenced block seen once was never highlighted at all. The floor is the
    /// cold render below it — a pipeline that highlighted synchronously would fail that assertion
    /// and make this one vacuous.
    func testASettledBlockIsRebuiltWhenItsHighlightLands() async {
        let markdown = MarkdownText()
        let highlighter = CodeHighlighter()
        var phases = RenderPhases()
        let source = "```swift\nlet invented = 1\nlet other = invented + 1\n```"

        let cold = markdown.attributed(source, highlighter: highlighter, phases: &phases)
        XCTAssertEqual(colours(cold), 0, "a cold request drew \(colours(cold)) colour(s) rather than plain text")

        let landed = await wait(upTo: 5) { highlighter.offMainHighlights >= 1 }
        XCTAssertTrue(landed, "no highlight landed within the wait; \(highlighter.highlightRequests) were requested")

        let warm = markdown.attributed(source, highlighter: highlighter, phases: &phases)
        XCTAssertGreaterThan(colours(warm), 1,
                             "the block still draws \(colours(warm)) colour(s) after its highlight landed")
    }

    /// The process-wide highlight cache is bounded, and bounded by use (§6).
    ///
    /// **Discriminating.** The cache retained every distinct source and its attributed result with
    /// no eviction at all, so a day-long session accumulated one entry per fenced block it ever
    /// drew. The floor is the second half: a cache bounded by throwing everything away would also
    /// re-highlight the block asked for most recently.
    func testTheHighlightCacheIsBounded() async {
        let highlighter = CodeHighlighter()
        let blocks = (0..<300).map { (code: "let invented\($0) = \($0)", language: Optional("swift")) }
        await highlighter.warm(blocks)
        let warmed = highlighter.offMainHighlights
        XCTAssertEqual(warmed, blocks.count, "warming \(blocks.count) block(s) ran \(warmed) highlight(s)")

        _ = highlighter.styling(code: blocks[0].code, language: "swift")
        let evicted = await wait(upTo: 5) { highlighter.offMainHighlights > warmed }
        XCTAssertTrue(evicted, "the oldest of \(blocks.count) entries survived, so the cache is unbounded")

        _ = highlighter.styling(code: blocks[blocks.count - 1].code, language: "swift")
        let refilled = await wait(upTo: 0.5) { highlighter.offMainHighlights > warmed + 1 }
        XCTAssertFalse(refilled, "the most recent entry was evicted too, so the bound is not by use")
    }


    /// A destination is routed by its shape, through the one capability every link in this leaf
    /// leaves by (contract Y7).
    ///
    /// **Discriminating.** Nothing routed a markdown link at all before this: the walk kept no
    /// destination and the row installed no handler, so pressing one did nothing. The three arms
    /// are the three answers that differ — a URL the router hands on, a path the router opens as a
    /// file, and a relative path in a channel whose working directory is unknown, which is the one
    /// case that must resolve to nothing rather than to the app's own directory.
    @MainActor
    func testALinkIsRoutedByTheShapeOfItsDestination() async throws {
        let cwd = URL(filePath: "/invented/project")
        let absolute = try XCTUnwrap(TimelineLinkDestination.url(for: "/invented/project/notes.md"))
        XCTAssertEqual(TimelineLinkDestination.link(for: absolute, cwd: nil),
                       .file(URL(filePath: "/invented/project/notes.md"), line: nil),
                       "an absolute path did not route as a file link")

        let relative = try XCTUnwrap(TimelineLinkDestination.url(for: "notes.md"))
        XCTAssertEqual(TimelineLinkDestination.link(for: relative, cwd: cwd),
                       .file(cwd.appending(path: "notes.md"), line: nil),
                       "a relative path was not resolved against the channel's directory")
        XCTAssertNil(TimelineLinkDestination.link(for: relative, cwd: nil),
                     "a relative path was resolved in a channel with no directory to resolve it against")

        let remote = try XCTUnwrap(TimelineLinkDestination.url(for: "https://example.invalid/page"))
        XCTAssertEqual(TimelineLinkDestination.link(for: remote, cwd: cwd),
                       .url(URL(string: "https://example.invalid/page")!),
                       "a URL destination did not route as a URL link")

        // And the activation reaches the capability, which is what makes the routing above more
        // than a pure function nobody calls.
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router, cwd: cwd)
        XCTAssertTrue(TimelineLinkDestination.open(remote, in: context), "the URL link was not accepted")
        var delivered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await router.opened.count == 1 { delivered = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(delivered, "the router received nothing within the wait")
        let opened = await router.openedURLs
        XCTAssertEqual(opened, ["https://example.invalid/page"], "the router was given \(opened.count) URL link(s)")

        // The floor: no context is no capability, so the row draws a link that does nothing rather
        // than reaching for a stand-in.
        XCTAssertFalse(TimelineLinkDestination.open(remote, in: nil),
                       "a row outside the timeline's subtree routed a link anyway")
    }

    /// A build that began under the previous styling is refused at the write (§6).
    ///
    /// **Discriminating.** `warm` read the cache, built and wrote with no check between them, so a
    /// preference flip landing mid-build repopulated the cache it had just cleared with the styling
    /// the flip existed to remove — and every row drawn afterwards read it back. The floor is the
    /// second half: a write that refused everything would satisfy the first assertion and leave the
    /// warm-up filling nothing at all.
    func testAWriteFromTheOldStylingIsRefused() {
        let markdown = MarkdownText()
        let stale = markdown.styling
        markdown.clear()
        XCTAssertFalse(markdown.write("an invented block", NSAttributedString(string: "x"),
                                      pending: [], ifStyling: stale),
                       "a build from the previous styling was written into the cache the flip cleared")
        XCTAssertEqual(markdown.parseCount, 0,
                       "the refused write still counted \(markdown.parseCount) parse(s)")

        XCTAssertTrue(markdown.write("an invented block", NSAttributedString(string: "x"),
                                     pending: [], ifStyling: markdown.styling),
                      "a build from the current styling was refused too")
        XCTAssertEqual(markdown.parseCount, 1,
                       "the accepted write counted \(markdown.parseCount) parse(s)")
    }

    // MARK: - Emphasis over nested inline content (round 3, scalpel-4 #5)

    /// Bold and italic are **applied over** their children rather than replacing them.
    ///
    /// **Discriminating.** Both arms built a new run from the node's plain-text projection, which
    /// keeps a nested link's label and throws its destination away — the link is then blue-free,
    /// dead text — and which projects an `InlineHTML` node, having no children, to the empty
    /// string, so `**a <b>b</b> c**` lost its tags. The floor is that the emphasis itself is still
    /// applied, or a walk that ignored `Strong` entirely would pass the first two assertions.
    func testEmphasisKeepsTheInlineContentUnderIt() throws {
        let rendered = build("**[guide](https://example.invalid/page)** and *a <b>b</b> c* here")
        XCTAssertEqual(destinations(rendered), ["https://example.invalid/page"],
                       "a strong-wrapped link carried \(destinations(rendered).count) destination(s), not 1")
        XCTAssertTrue(rendered.string.contains("<b>b</b>"),
                      "the inline HTML under the emphasis was lost; \(rendered.length) character(s) were rendered")

        // The emphasis is still applied, on top of the runs it was applied over.
        let label = try XCTUnwrap(rendered.string.range(of: "guide"), "the strong link's label was not rendered")
        let at = rendered.string.distance(from: rendered.string.startIndex, to: label.lowerBound)
        let font = rendered.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                      "the strong-wrapped link's label is not bold")
        let italic = try XCTUnwrap(rendered.string.range(of: "c here"), "the emphasised run was not rendered")
        let atItalic = rendered.string.distance(from: rendered.string.startIndex, to: italic.lowerBound)
        let italicFont = rendered.attribute(.font, at: atItalic, effectiveRange: nil) as? NSFont
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) ?? false,
                      "the emphasised text is not italic")
    }

    // MARK: - The ordered list's own numbering (round 3, scalpel-4 #6)

    /// A list that begins at `4.` is drawn from four.
    ///
    /// **Discriminating.** The walk numbered from the enumeration offset and never read the list's
    /// own start, so a numbered list continuing an earlier one — which is how model output writes
    /// step four of a procedure — was renumbered from one, silently telling the reader to do the
    /// wrong step. The floor is the second half: a list that does start at one still says one.
    func testAnOrderedListKeepsItsStartNumber() {
        let continued = build("4. an invented step\n5. another invented step\n")
        XCTAssertTrue(continued.string.contains("4. "),
                      "the list did not start at four; \(continued.length) character(s) were rendered")
        XCTAssertTrue(continued.string.contains("5. "), "the list's second item is not five")
        XCTAssertFalse(continued.string.contains("1. "), "the list was renumbered from one")

        let ordinary = build("1. an invented step\n2. another invented step\n")
        XCTAssertTrue(ordinary.string.contains("1. ") && ordinary.string.contains("2. "),
                      "an ordinary list no longer numbers from one")
    }
}
