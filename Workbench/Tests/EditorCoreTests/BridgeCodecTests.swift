import Foundation
import XCTest
@testable import EditorCore

/// W4's message vocabulary, pinned on both sides of the wire.
///
/// Three kinds of assertion, and only two of them can fail on the defect that matters.
/// A Swift round trip agrees with itself whatever the JavaScript believes, so the literal
/// JSON strings — written the way `bridge.js` writes them — and the bootstrap-source check
/// are what make this suite discriminating (spec §5, Decision Log 2026-09-07).
final class BridgeCodecTests: XCTestCase {

    // MARK: - Samples

    /// One value per host-to-editor message. Invented content only (§11).
    private static let commands: [EditorCommand] = [
        .open(path: "Widgets/Sprocket.swift", language: "swift",
              text: "struct Sprocket {}\n", line: 12),
        .open(path: "Widgets/Gasket.txt", language: "plaintext", text: "gasket\n", line: nil),
        .setText(text: "line one\nline two\n"),
        .gotoLine(line: 40, column: 7),
        .gotoLine(line: 3, column: nil),
        .setTheme(name: "vs-dark"),
        .showDiff(path: "Widgets/Flange.swift",
                  original: "let flange = 1\n", modified: "let flange = 2\n", language: "swift"),
        .save,
    ]

    /// One value per editor-to-host message.
    private static let events: [EditorEvent] = [
        .ready,
        .dirty(path: "Widgets/Sprocket.swift", isDirty: true),
        .saveRequested(path: "Widgets/Sprocket.swift", text: "struct Sprocket { }\n"),
        .cursor(line: 18, column: 2),
        .error(message: "the buffer named in the request is not open"),
    ]

    // MARK: - 1. Round trip

    func testEveryCommandRoundTrips() throws {
        for command in Self.commands {
            let data = try JSONEncoder().encode(command)
            let back = try JSONDecoder().decode(EditorCommand.self, from: data)
            XCTAssertEqual(back, command, "round trip changed the value")
        }
    }

    func testEveryEventRoundTrips() throws {
        for event in Self.events {
            let data = try JSONEncoder().encode(event)
            let back = try JSONDecoder().decode(EditorEvent.self, from: data)
            XCTAssertEqual(back, event, "round trip changed the value")
        }
    }

    // MARK: - 2. Decode from a literal JSON line, as `bridge.js` writes it

    func testOpenDecodesFromLiteralJSON() throws {
        let line = #"{"type":"open","path":"Widgets/Sprocket.swift","language":"swift","text":"struct Sprocket {}\n","line":12}"#
        guard case let .open(path, language, text, lineNumber) = try Self.decodeCommand(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(path, "Widgets/Sprocket.swift")
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(text, "struct Sprocket {}\n")
        XCTAssertEqual(lineNumber, 12)
    }

    func testSetTextDecodesFromLiteralJSON() throws {
        let line = #"{"type":"setText","text":"line one\nline two\n"}"#
        guard case let .setText(text) = try Self.decodeCommand(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(text, "line one\nline two\n")
    }

    func testGotoLineDecodesFromLiteralJSON() throws {
        let line = #"{"type":"gotoLine","line":40,"column":7}"#
        guard case let .gotoLine(lineNumber, column) = try Self.decodeCommand(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(lineNumber, 40)
        XCTAssertEqual(column, 7)
    }

    func testSetThemeDecodesFromLiteralJSON() throws {
        let line = #"{"type":"setTheme","name":"hc-black"}"#
        guard case let .setTheme(name) = try Self.decodeCommand(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(name, "hc-black")
    }

    func testShowDiffDecodesFromLiteralJSON() throws {
        let line = #"{"type":"showDiff","path":"Widgets/Flange.swift","original":"let flange = 1\n","modified":"let flange = 2\n","language":"swift"}"#
        guard case let .showDiff(path, original, modified, language) = try Self.decodeCommand(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(path, "Widgets/Flange.swift")
        XCTAssertEqual(original, "let flange = 1\n")
        XCTAssertEqual(modified, "let flange = 2\n")
        XCTAssertEqual(language, "swift")
    }

    func testSaveDecodesFromLiteralJSON() throws {
        XCTAssertEqual(try Self.decodeCommand(#"{"type":"save"}"#), .save)
    }

    func testReadyDecodesFromLiteralJSON() throws {
        XCTAssertEqual(try Self.decodeEvent(#"{"type":"ready"}"#), .ready)
    }

    func testDirtyDecodesFromLiteralJSON() throws {
        let line = #"{"type":"dirty","path":"Widgets/Sprocket.swift","isDirty":true}"#
        guard case let .dirty(path, isDirty) = try Self.decodeEvent(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(path, "Widgets/Sprocket.swift")
        XCTAssertTrue(isDirty)
    }

    func testSaveRequestedDecodesFromLiteralJSON() throws {
        let line = #"{"type":"saveRequested","path":"Widgets/Sprocket.swift","text":"struct Sprocket { }\n"}"#
        guard case let .saveRequested(path, text) = try Self.decodeEvent(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(path, "Widgets/Sprocket.swift")
        XCTAssertEqual(text, "struct Sprocket { }\n")
    }

    func testCursorDecodesFromLiteralJSON() throws {
        let line = #"{"type":"cursor","line":18,"column":2}"#
        guard case let .cursor(lineNumber, column) = try Self.decodeEvent(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(lineNumber, 18)
        XCTAssertEqual(column, 2)
    }

    func testErrorDecodesFromLiteralJSON() throws {
        let line = #"{"type":"error","message":"the buffer named in the request is not open"}"#
        guard case let .error(message) = try Self.decodeEvent(line) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertEqual(message, "the buffer named in the request is not open")
    }

    // MARK: - 3. The two sides do not drift

    /// The one test whose failure is the failure this codec actually has: a `type` string
    /// that the Swift side emits and the committed bootstrap has never heard of.
    func testEveryTypeStringTheCodecEmitsAppearsInTheBootstrap() throws {
        let url = try XCTUnwrap(EditorResources.bridgeScriptURL,
                                "bridge.js is not in Bundle.module")
        let source = try String(contentsOf: url, encoding: .utf8)

        let emitted = try Self.commands.map(Self.typeString(of:)) + Self.events.map(Self.typeString(of:))
        XCTAssertEqual(Set(emitted).count, 11, "the vocabulary is eleven messages and no other")
        for type in Set(emitted) {
            XCTAssertTrue(source.contains("\"\(type)\"") || source.contains("'\(type)'"),
                          "the bootstrap does not mention the type string \(type)")
        }
    }

    // MARK: - 4. An unknown type is a typed failure

    func testUnknownCommandTypeIsATypedFailure() {
        let line = #"{"type":"reticulate","path":"Widgets/Sprocket.swift"}"#
        XCTAssertThrowsError(try Self.decodeCommand(line)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("an unknown type must decode to a DecodingError, not \(type(of: error))")
            }
            XCTAssertTrue(context.debugDescription.contains("reticulate"),
                          "the failure names the type it did not recognise")
        }
    }

    func testUnknownEventTypeIsATypedFailure() {
        let line = #"{"type":"reticulate","message":"nope"}"#
        XCTAssertThrowsError(try Self.decodeEvent(line)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("an unknown type must decode to a DecodingError, not \(type(of: error))")
            }
        }
    }

    func testAMissingRequiredFieldIsATypedFailure() {
        XCTAssertThrowsError(try Self.decodeEvent(#"{"type":"dirty","path":"Widgets/Sprocket.swift"}"#)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("a missing field must decode to a keyNotFound, not \(type(of: error))")
            }
        }
    }

    // MARK: - 5. Optional fields are genuinely optional

    func testOpenWithNoLineOmitsTheKeyAndDecodesBackToNil() throws {
        let encoded = try Self.encodedObject(EditorCommand.open(path: "Widgets/Gasket.txt", language: "plaintext",
                                                   text: "gasket\n", line: nil))
        XCTAssertNil(encoded["line"], "a nil line must be absent, not null")
        XCTAssertEqual(Set(encoded.keys), ["type", "path", "language", "text"])

        guard case let .open(_, _, _, line) = try Self.decodeCommand(#"{"type":"open","path":"Widgets/Gasket.txt","language":"plaintext","text":"gasket\n"}"#) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertNil(line)
    }

    func testGotoLineWithNoColumnOmitsTheKeyAndDecodesBackToNil() throws {
        let encoded = try Self.encodedObject(EditorCommand.gotoLine(line: 3, column: nil))
        XCTAssertNil(encoded["column"], "a nil column must be absent, not null")
        XCTAssertEqual(Set(encoded.keys), ["type", "line"])

        guard case let .gotoLine(_, column) = try Self.decodeCommand(#"{"type":"gotoLine","line":3}"#) else {
            return XCTFail("decoded to the wrong case")
        }
        XCTAssertNil(column)
    }

    // MARK: - Helpers

    private static func decodeCommand(_ line: String) throws -> EditorCommand {
        try JSONDecoder().decode(EditorCommand.self, from: Data(line.utf8))
    }

    private static func decodeEvent(_ line: String) throws -> EditorEvent {
        try JSONDecoder().decode(EditorEvent.self, from: Data(line.utf8))
    }

    private static func encodedObject<Message: Encodable>(_ message: Message) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func typeString<Message: Encodable>(of message: Message) throws -> String {
        try XCTUnwrap(encodedObject(message)["type"] as? String)
    }
}
