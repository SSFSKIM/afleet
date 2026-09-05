import Foundation
import ClaudeWire

/// The engine's stamps are ISO 8601 with fractional seconds; a stamp written by an older writer has none, so both
/// spellings are tried in that order. `ISO8601DateFormatter` is a class and is not `Sendable`, so a parser is made
/// per reduction rather than shared; a reduction is a single synchronous call and owns its instance outright.
struct TimestampParser {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

/// Blocks to items: the half of the projection that the transcript-record reducer and the wire reducer must agree on
/// item for item (parent §7.3 — the record reducer is primary and check two compares the two). Everything here is
/// stated in terms of a *message*, never a record envelope, so Task 8 can feed it `assistant`/`user` wire frames and
/// get the same items this file's caller gets from `assistant`/`user` transcript records.
///
/// The builder is a value with an append-only cursor. `items` is the rendered order; the join tables let a later
/// record complete an earlier call, retract an earlier item, or fold into an open assistant run.
struct ItemBuilder {
    /// The one MCP tool whose call is a first-class item rather than a tool card (spec "The record reducer", rule 6).
    static let sendUserFileTool = "mcp__afleet__send_user_file"

    let stream: LogicalStream
    let sourceFile: URL?
    let origin: Provenance.Origin
    let agentID: String?

    private(set) var items: [TimelineItem] = []
    /// `ItemID.key` → position in `items`. Rebuilt whenever an item is retracted, so no index outlives its item.
    private var indexByKey: [String: Int] = [:]
    /// Assistant record uuid → the tool-use ids that record's blocks opened, for the `sourceToolAssistantUUID` join.
    private var callsByAssistantUUID: [String: [String]] = [:]
    /// Record uuid → the key of the item it folded into, for `supersedes` naming a record inside a merged item.
    private var itemKeyByRecordUUID: [String: String] = [:]
    /// The open assistant run: the item key and the `message.id` that consecutive records must match to fold into it.
    private var runKey: String?
    private var runMessageID: String?

    init(stream: LogicalStream, sourceFile: URL?, origin: Provenance.Origin) {
        self.stream = stream
        self.sourceFile = sourceFile
        self.origin = origin
        if case .agent(let taskID) = stream.name { self.agentID = taskID } else { self.agentID = nil }
    }

    // MARK: - Identity

    private func id(_ key: String) -> ItemID { ItemID(stream: stream, key: key) }
    private func provenance(_ key: RecordKey?) -> Provenance {
        Provenance(stream: stream, agentID: agentID, sourceFile: sourceFile,
                   records: key.map { Set([$0]) } ?? [], origin: origin)
    }

    // MARK: - Assistant

    /// One `assistant` record or frame. Records sharing `message.id` with the open run fold into its item: blocks are
    /// concatenated in record order, `recordUUIDs` grows in order, `model` stays the first's and `stopReason` becomes
    /// the last's (rule 5). Any record that renders — a user, a boundary, a notification — closes the run first, so
    /// "consecutive" means consecutive *in the projection*; an attachment, a `progress` record or a hidden `isMeta`
    /// user renders nothing and therefore never breaks a run.
    mutating func addAssistant(uuid: String, key: RecordKey?, message: Message, timestamp: Date?, supersedes: [String]) {
        let messageID = message.fields.id
        let blocks = message.fields.content
        let itemKey: String
        if let runKey, let runMessageID, let messageID, runMessageID == messageID,
           let index = indexByKey[runKey], case .assistantMessage(var item) = items[index] {
            item.blocks.append(contentsOf: blocks)
            item.recordUUIDs.append(uuid)
            item.stopReason = message.fields.stopReason
            if let key { item.provenance.records.insert(key) }
            items[index] = .assistantMessage(item)
            itemKey = runKey
        } else {
            let item = AssistantMessageItem(id: id(uuid), timestamp: timestamp, provenance: provenance(key),
                                            messageID: messageID, model: message.fields.model, blocks: blocks,
                                            stopReason: message.fields.stopReason, recordUUIDs: [uuid])
            append(.assistantMessage(item))
            itemKey = uuid
            runKey = uuid
            runMessageID = messageID
        }
        itemKeyByRecordUUID[uuid] = itemKey
        let parent = id(itemKey)
        for block in blocks {
            guard case .toolUse(let use) = block else { continue }
            open(use, parent: parent, assistantUUID: uuid, key: key, timestamp: timestamp, messageID: messageID)
        }
        if !supersedes.isEmpty { retract(supersedes, by: uuid) }
    }

    /// Every `tool_use` block opens an item keyed by the tool-use id: a `ToolCallItem`, or a `SentFileItem` for the
    /// one MCP tool whose two halves are both records (rule 6).
    private mutating func open(_ use: ToolUseBlock, parent: ItemID, assistantUUID: String,
                               key: RecordKey?, timestamp: Date?, messageID: String?) {
        let toolUseID = use.fields.id
        callsByAssistantUUID[assistantUUID, default: []].append(toolUseID)
        if use.fields.name == Self.sendUserFileTool {
            let input = use.fields.input
            append(.sentFile(SentFileItem(id: id(toolUseID), timestamp: timestamp, threadParent: parent,
                                          provenance: provenance(key), toolUseID: toolUseID,
                                          files: input["files"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                          caption: input["caption"]?.stringValue, delivered: nil)))
        } else {
            append(.toolCall(ToolCallItem(id: id(toolUseID), timestamp: timestamp, threadParent: parent,
                                          provenance: provenance(key), toolUseID: toolUseID, name: use.fields.name,
                                          rawInput: use.fields.input, messageID: messageID, status: .running)))
        }
    }

    // MARK: - User

    /// One `user` record or frame. Its `tool_result` blocks complete the calls they name; a record that is nothing but
    /// tool results renders no message of its own (rule 6). `origin.kind` absent or `"human"` is the operator, anything
    /// else is a peer (rule 7).
    mutating func addUser(uuid: String, key: RecordKey?, message: UserMessage, timestamp: Date?,
                          messageOrigin: MessageOrigin?, toolUseResult: JSONValue?, toolDenialKind: String?,
                          sourceToolAssistantUUID: String?) {
        closeRun()
        let content = message.fields.content
        if joinToolResults(message: message, key: key, toolUseResult: toolUseResult,
                           toolDenialKind: toolDenialKind, sourceToolAssistantUUID: sourceToolAssistantUUID) { return }
        let kind = messageOrigin?.fields.kind
        if kind == nil || kind == "human" {
            append(.userMessage(UserMessageItem(id: id(uuid), timestamp: timestamp, provenance: provenance(key),
                                                blocks: Self.blocks(of: content), text: Self.text(of: content),
                                                promptUUID: uuid)))
        } else {
            append(.peerMessage(PeerMessageItem(id: id(uuid), timestamp: timestamp, provenance: provenance(key),
                                                originKind: kind ?? "", from: messageOrigin?.fields.from,
                                                name: messageOrigin?.fields.name, blocks: Self.blocks(of: content),
                                                text: Self.text(of: content))))
        }
    }

    /// The `tool_result` half of a `user` record: every block completes the call its id names. Returns true when the
    /// record is nothing but tool results and therefore renders no message of its own (rule 6). Separated from
    /// `addUser` because a result completes a call wherever its record lies — the reducer replays off-leaf-path
    /// results through this entry point, which produces no item and so leaves rule 4 alone.
    @discardableResult
    mutating func joinToolResults(message: UserMessage, key: RecordKey?, toolUseResult: JSONValue?,
                                  toolDenialKind: String?, sourceToolAssistantUUID: String?) -> Bool {
        guard case .blocks(let blocks) = message.fields.content else { return false }
        for block in blocks {
            guard case .toolResult(let result) = block else { continue }
            if complete(result.fields.toolUseID, with: result, structured: toolUseResult,
                        denialKind: toolDenialKind, key: key) { continue }
            // The block id named no call this builder opened. `sourceToolAssistantUUID` names the assistant
            // record the result belongs to; when exactly one of that record's calls is still open, it is the one.
            if let source = sourceToolAssistantUUID, let only = soleOpenCall(of: source) {
                _ = complete(only, with: result, structured: toolUseResult, denialKind: toolDenialKind, key: key)
            }
        }
        return !blocks.isEmpty && blocks.allSatisfy { if case .toolResult = $0 { true } else { false } }
    }

    /// A result whose block id matched nothing joins by the assistant record it names, but only when that record left
    /// exactly one call open: two open calls cannot be told apart, and completing the wrong one is worse than leaving
    /// both running.
    private func soleOpenCall(of assistantUUID: String) -> String? {
        let open = (callsByAssistantUUID[assistantUUID] ?? []).filter { toolUseID in
            guard let index = indexByKey[toolUseID] else { return false }
            switch items[index] {
            case .toolCall(let call): return call.status == .running
            case .sentFile(let sent): return sent.delivered == nil
            default: return false
            }
        }
        return open.count == 1 ? open[0] : nil
    }

    @discardableResult
    private mutating func complete(_ toolUseID: String, with result: ToolResultBlock, structured: JSONValue?,
                                   denialKind: String?, key: RecordKey?) -> Bool {
        guard let index = indexByKey[toolUseID] else { return false }
        switch items[index] {
        case .toolCall(var call):
            guard call.status == .running else { return false }
            call.result = result.fields.content
            call.isError = result.fields.isError
            call.structuredResult = structured
            call.denialKind = denialKind
            call.status = denialKind != nil ? .denied : (result.fields.isError == true ? .failed : .completed)
            if let key { call.provenance.records.insert(key) }
            items[index] = .toolCall(call)
            return true
        case .sentFile(var sent):
            guard sent.delivered == nil else { return false }
            // The engine writes `is_error` only when the call failed, so an absent flag is a delivery, exactly as
            // the JS `!result.is_error` the tool's own writer applies.
            sent.delivered = !(result.fields.isError ?? false)
            if let key { sent.provenance.records.insert(key) }
            items[index] = .sentFile(sent)
            return true
        default:
            return false
        }
    }

    // MARK: - System records

    /// `compact_boundary`. A boundary that preserves neither a segment nor a message list is a hard truncation: the
    /// engine kept nothing before it, so neither does the projection, and the boundary becomes the first item (rule 8).
    mutating func addCompactBoundary(uuid: String, key: RecordKey?, timestamp: Date?,
                                     compactMetadata: JSONValue?, logicalParentUUID: String?) {
        closeRun()
        let preservedKeys = ["preserved_segment", "preservedSegment", "preserved_messages", "preservedMessages"]
        let preserved = preservedKeys.contains { compactMetadata?[$0] != nil }
        if !preserved { discardEverything() }
        append(.compactBoundary(CompactBoundaryItem(
            id: id(uuid), timestamp: timestamp, provenance: provenance(key),
            trigger: compactMetadata?["trigger"]?.stringValue, hardTruncation: !preserved,
            preTokens: (compactMetadata?["pre_tokens"] ?? compactMetadata?["preTokens"])?.intValue.map(Int.init),
            postTokens: (compactMetadata?["post_tokens"] ?? compactMetadata?["postTokens"])?.intValue.map(Int.init),
            logicalParentUUID: logicalParentUUID)))
    }

    /// `informational`, `local_command`, `turn_duration`, `stop_hook_summary` and any other `system` subtype: a row the
    /// file carries and the wire does not, so `fileOnly` (rule 8).
    mutating func addNotification(uuid: String, key: RecordKey?, timestamp: Date?,
                                  subtype: String?, text: String?, level: String?) {
        closeRun()
        append(.notification(NotificationItem(id: id(uuid), timestamp: timestamp, provenance: provenance(key),
                                              key: subtype ?? "system", text: text ?? "",
                                              level: level ?? "info", fileOnly: true)))
    }

    /// A line the decoder could not read. The channel shows a warning row rather than losing the position (parent §10).
    mutating func addOpaque(key: RecordKey?, identity: String, reason: String, value: JSONValue) {
        closeRun()
        append(.opaque(OpaqueItem(id: id(identity), provenance: provenance(key), reason: reason, value: value)))
    }

    // MARK: - Retraction and bookkeeping

    /// `supersedes` names record uuids the engine replaced. A named uuid that keys an item retracts it; a named uuid
    /// that merged into an item alongside others cannot be pulled out of it, so that item is marked instead.
    private mutating func retract(_ uuids: [String], by superseder: String) {
        var removals: [Int] = []
        for uuid in uuids {
            if let index = indexByKey[uuid] {
                removals.append(index)
            } else if let owner = itemKeyByRecordUUID[uuid], let index = indexByKey[owner],
                      case .assistantMessage(var item) = items[index] {
                item.supersededBy = superseder
                items[index] = .assistantMessage(item)
            }
        }
        guard !removals.isEmpty else { return }
        let dropped = Set(removals)
        items = items.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        reindex()
    }

    private mutating func append(_ item: TimelineItem) {
        items.append(item)
        indexByKey[item.id.key] = items.count - 1
    }

    private mutating func reindex() {
        indexByKey.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() { indexByKey[item.id.key] = index }
    }

    private mutating func discardEverything() {
        items.removeAll()
        indexByKey.removeAll()
        callsByAssistantUUID.removeAll()
        itemKeyByRecordUUID.removeAll()
        closeRun()
    }

    /// Closes the open assistant run, so the next `assistant` record starts a new item even if it repeats a `message.id`.
    mutating func closeRun() {
        runKey = nil
        runMessageID = nil
    }

    // MARK: - Content

    /// A string content becomes the one text block it stands for, built by decoding — `TextBlockFields`' memberwise
    /// initialiser is internal to `WireFrames`, and a decoded block is the same value the blocks spelling produces.
    static func blocks(of content: UserContent) -> [ContentBlock] {
        switch content {
        case .blocks(let blocks):
            return blocks
        case .text(let string):
            let value = JSONValue.object(["type": .string("text"), "text": .string(string)])
            guard let data = try? value.canonicalData(),
                  let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else { return [] }
            return [block]
        }
    }

    /// A string content is the text; blocks contribute their `text` blocks, joined by newlines.
    static func text(of content: UserContent) -> String {
        switch content {
        case .text(let string): return string
        case .blocks(let blocks):
            return blocks.compactMap { if case .text(let t) = $0 { t.fields.text } else { nil } }.joined(separator: "\n")
        }
    }
}
