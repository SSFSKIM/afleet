import XCTest
import WireFrames
import WireTestSupport

final class FrameDecoderTests: XCTestCase {
    private func decode(_ name: String) throws -> Frame { FrameDecoder.decode(line: try TestPaths.sample(name)) }

    func testAssistantDecodesTypedWithBlocks() throws {
        guard case .assistant(let f) = try decode("assistant") else { return XCTFail("not assistant") }
        XCTAssertEqual(f.message.id, "msg_01")
        XCTAssertEqual(f.message.model, "claude-opus-5")
        XCTAssertEqual(f.message.content.count, 2)
        guard case .text(let t) = f.message.content[0] else { return XCTFail() }
        XCTAssertEqual(t.text, "Hello")
        guard case .toolUse(let tu) = f.message.content[1] else { return XCTFail() }
        XCTAssertEqual(tu.id, "toolu_01"); XCTAssertEqual(tu.name, "Read")
        guard case .read(let input) = tu.typedInput else { return XCTFail() }
        XCTAssertEqual(input.filePath, "/tmp/scratch/a.txt")
        XCTAssertEqual(f.message.usage?["input_tokens"], .integer(12))
        XCTAssertEqual(f.userMessageUUID, "6d1d4b1e-0000-4000-8000-0000000000aa")
        XCTAssertNil(f.parentToolUseID)
    }

    func testUserToolResultAndReplay() throws {
        guard case .user(let u) = try decode("user") else { return XCTFail() }
        guard case .blocks(let blocks) = u.message.content, case .toolResult(let tr) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(tr.toolUseID, "toolu_01"); XCTAssertEqual(tr.isError, false)
        XCTAssertEqual(u.toolUseResult?["file"]?["numLines"], .integer(1))
        XCTAssertNil(u.isReplay)
        guard case .user(let r) = try decode("user_replay") else { return XCTFail() }
        XCTAssertEqual(r.isReplay, true)
        guard case .text(let s) = r.message.content else { return XCTFail() }
        XCTAssertEqual(s, "hello there")
        XCTAssertEqual(r.origin?.kind, "human")
    }

    func testStreamEventAndResult() throws {
        guard case .streamEvent(let e) = try decode("stream_event") else { return XCTFail() }
        XCTAssertEqual(e.event["delta"]?["text"], .string("Hel"))
        guard case .result(let r) = try decode("result") else { return XCTFail() }
        XCTAssertEqual(r.subtype, "success"); XCTAssertEqual(r.isError, false); XCTAssertEqual(r.numTurns, 1)
        XCTAssertEqual(r.totalCostUSD, 0.0012, accuracy: 1e-9)
        XCTAssertEqual(r.fastModeState, "off")
        XCTAssertEqual(r.modelUsage?["claude-opus-5"]?["contextWindow"], .integer(200000))
    }

    func testControlEnvelopes() throws {
        guard case .controlRequest(let req) = try decode("control_request_can_use_tool") else { return XCTFail() }
        XCTAssertEqual(req.requestID, RequestID(rawValue: "req-001")); XCTAssertEqual(req.subtype, "can_use_tool")
        XCTAssertEqual(req.request["tool_name"], .string("Write"))
        guard case .controlResponse(let ok) = try decode("control_response_success"), case .success(let s) = ok.body else { return XCTFail() }
        XCTAssertEqual(s.requestID.rawValue, "init-1"); XCTAssertEqual(s.response?["pid"], .integer(4242))
        guard case .controlResponse(let bad) = try decode("control_response_error"), case .error(let e) = bad.body else { return XCTFail() }
        XCTAssertEqual(e.error, "File rewinding is not enabled.")
        guard case .controlCancelRequest(let c) = try decode("control_cancel_request") else { return XCTFail() }
        XCTAssertEqual(c.requestID.rawValue, "req-001")
        guard case .keepAlive = try decode("keep_alive") else { return XCTFail() }
    }

    func testUnknownTypeIsOpaqueNotFatal() throws {
        guard case .opaque(let o) = try decode("unknown_type") else { return XCTFail() }
        XCTAssertEqual(o.type, "afleet_invented"); XCTAssertNil(o.subtype)
        XCTAssertEqual(o.reason, .unknownType)
        XCTAssertEqual(o.value["payload"]?["n"], .integer(1))
        XCTAssertEqual(String(decoding: o.raw, as: UTF8.self).prefix(8), "{\"type\":")
    }

    func testDecodeFailureOnKnownTypeIsOpaqueWithField() throws {
        let broken = Data(#"{"type":"assistant","message":"not-an-object","uuid":"u","session_id":"s","parent_tool_use_id":null}"#.utf8)
        guard case .opaque(let o) = FrameDecoder.decode(line: broken) else { return XCTFail() }
        guard case .decodeFailure(let field, _) = o.reason else { return XCTFail("\(o.reason)") }
        XCTAssertEqual(field, "message")
    }

    func testNonJSONLineIsOpaqueWithInvalidJSONReason() throws {
        guard case .opaque(let o) = FrameDecoder.decode(line: Data("not json at all".utf8)) else { return XCTFail() }
        XCTAssertEqual(o.reason, .invalidJSON)
    }

    func testReEncodeReproducesEveryKey() throws {
        for name in ["assistant", "user", "user_replay", "stream_event", "result", "control_request_can_use_tool",
                     "control_response_success", "control_response_error", "control_cancel_request", "keep_alive"] {
            let raw = try TestPaths.sample(name)
            let frame = FrameDecoder.decode(line: raw)
            if case .opaque = frame { XCTFail("\(name) decoded opaque"); continue }
            let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(frame))
            let original = try JSONDecoder().decode(JSONValue.self, from: raw)
            XCTAssertTrue(again.numericallyEqual(original), "\(name) lost keys or values")
        }
    }
}
