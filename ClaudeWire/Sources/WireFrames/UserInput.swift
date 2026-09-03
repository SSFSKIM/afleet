import Foundation

public struct ImageAttachment: Hashable, Sendable {
    public var mediaType: String
    public var base64: String
    public init(mediaType: String, base64: String) { self.mediaType = mediaType; self.base64 = base64 }
}
public struct UserInput: Hashable, Sendable {
    public var text: String
    public var images: [ImageAttachment]
    public init(text: String, images: [ImageAttachment] = []) { self.text = text; self.images = images }

    /// The §6.6 user frame: client uuid, parent_tool_use_id null, origin human.
    public func frame(uuid: UUID) -> JSONValue {
        let content: JSONValue
        if images.isEmpty { content = .string(text) }
        else {
            var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
            for img in images {
                blocks.append(.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string(img.mediaType), "data": .string(img.base64)])]))
            }
            content = .array(blocks)
        }
        return .object(["type": .string("user"), "uuid": .string(uuid.uuidString.lowercased()), "parent_tool_use_id": .null,
                        "origin": .object(["kind": .string("human")]), "message": .object(["role": .string("user"), "content": content])])
    }
}
