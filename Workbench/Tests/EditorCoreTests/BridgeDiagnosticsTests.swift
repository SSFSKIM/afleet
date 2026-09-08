import Foundation
import XCTest

@testable import EditorCore

/// The diagnostic an `error` event produces, against root spec §6.3's binding clause: no value
/// derived from a payload reaches the diagnostics log, whatever its diagnostic value, because
/// that log is unredacted by construction and §11's redactor works structurally by key name.
///
/// An `error` message is exactly such a value. Monaco interpolates model URIs and file paths
/// into its own exception text, and `bridge.js` forwards that text verbatim from `boot` and
/// from `receive`, so a message that reaches the public log takes a path with it.
final class BridgeDiagnosticsTests: XCTestCase {

    /// Invented, as §11 requires of anything written into a test: no path here exists on this
    /// machine or in this repository.
    private static let inventedMessage =
        "Cannot add model because it already exists: afleet-file:///Fixtures/Widgets/Sprocket.swift"

    /// Every token of the message long enough to identify it. `it` and `at`-length words are
    /// left out: a two-letter fragment appearing in a metadata line proves nothing.
    private static func identifyingTokens(of message: String) -> [String] {
        message
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    /// The whole path from the bridge to the log line, driven with a message that carries an
    /// invented path: the body arrives as `WKScriptMessage.body` would, is decoded by the same
    /// function the message handler calls, and is formatted by the same function `report` logs.
    func testTheDiagnosticLineCarriesNoFragmentOfAnErrorMessage() throws {
        let body: [String: Any] = ["type": "error", "message": Self.inventedMessage]
        guard case let .error(message) = try XCTUnwrap(MonacoEditorView.decodeEvent(from: body)) else {
            return XCTFail("the bridge's error event did not decode")
        }
        XCTAssertEqual(message, Self.inventedMessage)

        let line = MonacoEditorView.diagnosticLine(origin: .bridge, message: message)

        XCTAssertFalse(line.contains(message), "the whole message reached the public line: \(line)")
        for token in Self.identifyingTokens(of: message) {
            XCTAssertFalse(line.contains(token),
                           "the public line carries '\(token)' from the message: \(line)")
        }
    }

    /// The line still has to be worth writing: it names which path produced the error and how
    /// long the message was, which is the metadata §6.3 permits.
    func testTheDiagnosticLineClassifiesTheOriginAndTheMessagesLength() {
        for origin in BridgeErrorOrigin.allCases {
            let line = MonacoEditorView.diagnosticLine(origin: origin, message: Self.inventedMessage)
            XCTAssertTrue(line.contains(origin.rawValue),
                          "the line does not say which bridge path failed: \(line)")
            XCTAssertTrue(line.contains(String(Self.inventedMessage.count)),
                          "the line does not carry the message's length: \(line)")
        }
    }

    /// An empty message is the one route 3 produced in S3 (`{kind: "error", message: ""}`), and
    /// it must still classify rather than degenerate.
    func testAnEmptyMessageStillProducesAClassifiedLine() {
        let line = MonacoEditorView.diagnosticLine(origin: .transport, message: "")
        XCTAssertTrue(line.contains("transport"))
        XCTAssertTrue(line.contains("0"))
    }
}
