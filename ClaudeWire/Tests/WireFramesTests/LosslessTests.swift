import XCTest
import WireFrames

private struct PointFields: Codable, Sendable, DeclaredKeys {
    var x: Int
    var label: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case x, label = "display_label" }
}
private typealias Point = Lossless<PointFields>

final class LosslessTests: XCTestCase {
    func testUndeclaredKeysAreKeptAndReEncoded() throws {
        let raw = Data(#"{"x":1,"display_label":"p","future_key":{"deep":[1,2]},"other":true}"#.utf8)
        let p = try JSONDecoder().decode(Point.self, from: raw)
        XCTAssertEqual(p.x, 1)                       // dynamic member lookup into fields
        XCTAssertEqual(p.label, "p")
        XCTAssertEqual(p.additional["future_key"]?["deep"], .array([.integer(1), .integer(2)]))
        XCTAssertEqual(Set(p.additional.keys), ["future_key", "other"])
        let back = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(p))
        let original = try JSONDecoder().decode(JSONValue.self, from: raw)
        XCTAssertEqual(back, original)
    }

    func testDeclaredKeysComeFromCodingKeys() {
        XCTAssertEqual(PointFields.declaredKeys, ["x", "display_label"])
    }

    func testExplicitNullOnADeclaredOptionalSurvivesReEncoding() throws {
        let raw = Data(#"{"x":1,"display_label":null,"nested":{"k":null}}"#.utf8)
        let p = try JSONDecoder().decode(Point.self, from: raw)
        XCTAssertNil(p.label); XCTAssertEqual(p.explicitNulls, ["display_label"])
        let back = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back, try JSONDecoder().decode(JSONValue.self, from: raw))
        var mutated = p; mutated.label = "now set"
        let back2 = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(mutated))
        XCTAssertEqual(back2["display_label"], .string("now set"))
    }

    func testMissingRequiredFieldNamesTheField() {
        XCTAssertThrowsError(try JSONDecoder().decode(Point.self, from: Data(#"{"display_label":"p"}"#.utf8))) { error in
            XCTAssertEqual(DecodeFailure(error).field, "x")
        }
    }
}
