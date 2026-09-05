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

    func testCanonicalDataEscapesEveryControlCharacterInStringsAndInKeys() throws {
        let v: JSONValue = .object([
            "plain": .string("q\"b \\ s\nn\tt\rr\u{07}bell"),
            "k\u{01}": .string("control in the key"),
        ])
        let canonical = try v.canonicalData()
        let text = String(decoding: canonical, as: UTF8.self)
        XCTAssertTrue(text.contains(#"\u0007"#), text)
        XCTAssertTrue(text.contains(#"\u0001"#), text)
        XCTAssertTrue(text.contains(#"\n"#) && text.contains(#"\t"#) && text.contains(#"\r"#), text)
        // The escape table is only correct if the result parses back to the same value.
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: canonical), v)
    }

    func testCanonicalDataThrowsForNonFiniteDoubles() {
        XCTAssertThrowsError(try JSONValue.number(.infinity).canonicalData())
        XCTAssertThrowsError(try JSONValue.number(-.infinity).canonicalData())
        XCTAssertThrowsError(try JSONValue.object(["k": .array([.number(.nan)])]).canonicalData())
    }

    func testCanonicalDataIsIdempotentAcrossADecodeForLargeIntegralDoubles() throws {
        // .number(1e16) and .integer(10000000000000000) are the same value reached two ways;
        // canonical bytes must not depend on which one the wire happened to produce.
        let once = try JSONValue.number(1e16).canonicalData()
        XCTAssertEqual(String(decoding: once, as: UTF8.self), "10000000000000000")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: once).canonicalData(), once)
        XCTAssertEqual(try JSONValue.integer(10_000_000_000_000_000).canonicalData(), once)
        // Fractional and out-of-Int64-range values keep the Double spelling.
        XCTAssertEqual(String(decoding: try JSONValue.number(1.5).canonicalData(), as: UTF8.self), "1.5")
        XCTAssertEqual(String(decoding: try JSONValue.number(-0.0).canonicalData(), as: UTF8.self), "0")
        XCTAssertNoThrow(try JSONValue.number(1e30).canonicalData())
    }

    func testNumericEqualityComparesObjectKeysNotInsertionOrder() {
        var a: [String: JSONValue] = [:]
        for k in ["one", "two", "three"] { a[k] = .integer(2) }
        var b: [String: JSONValue] = [:]
        for k in ["three", "two", "one"] { b[k] = .number(2) }
        XCTAssertTrue(JSONValue.object(a).numericallyEqual(.object(b)))
        // Same count, one key renamed: the key comparison, not the count, has to catch this.
        var renamed = b
        renamed["four"] = renamed.removeValue(forKey: "one")
        XCTAssertEqual(renamed.count, b.count)
        XCTAssertFalse(JSONValue.object(a).numericallyEqual(.object(renamed)))
        XCTAssertFalse(JSONValue.object(a).numericallyEqual(.object(["one": .integer(2), "two": .integer(2)])))
        XCTAssertTrue(JSONValue.array([.integer(1), .number(2.0)]).numericallyEqual(.array([.number(1.0), .integer(2)])))
        XCTAssertFalse(JSONValue.array([.integer(1)]).numericallyEqual(.array([.integer(1), .integer(1)])))
    }
}
