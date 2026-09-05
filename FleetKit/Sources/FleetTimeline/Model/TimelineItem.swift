import Foundation
import ClaudeWire

// MARK: - Identity and provenance

/// A timeline item's identity: the stream it belongs to plus a key the projection assigns (parent §7.3, contract X4).
public struct ItemID: Hashable, Sendable, Codable {
    public let stream: LogicalStream
    public let key: String
    public init(stream: LogicalStream, key: String) { self.stream = stream; self.key = key }
}

/// Where an item came from: which stream, which records built it, and by which route the host learned of them.
public struct Provenance: Hashable, Sendable, Codable {
    public var stream: LogicalStream
    public var agentID: String?
    public var sourceFile: URL?
    public var epoch: ProcessEpoch?
    public var records: Set<RecordKey>
    public var origin: Origin
    public enum Origin: String, Sendable, Codable { case file, mirror, wire, synthesised }
    public init(stream: LogicalStream, agentID: String? = nil, sourceFile: URL? = nil, epoch: ProcessEpoch? = nil,
                records: Set<RecordKey> = [], origin: Origin) {
        self.stream = stream; self.agentID = agentID; self.sourceFile = sourceFile; self.epoch = epoch
        self.records = records; self.origin = origin
    }
}

/// The thirteen kinds an item can take. The partition into durable and overlay lives in `ProjectionCategories`.
public enum TimelineCategory: String, CaseIterable, Sendable, Codable {
    case userMessage, assistantMessage, toolCall, cluster, taskRun, decision, hookRun, notification, peerMessage,
         compactBoundary, sentFile, turnSummary, opaque
}

// MARK: - Task vocabulary

/// The engine's ten background-task kinds (parity §20.8.1), with `other` for a kind this engine does not yet emit.
public enum TaskKind: Hashable, Sendable, Codable {
    case localBash, localAgent, remoteAgent, inProcessTeammate, localWorkflow, monitorMCP, monitorWS, mcpTask, dream, autoModeScan
    case other(String)

    public init(wire: String) {
        switch wire {
        case "local_bash": self = .localBash
        case "local_agent": self = .localAgent
        case "remote_agent": self = .remoteAgent
        case "in_process_teammate": self = .inProcessTeammate
        case "local_workflow": self = .localWorkflow
        case "monitor_mcp": self = .monitorMCP
        case "monitor_ws": self = .monitorWS
        case "mcp_task": self = .mcpTask
        case "dream": self = .dream
        case "auto_mode_scan": self = .autoModeScan
        default: self = .other(wire)
        }
    }
    public var wire: String {
        switch self {
        case .localBash: "local_bash"; case .localAgent: "local_agent"; case .remoteAgent: "remote_agent"
        case .inProcessTeammate: "in_process_teammate"; case .localWorkflow: "local_workflow"
        case .monitorMCP: "monitor_mcp"; case .monitorWS: "monitor_ws"; case .mcpTask: "mcp_task"
        case .dream: "dream"; case .autoModeScan: "auto_mode_scan"; case .other(let raw): raw
        }
    }
}

/// The registry's five statuses collapsed to four: `killed` and `stopped` are one state under two spellings
/// (parity §20.8.4 — `task_updated` keeps `killed`, `task_notification` maps it to `stopped`). An unrecognised
/// spelling reads as `.running` rather than crashing: a live task the host cannot classify is still live.
public enum TaskStatus: String, Sendable, Codable {
    case running, completed, failed, stopped
    public init(wire: String) {
        switch wire {
        case "completed": self = .completed
        case "failed": self = .failed
        case "killed", "stopped": self = .stopped
        default: self = .running        // "pending", "running", and anything unknown
        }
    }
}

// MARK: - Payloads

public struct UserMessageItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var blocks: [ContentBlock]
    public var text: String
    public var isReplay: Bool
    public var promptUUID: String
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                blocks: [ContentBlock] = [], text: String = "", isReplay: Bool = false, promptUUID: String = "") {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.blocks = blocks; self.text = text; self.isReplay = isReplay; self.promptUUID = promptUUID
    }
}

public struct AssistantMessageItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var messageID: String?
    public var model: String?
    public var blocks: [ContentBlock]
    public var stopReason: String?
    public var isStreaming: Bool
    public var supersededBy: String?
    public var recordUUIDs: [String]
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                messageID: String? = nil, model: String? = nil, blocks: [ContentBlock] = [], stopReason: String? = nil,
                isStreaming: Bool = false, supersededBy: String? = nil, recordUUIDs: [String] = []) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.messageID = messageID; self.model = model; self.blocks = blocks; self.stopReason = stopReason
        self.isStreaming = isStreaming; self.supersededBy = supersededBy; self.recordUUIDs = recordUUIDs
    }
}

public struct ToolCallItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var toolUseID: String
    public var name: String
    /// The tool's input exactly as the engine wrote it. `input` below types it on demand; `ToolInput` is not `Codable`.
    public var rawInput: JSONValue
    public var result: JSONValue?
    public var isError: Bool?
    public var structuredResult: JSONValue?
    public var denialKind: String?
    public var messageID: String?
    public var status: Status
    public enum Status: String, Sendable, Codable { case running, completed, failed, denied }
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                toolUseID: String, name: String, rawInput: JSONValue, result: JSONValue? = nil, isError: Bool? = nil,
                structuredResult: JSONValue? = nil, denialKind: String? = nil, messageID: String? = nil, status: Status) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.toolUseID = toolUseID; self.name = name; self.rawInput = rawInput; self.result = result
        self.isError = isError; self.structuredResult = structuredResult; self.denialKind = denialKind
        self.messageID = messageID; self.status = status
    }
}
extension ToolCallItem {
    /// Typed on demand from the stored raw input; never a stored field (`ToolInput` is `Hashable, Sendable` only).
    public var input: ToolInput { ToolInput.parse(name: name, input: rawInput) }
}

public struct ToolClusterItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var toolUseIDs: [String]
    public var label: String?
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                toolUseIDs: [String] = [], label: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.toolUseIDs = toolUseIDs; self.label = label
    }
}

public struct TaskRunItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var taskID: String
    public var kind: TaskKind
    public var description: String
    public var status: TaskStatus
    public var summary: String?
    public var outputFile: URL?
    public var usage: JSONValue?
    public var toolUseID: String?
    public var agentType: String?
    public var depth: Int?
    public var synthesised: Bool
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                taskID: String, kind: TaskKind, description: String, status: TaskStatus, summary: String? = nil,
                outputFile: URL? = nil, usage: JSONValue? = nil, toolUseID: String? = nil, agentType: String? = nil,
                depth: Int? = nil, synthesised: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.taskID = taskID; self.kind = kind; self.description = description; self.status = status
        self.summary = summary; self.outputFile = outputFile; self.usage = usage; self.toolUseID = toolUseID
        self.agentType = agentType; self.depth = depth; self.synthesised = synthesised
    }
}

public struct DecisionItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var requestID: RequestID
    public var kind: Kind
    public var title: String
    public var toolUseID: String?
    public var agentID: String?
    public var state: State
    public var payload: JSONValue
    /// `other`: a subtype the host does not model, reached only through `.policyAnswered`.
    public enum Kind: String, Sendable, Codable { case permission, question, plan, dialog, elicitation, other }
    public enum State: Hashable, Sendable, Codable {
        case pending, answered(outcome: String), cancelled, policyAnswered(error: String), inert
    }
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                requestID: RequestID, kind: Kind, title: String, toolUseID: String? = nil, agentID: String? = nil,
                state: State, payload: JSONValue) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.requestID = requestID; self.kind = kind; self.title = title; self.toolUseID = toolUseID
        self.agentID = agentID; self.state = state; self.payload = payload
    }
}

public struct HookRunItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var hookID: String
    public var hookName: String
    public var event: String
    public var outcome: String?
    public var exitCode: Int?
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                hookID: String, hookName: String, event: String, outcome: String? = nil, exitCode: Int? = nil) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.hookID = hookID; self.hookName = hookName; self.event = event; self.outcome = outcome; self.exitCode = exitCode
    }
}

public struct NotificationItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var key: String
    public var text: String
    public var level: String
    public var fileOnly: Bool
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                key: String, text: String, level: String, fileOnly: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.key = key; self.text = text; self.level = level; self.fileOnly = fileOnly
    }
}

public struct PeerMessageItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var originKind: String
    public var from: String?
    public var name: String?
    public var blocks: [ContentBlock]
    public var text: String
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                originKind: String, from: String? = nil, name: String? = nil, blocks: [ContentBlock] = [], text: String = "") {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.originKind = originKind; self.from = from; self.name = name; self.blocks = blocks; self.text = text
    }
}

public struct CompactBoundaryItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var trigger: String?
    public var hardTruncation: Bool
    public var preTokens: Int?
    public var postTokens: Int?
    public var logicalParentUUID: String?
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                trigger: String? = nil, hardTruncation: Bool = false, preTokens: Int? = nil, postTokens: Int? = nil,
                logicalParentUUID: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.trigger = trigger; self.hardTruncation = hardTruncation; self.preTokens = preTokens
        self.postTokens = postTokens; self.logicalParentUUID = logicalParentUUID
    }
}

public struct SentFileItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var toolUseID: String
    public var files: [String]
    public var caption: String?
    public var delivered: Bool?
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                toolUseID: String, files: [String] = [], caption: String? = nil, delivered: Bool? = nil) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.toolUseID = toolUseID; self.files = files; self.caption = caption; self.delivered = delivered
    }
}

public struct TurnSummaryItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var subtype: String
    public var durationMs: Int
    public var costUSD: Double
    public var numTurns: Int
    public var stopReason: String?
    public var usage: JSONValue?
    public var permissionDenials: JSONValue?
    public var attribution: TurnAttribution
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                subtype: String, durationMs: Int, costUSD: Double, numTurns: Int, stopReason: String? = nil,
                usage: JSONValue? = nil, permissionDenials: JSONValue? = nil, attribution: TurnAttribution) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.subtype = subtype; self.durationMs = durationMs; self.costUSD = costUSD; self.numTurns = numTurns
        self.stopReason = stopReason; self.usage = usage; self.permissionDenials = permissionDenials
        self.attribution = attribution
    }
}

/// Which prompt a `result` belongs to: the prompt's uuid, a relocation the host did not prompt, or nothing it can attribute.
public enum TurnAttribution: Hashable, Sendable, Codable { case prompted(uuid: String), relocation, unprompted }

public struct OpaqueItem: Hashable, Sendable, Codable {
    public var id: ItemID
    public var timestamp: Date?
    public var threadParent: ItemID?
    public var provenance: Provenance
    public var type: String?
    public var subtype: String?
    public var reason: String
    public var value: JSONValue
    public init(id: ItemID, timestamp: Date? = nil, threadParent: ItemID? = nil, provenance: Provenance,
                type: String? = nil, subtype: String? = nil, reason: String, value: JSONValue) {
        self.id = id; self.timestamp = timestamp; self.threadParent = threadParent; self.provenance = provenance
        self.type = type; self.subtype = subtype; self.reason = reason; self.value = value
    }
}

// MARK: - The item

public enum TimelineItem: Identifiable, Hashable, Sendable, Codable {
    case userMessage(UserMessageItem)
    case assistantMessage(AssistantMessageItem)
    case toolCall(ToolCallItem)
    case cluster(ToolClusterItem)
    case taskRun(TaskRunItem)
    case decision(DecisionItem)
    case hookRun(HookRunItem)
    case notification(NotificationItem)
    case peerMessage(PeerMessageItem)
    case compactBoundary(CompactBoundaryItem)
    case sentFile(SentFileItem)
    case turnSummary(TurnSummaryItem)
    case opaque(OpaqueItem)

    public var id: ItemID {
        switch self {
        case .userMessage(let i): i.id; case .assistantMessage(let i): i.id; case .toolCall(let i): i.id
        case .cluster(let i): i.id; case .taskRun(let i): i.id; case .decision(let i): i.id
        case .hookRun(let i): i.id; case .notification(let i): i.id; case .peerMessage(let i): i.id
        case .compactBoundary(let i): i.id; case .sentFile(let i): i.id; case .turnSummary(let i): i.id
        case .opaque(let i): i.id
        }
    }
    public var timestamp: Date? {
        switch self {
        case .userMessage(let i): i.timestamp; case .assistantMessage(let i): i.timestamp; case .toolCall(let i): i.timestamp
        case .cluster(let i): i.timestamp; case .taskRun(let i): i.timestamp; case .decision(let i): i.timestamp
        case .hookRun(let i): i.timestamp; case .notification(let i): i.timestamp; case .peerMessage(let i): i.timestamp
        case .compactBoundary(let i): i.timestamp; case .sentFile(let i): i.timestamp; case .turnSummary(let i): i.timestamp
        case .opaque(let i): i.timestamp
        }
    }
    public var threadParent: ItemID? {
        switch self {
        case .userMessage(let i): i.threadParent; case .assistantMessage(let i): i.threadParent; case .toolCall(let i): i.threadParent
        case .cluster(let i): i.threadParent; case .taskRun(let i): i.threadParent; case .decision(let i): i.threadParent
        case .hookRun(let i): i.threadParent; case .notification(let i): i.threadParent; case .peerMessage(let i): i.threadParent
        case .compactBoundary(let i): i.threadParent; case .sentFile(let i): i.threadParent; case .turnSummary(let i): i.threadParent
        case .opaque(let i): i.threadParent
        }
    }
    public var provenance: Provenance {
        switch self {
        case .userMessage(let i): i.provenance; case .assistantMessage(let i): i.provenance; case .toolCall(let i): i.provenance
        case .cluster(let i): i.provenance; case .taskRun(let i): i.provenance; case .decision(let i): i.provenance
        case .hookRun(let i): i.provenance; case .notification(let i): i.provenance; case .peerMessage(let i): i.provenance
        case .compactBoundary(let i): i.provenance; case .sentFile(let i): i.provenance; case .turnSummary(let i): i.provenance
        case .opaque(let i): i.provenance
        }
    }
    public var category: TimelineCategory {
        switch self {
        case .userMessage: .userMessage; case .assistantMessage: .assistantMessage; case .toolCall: .toolCall
        case .cluster: .cluster; case .taskRun: .taskRun; case .decision: .decision
        case .hookRun: .hookRun; case .notification: .notification; case .peerMessage: .peerMessage
        case .compactBoundary: .compactBoundary; case .sentFile: .sentFile; case .turnSummary: .turnSummary
        case .opaque: .opaque
        }
    }
}
