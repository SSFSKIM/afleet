import XCTest
import WireFrames

final class JSONValueTests: XCTestCase {
    func testDecodesEveryKindAndKeepsIntegersApart() throws {
        let data = Data(#"{"a":1,"b":1.5,"c":"s","d":true,"e":null,"f":[1,"x"],"g":{"h":2}}"#.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v["a"], .integer(1))
        XCTAssertEqual(v["b"], .number(1.5))
        XCTAssertEqual(v["c"], .string("s"))
        XCTAssertEqual(v["d"], .bool(true))
        XCTAssertEqual(v["e"], .null)
        XCTAssertEqual(v["f"], .array([.integer(1), .string("x")]))
        XCTAssertEqual(v["g"]?["h"], .integer(2))
        XCTAssertNil(v["missing"])
    }

    func testCanonicalDataSortsKeysRecursivelyAndIsStable() throws {
        let a = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"z":{"b":1,"a":2},"a":[3,{"y":1,"x":2}]}"#.utf8))
        let b = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[3,{"x":2,"y":1}],"z":{"a":2,"b":1}}"#.utf8))
        XCTAssertEqual(try a.canonicalData(), try b.canonicalData())
        XCTAssertEqual(String(decoding: try a.canonicalData(), as: UTF8.self), #"{"a":[3,{"x":2,"y":1}],"z":{"a":2,"b":1}}"#)
    }

    func testNumericEqualityAcrossIntegerAndNumber() {
        XCTAssertTrue(JSONValue.integer(1).numericallyEqual(.number(1.0)))
        XCTAssertFalse(JSONValue.integer(1).numericallyEqual(.number(1.5)))
        XCTAssertTrue(JSONValue.object(["k": .integer(2)]).numericallyEqual(.object(["k": .number(2)])))
        XCTAssertFalse(JSONValue.string("1").numericallyEqual(.integer(1)))
    }

    func testEncodeDecodeRoundTrip() throws {
        let v: JSONValue = .object(["n": .integer(-42), "s": .string("é\n"), "arr": .array([.null, .bool(false)])])
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
    }

    func testLargeIntegersStayIntegers() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data("9007199254740993".utf8))
        XCTAssertEqual(v, .integer(9_007_199_254_740_993))
    }
}
