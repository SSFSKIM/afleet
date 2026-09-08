import Foundation
import XCTest
@testable import BrowserPanel

/// C7.6 milestone 2, first half: the ledger's Q9 table, row by row.
///
/// Every host below is invented. `.invalid` and `.test` are reserved and can never resolve;
/// `localhost`, `127.0.0.1` and `[::1]` are loopback. Nothing here names a real site (§11).
final class URLInputTests: XCTestCase {

    private func normalized(_ input: String) -> URLInput.Normalized {
        URLInput.normalize(input)
    }

    private func url(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard case .url(let resolved) = normalized(input) else {
            XCTFail("expected a URL from \(input.debugDescription)", file: file, line: line)
            return nil
        }
        return resolved
    }

    // MARK: Row 1 — empty or whitespace

    func testEmptyOrWhitespaceInputDoesNothing() {
        for input in ["", " ", "\t", "\n", "   \t \n "] {
            XCTAssertEqual(normalized(input), .empty, "\(input.debugDescription) must load nothing")
        }
    }

    // MARK: Row 2 — an explicit http, https or about scheme

    func testAnExplicitHTTPHTTPSOrAboutSchemeIsTakenAsTyped() {
        XCTAssertEqual(url("http://example.invalid/a")?.absoluteString, "http://example.invalid/a")
        XCTAssertEqual(url("https://example.invalid/a?b=c")?.absoluteString, "https://example.invalid/a?b=c")
        XCTAssertEqual(url("about:blank")?.absoluteString, "about:blank")
    }

    func testTheSchemeIsRecognisedRegardlessOfCase() {
        let resolved = url("HTTPS://example.invalid/")
        XCTAssertEqual(resolved?.scheme?.lowercased(), "https")
        XCTAssertEqual(resolved?.host(), "example.invalid")
    }

    func testSurroundingWhitespaceIsTrimmedBeforeAnythingElse() {
        XCTAssertEqual(url("  https://example.invalid/  ")?.absoluteString, "https://example.invalid/")
    }

    // MARK: Row 3 — loopback, and the scheme trap the row exists to close

    /// `URL(string: "localhost:8123")` parses `localhost` as the *scheme*, which is the silent
    /// failure this row of Q9's table exists to close.
    func testLocalhostWithAPortIsNotParsedAsAScheme() {
        XCTAssertEqual(URL(string: "localhost:8123")?.scheme, "localhost",
                       "the trap itself, asserted so the table's reason cannot be forgotten")
        let resolved = url("localhost:8123")
        XCTAssertEqual(resolved?.scheme, "http")
        XCTAssertEqual(resolved?.host(), "localhost")
        XCTAssertEqual(resolved?.port, 8123)
    }

    func testLoopbackHostsTakeTheHTTPPrefix() {
        XCTAssertEqual(url("localhost")?.absoluteString, "http://localhost")
        XCTAssertEqual(url("localhost:8123")?.absoluteString, "http://localhost:8123")
        XCTAssertEqual(url("127.0.0.1:8123")?.absoluteString, "http://127.0.0.1:8123")
        XCTAssertEqual(url("[::1]:8123")?.absoluteString, "http://[::1]:8123")
        XCTAssertEqual(url("panel.localhost")?.absoluteString, "http://panel.localhost")
        XCTAssertEqual(url("localhost:8123/listing/")?.absoluteString, "http://localhost:8123/listing/")
    }

    /// A dotted loopback address with no port would otherwise fall to row 5 and take `https://`.
    func testABareLoopbackAddressTakesHTTPAndNotHTTPS() {
        XCTAssertEqual(url("127.0.0.1")?.scheme, "http")
        XCTAssertEqual(url("[::1]")?.scheme, "http")
    }

    // MARK: Row 4 — a bare host and an all-digit port

    func testABareHostAndAnAllDigitPortTakesTheHTTPPrefix() {
        XCTAssertEqual(url("example.invalid:8080")?.absoluteString, "http://example.invalid:8080")
        XCTAssertEqual(url("build:9000/status")?.absoluteString, "http://build:9000/status")
    }

    /// Row 4 needs an *all-digit* port. `notahost:eight` has a colon and no dot, so with the digit
    /// requirement dropped it would silently become `http://notahost:eight`.
    func testAColonWithANonDigitTailIsNotAHostAndPort() {
        XCTAssertEqual(normalized("notahost:eight"), .notAURL)
    }

    // MARK: Row 5 — a dot, no whitespace

    func testADottedHostWithNoWhitespaceTakesTheHTTPSPrefix() {
        XCTAssertEqual(url("example.invalid")?.absoluteString, "https://example.invalid")
        XCTAssertEqual(url("docs.example.test/guide")?.absoluteString, "https://docs.example.test/guide")
    }

    // MARK: Row 6 — anything else

    func testInputThatIsNotAURLReportsTheNotAURLState() {
        for input in ["how do I", "notahost", "example invalid", "a b.c"] {
            XCTAssertEqual(normalized(input), .notAURL,
                           "\(input.debugDescription) is not a URL and must not load")
        }
    }

    /// Q9, and the reason it is written in capitals there: a typed string that is not a URL is a
    /// keystroke, and a keystroke does not leave the machine.
    func testThereIsNoWebSearchFallback() {
        for input in ["swift concurrency", "what is a coalescer", "buy milk"] {
            XCTAssertEqual(normalized(input), .notAURL,
                           "a phrase must never be normalised into a search provider's URL")
        }
        // Belt and braces: no result of any input in this suite names a query endpoint.
        if case .url(let resolved) = normalized("swift concurrency") {
            XCTFail("a phrase produced \(resolved.absoluteString)")
        }
    }
}
