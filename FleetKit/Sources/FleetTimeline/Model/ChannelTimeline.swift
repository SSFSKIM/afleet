import Foundation
import ClaudeWire

// MARK: - The read model

/// The read model the renderer holds: the durable projection, the overlay and the preview, merged in order
/// (contract X4). C6 holds one of these per channel; C7's Browser leaf calls `recentURLs(limit:)`.
public struct ChannelTimeline: Sendable, Hashable {
    public var durable: DurableProjection
    public var overlay: Overlay
    public var preview: StreamingPreview?

    public init(durable: DurableProjection = .empty, overlay: Overlay = .empty, preview: StreamingPreview? = nil) {
        self.durable = durable; self.overlay = overlay; self.preview = preview
    }

    /// The durable items with the overlay's items merged by timestamp, stable for ties with the durable item first;
    /// the preview is excluded because it is not an item yet. An item with no timestamp sorts after every timestamped
    /// one, keeping its own half's order — the only total order that needs no invented instant.
    public var items: [TimelineItem] {
        let durableItems = durable.items
        let overlayItems = overlay.items
        var decorated: [(item: TimelineItem, at: Date, half: Int, index: Int)] = []
        decorated.reserveCapacity(durableItems.count + overlayItems.count)
        for (index, item) in durableItems.enumerated() {
            decorated.append((item, item.timestamp ?? .distantFuture, 0, index))
        }
        for (index, item) in overlayItems.enumerated() {
            decorated.append((item, item.timestamp ?? .distantFuture, 1, index))
        }
        decorated.sort { a, b in
            if a.at != b.at { return a.at < b.at }
            if a.half != b.half { return a.half < b.half }
            return a.index < b.index
        }
        return decorated.map(\.item)
    }

    /// The URLs the channel has shown, most recent first and de-duplicated by the exact URL, at most `limit` of them.
    /// "Most recent" is `items` order — the position of the last item that mentioned the URL — which is the same
    /// order the renderer shows, so an item carrying no timestamp needs no separate rule here.
    ///
    /// It reads `items` and nothing else — never a frame, never a record — which is what keeps it from disagreeing
    /// with what the timeline renders. Only the kinds in `URLSources.contributing` are scanned.
    public func recentURLs(limit: Int) -> [SeenURL] {
        guard limit > 0 else { return [] }
        var seen: [String: (url: URL, firstSeen: ItemID, firstSeenAt: Date?, lastSeen: ItemID, lastSeenAt: Date?,
                            lastIndex: Int, sighting: Int)] = [:]
        var order: [String] = []
        for (index, item) in items.enumerated() {
            guard let source = URLSources.source(of: item), URLSources.contributing.contains(source.kind) else { continue }
            for url in URLScanner.urls(in: source.text) {
                let key = url.absoluteString
                if var record = seen[key] {
                    record.lastSeen = item.id
                    record.lastSeenAt = item.timestamp
                    record.lastIndex = index
                    seen[key] = record
                } else {
                    seen[key] = (url, item.id, item.timestamp, item.id, item.timestamp, index, order.count)
                    order.append(key)
                }
            }
        }
        // Recency is the position of the last item that mentioned the URL, not that item's timestamp: `items` is
        // already in render order, so the index *is* the recency, and an item with no timestamp needs no second
        // convention here to contradict the one the merge already applied. Two URLs last seen in the same item tie on
        // that index, and the tie is broken by the order the scanner found them in, which makes the ordering total —
        // `Array.sorted` is not stable, so an incomplete comparator would lose the appearance order the scanner keeps.
        let sorted = order.compactMap { seen[$0] }.sorted { a, b in
            if a.lastIndex != b.lastIndex { return a.lastIndex > b.lastIndex }
            return a.sighting < b.sighting
        }
        return sorted.prefix(limit).map {
            SeenURL(url: $0.url, firstSeen: $0.firstSeen, firstSeenAt: $0.firstSeenAt,
                    lastSeen: $0.lastSeen, lastSeenAt: $0.lastSeenAt)
        }
    }
}

/// One URL the channel has shown, with the first and the last item that mentioned it.
public struct SeenURL: Hashable, Sendable, Codable {
    public let url: URL
    public let firstSeen: ItemID
    public let firstSeenAt: Date?
    public let lastSeen: ItemID
    public let lastSeenAt: Date?
    public init(url: URL, firstSeen: ItemID, firstSeenAt: Date?, lastSeen: ItemID, lastSeenAt: Date?) {
        self.url = url; self.firstSeen = firstSeen; self.firstSeenAt = firstSeenAt
        self.lastSeen = lastSeen; self.lastSeenAt = lastSeenAt
    }
}

// MARK: - Which items contribute

public enum URLSources {
    /// The item kinds whose text is scanned for URLs. Tool results carry dev-server and
    /// documentation URLs; assistant text carries the ones the model names; local command
    /// output carries what a slash command printed. User messages are excluded because the
    /// person typed them; thinking blocks, attachments, hidden records and captions are excluded.
    public static let contributing: Set<URLSourceKind> = [.toolResultText, .assistantText, .localCommandOutput]

    /// The kind an item contributes as and the text that kind names, or nil for an item no kind covers.
    /// It is the single place the mapping lives, so `contributing` alone decides what is scanned.
    static func source(of item: TimelineItem) -> (kind: URLSourceKind, text: String)? {
        switch item {
        case .toolCall(let call):
            guard let result = call.result else { return nil }
            return (.toolResultText, resultText(of: result))
        case .assistantMessage(let message):
            let text = message.blocks.compactMap { if case .text(let block) = $0 { block.fields.text } else { nil } }
                .joined(separator: "\n")
            return (.assistantText, text)
        case .notification(let notification):
            // The wire spelling and the transcript spelling of the same thing: `local_command_output` on the wire,
            // a file-only `local_command` `system` record in the transcript.
            let isLocalCommand = notification.key == "local_command_output"
                || (notification.key == "local_command" && notification.fileOnly)
            guard isLocalCommand else { return nil }
            return (.localCommandOutput, notification.text)
        default:
            return nil
        }
    }

    /// A tool result's text: the `content` of a `tool_result` block is a string, or an array of blocks whose `text`
    /// members carry it (`ToolResultBlockFields.content` is an unmodelled `JSONValue` — interpreting it is C3's job).
    private static func resultText(of value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        guard let array = value.arrayValue else { return "" }
        return array.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}

public enum URLSourceKind: String, Sendable, Codable, CaseIterable { case toolResultText, assistantText, localCommandOutput }

// MARK: - The scanner

public enum URLScanner {
    /// `http://` or `https://` then characters up to whitespace or one of `"'<>` `)` `]`; trailing `.,;:!?` trimmed; parsed with
    /// `URL(string:)`, failures dropped. Order of appearance preserved; duplicates within one text preserved (the caller de-duplicates).
    public static func urls(in text: String) -> [URL] {
        let characters = Array(text)
        var out: [URL] = []
        var i = 0
        while i < characters.count {
            guard let bodyStart = schemeEnd(of: characters, at: i) else { i += 1; continue }
            var end = bodyStart
            while end < characters.count, !characters[end].isWhitespace, !Self.terminators.contains(characters[end]) {
                end += 1
            }
            var trimmed = end
            while trimmed > bodyStart, Self.trailing.contains(characters[trimmed - 1]) { trimmed -= 1 }
            if trimmed > bodyStart, let url = URL(string: String(characters[i..<trimmed])) { out.append(url) }
            i = max(end, i + 1)
        }
        return out
    }

    private static let terminators: Set<Character> = ["\"", "'", "<", ">", ")", "]"]
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// The index just past `http://` or `https://` at `index`, or nil if neither starts there.
    private static func schemeEnd(of characters: [Character], at index: Int) -> Int? {
        for scheme in ["https://", "http://"] {
            let end = index + scheme.count
            guard end <= characters.count else { continue }
            if String(characters[index..<end]) == scheme { return end }
        }
        return nil
    }
}
