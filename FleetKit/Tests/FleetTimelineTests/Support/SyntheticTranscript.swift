import Foundation
@testable import FleetTimeline

/// Invented transcripts for the tests that need a file above the whole-file threshold. Every uuid is `00000000-0000-4000-8000-`
/// plus a twelve-digit counter, the session id is `33333333-3333-4333-8333-333333333333`, every text is generated ASCII; no
/// engine byte. Records are the shapes Task 1 decodes: a human `user` (`message.role == "user"`, a string `message.content`),
/// an `assistant` (`message.id`, one text block), a `last-prompt` (`lastPrompt`, `leafUuid`), all with `parentUuid`,
/// `isSidechain: false`, `sessionId`, `timestamp` and `type`.
enum SyntheticTranscript {
    static let sessionID = "33333333-3333-4333-8333-333333333333"

    struct File {
        let data: Data
        let ranges: [ByteRange]          // one per record, in file order — what the reader must report byte for byte
        let turnStarts: [Int]            // indices into `ranges` of every human `user` record
        let leafUUID: String             // what the final `last-prompt` names
        let leafIndex: Int               // that record's index into `ranges`
    }

    /// `turns` turns, each a human `user` record whose `message.content` is `paddingBytes` bytes long, one uuid-less `atis-latch`
    /// record with fixed invented fields (byte-identical in every turn, so identical canonical hashes straddle every window boundary)
    /// and an `assistant` reply, the `user` and `assistant` records chained by `parentUuid` from the first; the final record is a
    /// `last-prompt` whose `leafUuid` is turn `leafTurn`'s `user` uuid.
    static func linear(turns: Int, paddingBytes: Int, leafTurn: Int) -> File {
        var builder = Builder()
        var parent: String? = nil
        var leaf = ""
        for turn in 1...turns {
            let (user, assistant) = builder.appendTurn(number: turn, paddingBytes: paddingBytes, parent: parent)
            if turn == leafTurn { leaf = user }
            parent = assistant
        }
        builder.appendLastPrompt(leaf: leaf)
        return builder.finish(leaf: leaf)
    }

    /// `turns` turns as above, then `thenTurns` more whose first `user` record's `parentUuid` is turn `rewindAfterTurn`'s assistant
    /// — a rewind, the first branch's tail left in the file as the engine leaves it — and a final `last-prompt` whose `leafUuid`
    /// is the second branch's last `user` uuid.
    static func rewound(turns: Int, paddingBytes: Int, rewindAfterTurn: Int, thenTurns: Int) -> File {
        var builder = Builder()
        var parent: String? = nil
        var rewindPoint = ""
        for turn in 1...turns {
            let (_, assistant) = builder.appendTurn(number: turn, paddingBytes: paddingBytes, parent: parent)
            if turn == rewindAfterTurn { rewindPoint = assistant }
            parent = assistant
        }
        parent = rewindPoint
        var leaf = ""
        for turn in 1...thenTurns {
            let (user, assistant) = builder.appendTurn(number: turns + turn, paddingBytes: paddingBytes, parent: parent)
            leaf = user
            parent = assistant
        }
        builder.appendLastPrompt(leaf: leaf)
        return builder.finish(leaf: leaf)
    }

    /// One turn of a session that queues input, as six lines each ending in `\n`: a human `user` (uuid), two `queue-operation`
    /// records (`operation` `enqueue` then `dequeue`, distinct `timestamp`s, so their hashes differ), a `file-history-snapshot`
    /// (`messageId` = the `user` uuid), an `assistant` (`message.id`) and a `last-prompt` naming the `user` uuid. `turn` seeds the
    /// uuid counter and the timestamps, so turns 1 and 2 never collide.
    static func queuedTurnLines(turn: Int) -> [Data] {
        let base = turn * 1_000
        let user = uuid(base + 1), assistant = uuid(base + 2)
        let lines = [
            userLine(uuid: user, parent: nil, text: "queued prompt \(turn)", stamp: base + 1),
            #"{"type":"queue-operation","sessionId":"\#(sessionID)","operation":"enqueue","timestamp":"\#(timestamp(base + 1))"}"#,
            #"{"type":"queue-operation","sessionId":"\#(sessionID)","operation":"dequeue","timestamp":"\#(timestamp(base + 2))"}"#,
            #"{"type":"file-history-snapshot","sessionId":"\#(sessionID)","messageId":"\#(user)","snapshot":{"files":{}}}"#,
            assistantLine(uuid: assistant, parent: user, text: "queued reply \(turn)", stamp: base + 2),
            #"{"type":"last-prompt","sessionId":"\#(sessionID)","leafUuid":"\#(user)","lastPrompt":"queued prompt \#(turn)"}"#,
        ]
        return lines.map { Data(($0 + "\n").utf8) }
    }

    // MARK: - Invented identifiers and text

    static func uuid(_ counter: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", counter) }

    static func timestamp(_ counter: Int) -> String {
        String(format: "2026-01-01T%02d:%02d:%02d.%03dZ", (counter / 3600) % 24, (counter / 60) % 60, counter % 60, counter % 1000)
    }

    /// Generated ASCII: a deterministic 64-character block repeated to length. Nothing here came off a wire or a disk.
    static func text(_ bytes: Int, seed: Int) -> String {
        guard bytes > 0 else { return "" }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 ")
        var state = UInt64(bitPattern: Int64(seed)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var block = ""
        for _ in 0..<64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            block.append(alphabet[Int(state >> 33) % alphabet.count])
        }
        return String(String(repeating: block, count: bytes / block.count + 1).prefix(bytes))
    }

    // MARK: - Record shapes

    private static func userLine(uuid: String, parent: String?, text: String, stamp: Int) -> String {
        let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"user","uuid":"\#(uuid)","parentUuid":\#(parentJSON),"isSidechain":false,"sessionId":"\#(sessionID)","timestamp":"\#(timestamp(stamp))","message":{"role":"user","content":"\#(text)"}}"#
    }

    private static func assistantLine(uuid: String, parent: String, text: String, stamp: Int) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":"\#(parent)","isSidechain":false,"sessionId":"\#(sessionID)","timestamp":"\#(timestamp(stamp))","message":{"id":"msg_\#(uuid.suffix(12))","type":"message","role":"assistant","model":"synthetic-model","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#
    }

    /// Byte-identical in every turn on purpose: the repeated uuid-less line whose canonical hash straddles window boundaries.
    private static let atisLatchLine = #"{"type":"atis-latch","sessionId":"\#(sessionID)","atis":"synthetic-latch"}"#

    private struct Builder {
        private var bytes = Data()
        private var ranges: [ByteRange] = []
        private var turnStarts: [Int] = []
        private var index: [String: Int] = [:]      // uuid → record index, for `leafIndex`
        private var counter = 0

        private mutating func append(_ line: String, uuid: String? = nil, turnStart: Bool = false) {
            let encoded = Data(line.utf8)
            ranges.append(ByteRange(offset: bytes.count, length: encoded.count))
            if turnStart { turnStarts.append(ranges.count - 1) }
            if let uuid { index[uuid] = ranges.count - 1 }
            bytes.append(encoded)
            bytes.append(UInt8(ascii: "\n"))
        }

        /// One turn: the human `user`, the repeated `atis-latch`, the `assistant`. Returns the two uuids.
        mutating func appendTurn(number: Int, paddingBytes: Int, parent: String?) -> (user: String, assistant: String) {
            counter += 1; let user = SyntheticTranscript.uuid(counter)
            counter += 1; let assistant = SyntheticTranscript.uuid(counter)
            append(SyntheticTranscript.userLine(uuid: user, parent: parent,
                                                text: SyntheticTranscript.text(paddingBytes, seed: number),
                                                stamp: number * 2), uuid: user, turnStart: true)
            append(SyntheticTranscript.atisLatchLine)
            append(SyntheticTranscript.assistantLine(uuid: assistant, parent: user,
                                                     text: SyntheticTranscript.text(120, seed: -number),
                                                     stamp: number * 2 + 1), uuid: assistant)
            return (user, assistant)
        }

        mutating func appendLastPrompt(leaf: String) {
            append(#"{"type":"last-prompt","sessionId":"\#(SyntheticTranscript.sessionID)","leafUuid":"\#(leaf)","lastPrompt":"synthetic prompt"}"#)
        }

        func finish(leaf: String) -> File {
            File(data: bytes, ranges: ranges, turnStarts: turnStarts, leafUUID: leaf, leafIndex: index[leaf] ?? -1)
        }
    }
}
