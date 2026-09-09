import Foundation
import ClaudeWire

/// One agent run: a `task_started` with `task_type == "local_agent"`, and everything the host learns about it after.
///
/// A node stores **no path**. Its transcript lives at an alias of `<configHome>/projects/<slug>/…` and the slug moves
/// when the project directory is renamed, so the URL is computed from the tree's current slug on every call
/// (`AgentRunTree.transcriptURL(of:)`). Nothing stale can be stored because nothing is stored.
public struct AgentRunNode: Hashable, Sendable, Identifiable, Codable {
    /// The engine's `task_id`.
    public let id: String
    public var agentType: String?
    public var description: String
    /// The badge the UI shows. Neither the task frames nor the `.meta.json` sidecar carries a model, so it can only
    /// come from the run's own forwarded frames — `observe(assistantModel:agentID:)`. It is nil until one arrives.
    public var model: String?
    public var status: TaskStatus
    public var depth: Int
    public var parent: String?
    public var parentSource: ParentSource
    public var activityLine: String?
    public var lastToolName: String?
    public var elapsedOrigin: Date
    public var endedAt: Date?
    /// The `tool_use` block that spawned this run — the wire reducer's route for a frame forwarded from inside it.
    public var toolUseID: String?
    public var children: [String]
    /// How many `task_started` frames this id has carried: a re-armed id is one node that ran more than once.
    public var startedCount: Int

    /// Which of the three independent sources answered the parent question first. `.none` means none has.
    public enum ParentSource: String, Sendable, Codable { case agentMetadata, metaFile, twoStepJoin, none }

    public init(id: String, agentType: String? = nil, description: String = "", model: String? = nil,
                status: TaskStatus = .running, depth: Int = 1, parent: String? = nil,
                parentSource: ParentSource = .none, activityLine: String? = nil, lastToolName: String? = nil,
                elapsedOrigin: Date, endedAt: Date? = nil, toolUseID: String? = nil,
                children: [String] = [], startedCount: Int = 0) {
        self.id = id; self.agentType = agentType; self.description = description; self.model = model
        self.status = status; self.depth = depth; self.parent = parent; self.parentSource = parentSource
        self.activityLine = activityLine; self.lastToolName = lastToolName; self.elapsedOrigin = elapsedOrigin
        self.endedAt = endedAt; self.toolUseID = toolUseID; self.children = children; self.startedCount = startedCount
    }
}

public enum AgentRunTreeError: Error, Sendable, Equatable {
    /// A URL handed to `apply(metaFile:)` whose last component is not `agent-<taskId>.meta.json`.
    case notAnAgentSidecar
}

/// The tree of agent runs of one session (parent §8.8), folded from the engine's task frames.
///
/// The parent link has **three independent sources**, and they arrive in no fixed order: the `agent_metadata` mirror
/// entry (which arrives before the sidecar file exists on disk), the `.meta.json` sidecar itself, and a two-step join
/// over the frames' `parent_tool_use_id`. The first source to answer sets the link and a later one never overwrites
/// it — but a later one that *disagrees* is recorded in `conflicts`, because a silent overwrite and a silent drop
/// would otherwise look identical. Every answer any source gave is kept in `parentAnswers`, so a test can assert that
/// the sources actually ran rather than that they were merely quiet.
public struct AgentRunTree: Hashable, Sendable {
    public private(set) var nodes: [String: AgentRunNode]
    /// Disagreements between parent sources, as identifier-only sentences (never a path, a title or a payload).
    public private(set) var conflicts: [String]
    /// Every parent id each source produced, per node id. Empty for a node no source has answered for.
    public private(set) var parentAnswers: [String: [AgentRunNode.ParentSource: String]]
    /// The project directory alias the session's transcripts currently live under. `relocate(slug:)` replaces it and
    /// every node's URL moves with it.
    public private(set) var slug: String

    private let configHome: URL
    private let sessionID: SessionID
    /// Node ids in **start order**: every node by its `elapsedOrigin`, which is when the run began for a node a
    /// `task_started` named and the source's own instant for one a metadata source created, until the file half's
    /// reading or a later `task_started` takes it back. Ties break by the order the tree first heard of the ids.
    ///
    /// Sorted rather than appended because the two channel kinds hear of their runs in different orders — a live
    /// channel in `task_started` order, a file-only one in whatever order the directory enumerates its sidecars, which
    /// is by file name — and a tree whose roots read differently depending on how the channel was opened is a
    /// different tree.
    private var order: [String]
    /// The order the tree first heard of each id, which breaks a tie between two equal instants.
    private var sequence: [String: Int]
    private var nextSequence: Int
    /// The two-step join's index: a tool-use id → the `parent_tool_use_id` of the frame that carried that block.
    /// `.some(nil)` is "carried by a top-level frame"; a missing key is "never observed".
    private var carriedBy: [String: String?]

    public init(configHome: URL, sessionID: SessionID, slug: String) {
        self.nodes = [:]; self.conflicts = []; self.parentAnswers = [:]; self.slug = slug
        self.configHome = configHome.standardizedFileURL; self.sessionID = sessionID
        self.order = []; self.carriedBy = [:]; self.sequence = [:]; self.nextSequence = 0
    }

    // MARK: - Task frames

    /// Only `task_type == "local_agent"` makes a node: a background shell is a registry row, not an agent run.
    /// A repeated `task_started` for an id the tree already holds is the same node run again, not a second node.
    public mutating func apply(taskStarted f: TaskStarted, at now: Date) {
        guard f.taskType == "local_agent" else { return }
        if nodes[f.taskID] == nil {
            nodes[f.taskID] = AgentRunNode(id: f.taskID, elapsedOrigin: now)
            insert(f.taskID)
        } else if nodes[f.taskID]!.startedCount == 0 {
            // A metadata source created this node and stamped it with its own arrival. The run's first `task_started`
            // is when the run actually began, so it takes the origin back; a *repeat* start does not, because the
            // elapsed reading a re-armed run shows is the one `startedCount` already documents.
            nodes[f.taskID]!.elapsedOrigin = now
        }
        nodes[f.taskID]!.description = f.description
        if let type = f.subagentType { nodes[f.taskID]!.agentType = type }
        if let use = f.toolUseID { nodes[f.taskID]!.toolUseID = use }
        if let depth = f.spawnDepth { nodes[f.taskID]!.depth = depth }
        nodes[f.taskID]!.status = .running
        nodes[f.taskID]!.endedAt = nil
        nodes[f.taskID]!.startedCount += 1
        resort()
        resolveJoins()
    }

    /// The run's activity line and last tool. It never creates a node: a `task_progress` for an id the tree has not
    /// seen start belongs to a task this tree does not model.
    ///
    /// `summary` wins over `description` when the frame carries one (child spec: the activity line is
    /// `task_progress.description` and `last_tool_name`, replaced by `summary` when present): the summary is the
    /// engine's own sentence about what the run is doing, and the description is the lower-level step under it.
    public mutating func apply(taskProgress f: TaskProgress, at now: Date) {
        guard nodes[f.taskID] != nil else { return }
        nodes[f.taskID]!.activityLine = f.summary ?? f.description
        if let tool = f.lastToolName { nodes[f.taskID]!.lastToolName = tool }
        if let type = f.subagentType { nodes[f.taskID]!.agentType = type }
        if let use = f.toolUseID, nodes[f.taskID]!.toolUseID == nil { nodes[f.taskID]!.toolUseID = use; resolveJoins() }
    }

    public mutating func apply(taskUpdated f: TaskUpdated, at now: Date) {
        guard nodes[f.taskID] != nil else { return }
        if let status = f.patch["status"]?.stringValue { nodes[f.taskID]!.status = TaskStatus(wire: status) }
        if let end = f.patch["end_time"]?.intValue { nodes[f.taskID]!.endedAt = Date(timeIntervalSince1970: Double(end) / 1000) }
        if let description = f.patch["description"]?.stringValue { nodes[f.taskID]!.description = description }
    }

    public mutating func apply(taskNotification f: TaskNotification, at now: Date) {
        guard nodes[f.taskID] != nil else { return }
        nodes[f.taskID]!.status = TaskStatus(wire: f.status)
        if let use = f.toolUseID, nodes[f.taskID]!.toolUseID == nil { nodes[f.taskID]!.toolUseID = use; resolveJoins() }
        if nodes[f.taskID]!.endedAt == nil { nodes[f.taskID]!.endedAt = now }
    }

    /// A heartbeat from inside a run: it moves the `lastToolName` and `activityLine` of the node whose `toolUseID` is
    /// the frame's `parent_tool_use_id`, and nothing else. A frame with no parent belongs to the main stream.
    public mutating func apply(toolProgress f: ToolProgressFrame, at now: Date) {
        guard let parent = f.parentToolUseID, let node = node(withToolUse: parent) else { return }
        nodes[node.id]!.lastToolName = f.toolName
        nodes[node.id]!.activityLine = f.toolName
    }

    // MARK: - Parent source one: the `agent_metadata` mirror entry

    /// The mirror carries the sidecar's body before the sidecar file exists on disk. The stream names the task.
    ///
    /// `now` is the instant this source spoke, and it is the created node's `elapsedOrigin` when this source is the
    /// first to name the run at all (see `absorb`).
    public mutating func apply(agentMetadata m: AgentMetadataRecord, for stream: LogicalStream, at now: Date = Date()) {
        guard case .agent(let taskID) = stream.name else { return }
        absorb(m.fields, taskID: taskID, source: .agentMetadata, at: now)
    }

    // MARK: - Parent source two: the `.meta.json` sidecar on disk

    /// Reads `agent-<taskId>.meta.json`. The task id comes from the file name, so the sidecar is readable wherever it
    /// lies; the bytes are read `O_RDONLY | O_NOFOLLOW` through the transcript reader, and nothing is written.
    public mutating func apply(metaFile url: URL, at now: Date = Date()) throws {
        let name = url.lastPathComponent
        guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { throw AgentRunTreeError.notAnAgentSidecar }
        let taskID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
        guard !taskID.isEmpty else { throw AgentRunTreeError.notAnAgentSidecar }
        let data = try TranscriptReader(url: url).read(at: 0, length: .max)
        let fields = try JSONDecoder().decode(AgentMetadataFields.self, from: data)
        absorb(fields, taskID: taskID, source: .metaFile, at: now)
    }

    // MARK: - Parent source three: the two-step join

    /// One frame's join input: its `parent_tool_use_id` and the tool-use ids its blocks carry. A node's `toolUseID` is
    /// the block that spawned it, so the frame that *carried* that block names the run the spawn happened inside.
    public mutating func observe(parentToolUseID: String?, carryingToolUseIDs: [String]) {
        for id in carryingToolUseIDs where carriedBy[id] == nil { carriedBy[id] = .some(parentToolUseID) }
        resolveJoins()
    }

    /// The model badge, from a frame forwarded out of the run itself.
    public mutating func observe(assistantModel model: String, agentID: String) {
        guard nodes[agentID] != nil else { return }
        nodes[agentID]!.model = model
    }

    // MARK: - Queries

    /// Nodes with no parent, in start order. On a well-formed session these are exactly the depth-1 runs; a node whose
    /// parent no source has answered for shows at the top rather than disappearing.
    public var roots: [String] { order.filter { nodes[$0]?.parent == nil } }

    public func children(of id: String) -> [String] { nodes[id]?.children ?? [] }

    public func node(_ id: String) -> AgentRunNode? { nodes[id] }

    /// The node whose *spawning* `tool_use` id matches — the wire reducer's route for a forwarded frame. Matching is
    /// against `toolUseID`, never the node id: a task id and a tool-use id are different namespaces.
    public func node(withToolUse toolUseID: String) -> AgentRunNode? {
        for id in order where nodes[id]?.toolUseID == toolUseID { return nodes[id] }
        return nil
    }

    /// Finished, but a child is still running: the run's own work is over and the branch is not.
    public func isParked(_ id: String) -> Bool {
        guard let node = nodes[id], node.status != .running else { return false }
        return node.children.contains { nodes[$0]?.status == .running }
    }

    /// `<configHome>/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl`, computed from the tree's *current* slug
    /// on every call. Nil for an id the tree does not hold.
    public func transcriptURL(of id: String) -> URL? {
        guard nodes[id] != nil else { return nil }
        return TranscriptPath.path(of: LogicalStream(configHome: configHome, sessionID: sessionID, name: .agent(taskID: id)),
                                   slug: slug)
    }

    /// The project directory was renamed. One assignment moves every node's URL, because no node holds one.
    public mutating func relocate(slug: String) { self.slug = slug }

    // MARK: - Internals

    /// **A metadata source creates the node when no `task_started` has.** Both sources name an agent stream — the
    /// mirror entry by its stream, the sidecar by its `agent-<taskId>.meta.json` name — and an agent stream *is* a
    /// `local_agent` run, so there is nothing else the record could be about. Without this the tree of a channel
    /// opened from its files alone is permanently empty: no wire means no `task_started`, and every node the sidecars
    /// describe would be dropped by a guard that exists only because `task_started` used to be the sole creator.
    ///
    /// A node created here reads `.running` and keeps that reading **only until something says otherwise**. Neither
    /// the sidecar nor the mirror entry carries a status, so `.running` is what the type defaults to and not an
    /// assertion; `reconcile(fileReadings:)` then hands the node the file half's own reading of the same run, which
    /// is the `taskRun` row's — completed or failed as the spawning call's result says, running only where the merged
    /// line holds no spawning call for it. Saying `.running` and stopping there is what made an archived channel's
    /// row read *Completed* beside a tree node that read running.
    ///
    /// `elapsedOrigin` is this source's instant, and it is replaced by the first `task_started` the node ever sees or
    /// by the file half's reading of when the run began: the metadata's arrival is when the *host learned of* the
    /// run, not when the run began, and the start order the tree is sorted in has to be the run's.
    private mutating func absorb(_ m: AgentMetadataFields, taskID: String, source: AgentRunNode.ParentSource,
                                 at now: Date) {
        if nodes[taskID] == nil {
            nodes[taskID] = AgentRunNode(id: taskID, elapsedOrigin: now)
            insert(taskID)
        }
        if nodes[taskID]!.agentType == nil { nodes[taskID]!.agentType = m.agentType }
        if nodes[taskID]!.description.isEmpty { nodes[taskID]!.description = m.description }
        // The sidecar can be the first to name the spawning block, and the block is the join's key, so learning it
        // here has to re-run the join; nothing else does it for us.
        let learnedToolUse = nodes[taskID]!.toolUseID == nil && m.toolUseId != nil
        if nodes[taskID]!.toolUseID == nil { nodes[taskID]!.toolUseID = m.toolUseId }
        // `depth` is written whenever the metadata states one, unlike the optional fields above, which are written
        // only when unset. It has to be: `depth` is not optional, its default (1) is also a legal value, so "unset"
        // is not representable and a write-if-unset rule would silently keep the default for a run whose
        // `task_started` carried no `spawn_depth`. Both sources carry the engine's own spawn depth for the same run
        // and the corpus shows them equal, so this is a no-op wherever both are present.
        if let depth = m.spawnDepth { nodes[taskID]!.depth = depth }
        if let parent = m.parentAgentId { link(taskID, to: parent, from: source) }
        if learnedToolUse { resolveJoins() }
    }

    /// The file half's reading of one agent run, as the merged projection's `taskRun` row states it.
    ///
    /// The row is derived in `RecordReducer.taskRun(for:spawnedBy:toolUseID:)` and the two halves of one channel must
    /// not disagree about the same run, so the row is the authority for a node no `task_started` has named.
    public struct FileReading: Hashable, Sendable {
        /// The spawning call's own status, or `.running` where the merged line holds no spawning call for the run.
        public var status: TaskStatus
        /// When the run began, as the row places it — the spawning call's instant. Nil where the row carries none.
        public var startedAt: Date?
        public init(status: TaskStatus, startedAt: Date? = nil) {
            self.status = status; self.startedAt = startedAt
        }
    }

    /// The file half's readings, applied to the nodes **no `task_started` has named** (`startedCount == 0`).
    ///
    /// A run the wire started is the wire's: its frames carry a status the transcript cannot, and `task_notification`
    /// is the only thing that ever says a run ended. A run only the metadata named has no such source, and the row
    /// the same channel already draws for it is the honest reading — so the node takes it rather than defaulting to
    /// running for ever. Returns whether anything moved, so a caller publishes only a real change.
    @discardableResult
    public mutating func reconcile(fileReadings: [String: FileReading]) -> Bool {
        var moved = false
        for (id, reading) in fileReadings {
            guard var node = nodes[id], node.startedCount == 0 else { continue }
            if node.status != reading.status { node.status = reading.status; moved = true }
            if let startedAt = reading.startedAt, node.elapsedOrigin != startedAt {
                node.elapsedOrigin = startedAt; moved = true
            }
            nodes[id] = node
        }
        if moved { resort() }
        return moved
    }

    /// A node the tree has just created takes its place in start order — and takes the children that
    /// were already waiting for it.
    ///
    /// **A link can be made before the parent exists.** The three parent sources arrive in no fixed
    /// order and a file-only channel reads its sidecars in file-name order, so a child's metadata
    /// routinely names a parent no node has been created for yet: `link` writes the child's `parent`
    /// and `rebuildChildren` skips it, because there is nothing to hang it on. Without this the
    /// branch is then lost in both directions — the parent lists no children, and the child is not a
    /// root either, because its `parent` is set — so the run is drawn nowhere at all.
    private mutating func insert(_ id: String) {
        sequence[id] = nextSequence
        nextSequence += 1
        order.append(id)
        resort()
        rebuildChildren()
    }

    /// `order` by `elapsedOrigin`, ties broken by the order the tree first heard of the ids. Called after anything
    /// that can create a node or move one's origin; the array holds one entry per agent run of one session.
    private mutating func resort() {
        order.sort { a, b in
            guard let first = nodes[a], let second = nodes[b] else { return false }
            if first.elapsedOrigin != second.elapsedOrigin { return first.elapsedOrigin < second.elapsedOrigin }
            return (sequence[a] ?? 0) < (sequence[b] ?? 0)
        }
    }

    /// Every node without a parent whose spawning block has been observed. Runs after each fold step that could
    /// change either side, and calls `link` even when the parent is already set, so a disagreement is recorded.
    private mutating func resolveJoins() {
        for id in order {
            guard let use = nodes[id]?.toolUseID, let observed = carriedBy[use], let carrier = observed else { continue }
            guard let parent = node(withToolUse: carrier) else { continue }
            link(id, to: parent.id, from: .twoStepJoin)
        }
    }

    /// First source wins; a later source that agrees is recorded and changes nothing; a later source that disagrees
    /// is recorded as a conflict and still changes nothing.
    ///
    /// The record is **idempotent**. `resolveJoins()` re-offers every node's join answer after every observation, so a
    /// standing disagreement is re-offered once per message frame for the life of the session; appending each time
    /// would grow this value without bound. A source repeating an answer it has already given is therefore a no-op,
    /// and only a genuinely new answer — a source speaking for the first time, or changing its mind — is recorded.
    private mutating func link(_ id: String, to parentID: String, from source: AgentRunNode.ParentSource) {
        guard nodes[id] != nil, parentID != id else { return }
        let alreadySaid = parentAnswers[id]?[source]
        parentAnswers[id, default: [:]][source] = parentID
        if let existing = nodes[id]!.parent {
            guard existing != parentID, alreadySaid != parentID else { return }
            conflicts.append("agent \(id): \(source.rawValue) says parent \(parentID), kept \(existing) from \(nodes[id]!.parentSource.rawValue)")
            return
        }
        nodes[id]!.parent = parentID
        nodes[id]!.parentSource = source
        rebuildChildren()
    }

    /// `children` is derived from `parent`, never maintained beside it, so the two cannot drift.
    private mutating func rebuildChildren() {
        for id in order { nodes[id]!.children = [] }
        for id in order {
            guard let parent = nodes[id]!.parent, nodes[parent] != nil else { continue }
            nodes[parent]!.children.append(id)
        }
    }
}
