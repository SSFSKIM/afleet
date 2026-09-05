import Foundation
import ClaudeWire

/// The primary reducer: a pure function from one stream's transcript records to its `StreamProjection`, and a merge
/// across a logical session's streams (spec "The record reducer"; parent §7.3 — the wire reducer is written to agree
/// with this one item for item, and check two compares them). Nothing here reads a file or a clock.
public struct RecordReducer: Sendable {
    public struct Options: Sendable, Hashable {
        public var hideMeta = true
        /// The engine's own orphan-attachment window, `var bns = 5000` at `~/claude-code-bundle/2.1.258/cli.pretty.js`
        /// line 432675, read by `Sns` (the `tengu_chain_timestamp_fallback` arm of `buildConversationChain`, `aEe`,
        /// line 432604): five seconds, in milliseconds there and in seconds here. Parity §35.13 states the same value.
        public var healWindow: TimeInterval = 5
        public var window: WindowMarker? = nil
        /// From the reader, keyed as this reduction keys its records; a mirror-delivered record has none yet.
        public var locators: [RecordKey: RecordLocator] = [:]
        /// The key for each record, positionally, when the caller has already assigned them. `StreamIngestion` has:
        /// it numbers occurrences in *application* order and publishes those keys in `Effect.applied`, in
        /// `rawRecord(for:)` and in every locator it hands out. Re-deriving them here from the array's own order
        /// would silently renumber a hash occurrence the moment `loadEarlier` prepended an older one, so one public
        /// `RecordKey` would name a different record depending on which surface was asked. Nil — the offline path,
        /// where the array *is* the file — falls back to `RecordKey.keys(for:in:)`.
        public var keys: [RecordKey]?
        public init() {}
    }

    // MARK: - Reduce

    public static func reduce(_ records: [TranscriptRecord], stream: LogicalStream, sourceFile: URL? = nil,
                              origin: Provenance.Origin = .file, options: Options = .init()) -> StreamProjection {
        let keys = options.keys ?? RecordKey.keys(for: records, in: stream)
        precondition(keys.count == records.count, "RecordReducer.Options.keys must be one key per record")
        let clock = TimestampParser()

        // 1. Partition. Conversation records go to the tree; the rest fold, hide or warn where they stand.
        var conversation: [TranscriptRecord] = []
        var keyByUUID: [String: RecordKey] = [:]
        var session = SessionState()
        var clearedToEmpty = false
        var hidden: [HiddenRecord] = []
        var warnings: [ReadWarning] = []
        var metadata: AgentMetadataRecord?
        var opaque: [TimelineItem] = []
        var builderForOpaque = ItemBuilder(stream: stream, sourceFile: sourceFile, origin: origin)

        func hide(_ record: TranscriptRecord, _ key: RecordKey, _ reason: HiddenRecord.Reason) {
            hidden.append(HiddenRecord(key: key, kind: record.kind, timestamp: clock.parse(timestampString(of: record)),
                                       reason: reason, locator: options.locators[key]))
        }

        for (record, key) in zip(records, keys) {
            if record.isConversation {
                conversation.append(record)
                if let uuid = record.uuid { keyByUUID[uuid] = key }
                if let reason = hiddenReason(record, hideMeta: options.hideMeta) { hide(record, key, reason) }
                continue
            }
            switch record {
            case .sessionState(let state, _):
                hide(record, key, .sessionState)
                fold(state, into: &session, clearedToEmpty: &clearedToEmpty)
            case .agentMetadata(let record, _):
                metadata = record
            case .unknown(let kind, _):
                hide(record, key, .unknownKind)
                warnings.append(ReadWarning(kind: .unknownKind, stream: stream.name, recordKind: kind))
            case .undecodable(_, let byteOffset, let reason):
                warnings.append(ReadWarning(kind: .undecodable, stream: stream.name, byteOffset: byteOffset))
                builderForOpaque.addOpaque(key: key, identity: record.contentHash ?? "undecodable",
                                           reason: "undecodable", value: .string(reason))
            default:
                break   // unreachable: every remaining case has a uuid and is a conversation kind
            }
        }
        opaque = builderForOpaque.items

        // 2. Leaf. Only the *last* `last-prompt` in file order decides, which is why it is read here and not folded
        // record by record: `control-shapes` writes a cleared prompt (`leafUuid: null, explicit: true`) and then a
        // further prompt carrying no `leafUuid` at all, and the file's leaf is the later record's silence, not the
        // earlier record's clear. `WindowedTranscript.namedLeaf` (Task 2) reads the same one record.
        if let last = records.reversed().first(where: { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt"
        }), case .sessionState(let state, _) = last, let value = state.leafUuid {
            session.leaf = value
            clearedToEmpty = (value == nil && state.explicit)
        }
        session.clearedToEmpty = clearedToEmpty

        // 3. Tree and healing.
        let tree = ConversationTree(conversation: conversation, healWindow: options.healWindow,
                                    windowRootAllowed: options.window?.earlierAvailable == true, clock: clock)
        for uuid in tree.healed {
            warnings.append(ReadWarning(kind: .orphanHealed, stream: stream.name,
                                        recordKind: tree.byUUID[uuid]?.kind))
        }
        for uuid in tree.unhealed {
            warnings.append(ReadWarning(kind: .orphanUnhealed, stream: stream.name,
                                        recordKind: tree.byUUID[uuid]?.kind))
        }

        // 4–8. Items from the chain, branches from the rest. Rule 4's unit of production for an assistant message is
        // the `message.id` *group*, not the single record: a group is produced when any one of its records lies on the
        // chain, and `tree.regrouped(chain:)` splices the rest of it — plus the `tool_result` users those records
        // parent — back onto the rendered line, exactly as the engine's `kns` does. A group with no record on the
        // chain is not produced and stays in `branches`.
        let chain = clearedToEmpty ? [] : tree.chain(to: session.leaf)
        if !clearedToEmpty, session.leaf == nil { session.leaf = chain.last }
        let rendered = clearedToEmpty ? [] : tree.regrouped(chain: chain)
        let branches = tree.branches(excluding: Set(rendered))
        var builder = ItemBuilder(stream: stream, sourceFile: sourceFile, origin: origin)
        for uuid in rendered {
            guard let record = tree.byUUID[uuid] else { continue }
            let key = keyByUUID[uuid]
            switch record {
            case .attachment, .progress:
                continue                                        // hidden above; renders nothing and breaks no run
            case .user(let user):
                if options.hideMeta, user.fields.isMeta == true { continue }
                builder.addUser(uuid: uuid, key: key, message: user.fields.message,
                                timestamp: clock.parse(user.fields.timestamp), messageOrigin: user.fields.origin,
                                toolUseResult: user.fields.toolUseResult, toolDenialKind: user.fields.toolDenialKind,
                                sourceToolAssistantUUID: user.fields.sourceToolAssistantUUID)
            case .assistant(let assistant):
                builder.addAssistant(uuid: uuid, key: key, message: assistant.fields.message,
                                     timestamp: clock.parse(assistant.fields.timestamp),
                                     supersedes: assistant.additional["supersedes"]?.arrayValue?
                                        .compactMap(\.stringValue) ?? [])
            case .system(let system):
                let timestamp = clock.parse(system.fields.timestamp)
                if system.fields.subtype == "compact_boundary" {
                    builder.addCompactBoundary(uuid: uuid, key: key, timestamp: timestamp,
                                               compactMetadata: system.fields.compactMetadata,
                                               logicalParentUUID: system.fields.logicalParentUuid)
                } else {
                    builder.addNotification(uuid: uuid, key: key, timestamp: timestamp, subtype: system.fields.subtype,
                                            text: system.fields.content, level: system.fields.level)
                }
            default:
                continue
            }
        }

        // Rule 4 governs which records produce *items*, and a `tool_result` block produces none: it completes an item
        // another record already produced. Rule 3 states the join with no chain qualification — "the `user` record
        // whose `tool_result` block names that id completes it" — and the engine agrees, re-attaching off-chain results
        // in `kns` (2.1.258 cli.pretty.js:432695, called from `buildConversationChain` right after the leaf walk). So a
        // result completes its call by `tool_use_id` wherever the record carrying it lies. Only the id join runs here:
        // the `sourceToolAssistantUUID` fallback resolves an id the engine rewrote on the chain, and guessing across a
        // branch could complete the wrong call.
        let onChain = Set(rendered)
        for uuid in tree.order where !onChain.contains(uuid) {
            guard case .user(let user) = tree.byUUID[uuid] else { continue }
            builder.joinToolResults(message: user.fields.message, key: keyByUUID[uuid],
                                    toolUseResult: user.fields.toolUseResult,
                                    toolDenialKind: user.fields.toolDenialKind,
                                    sourceToolAssistantUUID: nil)
        }

        return StreamProjection(stream: stream, items: builder.items + opaque, hidden: hidden, branches: branches,
                                session: session, warnings: warnings, window: options.window, metadata: metadata)
    }

    // MARK: - Merge

    /// The main stream's items in chain order, with each agent stream's items spliced in under the call that spawned
    /// it (rule 9). The splice recurses, so a depth-2 agent lands under the depth-1 agent's own call.
    public static func merge(_ streams: [StreamProjection], main: LogicalStream) -> DurableProjection {
        guard let mainProjection = streams.first(where: { $0.stream == main }) else { return .empty }
        var agentByToolUse: [String: StreamProjection] = [:]
        for projection in streams where projection.stream != main {
            if let toolUse = projection.metadata?.toolUseId { agentByToolUse[toolUse] = projection }
        }
        var attached: Set<String> = []

        func expand(_ items: [TimelineItem]) -> [TimelineItem] {
            var out: [TimelineItem] = []
            for item in items {
                out.append(item)
                guard let toolUse = spawningToolUseID(of: item), let agent = agentByToolUse[toolUse],
                      !attached.contains(toolUse) else { continue }
                attached.insert(toolUse)
                let run = taskRun(for: agent, spawnedBy: item, toolUseID: toolUse)
                out.append(.taskRun(run))
                out.append(contentsOf: expand(stamp(agent.items, under: run)))
            }
            return out
        }

        var items = expand(mainProjection.items)
        // An agent stream whose spawning call is nowhere in the merged line is still the session's: it is appended
        // rather than dropped, so a truncated window never loses a subagent's transcript.
        for projection in streams where projection.stream != main {
            guard let toolUse = projection.metadata?.toolUseId, !attached.contains(toolUse) else { continue }
            attached.insert(toolUse)
            let run = taskRun(for: projection, spawnedBy: nil, toolUseID: toolUse)
            items.append(.taskRun(run))
            items.append(contentsOf: expand(stamp(projection.items, under: run)))
        }

        let others = streams.filter { $0.stream != main }
        return DurableProjection(items: items,
                                 hidden: mainProjection.hidden + others.flatMap(\.hidden),
                                 branches: mainProjection.branches + others.flatMap(\.branches),
                                 session: mainProjection.session,
                                 warnings: mainProjection.warnings + others.flatMap(\.warnings),
                                 window: mainProjection.window,
                                 streams: streams.map(\.stream))
    }

    private static func spawningToolUseID(of item: TimelineItem) -> String? {
        switch item {
        case .toolCall(let call): return call.toolUseID
        case .taskRun(let run): return run.toolUseID
        default: return nil
        }
    }

    /// The run row for an agent stream, synthesised from its `.meta.json` sidecar. `synthesised: false`: the metadata
    /// is a recorded artefact, not the host's guess — only the *row* is assembled here.
    private static func taskRun(for agent: StreamProjection, spawnedBy call: TimelineItem?, toolUseID: String) -> TaskRunItem {
        let taskID: String
        if case .agent(let id) = agent.stream.name { taskID = id } else { taskID = toolUseID }
        let status: TaskStatus
        if case .toolCall(let call) = call {
            switch call.status {
            case .running: status = .running
            case .completed: status = .completed
            case .failed: status = .failed
            case .denied: status = .stopped
            }
        } else {
            status = .running
        }
        // The spawning call, not the agent's own first item: the run belongs where the call is in the main stream's
        // timestamp order (parent §7.3), and both halves of the invariant hold that call while only the file half
        // holds the agent's opening prompt, which `fileOnlyRecordKinds` now excludes.
        return TaskRunItem(id: ItemID(stream: agent.stream, key: taskID),
                           timestamp: call?.timestamp ?? agent.items.first?.timestamp,
                           threadParent: call?.id,
                           provenance: Provenance(stream: agent.stream, agentID: taskID,
                                                  sourceFile: agent.items.first?.provenance.sourceFile,
                                                  origin: .file),
                           taskID: taskID, kind: .localAgent,
                           description: agent.metadata?.fields.description ?? "", status: status,
                           toolUseID: toolUseID, agentType: agent.metadata?.fields.agentType,
                           depth: agent.metadata?.fields.spawnDepth, synthesised: false)
    }

    /// The agent's own top-level items hang off its run row; every item of the stream carries the agent id.
    private static func stamp(_ items: [TimelineItem], under run: TaskRunItem) -> [TimelineItem] {
        items.map { item in
            var item = item
            withProvenance(&item) { $0.agentID = run.taskID }
            if item.threadParent == nil { withThreadParent(&item) { $0 = run.id } }
            return item
        }
    }

    // MARK: - Session state

    /// The engine's fold policy, by `SessionStateVocabulary.kinds`. `.accumulate` kinds are kept in `hidden` only;
    /// `.boundaryCleared` behaves as last-wins here, because the clearing is the engine's compaction bookkeeping and
    /// not this reducer's (spec rule 1).
    private static func fold(_ state: SessionStateRecord, into session: inout SessionState, clearedToEmpty: inout Bool) {
        switch state.fields.type {
        case "last-prompt":
            // The leaf reads the last such record alone, above; folding it record by record would keep a stale clear.
            // `rewound` is the exception, and the corpus is why: `control-shapes` records the rewind on the *third*
            // of its four `last-prompt` records and the fourth is silent about it, so last-wins would lose the fact
            // the engine wrote. A rewind is something that happened, not a current state, so it latches.
            if state.rewound { session.rewound = true }
        case "continued-in":
            // The destination, never this record's own `sessionId`, which is the source (2.1.258 line 246351).
            if let destination = state.continuedInSessionId { session.continuedIn = destination }
        case "summary": if let value = state.summary { session.summary = value }
        case "custom-title": if let value = state.customTitle { session.customTitle = value }
        case "ai-title": if let value = state.aiTitle { session.aiTitle = value }
        case "agent-name": if let value = state.agentName { session.agentName = value }
        case "relocated": if let value = state.relocatedCwd { session.relocatedCwd = value }
        case "mode": if let value = state.mode { session.mode = value }
        case "tag": if let value = state.tag { session.tag = value }
        case "atis-latch": if let value = state.atis { session.atisLatch = value }
        case "cost-state": session.costState = state.costState
        default: break
        }
    }

    // MARK: - Record shape

    static func hiddenReason(_ record: TranscriptRecord, hideMeta: Bool) -> HiddenRecord.Reason? {
        switch record {
        case .attachment: return .attachment
        case .progress: return .progress
        case .user(let user): return (hideMeta && user.fields.isMeta == true) ? .isMeta : nil
        default: return nil
        }
    }

    static func timestampString(of record: TranscriptRecord) -> String? {
        switch record {
        case .user(let r): return r.fields.timestamp
        case .assistant(let r): return r.fields.timestamp
        case .attachment(let r): return r.fields.timestamp
        case .system(let r): return r.fields.timestamp
        case .progress(let r): return r.fields.timestamp
        case .sessionState(let r, _): return r.additional["timestamp"]?.stringValue
        default: return nil
        }
    }

    /// Compared as an optional: the engine's own `Sns` uses `!==`, so a record that declares nothing is not the same
    /// side of the tree as one that declares `false`.
    static func isSidechain(of record: TranscriptRecord) -> Bool? {
        switch record {
        case .user(let r): return r.fields.isSidechain
        case .assistant(let r): return r.fields.isSidechain
        case .attachment(let r): return r.fields.isSidechain
        case .system(let r): return r.fields.isSidechain
        default: return nil
        }
    }

    // MARK: - Item field writers

    private static func withProvenance(_ item: inout TimelineItem, _ body: (inout Provenance) -> Void) {
        switch item {
        case .userMessage(var i): body(&i.provenance); item = .userMessage(i)
        case .assistantMessage(var i): body(&i.provenance); item = .assistantMessage(i)
        case .toolCall(var i): body(&i.provenance); item = .toolCall(i)
        case .cluster(var i): body(&i.provenance); item = .cluster(i)
        case .taskRun(var i): body(&i.provenance); item = .taskRun(i)
        case .decision(var i): body(&i.provenance); item = .decision(i)
        case .hookRun(var i): body(&i.provenance); item = .hookRun(i)
        case .notification(var i): body(&i.provenance); item = .notification(i)
        case .peerMessage(var i): body(&i.provenance); item = .peerMessage(i)
        case .compactBoundary(var i): body(&i.provenance); item = .compactBoundary(i)
        case .sentFile(var i): body(&i.provenance); item = .sentFile(i)
        case .turnSummary(var i): body(&i.provenance); item = .turnSummary(i)
        case .opaque(var i): body(&i.provenance); item = .opaque(i)
        }
    }

    private static func withThreadParent(_ item: inout TimelineItem, _ body: (inout ItemID?) -> Void) {
        switch item {
        case .userMessage(var i): body(&i.threadParent); item = .userMessage(i)
        case .assistantMessage(var i): body(&i.threadParent); item = .assistantMessage(i)
        case .toolCall(var i): body(&i.threadParent); item = .toolCall(i)
        case .cluster(var i): body(&i.threadParent); item = .cluster(i)
        case .taskRun(var i): body(&i.threadParent); item = .taskRun(i)
        case .decision(var i): body(&i.threadParent); item = .decision(i)
        case .hookRun(var i): body(&i.threadParent); item = .hookRun(i)
        case .notification(var i): body(&i.threadParent); item = .notification(i)
        case .peerMessage(var i): body(&i.threadParent); item = .peerMessage(i)
        case .compactBoundary(var i): body(&i.threadParent); item = .compactBoundary(i)
        case .sentFile(var i): body(&i.threadParent); item = .sentFile(i)
        case .turnSummary(var i): body(&i.threadParent); item = .turnSummary(i)
        case .opaque(var i): body(&i.threadParent); item = .opaque(i)
        }
    }
}

/// The conversation as the engine keeps it: records by uuid, children by `parentUuid`, the leaf, the chain.
/// Task 8's rewind handling walks the same tree.
struct ConversationTree {
    var byUUID: [String: TranscriptRecord] = [:]
    var children: [String: [String]] = [:]
    /// File order of the conversation uuids.
    var order: [String] = []
    var roots: [String] = []
    var healed: [String] = []
    var unhealed: [String] = []
    /// Records whose parent lies before an open window: roots by construction, neither healed nor warned about.
    var windowRoots: [String] = []

    private var parentOf: [String: String] = [:]
    private var position: [String: Int] = [:]

    init(conversation: [TranscriptRecord], healWindow: TimeInterval) {
        self.init(conversation: conversation, healWindow: healWindow, windowRootAllowed: false, clock: TimestampParser())
    }

    /// `windowRootAllowed` is `options.window?.earlierAvailable == true`. Under an open window the *earliest* record
    /// whose parent is missing is a window root: Task 2's closure rule put the window's start at a turn boundary, so
    /// that parent lies before the window rather than being lost. Every later missing parent is a real orphan.
    init(conversation: [TranscriptRecord], healWindow: TimeInterval, windowRootAllowed: Bool, clock: TimestampParser) {
        var stamps: [String: Date] = [:]
        var sidechain: [String: Bool?] = [:]
        for record in conversation {
            guard let uuid = record.uuid, byUUID[uuid] == nil else { continue }
            byUUID[uuid] = record
            position[uuid] = order.count
            order.append(uuid)
            if let date = clock.parse(RecordReducer.timestampString(of: record)) { stamps[uuid] = date }
            sidechain[uuid] = RecordReducer.isSidechain(of: record)
        }
        var windowRootRemaining = windowRootAllowed
        for (index, uuid) in order.enumerated() {
            guard let record = byUUID[uuid] else { continue }
            guard let declared = WindowedTranscript.parentUUID(of: record) else { roots.append(uuid); continue }
            if byUUID[declared] != nil { attach(uuid, to: declared); continue }
            if windowRootRemaining {
                windowRootRemaining = false
                windowRoots.append(uuid)
                roots.append(uuid)
                continue
            }
            if let host = Self.host(for: uuid, at: index, order: order, stamps: stamps,
                                    sidechain: sidechain, window: healWindow) {
                healed.append(uuid)
                attach(uuid, to: host)
            } else {
                unhealed.append(uuid)
                roots.append(uuid)
            }
        }
    }

    private mutating func attach(_ uuid: String, to parent: String) {
        parentOf[uuid] = parent
        children[parent, default: []].append(uuid)
    }

    /// The nearest earlier record in file order with the same `isSidechain` whose timestamp is at most `window`
    /// before this one. The engine's `Sns` (2.1.258 line 432676) scans the whole map and keeps the *smallest*
    /// non-negative delta, first one winning a tie; file order and time order agree on every recorded transcript,
    /// and the two rules can only part when two records share a timestamp.
    private static func host(for uuid: String, at index: Int, order: [String], stamps: [String: Date],
                             sidechain: [String: Bool?], window: TimeInterval) -> String? {
        guard index > 0, let stamp = stamps[uuid] else { return nil }
        let side = sidechain[uuid] ?? nil
        for candidate in order[0..<index].reversed() {
            guard (sidechain[candidate] ?? nil) == side, let other = stamps[candidate] else { continue }
            let delta = stamp.timeIntervalSince(other)
            if delta >= 0, delta <= window { return candidate }
        }
        return nil
    }

    /// Root-to-leaf chain for a leaf; the leaf is `last-prompt.leafUuid`, else the last conversation record in file
    /// order. The walk is bounded by a visited set: a `parentUuid` cycle yields the partial chain, as the engine's
    /// own walk does, rather than hanging.
    func chain(to leaf: String?) -> [String] {
        let target: String?
        if let leaf, byUUID[leaf] != nil { target = leaf } else { target = order.last }
        guard let target else { return [] }
        var walk: [String] = []
        var seen: Set<String> = []
        var cursor: String? = target
        while let uuid = cursor, !seen.contains(uuid) {
            seen.insert(uuid)
            walk.append(uuid)
            cursor = parentOf[uuid]
        }
        return walk.reversed()
    }

    /// The chain with each rendered `message.id` group made whole again — the engine's `kns`
    /// (`~/claude-code-bundle/2.1.258/cli.pretty.js` line 432695, called from `buildConversationChain`/`aEe` at line
    /// 432623 immediately after the leaf walk, and reported as `tengu_chain_parallel_tr_recovered` at line 432743).
    ///
    /// One API message can be written as several `assistant` records, and when it opened parallel tool calls only one
    /// of them is on the `parentUuid` chain: the others hang off the first as siblings, together with the `user`
    /// records answering them. The engine puts them back, and so must this reducer — the wire side has no
    /// `parentUuid` at all and groups by `message.id` alone, so anything else would make the two disagree on every
    /// parallel tool call (parent §7.3, check two).
    ///
    /// For each `message.id` with **at least one** record on the chain, the group's off-chain records and the
    /// off-chain `tool_result` users they parent are spliced in after the *last* on-chain record of that group, so the
    /// group's records stay consecutive in the projection and `ItemBuilder.addAssistant` folds them into one item with
    /// every record's uuid and blocks in file order. A `message.id` with **no** record on the chain is never
    /// considered, so it produces nothing and its records stay in `branches`.
    ///
    /// Two deliberate divergences, both unobservable on the corpus: the spliced records are ordered by file order
    /// where the bundle sorts them by timestamp (the same reasoning as `host(for:...)` — file order and time order
    /// agree on every recording), and the parent read here is the declared `parentUuid`, as the bundle reads it,
    /// rather than a healed attachment.
    func regrouped(chain: [String]) -> [String] {
        var messageIDOf: [String: String] = [:]
        var members: [String: [String]] = [:]
        var resultsByParent: [String: [String]] = [:]
        for uuid in order {
            guard let record = byUUID[uuid] else { continue }
            switch record {
            case .assistant(let assistant):
                guard let messageID = assistant.fields.message.fields.id else { continue }
                messageIDOf[uuid] = messageID
                members[messageID, default: []].append(uuid)
            case .user(let user):
                guard let parent = WindowedTranscript.parentUUID(of: record),
                      case .blocks(let blocks) = user.fields.message.fields.content,
                      blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) else { continue }
                resultsByParent[parent, default: []].append(uuid)
            default:
                continue
            }
        }
        // The anchor is the last on-chain record of the group, as the bundle's `d` map is (it overwrites per id).
        var anchorOf: [String: String] = [:]
        for uuid in chain { if let messageID = messageIDOf[uuid] { anchorOf[messageID] = uuid } }

        var claimed = Set(chain)
        var handled: Set<String> = []
        var spliced: [String: [String]] = [:]
        for uuid in chain {
            guard let messageID = messageIDOf[uuid], !handled.contains(messageID) else { continue }
            handled.insert(messageID)
            let group = members[messageID] ?? [uuid]
            var pulled = group.filter { !claimed.contains($0) }
            pulled.append(contentsOf: group.flatMap { resultsByParent[$0] ?? [] }.filter { !claimed.contains($0) })
            guard !pulled.isEmpty else { continue }
            claimed.formUnion(pulled)
            spliced[anchorOf[messageID] ?? uuid, default: []].append(contentsOf: pulled)
        }
        guard !spliced.isEmpty else { return chain }

        var out: [String] = []
        for uuid in chain {
            out.append(uuid)
            if let extra = spliced[uuid] { out.append(contentsOf: extra) }
        }
        return out
    }

    /// Every off-chain subtree, one `Branch` each: the head is the record whose parent is on the chain (or nowhere),
    /// the tail is the subtree's last record in file order, and the count is the subtree's size.
    func branches(excluding chain: Set<String>) -> [Branch] {
        let off = order.filter { !chain.contains($0) }
        guard !off.isEmpty else { return [] }
        let offSet = Set(off)
        var out: [Branch] = []
        for head in off {
            if let parent = parentOf[head], offSet.contains(parent) { continue }
            var subtree: [String] = []
            var queue = [head]
            var seen: Set<String> = [head]
            while let uuid = queue.first {
                queue.removeFirst()
                subtree.append(uuid)
                for child in children[uuid] ?? [] where offSet.contains(child) && !seen.contains(child) {
                    seen.insert(child)
                    queue.append(child)
                }
            }
            let tail = subtree.max { (position[$0] ?? 0) < (position[$1] ?? 0) } ?? head
            out.append(Branch(head: head, tail: tail, count: subtree.count))
        }
        return out
    }
}
