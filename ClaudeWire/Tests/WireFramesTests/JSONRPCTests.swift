import XCTest
import WireFrames

final class JSONRPCTests: XCTestCase {
    private func decode(_ s: String) throws -> JSONRPCMessage { try JSONDecoder().decode(JSONRPCMessage.self, from: Data(s.utf8)) }

    func testClassifiesRequestNotificationResponseError() throws {
        guard case .request(let req) = try decode(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) else { return XCTFail() }
        XCTAssertEqual(req.id, .number(1)); XCTAssertEqual(req.method, "ping"); XCTAssertNil(req.params)
        guard case .notification(let n) = try decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) else { return XCTFail() }
        XCTAssertEqual(n.method, "notifications/initialized")
        guard case .response(let r) = try decode(#"{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}"#) else { return XCTFail() }
        XCTAssertEqual(r.id, .string("abc")); XCTAssertEqual(r.result["ok"], .bool(true))
        guard case .error(let e) = try decode(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Method not found"}}"#) else { return XCTFail() }
        XCTAssertEqual(e.id, .null); XCTAssertEqual(e.error.code, -32601)
    }

    func testEncodingMatchesWire() throws {
        let m = JSONRPCMessage.response(.init(id: .number(0), result: .object([:])))
        let v = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(v, .object(["jsonrpc": .string("2.0"), "id": .integer(0), "result": .object([:])]))
        let err = JSONRPCMessage.error(.init(id: .number(3), error: .init(code: -32601, message: "Method not found", data: nil)))
        let ev = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(err))
        XCTAssertEqual(ev["error"]?["code"], .integer(-32601))
        XCTAssertNil(ev["error"]?["data"])
    }

    func testPresentButUnmappableIDThrowsInsteadOfSilentlyBecomingANotification() throws {
        // A notification owes no response, so misclassifying a request as one would hang the peer.
        for raw in [#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
                    #"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#,
                    #"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#,
                    #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#] {
            XCTAssertThrowsError(try decode(raw), raw) { error in
                XCTAssertEqual(DecodeFailure(error).field, "id", raw)
            }
        }
    }

    func testAbsentIDIsStillANotification() throws {
        guard case .notification(let n) = try decode(#"{"jsonrpc":"2.0","method":"ping","params":{"a":1}}"#) else { return XCTFail() }
        XCTAssertEqual(n.method, "ping")
        XCTAssertEqual(n.params?["a"], .integer(1))
    }
}
