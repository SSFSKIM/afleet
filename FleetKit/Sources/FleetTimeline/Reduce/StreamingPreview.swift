import Foundation
import ClaudeWire

/// One partially assembled content block of the message currently streaming.
public struct PreviewBlock: Sendable, Hashable, Codable {
    /// What the block will become. `toolInput` accumulates `input_json_delta` fragments, which are not valid JSON
    /// until the block stops, so they are kept as the text the engine sent.
    public enum Kind: String, Sendable, Codable { case text, thinking, toolInput, other }
    public var index: Int
    public var kind: Kind
    public var text: String
    public var toolName: String?
    public var toolUseID: String?
    public var complete: Bool
    public init(index: Int, kind: Kind, text: String = "", toolName: String? = nil,
                toolUseID: String? = nil, complete: Bool = false) {
        self.index = index; self.kind = kind; self.text = text; self.toolName = toolName
        self.toolUseID = toolUseID; self.complete = complete
    }
}

/// The Anthropic partial-message events of `stream_event`, assembled into what the channel shows before the
/// `assistant` frame makes the message durable. ClaudeWire models `stream_event.event` as an unstructured
/// `JSONValue` on purpose, so the parsing is here.
///
/// `signature_delta` is ignored: a thinking signature is opaque, is never rendered, and would only make the preview
/// churn. `message_delta` carries the stop reason and `message_stop` marks the message complete.
public struct StreamingPreview: Sendable, Hashable, Codable {
    public var messageID: String?
    public var model: String?
    public var blocks: [PreviewBlock]
    public var stopReason: String?
    public var isComplete: Bool

    public init(messageID: String? = nil, model: String? = nil, blocks: [PreviewBlock] = [],
                stopReason: String? = nil, isComplete: Bool = false) {
        self.messageID = messageID; self.model = model; self.blocks = blocks
        self.stopReason = stopReason; self.isComplete = isComplete
    }

    /// The visible text, in block order — what the channel renders and what the finished `AssistantMessageItem`'s
    /// text blocks must equal.
    public var text: String {
        blocks.filter { $0.kind == .text }.map(\.text).joined()
    }

    /// Whether an event with no preview open starts one. Only these two do: a `content_block_delta` or a
    /// `content_block_stop` arriving after the `assistant` frame collapsed the preview has nothing left to add, and
    /// answering it with a fresh empty preview would leave a phantom in the channel.
    public static func opens(_ event: JSONValue) -> Bool {
        let type = event["type"]?.stringValue
        return type == "message_start" || type == "content_block_start"
    }

    /// Returns whether anything visible changed.
    @discardableResult
    public mutating func apply(event: JSONValue) -> Bool {
        switch event["type"]?.stringValue {
        case "message_start":
            messageID = event["message"]?["id"]?.stringValue
            model = event["message"]?["model"]?.stringValue
            return true

        case "content_block_start":
            guard let index = event["index"]?.intValue.map(Int.init) else { return false }
            let block = event["content_block"]
            let kind: PreviewBlock.Kind = switch block?["type"]?.stringValue {
            case "text": .text
            case "thinking": .thinking
            case "tool_use": .toolInput
            default: .other
            }
            let seed = switch kind {
            case .text: block?["text"]?.stringValue ?? ""
            case .thinking: block?["thinking"]?.stringValue ?? ""
            default: ""
            }
            set(PreviewBlock(index: index, kind: kind, text: seed,
                             toolName: block?["name"]?.stringValue, toolUseID: block?["id"]?.stringValue))
            return true

        case "content_block_delta":
            guard let index = event["index"]?.intValue.map(Int.init),
                  let position = blocks.firstIndex(where: { $0.index == index }) else { return false }
            let delta = event["delta"]
            let fragment: String? = switch delta?["type"]?.stringValue {
            case "text_delta": delta?["text"]?.stringValue
            case "thinking_delta": delta?["thinking"]?.stringValue
            case "input_json_delta": delta?["partial_json"]?.stringValue
            default: nil                                     // `signature_delta` and anything unmodelled
            }
            guard let fragment, !fragment.isEmpty else { return false }
            blocks[position].text += fragment
            return true

        case "content_block_stop":
            guard let index = event["index"]?.intValue.map(Int.init),
                  let position = blocks.firstIndex(where: { $0.index == index }) else { return false }
            blocks[position].complete = true
            return true

        case "message_delta":
            guard let reason = event["delta"]?["stop_reason"]?.stringValue else { return false }
            stopReason = reason
            return true

        case "message_stop":
            isComplete = true
            return true

        default:
            return false
        }
    }

    private mutating func set(_ block: PreviewBlock) {
        if let position = blocks.firstIndex(where: { $0.index == block.index }) {
            blocks[position] = block
        } else {
            blocks.append(block)
            blocks.sort { $0.index < $1.index }
        }
    }
}
