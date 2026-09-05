import XCTest
import WireFrames

final class UserInputTests: XCTestCase {
    func testTextOnlyFrame() throws {
        let uuid = UUID()
        let v = UserInput(text: "hi").frame(uuid: uuid)
        XCTAssertEqual(v["type"], .string("user")); XCTAssertEqual(v["uuid"], .string(uuid.uuidString.lowercased()))
        XCTAssertEqual(v["parent_tool_use_id"], .null); XCTAssertEqual(v["origin"], .object(["kind": .string("human")]))
        XCTAssertEqual(v["message"], .object(["role": .string("user"), "content": .string("hi")]))
    }
    func testImagesBecomeBlocks() throws {
        let v = UserInput(text: "look", images: [ImageAttachment(mediaType: "image/png", base64: "AAAA")]).frame(uuid: UUID())
        let content = v["message"]?["content"]?.arrayValue
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"], .string("text")); XCTAssertEqual(content?[1]["type"], .string("image"))
        XCTAssertEqual(content?[1]["source"]?["media_type"], .string("image/png"))
        XCTAssertEqual(content?[1]["source"]?["type"], .string("base64"))
        XCTAssertEqual(content?[1]["source"]?["data"], .string("AAAA"))
    }
}
