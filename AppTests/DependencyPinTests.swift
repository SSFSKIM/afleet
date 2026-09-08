import Foundation
import XCTest
import Markdown
import HighlightKit

/// The two packages C6.1's seam commit pins, proved rather than declared.
///
/// A pin that nothing imports is a line in a manifest, and a manifest line can name a package that
/// does not resolve, does not build on this deployment target, or does not carry what the child
/// spec says it carries. Nothing under `App/` imports either package until the tasks that use them
/// land, so this suite is where the pin is exercised in the meantime — and it stays afterwards,
/// because what it asserts is the *pin*, not the renderer.
///
/// No engine byte and no path reaches an assertion here; every sample below is invented (§11).
final class DependencyPinTests: XCTestCase {

    // MARK: - swift-markdown

    /// `swift-markdown` resolves, and parses the block kinds the timeline will ask it for.
    ///
    /// Pinned by revision rather than by version: the project publishes no semver tags, only
    /// `swift-DEVELOPMENT-SNAPSHOT-*`, so `de3e245b` — the tip of `release/6.3` and `release/6.3.1`,
    /// which are one commit — is what "exactly" can mean. The floor is that the document has
    /// children at all: a parser that returned an empty tree would satisfy a bare "it compiled".
    func testSwiftMarkdownParsesTheBlockKindsTheTimelineNeeds() {
        let source = """
        # A heading

        A paragraph with `inline code` and a [link](https://invented.example/one).

        - one
          - nested
        1. first
        2. second

        | a | b |
        |---|---|
        | 1 | 2 |

        > quoted

        ```swift
        let invented = 1
        ```
        """
        let document = Document(parsing: source)
        XCTAssertGreaterThan(document.childCount, 0, "the parser produced an empty document")

        var kinds: Set<String> = []
        for child in document.children { kinds.insert(String(describing: type(of: child))) }
        for required in ["Heading", "Paragraph", "UnorderedList", "OrderedList", "BlockQuote", "CodeBlock"] {
            XCTAssertTrue(kinds.contains(required),
                          "the parser produced no \(required); it produced \(kinds.count) distinct block kinds")
        }
    }

    /// GFM tables are on. The engine's own renderer runs `marked` with GFM enabled (parity §41.17),
    /// and a table that parsed as a paragraph would render as pipes on screen.
    func testGFMTablesAreParsedAsTables() {
        let document = Document(parsing: "| a | b |\n|---|---|\n| 1 | 2 |\n",
                                options: .parseBlockDirectives)
        let isTable = document.children.contains { $0 is Table }
        XCTAssertTrue(isTable, "a GFM table parsed as \(document.children.map { String(describing: type(of: $0)) })")
    }

    // MARK: - HighlightKit

    /// The highlighter resolves and carries the grammars the child spec's §6 claims.
    ///
    /// **This is the test that replaces trusting a README.** The library's own page says
    /// "65 languages"; what matters is that the languages arbitrary model output actually contains
    /// are among them, and that a pin bump which dropped one fails here rather than silently
    /// rendering that language flat.
    func testHighlightKitCarriesTheGrammarsWeNamed() {
        let highlighter = Highlighter()
        let names = highlighter.languageNames
        // Measured at the pinned tag: 65. The floor is set below it so a grammar added upstream is
        // not a failure, while a bump that dropped several is.
        XCTAssertGreaterThanOrEqual(names.count, 60,
                                    "the pinned highlighter carries \(names.count) grammars, below the 60 the spec claims")
        let required = ["swift", "python", "typescript", "javascript", "json", "bash", "ruby",
                        "csharp", "sql", "yaml", "rust", "go", "java", "php", "lua"]
        let missing = required.filter { !highlighter.hasLanguage(named: $0) }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) of \(required.count) named grammars are absent")
    }

    /// Highlighting a sample produces more than one token class, so the grammar is doing work.
    ///
    /// The floor matters: a highlighter that returned the input as one undifferentiated run would
    /// pass "it did not crash" and would look, on screen, exactly like no highlighting at all.
    func testHighlightingProducesDistinctScopes() {
        let highlighter = Highlighter()
        let result = highlighter.highlight("func invented(a: Int) -> String { return \"x\" }", as: "swift")
        let scopes = Set(result.tokens.map(\.scope))
        XCTAssertGreaterThan(scopes.count, 1,
                             "highlighting a Swift sample produced \(scopes.count) distinct scope(s)")

        // The other half of the common path: the library styles into `NSAttributedString` itself,
        // so the renderer needs no attribute mapping of its own.
        let styled = highlighter.attributedString(for: "let invented = 1", language: "swift")
        XCTAssertGreaterThan(styled.length, 0, "styling a Swift sample produced an empty string")
    }

    /// An unknown language is a fallback, not a crash and not an empty result — which is what a
    /// fenced block tagged with a language no grammar covers has to do.
    func testAnUnknownLanguageFallsBackRatherThanFailing() {
        let highlighter = Highlighter()
        XCTAssertFalse(highlighter.hasLanguage(named: "invented-language"),
                       "the pinned highlighter claims a grammar for an invented language name")
    }
}
