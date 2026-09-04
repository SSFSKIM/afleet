import XCTest
import WireFrames
import WireDiagnostics
import WireTestSupport

final class RedactorTests: XCTestCase {
    private func redacted(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(Redactor.redact(line: Data(s.utf8))))
    }
    func testStringSecretsReplacedNumbersUntouched() throws {
        let v = try redacted(#"{"type":"result","usage":{"input_tokens":12,"output_tokens":3,"thinking_tokens":1},"max_tokens":8,"tokens":5,"access_token":"sk-ant-abc","nested":{"apiKey":"k","oauthState":"s","secret_value":"v","count_tokens":7}}"#)
        XCTAssertEqual(v["usage"]?["input_tokens"], .integer(12)); XCTAssertEqual(v["usage"]?["thinking_tokens"], .integer(1))
        XCTAssertEqual(v["max_tokens"], .integer(8)); XCTAssertEqual(v["tokens"], .integer(5))
        XCTAssertEqual(v["access_token"], .string("<redacted>")); XCTAssertEqual(v["nested"]?["apiKey"], .string("<redacted>"))
        XCTAssertEqual(v["nested"]?["oauthState"], .string("<redacted>")); XCTAssertEqual(v["nested"]?["secret_value"], .string("<redacted>"))
        XCTAssertEqual(v["nested"]?["count_tokens"], .integer(7))          // a number, never redacted
    }
    func testAccountFieldsAndEnvironmentFramesDropped() throws {
        let v = try redacted(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"account":{"email":"a@b.c","uuid":"u"},"pid":1}}}"#)
        XCTAssertEqual(v["response"]?["response"]?["account"], .string("<redacted>")); XCTAssertEqual(v["response"]?["response"]?["pid"], .integer(1))
        XCTAssertNil(Redactor.redact(line: Data(#"{"type":"control_request","request_id":"e","request":{"subtype":"update_environment_variables","variables":{"A":"1"}}}"#.utf8)))
    }
    func testMCPBodiesTruncatedTo4KB() throws {
        let big = String(repeating: "x", count: 5000)
        let v = try redacted(#"{"type":"control_request","request_id":"m","request":{"subtype":"mcp_message","server_name":"afleet","message":{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"blob":""# + big + #""}}}}"#)
        let msg = v["request"]?["message"]
        XCTAssertEqual(msg?["truncated"]?.intValue.map { $0 > 4096 }, true)
        XCTAssertNil(msg?["params"])
    }
    func testUnparseableLineIsNotCaptured() {
        XCTAssertNil(Redactor.redact(line: Data("garbage".utf8)))
    }
    func testTypedFramesStayTypedAfterRedaction() throws {
        for name in try TestPaths.sampleNames() {
            let raw = try TestPaths.sample(name)
            let before = FrameDecoder.decode(line: raw)
            guard let after = Redactor.redact(line: raw) else { XCTFail("\(name) dropped"); continue }
            let afterFrame = FrameDecoder.decode(line: after)
            XCTAssertEqual(before.typeName, afterFrame.typeName, name)
            if case .opaque = before { continue }
            if case .opaque(let o) = afterFrame { XCTFail("\(name) became opaque after redaction: \(o.reason)") }
        }
    }
}
