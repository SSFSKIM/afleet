import Foundation
import ClaudeWire

public struct UserRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var isMeta: Bool?; public var isCompactSummary: Bool?; public var agentId: String?
    public var sessionId: String?; public var cwd: String?; public var timestamp: String?; public var version: String?
    public var gitBranch: String?; public var slug: String?; public var entrypoint: String?; public var userType: String?
    public var promptId: String?; public var promptSource: String?; public var permissionMode: String?
    public var toolUseResult: JSONValue?; public var sourceToolAssistantUUID: String?; public var toolDenialKind: String?
    public var origin: MessageOrigin?; public var queueSkipAttachments: Bool?; public var message: UserMessage
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, logicalParentUuid, isSidechain, isMeta, isCompactSummary, agentId, sessionId, cwd, timestamp,
             version, gitBranch, slug, entrypoint, userType, promptId, promptSource, permissionMode, toolUseResult,
             sourceToolAssistantUUID, toolDenialKind, origin, queueSkipAttachments, message
    }
    public init(type: String, uuid: String, parentUuid: String? = nil, logicalParentUuid: String? = nil,
                isSidechain: Bool? = nil, isMeta: Bool? = nil, isCompactSummary: Bool? = nil, agentId: String? = nil,
                sessionId: String? = nil, cwd: String? = nil, timestamp: String? = nil, version: String? = nil,
                gitBranch: String? = nil, slug: String? = nil, entrypoint: String? = nil, userType: String? = nil,
                promptId: String? = nil, promptSource: String? = nil, permissionMode: String? = nil,
                toolUseResult: JSONValue? = nil, sourceToolAssistantUUID: String? = nil, toolDenialKind: String? = nil,
                origin: MessageOrigin? = nil, queueSkipAttachments: Bool? = nil, message: UserMessage) {
        self.type = type; self.uuid = uuid; self.parentUuid = parentUuid; self.logicalParentUuid = logicalParentUuid
        self.isSidechain = isSidechain; self.isMeta = isMeta; self.isCompactSummary = isCompactSummary; self.agentId = agentId
        self.sessionId = sessionId; self.cwd = cwd; self.timestamp = timestamp; self.version = version
        self.gitBranch = gitBranch; self.slug = slug; self.entrypoint = entrypoint; self.userType = userType
        self.promptId = promptId; self.promptSource = promptSource; self.permissionMode = permissionMode
        self.toolUseResult = toolUseResult; self.sourceToolAssistantUUID = sourceToolAssistantUUID; self.toolDenialKind = toolDenialKind
        self.origin = origin; self.queueSkipAttachments = queueSkipAttachments; self.message = message
    }
}
public typealias UserRecord = Lossless<UserRecordFields>

public struct AssistantRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var agentId: String?; public var sessionId: String?; public var cwd: String?
    public var timestamp: String?; public var version: String?; public var gitBranch: String?; public var slug: String?
    public var entrypoint: String?; public var userType: String?; public var requestId: String?; public var isApiErrorMessage: Bool?
    public var apiErrorStatus: JSONValue?; public var error: JSONValue?; public var effort: String?; public var quotaLimits: JSONValue?
    public var apiBlockIndex: Int?; public var attributionAgent: String?; public var attributionMcpServer: String?
    public var attributionMcpTool: String?; public var message: Message
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, logicalParentUuid, isSidechain, agentId, sessionId, cwd, timestamp, version, gitBranch, slug,
             entrypoint, userType, requestId, isApiErrorMessage, apiErrorStatus, error, effort, quotaLimits, apiBlockIndex,
             attributionAgent, attributionMcpServer, attributionMcpTool, message
    }
    public init(type: String, uuid: String, parentUuid: String? = nil, logicalParentUuid: String? = nil,
                isSidechain: Bool? = nil, agentId: String? = nil, sessionId: String? = nil, cwd: String? = nil,
                timestamp: String? = nil, version: String? = nil, gitBranch: String? = nil, slug: String? = nil,
                entrypoint: String? = nil, userType: String? = nil, requestId: String? = nil, isApiErrorMessage: Bool? = nil,
                apiErrorStatus: JSONValue? = nil, error: JSONValue? = nil, effort: String? = nil, quotaLimits: JSONValue? = nil,
                apiBlockIndex: Int? = nil, attributionAgent: String? = nil, attributionMcpServer: String? = nil,
                attributionMcpTool: String? = nil, message: Message) {
        self.type = type; self.uuid = uuid; self.parentUuid = parentUuid; self.logicalParentUuid = logicalParentUuid
        self.isSidechain = isSidechain; self.agentId = agentId; self.sessionId = sessionId; self.cwd = cwd
        self.timestamp = timestamp; self.version = version; self.gitBranch = gitBranch; self.slug = slug
        self.entrypoint = entrypoint; self.userType = userType; self.requestId = requestId; self.isApiErrorMessage = isApiErrorMessage
        self.apiErrorStatus = apiErrorStatus; self.error = error; self.effort = effort; self.quotaLimits = quotaLimits
        self.apiBlockIndex = apiBlockIndex; self.attributionAgent = attributionAgent; self.attributionMcpServer = attributionMcpServer
        self.attributionMcpTool = attributionMcpTool; self.message = message
    }
}
public typealias AssistantRecord = Lossless<AssistantRecordFields>

public struct AttachmentRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var isSidechain: Bool?
    public var agentId: String?; public var sessionId: String?; public var cwd: String?; public var timestamp: String?
    public var version: String?; public var gitBranch: String?; public var slug: String?; public var entrypoint: String?
    public var userType: String?; public var rendered: JSONValue?; public var attachment: JSONValue
    public var attachmentType: String? { attachment["type"]?.stringValue }
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, isSidechain, agentId, sessionId, cwd, timestamp, version, gitBranch, slug, entrypoint, userType, rendered, attachment
    }
    public init(type: String, uuid: String, parentUuid: String? = nil, isSidechain: Bool? = nil,
                agentId: String? = nil, sessionId: String? = nil, cwd: String? = nil, timestamp: String? = nil,
                version: String? = nil, gitBranch: String? = nil, slug: String? = nil, entrypoint: String? = nil,
                userType: String? = nil, rendered: JSONValue? = nil, attachment: JSONValue) {
        self.type = type; self.uuid = uuid; self.parentUuid = parentUuid; self.isSidechain = isSidechain
        self.agentId = agentId; self.sessionId = sessionId; self.cwd = cwd; self.timestamp = timestamp
        self.version = version; self.gitBranch = gitBranch; self.slug = slug; self.entrypoint = entrypoint
        self.userType = userType; self.rendered = rendered; self.attachment = attachment
    }
}
public typealias AttachmentRecord = Lossless<AttachmentRecordFields>

/// On-disk `system` records (`compact_boundary`, `informational`, `local_command`, `turn_duration`, `stop_hook_summary`, …).
/// None appears in the corpus; the fields are the bundle's writer fields and parity §35.1.
public struct SystemRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String?; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var agentId: String?; public var sessionId: String?; public var cwd: String?; public var timestamp: String?
    public var content: String?; public var level: String?; public var durationMs: Int?; public var toolUseID: String?
    public var preventContinuation: Bool?; public var compactMetadata: JSONValue?; public var isMeta: Bool?
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, uuid, parentUuid, logicalParentUuid, isSidechain, agentId, sessionId, cwd, timestamp, content, level,
             durationMs, toolUseID, preventContinuation, compactMetadata, isMeta
    }
    public init(type: String, subtype: String? = nil, uuid: String, parentUuid: String? = nil, logicalParentUuid: String? = nil,
                isSidechain: Bool? = nil, agentId: String? = nil, sessionId: String? = nil, cwd: String? = nil, timestamp: String? = nil,
                content: String? = nil, level: String? = nil, durationMs: Int? = nil, toolUseID: String? = nil,
                preventContinuation: Bool? = nil, compactMetadata: JSONValue? = nil, isMeta: Bool? = nil) {
        self.type = type; self.subtype = subtype; self.uuid = uuid; self.parentUuid = parentUuid; self.logicalParentUuid = logicalParentUuid
        self.isSidechain = isSidechain; self.agentId = agentId; self.sessionId = sessionId; self.cwd = cwd; self.timestamp = timestamp
        self.content = content; self.level = level; self.durationMs = durationMs; self.toolUseID = toolUseID
        self.preventContinuation = preventContinuation; self.compactMetadata = compactMetadata; self.isMeta = isMeta
    }
}
public typealias SystemRecord = Lossless<SystemRecordFields>

/// `progress` is a conversation record the engine never stores as a message (parity §35.1). Modelled so it is recognised, never rendered.
public struct ProgressRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var timestamp: String?; public var data: JSONValue?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, uuid, parentUuid, timestamp, data }
    public init(type: String, uuid: String, parentUuid: String? = nil, timestamp: String? = nil, data: JSONValue? = nil) {
        self.type = type; self.uuid = uuid; self.parentUuid = parentUuid; self.timestamp = timestamp; self.data = data
    }
}
public typealias ProgressRecord = Lossless<ProgressRecordFields>

/// The `.meta.json` body plus `type: "agent_metadata"`, as the mirror carries it (fixtures `explore-depth-1`, `nested-depth-2`).
public struct AgentMetadataFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String?; public var agentType: String; public var description: String; public var toolUseId: String?
    public var spawnDepth: Int?; public var parentAgentId: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, agentType, description, toolUseId, spawnDepth, parentAgentId }
    public init(type: String? = nil, agentType: String, description: String, toolUseId: String? = nil,
                spawnDepth: Int? = nil, parentAgentId: String? = nil) {
        self.type = type; self.agentType = agentType; self.description = description; self.toolUseId = toolUseId
        self.spawnDepth = spawnDepth; self.parentAgentId = parentAgentId
    }
}
public typealias AgentMetadataRecord = Lossless<AgentMetadataFields>

/// Every session-state kind shares one lossless shape; typed accessors read the fields the reducer and the index use.
public struct SessionStateFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var sessionId: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, sessionId }
    public init(type: String, sessionId: String? = nil) { self.type = type; self.sessionId = sessionId }
}
public typealias SessionStateRecord = Lossless<SessionStateFields>
public extension Lossless where Fields == SessionStateFields {
    var lastPrompt: String? { additional["lastPrompt"]?.stringValue }
    /// `nil` when the key is absent; `.some(nil)` when it was an explicit null (cleared to empty, parity §35.4);
    /// `.some(id)` when it carried a string. `leafUuid` is not a declared key, so an explicit null arrives as
    /// `additional["leafUuid"] == .null`; the `explicitNulls` check is here for the day it becomes declared.
    /// A key present with any other JSON type (a number, an object) is malformed — it is neither a leaf uuid nor
    /// a recorded clear, and this engine has never written one — so it reads as absent rather than as a clear,
    /// which is the reading that cannot silently erase a leaf.
    var leafUuid: String?? {
        if explicitNulls.contains("leafUuid") { return .some(nil) }
        guard let value = additional["leafUuid"] else { return nil }
        if case .null = value { return .some(nil) }
        guard let text = value.stringValue else { return nil }
        return .some(text)
    }
    var explicit: Bool { additional["explicit"]?.boolValue ?? false }
    var rewound: Bool { additional["rewound"]?.boolValue ?? false }
    var aiTitle: String? { additional["aiTitle"]?.stringValue }
    var customTitle: String? { additional["customTitle"]?.stringValue }
    var summary: String? { additional["summary"]?.stringValue }
    var relocatedCwd: String? { additional["relocatedCwd"]?.stringValue }
    var mode: String? { additional["mode"]?.stringValue }
    var atis: String? { additional["atis"]?.stringValue }
    var continuedInSessionId: String? { additional["continuedInSessionId"]?.stringValue }   // 2.1.258 line 246351: the destination; this record's `sessionId` is the source, never read here
    var agentName: String? { additional["agentName"]?.stringValue }
    var tag: String? { additional["tag"]?.stringValue }
    var messageId: String? { additional["messageId"]?.stringValue }
    var operation: String? { additional["operation"]?.stringValue }
    var costState: JSONValue? { fields.type == "cost-state" ? .object(additional) : nil }
}
