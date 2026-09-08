import Foundation
import XCTest

@testable import EditorCore

/// What the two ends of the bridge cost on the main actor for a buffer the size S3 measured.
///
/// S3 recorded 27–31 ms of host-side dispatch for the 5,243,442-byte fixture before a byte
/// reached WebKit, and the whole of that is Swift work this file can time without a web view.
/// Both directions did the same thing: they turned a buffer that was already in the right shape
/// into another representation and back again. The legacy shapes are restated here so the
/// comparison is a measurement rather than a claim, and so a later change that reintroduces
/// either of them fails a test rather than a benchmark nobody runs.
///
/// The bound is deliberately loose — a factor of two, best of several runs — because a tight
/// bound on a shared machine measures the machine.
final class BridgeThroughputTests: XCTestCase {

    /// 5,243,442 bytes across 209,919 lines, the shape S3's fixture had. Generated, never read
    /// from disk: nothing here touches a real file.
    private static let bigBuffer: String = {
        let line = "    let sprocket = Widget(identifier: 0, label: \"invented\")\n"
        var text = String()
        text.reserveCapacity(5_300_000)
        while text.utf8.count < 5_243_442 { text += line }
        return text
    }()

    private static let runs = 5

    /// Best of `runs`, in milliseconds. The best run is the one least disturbed by everything
    /// else on the machine, which is what makes repeated measurement worth anything.
    private func milliseconds(_ body: () -> Void) -> Double {
        body()  // warm-up: first touch pays for allocation the measurement is not about
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<Self.runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return best
    }

    // MARK: - Host to editor

    /// What `script(for:)` did: encode, decode to a `String`, escape that whole string into a
    /// JSON fragment, decode *that*, and interpolate the result into a JavaScript source line —
    /// five representations of the buffer, of which WebKit then parses the largest as source.
    private static func legacyScript(for command: EditorCommand) -> String? {
        guard let payload = try? JSONEncoder().encode(command),
              let json = String(data: payload, encoding: .utf8),
              let literal = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]),
              let literalText = String(data: literal, encoding: .utf8)
        else { return nil }
        return "window.afleetBridge.receive(JSON.parse(\(literalText)));"
    }

    func testPreparingASetTextCommandDoesNotDoubleEncodeTheBuffer() throws {
        let command = EditorCommand.setText(text: Self.bigBuffer)

        let legacy = milliseconds { _ = Self.legacyScript(for: command) }
        let shipped = milliseconds { _ = command.bridgedObject }
        print("[E3] setText 5 MB, host side: legacy \(String(format: "%.3f", legacy)) ms, "
              + "shipped \(String(format: "%.3f", shipped)) ms")

        XCTAssertLessThan(shipped, legacy / 2,
                          "preparing a 5 MB setText still costs what the double encoding cost: "
                          + "legacy \(legacy) ms, shipped \(shipped) ms")
    }

    /// The discriminating half of E3, and the reason the object above may be built by hand: it
    /// has to be field-for-field what the codec encodes. A faster path that said something
    /// slightly different would be a second vocabulary, which is exactly what W4 forbids.
    func testEveryCommandMarshalsToWhatTheCodecEncodes() throws {
        let commands: [EditorCommand] = [
            .open(path: "Widgets/Sprocket.swift", language: "swift", text: "invented\n", line: 42),
            .open(path: "Widgets/Sprocket.swift", language: "swift", text: "invented\n", line: nil),
            .setText(text: "invented\n"),
            .gotoLine(line: 42, column: 7),
            .gotoLine(line: 42, column: nil),
            .setTheme(name: "vs-dark"),
            .showDiff(path: "Widgets/Sprocket.swift", original: "one\n", modified: "two\n",
                      language: "swift"),
            .save,
        ]
        for command in commands {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command))
            XCTAssertEqual(command.bridgedObject as NSDictionary, encoded as? NSDictionary,
                           "the marshalled object and the encoded one disagree for \(command)")
            // And it survives the trip back through the codec, so the bridge sees one shape.
            let reencoded = try JSONSerialization.data(withJSONObject: command.bridgedObject)
            XCTAssertEqual(try JSONDecoder().decode(EditorCommand.self, from: reencoded), command)
        }
    }

    // MARK: - Editor to host

    /// What `decodeEvent(from:)` did with the dictionary WebKit hands the message handler:
    /// serialise the whole buffer back to JSON and decode it again.
    private static func legacyDecode(_ body: [String: Any]) -> EditorEvent? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(EditorEvent.self, from: data)
    }

    func testDecodingASaveRequestedDoesNotReserialiseTheBuffer() throws {
        let body: [String: Any] = [
            "type": "saveRequested", "path": "Fixtures/Widgets/Sprocket.swift", "text": Self.bigBuffer,
        ]

        let legacy = milliseconds { _ = Self.legacyDecode(body) }
        let shipped = milliseconds { _ = MonacoEditorView.decodeEvent(from: body) }
        print("[E4] saveRequested 5 MB, host side: legacy \(String(format: "%.3f", legacy)) ms, "
              + "shipped \(String(format: "%.3f", shipped)) ms")

        XCTAssertEqual(MonacoEditorView.decodeEvent(from: body), Self.legacyDecode(body),
                       "the direct decode disagrees with the JSON one")

        XCTAssertLessThan(shipped, legacy / 2,
                          "decoding a 5 MB saveRequested still reserialises it: "
                          + "legacy \(legacy) ms, shipped \(shipped) ms")
    }

    // MARK: - The direct decode agrees with the codec, message by message

    /// The discriminating half of E4: a faster decode that accepted a different set of objects
    /// would be a second, quieter vocabulary. Every W4 editor-to-host message, and every
    /// malformed body the codec rejects, has to land the same way both ways.
    func testEveryEventDecodesIdenticallyByBothRoutes() throws {
        let bodies: [[String: Any]] = [
            ["type": "ready"],
            ["type": "dirty", "path": "Widgets/Sprocket.swift", "isDirty": true],
            ["type": "dirty", "path": "Widgets/Sprocket.swift", "isDirty": false],
            ["type": "saveRequested", "path": "Widgets/Sprocket.swift", "text": "invented\n"],
            ["type": "cursor", "line": 42, "column": 7],
            ["type": "error", "message": "no editor is attached: open"],
            // Rejections, which matter as much as the acceptances.
            ["type": "unknownEvent"],
            ["type": "dirty", "path": "Widgets/Sprocket.swift"],
            ["type": "cursor", "line": 42],
            ["type": "dirty", "path": 7, "isDirty": true],
            ["type": "cursor", "line": "42", "column": 7],
            ["message": "no type at all"],
        ]
        for body in bodies {
            XCTAssertEqual(MonacoEditorView.decodeEvent(from: body), Self.legacyDecode(body),
                           "the two decode routes disagree on \(body["type"] ?? "no type")")
        }
    }

    /// The `String` body the codec's literal-JSON tests use still decodes: the direct route is
    /// an addition for the dictionary WebKit actually sends, not a replacement for the wire.
    func testAStringBodyStillDecodes() {
        XCTAssertEqual(MonacoEditorView.decodeEvent(from: #"{"type":"ready"}"#), .ready)
        XCTAssertNil(MonacoEditorView.decodeEvent(from: #"{"type":"nope"}"#))
        XCTAssertNil(MonacoEditorView.decodeEvent(from: 7))
    }
}
