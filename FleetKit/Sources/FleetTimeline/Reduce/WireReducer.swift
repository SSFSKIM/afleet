import Foundation
import ClaudeWire

/// The live half of the projection: a fold of `WireEvent`s (and the host signals no frame states) into the same
/// `DurableProjection` the record reducer produces, plus the `Overlay` of things only a running process has.
///
/// The durable half is built by feeding `ItemBuilder` — the *same* value the record reducer feeds — so the block
/// rules (merge by `message.id`, the `tool_use_id` join, `supersedes`, `mcp__afleet__send_user_file`) exist once and
/// the two reducers cannot drift (parent §7.3; check two compares them item for item). Nothing here re-derives them.
///
/// Two consequences of the wire's shape, both handled by feeding rather than by forking:
/// - A frame carries no `parentUuid`, so an assistant message is a `message.id` group by construction: consecutive
///   `assistant` frames of one message fold into one item because the builder's run stays open across the
///   `stream_event`s and task frames between them, none of which renders.
/// - A `tool_result` completes its call by `tool_use_id` wherever it arrives, which is what `ItemBuilder` already does.
public struct WireReducer: Sendable {
    /// The session's main stream. Agent streams are derived from it and the run tree's task ids.
    public let stream: LogicalStream

    public private(set) var durable: DurableProjection
    public private(set) var overlay: Overlay
    public private(set) var preview: StreamingPreview?
    public private(set) var registry: RegistryMirror
    public private(set) var agents: AgentRunTree
    /// Prompt uuids the host sent that no `result` has closed yet, oldest first.
    public private(set) var outstandingPrompts: [String]

    /// The projection the file already held when the channel opened — what `StreamIngestion.open` returned. Wire
    /// items continue it; a rewind may cut into it.
    private var seedItems: [TimelineItem]
    /// Everything the seed contributes besides its items. `var`, not `let`: `conversation_reset` clears the whole
    /// durable half, and the seed's hidden records, branches, warnings and window are part of it.
    private var seed: DurableProjection
    private var main: ItemBuilder
    private var agentBuilders: [String: ItemBuilder]
    private var agentOrder: [String]
    private var hiddenRecords: [HiddenRecord]
    private var session: SessionState
    private var epoch: ProcessEpoch
    private var slug: String
    /// `hostToolInvoked` arrivals with no `SentFileItem` open yet, held for the next row the builder opens.
    private var pendingDeliveries: Int

    public init(stream: LogicalStream, slug: String, seed: DurableProjection = .empty) {
        self.stream = stream
        self.slug = slug
        self.seed = seed
        self.seedItems = seed.items
        self.durable = seed
        self.overlay = .empty
        self.preview = nil
        self.registry = RegistryMirror()
        self.agents = AgentRunTree(configHome: stream.configHome, sessionID: stream.sessionID, slug: slug)
        self.outstandingPrompts = []
        self.main = ItemBuilder(stream: stream, sourceFile: nil, origin: .wire)
        self.agentBuilders = [:]
        self.agentOrder = []
        self.hiddenRecords = []
        self.session = seed.session
        self.epoch = .first
        self.pendingDeliveries = 0
        rebuild()
    }

    // MARK: - Apply

    public mutating func apply(_ event: WireEvent, at now: Date = Date()) -> [TimelineChange] {
        let before = Snapshot(self)
        route(event, at: now)
        rebuild()
        return before.difference(to: Snapshot(self))
    }

    public mutating func apply(_ signal: HostSignal, at now: Date = Date()) -> [TimelineChange] {
        let before = Snapshot(self)
        switch signal {
        case .promptSent(let uuid, _):
            outstandingPrompts.append(uuid)

        case .decisionAnswered(let id, let outcome):
            setDecision(id) { $0.state = .answered(outcome: outcome.label) }

        case .rewound(let toUUID):
            rewind(to: toUUID)

        case .processReplaced(let replacement):
            epoch = replacement
            overlay = .empty
            preview = nil
            outstandingPrompts = []

        case .relocated(let mainPath):
            if let (resolved, kind) = TranscriptPath.resolve(mainPath, under: stream.configHome),
               resolved.sessionID == stream.sessionID, case .mainTranscript(let moved) = kind {
                slug = moved
                agents.relocate(slug: moved)
            } else {
                overlay.banners.append(Banner(kind: .compatibility,
                                              text: "relocation path does not name this session's main transcript",
                                              epoch: epoch, at: now))
            }
        }
        rebuild()
        return before.difference(to: Snapshot(self))
    }

    // MARK: - Events

    private mutating func route(_ event: WireEvent, at now: Date) {
        switch event {
        case .handshakeCompleted, .sessionIdentityResolved, .stderr:
            return                                            // stderr is C4's

        case .frame(let frame, let frameEpoch):
            epoch = frameEpoch
            route(frame, at: now)

        case .request(let request):
            open(request, state: .pending, at: now)

        case .requestCancelled(let id, _):
            setDecision(id) { $0.state = .cancelled }

        case .policyAnswered(let request, let error):
            // The policy answers such a request itself and never surfaces it as `.request`, so the item usually has
            // to be created here — in the answered state, with `.other` for a payload the host does not model.
            if overlay.decisions[request.id] != nil {
                setDecision(request.id) { $0.state = .policyAnswered(error: error) }
            } else {
                open(request, state: .policyAnswered(error: error), at: now, allowingUnmodelled: true)
            }

        case .unansweredDialog(let request):
            open(request, state: .inert, at: now)

        case .hostToolInvoked:
            if !main.deliverOldestSentFile() { pendingDeliveries += 1 }

        case .exited:
            overlay.stale = true
            preview = nil
            for (id, decision) in overlay.decisions where decision.state == .pending {
                overlay.decisions[id]?.state = .inert
            }
        }
    }

    // MARK: - Frames

    private mutating func route(_ frame: Frame, at now: Date) {
        let clock = TimestampParser()
        switch frame {
        case .assistant(let f):
            let node = f.parentToolUseID.flatMap { agents.node(withToolUse: $0) }
            let uses = Self.toolUseIDs(of: f.message.fields.content)
            let stamp = clock.parse(f.timestamp) ?? now
            withBuilder(agent: node?.id) {
                $0.addAssistant(uuid: f.uuid, key: nil, message: f.message, timestamp: stamp,
                                supersedes: f.supersedes ?? [])
            }
            if let node, let model = f.message.fields.model { agents.observe(assistantModel: model, agentID: node.id) }
            agents.observe(parentToolUseID: f.parentToolUseID, carryingToolUseIDs: uses)
            // The engine emits one `assistant` frame per finished content block, interleaved with the deltas of the
            // block after it, so the preview is superseded either when it names this message or when it never saw a
            // `message_start` and so belongs to whatever message is in flight — which this frame proves is this one.
            if let open = preview, open.messageID == nil || open.messageID == f.message.fields.id { preview = nil }
            drainDeliveries()

        case .user(let f):
            let node = f.parentToolUseID.flatMap { agents.node(withToolUse: $0) }
            let stamp = clock.parse(f.timestamp) ?? now
            let uuid = f.uuid ?? Self.contentIdentity(of: f.message)
            if f.isSynthetic == true {
                let target = node.map { self.agentStream($0.id) } ?? stream
                hiddenRecords.append(HiddenRecord(key: RecordKey(stream: target, identity: .uuid(uuid)),
                                                  kind: "user", timestamp: stamp, reason: .isSynthetic, locator: nil))
                return
            }
            withBuilder(agent: node?.id) {
                $0.addUser(uuid: uuid, key: nil, message: f.message, timestamp: stamp,
                           messageOrigin: f.origin, toolUseResult: f.toolUseResult,
                           toolDenialKind: Self.denialKind(of: f), sourceToolAssistantUUID: nil,
                           isReplay: f.isReplay == true)
            }
            agents.observe(parentToolUseID: f.parentToolUseID,
                           carryingToolUseIDs: Self.toolUseIDs(of: f.message.fields.content))
            // The Bash tool's own sentence binds a background task's output file before any task frame names it.
            for (toolUseID, text) in Self.toolResultTexts(of: f.message.fields.content) {
                registry.observe(bashToolResult: text, toolUseID: toolUseID, at: now, epoch: epoch)
            }

        case .streamEvent(let f):
            if preview == nil {
                guard StreamingPreview.opens(f.event) else { return }
                preview = StreamingPreview()
            }
            preview?.apply(event: f.event)

        case .toolProgress(let f):
            registry.apply(toolProgress: f, at: now)
            agents.apply(toolProgress: f, at: now)

        case .result(let f):
            let attribution: TurnAttribution
            if f.numTurns == 0 {
                attribution = .relocation
            } else if !outstandingPrompts.isEmpty {
                attribution = .prompted(uuid: outstandingPrompts.removeFirst())
            } else {
                attribution = .unprompted
            }
            overlay.turns.append(TurnSummaryItem(
                id: ItemID(stream: stream, key: f.uuid), timestamp: now, provenance: provenance(),
                subtype: f.subtype, durationMs: f.durationMs, costUSD: f.totalCostUSD, numTurns: f.numTurns,
                stopReason: f.stopReason, usage: f.usage, permissionDenials: f.permissionDenials,
                attribution: attribution))

        case .system(let system):
            route(system, at: now, clock: clock)

        case .toolUseSummary(let f):
            guard let first = f.precedingToolUseIDs.first else { return }
            let id = ItemID(stream: stream, key: first)
            overlay.clusters[id] = ToolClusterItem(id: id, timestamp: now, provenance: provenance(),
                                                   toolUseIDs: f.precedingToolUseIDs, label: f.summary)

        case .commandLifecycle(let f):
            overlay.queue.apply(state: f.state, commandUUID: f.commandUUID)

        case .rateLimitEvent(let f):
            banner(.rateLimit, text: f.rateLimitInfo["status"]?.stringValue ?? "rate_limit", at: now)

        case .authStatus(let f):
            banner(.auth, text: f.error ?? (f.isAuthenticating ? "authenticating" : "authenticated"), at: now)

        case .conversationReset:
            clearConversation()

        case .promptSuggestion, .keepAlive, .controlRequest, .controlResponse, .controlCancelRequest:
            return

        case .transcriptMirror:
            return                                            // Task 10's: the mirror feeds the record reducer

        case .opaque(let o):
            main.addOpaque(key: nil, identity: RecordDecoder.canonicalHash(of: o.value),
                           reason: Self.describe(o.reason), value: o.value)
        }
    }

    private mutating func route(_ system: SystemFrame, at now: Date, clock: TimestampParser) {
        switch system {
        case .initialize:
            main.closeRun()                                   // a turn boundary, and no item

        case .taskStarted(let f):
            let touched = registry.apply(system, at: now, epoch: epoch)
            agents.apply(taskStarted: f, at: now)
            refresh(touched)

        case .taskUpdated(let f):
            let touched = registry.apply(system, at: now, epoch: epoch)
            agents.apply(taskUpdated: f, at: now)
            refresh(touched)

        case .taskProgress(let f):
            let touched = registry.apply(system, at: now, epoch: epoch)
            agents.apply(taskProgress: f, at: now)
            refresh(touched)

        case .taskNotification(let f):
            let touched = registry.apply(system, at: now, epoch: epoch)
            let isAgent = agents.node(f.taskID) != nil
            agents.apply(taskNotification: f, at: now)
            // An agent's completion updates the run row the merge already produces; a shell's has no row anywhere,
            // so the host makes one and says it did.
            if !isAgent, let entry = registry.entries[f.taskID] {
                main.addTaskRun(TaskRunItem(
                    id: ItemID(stream: stream, key: f.taskID), timestamp: now,
                    threadParent: entry.toolUseID.map { ItemID(stream: stream, key: $0) },
                    provenance: Provenance(stream: stream, epoch: epoch, origin: .synthesised),
                    taskID: f.taskID, kind: entry.kind, description: entry.description, status: entry.status,
                    summary: entry.summary, outputFile: entry.outputFile, usage: entry.usage,
                    toolUseID: entry.toolUseID, synthesised: true))
            }
            refresh(touched)

        case .backgroundTasksChanged:
            refresh(registry.apply(system, at: now, epoch: epoch))

        case .hookStarted(let f):
            overlay.hooks[f.hookID] = HookRunItem(id: ItemID(stream: stream, key: f.hookID), timestamp: now,
                                                  provenance: provenance(), hookID: f.hookID,
                                                  hookName: f.hookName, event: f.hookEvent)

        case .hookProgress(let f):
            if overlay.hooks[f.hookID] == nil {
                overlay.hooks[f.hookID] = HookRunItem(id: ItemID(stream: stream, key: f.hookID), timestamp: now,
                                                      provenance: provenance(), hookID: f.hookID,
                                                      hookName: f.hookName, event: f.hookEvent)
            }

        case .hookResponse(let f):
            var run = overlay.hooks[f.hookID] ?? HookRunItem(id: ItemID(stream: stream, key: f.hookID),
                                                             timestamp: now, provenance: provenance(),
                                                             hookID: f.hookID, hookName: f.hookName,
                                                             event: f.hookEvent)
            run.outcome = f.outcome
            run.exitCode = f.exitCode
            overlay.hooks[f.hookID] = run

        case .notification(let f):
            overlay.notifications.append(NotificationItem(id: ItemID(stream: stream, key: f.uuid), timestamp: now,
                                                          provenance: provenance(), key: f.key, text: f.text,
                                                          level: f.priority, fileOnly: false))

        case .localCommandOutput(let f):
            overlay.notifications.append(NotificationItem(id: ItemID(stream: stream, key: f.uuid), timestamp: now,
                                                          provenance: provenance(), key: "local_command_output",
                                                          text: f.content, level: "info", fileOnly: false))

        case .permissionDenied(let f):
            let agent = f.agentID.flatMap { agents.node($0) != nil ? $0 : nil }
            withBuilder(agent: agent) {
                $0.deny(toolUseID: f.toolUseID, kind: f.decisionReasonType, message: f.message)
            }

        case .compactBoundary(let f):
            main.addCompactBoundary(uuid: f.uuid, key: nil, timestamp: now,
                                    compactMetadata: f.compactMetadata, logicalParentUUID: nil)

        case .sessionStateChanged(let f):
            overlay.sessionState = f                          // last frame wins; no item

        case .status(let f):
            // The plan lists `.status` among the banner subtypes; this narrows it deliberately, and
            // `testStatusBannersOnlyWhenACompactionFailed` pins both directions so the narrowing cannot be mistaken
            // for an omission. `Banner.Kind` has no `status` case, and the frame arrives several times a turn
            // carrying nothing a channel would show — except `compact_error`, which is the one thing about it the
            // operator has to see, and which no fixture carries.
            if let failure = f.compactError { banner(.compatibility, text: failure, at: now) }

        case .apiRetry(let f):
            banner(.apiRetry, text: f.error, at: now)

        case .modelRefusalFallback(let f):
            banner(.modelFallback, text: f.content, at: now)

        case .modelRefusalNoFallback(let f):
            banner(.modelFallback, text: f.content, at: now)

        case .modelConsentFallback(let f):
            banner(.modelFallback, text: f.content, at: now)

        case .mirrorError(let f):
            // The banner only; the ingestion's switch to file-only is Task 10's.
            banner(.mirrorFileOnly, text: f.error, at: now)

        default:
            let value = Self.jsonValue(of: .system(system))
            main.addOpaque(key: nil,
                           identity: value["uuid"]?.stringValue ?? RecordDecoder.canonicalHash(of: value),
                           reason: "system/\(system.subtype)", value: value)
        }
    }

    // MARK: - Decisions

    private mutating func open(_ request: InboundRequest, state: DecisionItem.State, at now: Date,
                               allowingUnmodelled: Bool = false) {
        guard let kind = Self.kind(of: request.payload) ?? (allowingUnmodelled ? .other : nil) else {
            main.addOpaque(key: nil, identity: request.id.rawValue,
                           reason: "control_request/\(request.subtype)", value: request.raw)
            return
        }
        let id = ItemID(stream: stream, key: request.id.rawValue)
        overlay.decisions[request.id] = DecisionItem(
            id: id, timestamp: now, provenance: provenance(), requestID: request.id, kind: kind,
            title: Self.title(of: request.payload), toolUseID: Self.toolUseID(of: request.payload),
            agentID: Self.agentID(of: request.payload), state: state, payload: request.raw)
    }

    private mutating func setDecision(_ id: RequestID, _ body: (inout DecisionItem) -> Void) {
        guard var decision = overlay.decisions[id] else { return }
        body(&decision)
        overlay.decisions[id] = decision
    }

    private static func kind(of payload: InboundRequest.Payload) -> DecisionItem.Kind? {
        switch payload {
        case .canUseTool(let tool):
            switch tool.toolName {
            case "AskUserQuestion": return .question
            case "ExitPlanMode": return .plan
            default: return .permission
            }
        case .requestUserDialog: return .dialog
        case .elicitation: return .elicitation
        case .hookCallback: return .other
        case .mcpMessage, .unknown, .malformed: return nil
        }
    }

    private static func title(of payload: InboundRequest.Payload) -> String {
        switch payload {
        case .canUseTool(let t): return t.title ?? t.displayName ?? t.toolName
        case .requestUserDialog(let d): return d.dialogKind
        case .elicitation(let e): return e.title ?? e.displayName ?? e.message
        case .hookCallback(let h): return h.callbackID
        case .mcpMessage(let m): return m.serverName
        case .unknown(let subtype, _): return subtype
        case .malformed(let subtype, _, _): return subtype
        }
    }

    private static func toolUseID(of payload: InboundRequest.Payload) -> String? {
        switch payload {
        case .canUseTool(let t): return t.toolUseID
        case .requestUserDialog(let d): return d.toolUseID
        case .hookCallback(let h): return h.toolUseID
        default: return nil
        }
    }

    private static func agentID(of payload: InboundRequest.Payload) -> String? {
        if case .canUseTool(let t) = payload { return t.agentID }
        return nil
    }

    // MARK: - Rewind and reset

    /// Everything after the item the record uuid produced goes. An agent stream whose spawning call was dropped goes
    /// with it: its items would otherwise reattach to nothing and be appended at the end of the line.
    private mutating func rewind(to uuid: String) {
        preview = nil
        session.leaf = uuid
        if main.holds(recordUUID: uuid) {
            main.truncate(afterRecordUUID: uuid)
            dropOrphanedAgents()
            return
        }
        for id in agentOrder where agentBuilders[id]?.holds(recordUUID: uuid) == true {
            agentBuilders[id]?.truncate(afterRecordUUID: uuid)
            return
        }
        guard let index = seedItems.firstIndex(where: { Self.produced(by: uuid, $0) }) else { return }
        if index + 1 < seedItems.count { seedItems.removeSubrange((index + 1)...) }
        main = ItemBuilder(stream: stream, sourceFile: nil, origin: .wire)
        agentBuilders = [:]
        agentOrder = []
    }

    private mutating func dropOrphanedAgents() {
        let live = Set(main.items.map(\.id.key))
        let survivors = agentOrder.filter { id in
            guard let use = agents.node(id)?.toolUseID else { return true }
            return live.contains(use)
        }
        guard survivors.count != agentOrder.count else { return }
        for id in agentOrder where !survivors.contains(id) { agentBuilders[id] = nil }
        agentOrder = survivors
    }

    private mutating func clearConversation() {
        seed = .empty
        seedItems = []
        main = ItemBuilder(stream: stream, sourceFile: nil, origin: .wire)
        agentBuilders = [:]
        agentOrder = []
        hiddenRecords = []
        session = SessionState()
        session.leaf = nil
        preview = nil
    }

    // MARK: - Composition

    /// The merged line: the seed, then this process's streams spliced by rule 9. The splice is
    /// `RecordReducer.merge` itself — the wire supplies the agent metadata the file reads off `.meta.json` from the
    /// run tree instead, so the two sides splice identically by construction rather than by two implementations
    /// agreeing.
    private mutating func rebuild() {
        var projections = [StreamProjection(stream: stream, items: main.items)]
        for id in agentOrder {
            guard let builder = agentBuilders[id], let node = agents.node(id) else { continue }
            projections.append(StreamProjection(stream: agentStream(id), items: builder.items,
                                                metadata: Self.metadata(of: node)))
        }
        let merged = RecordReducer.merge(projections, main: stream)
        durable = DurableProjection(items: seedItems + merged.items.map(refreshed(_:)),
                                    hidden: seed.hidden + hiddenRecords,
                                    branches: seed.branches,
                                    session: session,
                                    warnings: seed.warnings,
                                    window: seed.window,
                                    streams: merged.streams)
    }

    /// The merge derives an agent's run row from its spawning call, which is all the file half can know. The wire
    /// knows more: the run tree carries the status the task frames reported and the registry carries the summary the
    /// notification handed back, so the row is completed here rather than left behind the frames.
    private func refreshed(_ item: TimelineItem) -> TimelineItem {
        guard case .taskRun(var run) = item, !run.synthesised, let node = agents.node(run.taskID) else { return item }
        run.status = node.status
        if !node.description.isEmpty { run.description = node.description }
        if let type = node.agentType { run.agentType = type }
        run.depth = node.depth
        run.provenance.origin = .wire
        run.provenance.epoch = epoch
        if let entry = registry.entries[run.taskID] {
            run.summary = entry.summary
            run.usage = entry.usage
            run.outputFile = entry.outputFile
        }
        return .taskRun(run)
    }

    /// Rows a task frame touched: the registry is the source of truth for a synthesised row's live fields, and the
    /// mirror's own return value is what says which ids the frame moved — including the ids a
    /// `background_tasks_changed` silently unlisted.
    private mutating func refresh(_ taskIDs: [String]) {
        for id in taskIDs {
            guard let entry = registry.entries[id] else { continue }
            main.update(taskRun: id) { run in
                run.status = entry.status
                run.summary = entry.summary
                run.usage = entry.usage
                run.outputFile = entry.outputFile
                if !entry.description.isEmpty { run.description = entry.description }
            }
        }
    }

    private mutating func withBuilder(agent id: String?, _ body: (inout ItemBuilder) -> Void) {
        guard let id else { return body(&main) }
        if agentBuilders[id] == nil {
            agentBuilders[id] = ItemBuilder(stream: agentStream(id), sourceFile: nil, origin: .wire)
            agentOrder.append(id)
        }
        body(&agentBuilders[id]!)
    }

    private mutating func drainDeliveries() {
        while pendingDeliveries > 0, main.deliverOldestSentFile() { pendingDeliveries -= 1 }
    }

    private func agentStream(_ taskID: String) -> LogicalStream {
        LogicalStream(configHome: stream.configHome, sessionID: stream.sessionID, name: .agent(taskID: taskID))
    }

    private func provenance() -> Provenance {
        Provenance(stream: stream, epoch: epoch, origin: .wire)
    }

    private mutating func banner(_ kind: Banner.Kind, text: String, at now: Date) {
        overlay.banners.append(Banner(kind: kind, text: text, epoch: epoch, at: now))
    }

    /// The denial the engine refused a call with. The transcript writes it as the record-level `toolDenialKind`;
    /// the wire writes it per tool-use id inside `tool_result_meta`, which `UserFields` does not declare and which
    /// therefore arrives in the frame's lossless extras. Reading it here is what makes a denied call read `.denied`
    /// on both halves of the invariant; `ItemBuilder.addUser` applies it exactly as the record reducer's value is
    /// applied, so there is no second denial path.
    private static func denialKind(of frame: UserFrame) -> String? {
        guard let meta = frame.additional["tool_result_meta"]?.arrayValue else { return nil }
        let answered = Set(Self.toolResultIDs(of: frame.message.fields.content))
        for entry in meta {
            guard let id = entry["id"]?.stringValue, answered.contains(id),
                  let kind = entry["non_execution_kind"]?.stringValue else { continue }
            return kind
        }
        return nil
    }

    private static func toolResultIDs(of content: UserContent) -> [String] {
        guard case .blocks(let blocks) = content else { return [] }
        return blocks.compactMap { if case .toolResult(let r) = $0 { r.fields.toolUseID } else { nil } }
    }

    private static func metadata(of node: AgentRunNode) -> AgentMetadataRecord {
        AgentMetadataRecord(fields: AgentMetadataFields(type: "agent_metadata", agentType: node.agentType ?? "",
                                                        description: node.description, toolUseId: node.toolUseID,
                                                        spawnDepth: node.depth, parentAgentId: node.parent))
    }

    private static func produced(by uuid: String, _ item: TimelineItem) -> Bool {
        if item.id.key == uuid { return true }
        if case .assistantMessage(let message) = item { return message.recordUUIDs.contains(uuid) }
        return false
    }

    private static func toolUseIDs(of blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { if case .toolUse(let use) = $0 { use.fields.id } else { nil } }
    }

    private static func toolUseIDs(of content: UserContent) -> [String] {
        guard case .blocks(let blocks) = content else { return [] }
        return toolUseIDs(of: blocks)
    }

    /// Every `tool_result` whose content is a plain string, by the call it answers.
    private static func toolResultTexts(of content: UserContent) -> [(String, String)] {
        guard case .blocks(let blocks) = content else { return [] }
        return blocks.compactMap { block in
            guard case .toolResult(let result) = block, let text = result.fields.content?.stringValue else { return nil }
            return (result.fields.toolUseID, text)
        }
    }

    /// A `user` frame's identity when it carries no uuid: the canonical hash of its message, which is stable across
    /// re-encodings and never collides with a real uuid.
    private static func contentIdentity(of message: UserMessage) -> String {
        guard let data = try? JSONEncoder().encode(message),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "user" }
        return RecordDecoder.canonicalHash(of: value)
    }

    private static func jsonValue(of frame: Frame) -> JSONValue {
        guard let data = try? FrameDecoder.encode(frame),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }

    private static func describe(_ reason: OpaqueReason) -> String {
        switch reason {
        case .invalidJSON: "invalid_json"
        case .unknownType: "unknown_type"
        case .unknownSubtype: "unknown_subtype"
        case .decodeFailure(let field, _): "decode_failure:\(field)"
        }
    }

    // MARK: - Change reporting

    /// The rendered line before and after one event. Changes are derived by comparing the two rather than reported
    /// by each route, so a route that forgets to say what it did cannot make a change disappear.
    private struct Snapshot {
        let order: [ItemID]
        let items: [ItemID: TimelineItem]
        let preview: StreamingPreview?
        let sessionState: SessionStateChanged?
        let session: SessionState
        let overlayDigest: Overlay

        init(_ reducer: WireReducer) {
            let all = reducer.durable.items + reducer.overlay.items
            order = all.map(\.id)
            items = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            preview = reducer.preview
            sessionState = reducer.overlay.sessionState
            session = reducer.durable.session
            overlayDigest = reducer.overlay
        }

        func difference(to after: Snapshot) -> [TimelineChange] {
            var out: [TimelineChange] = []
            for id in order where after.items[id] == nil { out.append(.removed(id)) }
            for id in after.order {
                guard let new = after.items[id] else { continue }
                if let old = items[id] { if old != new { out.append(.updated(id)) } } else { out.append(.inserted(id)) }
            }
            if preview != after.preview { out.append(.previewChanged) }
            if overlayDigest != after.overlayDigest { out.append(.overlayChanged) }
            if sessionState != after.sessionState || session != after.session { out.append(.sessionStateChanged) }
            return out
        }
    }
}
