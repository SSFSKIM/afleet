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
        XCTAssertEqual(try XCTUnwrap(r.totalCostUSD), 0.0012, accuracy: 1e-9)
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

    /// The pending arrays are re-emitted exactly as they arrived: an empty array stays a present
    /// empty array, and an element's keys beyond type/request_id/request survive re-encoding.
    func testPendingRequestArraysRoundTripVerbatim() throws {
        let raw = try TestPaths.sample("control_response_pending")
        guard case .controlResponse(let f) = FrameDecoder.decode(line: raw), case .success(let s) = f.body else { return XCTFail() }
        XCTAssertEqual(s.requestID.rawValue, "init-2")
        XCTAssertEqual(s.pendingPermissionRequests, [])
        XCTAssertEqual(s.pendingUserDialogRequests.count, 1)
        XCTAssertEqual(s.pendingUserDialogRequests[0].requestID.rawValue, "req-010")
        XCTAssertEqual(s.pendingUserDialogRequests[0].subtype, "request_user_dialog")
        XCTAssertEqual(s.pendingUserDialogRequests[0].request["dialog_kind"], .string("refusal_fallback_prompt"))
        let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(.controlResponse(f)))
        XCTAssertEqual(again["response"]?["pending_permission_requests"], .array([]), "an empty pending array lost its key")
        XCTAssertEqual(again["response"]?["pending_user_dialog_requests"]?[0]?["received_at"], .string("2026-09-04T00:00:02.000Z"),
                       "a pending element's extra key was dropped")
        let original = try JSONDecoder().decode(JSONValue.self, from: raw)
        XCTAssertTrue(again.numericallyEqual(original), "control_response_pending lost keys or values")
    }

    /// Pins the `ControlSuccess` / `ControlFailure` surface that Task 5's `InboundAnswer` and
    /// Task 10's `spawn()` build on, so keeping the pending arrays raw stays invisible to them.
    func testControlResponseAPIShapeForDownstreamTasks() throws {
        let s = ControlSuccess(requestID: RequestID(rawValue: "r1"), response: .object(["ok": .bool(true)]))
        let permissions: [ControlRequestFrame] = s.pendingPermissionRequests
        let dialogs: [ControlRequestFrame] = s.pendingUserDialogRequests
        XCTAssertEqual(permissions, []); XCTAssertEqual(dialogs, [])
        let encoded = try FrameDecoder.encode(.controlResponse(ControlResponseFrame(body: .success(s))))
        let v = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertNil(v["response"]?["pending_permission_requests"], "an empty array must still omit the key")
        XCTAssertEqual(v["response"]?["response"]?["ok"], .bool(true))
        let req = ControlRequestFrame(requestID: RequestID(rawValue: "r2"), request: .object(["subtype": .string("can_use_tool")]))
        XCTAssertEqual(ControlSuccess(requestID: RequestID(rawValue: "r1"), response: nil, pendingPermissionRequests: [req]).pendingPermissionRequests, [req])
        let error: String = ControlFailure(requestID: RequestID(rawValue: "r3"), error: "boom").error
        XCTAssertEqual(error, "boom")
    }

    /// A key one subtype models but the other does not must land in `additional` rather than being
    /// swallowed: an `error` response carrying `response` / `pending_*`, and a `success` response
    /// carrying `error`.
    func testCrossBranchKeysSurviveInAdditional() throws {
        let errorFrame = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"req-012","error":"nope","response":{"leftover":1},"pending_permission_requests":[]}}"#.utf8)
        guard case .controlResponse(let e) = FrameDecoder.decode(line: errorFrame), case .error = e.body else { return XCTFail() }
        XCTAssertEqual(e.additional["response"]?["leftover"], .integer(1))
        XCTAssertEqual(e.additional["pending_permission_requests"], .array([]))
        let againError = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(.controlResponse(e)))
        XCTAssertTrue(againError.numericallyEqual(try JSONDecoder().decode(JSONValue.self, from: errorFrame)),
                      "an error response dropped a key only the success branch models")

        let successFrame = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"req-013","response":{"ok":true},"error":"stray"}}"#.utf8)
        guard case .controlResponse(let s) = FrameDecoder.decode(line: successFrame), case .success = s.body else { return XCTFail() }
        XCTAssertEqual(s.additional["error"], .string("stray"))
        let againSuccess = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(.controlResponse(s)))
        XCTAssertTrue(againSuccess.numericallyEqual(try JSONDecoder().decode(JSONValue.self, from: successFrame)),
                      "a success response dropped a key only the error branch models")
    }

    /// A missing `error` must not be invented as `"error":""` on re-encode.
    func testErrorFrameWithoutErrorKeyDoesNotGainOne() throws {
        let raw = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"req-011"}}"#.utf8)
        guard case .controlResponse(let f) = FrameDecoder.decode(line: raw), case .error(let e) = f.body else { return XCTFail() }
        XCTAssertEqual(e.error, "")
        let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(.controlResponse(f)))
        XCTAssertNil(again["response"]?["error"], "an absent error key was invented")
        XCTAssertTrue(again.numericallyEqual(try JSONDecoder().decode(JSONValue.self, from: raw)))
    }

    /// The decoder's default branch covers both a valid JSON line that is not an object and an
    /// object carrying no `type` key.
    func testNonObjectJSONAndMissingTypeAreOpaqueUnknownType() throws {
        guard case .opaque(let array) = FrameDecoder.decode(line: Data("[1,2,3]".utf8)) else { return XCTFail() }
        XCTAssertEqual(array.reason, .unknownType); XCTAssertNil(array.type)
        XCTAssertEqual(array.value, .array([.integer(1), .integer(2), .integer(3)]))
        guard case .opaque(let untyped) = FrameDecoder.decode(line: Data(#"{"no_type_key":1}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(untyped.reason, .unknownType); XCTAssertNil(untyped.type); XCTAssertNil(untyped.subtype)
        XCTAssertEqual(untyped.value["no_type_key"], .integer(1))
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
                     "control_response_success", "control_response_error", "control_response_pending",
                     "control_cancel_request", "keep_alive"] {
            let raw = try TestPaths.sample(name)
            let frame = FrameDecoder.decode(line: raw)
            if case .opaque = frame { XCTFail("\(name) decoded opaque"); continue }
            let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(frame))
            let original = try JSONDecoder().decode(JSONValue.self, from: raw)
            XCTAssertTrue(again.numericallyEqual(original), "\(name) lost keys or values")
        }
    }
}
