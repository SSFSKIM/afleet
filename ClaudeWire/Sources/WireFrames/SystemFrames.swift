import Foundation

// Every `system` frame is `Lossless<XFields>`: the wire keys the typings declare are typed, and
// anything the CLI adds lands in `additional` so re-encoding reproduces the line key for key.
// Field names come from `sdk.d.ts` 0.3.259; Swift properties are camelCase with explicit CodingKeys.
// `uuid` and `session_id` are declared on every system payload.

public struct MCPServerStatus: Codable, Hashable, Sendable {
    public var name: String
    public var status: String
    public init(name: String, status: String) { self.name = name; self.status = status }
}

// MARK: - init

public struct SystemInitFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var cwd: String; public var sessionID: String
    public var tools: [String]; public var mcpServers: [MCPServerStatus]; public var model: String; public var permissionMode: String
    public var slashCommands: [String]; public var terminalSlashCommands: [String]?; public var apiKeySource: String; public var claudeCodeVersion: String
    public var outputStyle: String; public var agents: [String]?; public var skills: [String]; public var plugins: [JSONValue]; public var capabilities: [String]?
    public var fastModeState: String?; public var fastModeDisabledReason: String?; public var effort: String?; public var betas: [String]?
    public var messagingSocketPath: String?; public var uuid: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, cwd, sessionID = "session_id", tools, mcpServers = "mcp_servers", model, permissionMode, slashCommands = "slash_commands",
             terminalSlashCommands = "terminal_slash_commands", apiKeySource, claudeCodeVersion = "claude_code_version", outputStyle = "output_style",
             agents, skills, plugins, capabilities, fastModeState = "fast_mode_state", fastModeDisabledReason = "fast_mode_disabled_reason", effort, betas,
             messagingSocketPath = "messaging_socket_path", uuid
    }
}
public typealias SystemInit = Lossless<SystemInitFields>

// MARK: - session and permission

public struct SessionStateChangedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var state: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, state, uuid, sessionID = "session_id" }
}
public typealias SessionStateChanged = Lossless<SessionStateChangedFields>

public struct PermissionDeniedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var toolName: String; public var toolUseID: String; public var message: String
    public var agentID: String?; public var decisionReasonType: String?; public var decisionReason: String?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, toolName = "tool_name", toolUseID = "tool_use_id", message, agentID = "agent_id",
             decisionReasonType = "decision_reason_type", decisionReason = "decision_reason", uuid, sessionID = "session_id"
    }
}
public typealias PermissionDenied = Lossless<PermissionDeniedFields>

// MARK: - tasks

public struct TaskStartedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var taskID: String; public var toolUseID: String?; public var description: String
    public var subagentType: String?; public var isBackgrounded: Bool?; public var spawnDepth: Int?; public var taskType: String?; public var workflowName: String?
    public var prompt: String?; public var skipTranscript: Bool?; public var ambient: Bool?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, taskID = "task_id", toolUseID = "tool_use_id", description, subagentType = "subagent_type", isBackgrounded = "is_backgrounded",
             spawnDepth = "spawn_depth", taskType = "task_type", workflowName = "workflow_name", prompt, skipTranscript = "skip_transcript", ambient, uuid, sessionID = "session_id"
    }
}
public typealias TaskStarted = Lossless<TaskStartedFields>

public struct TaskUpdatedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var taskID: String; public var patch: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, taskID = "task_id", patch, uuid, sessionID = "session_id" }
}
public typealias TaskUpdated = Lossless<TaskUpdatedFields>

public struct TaskProgressFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var taskID: String; public var toolUseID: String?; public var description: String
    public var subagentType: String?; public var usage: JSONValue; public var lastToolName: String?; public var summary: String?
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, taskID = "task_id", toolUseID = "tool_use_id", description, subagentType = "subagent_type", usage,
             lastToolName = "last_tool_name", summary, uuid, sessionID = "session_id"
    }
}
public typealias TaskProgress = Lossless<TaskProgressFields>

public struct TaskNotificationFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var taskID: String; public var toolUseID: String?; public var status: String
    public var outputFile: String; public var summary: String; public var usage: JSONValue?; public var resourceLinks: JSONValue?
    public var skipTranscript: Bool?; public var ambient: Bool?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, taskID = "task_id", toolUseID = "tool_use_id", status, outputFile = "output_file", summary, usage,
             resourceLinks = "resource_links", skipTranscript = "skip_transcript", ambient, uuid, sessionID = "session_id"
    }
}
public typealias TaskNotification = Lossless<TaskNotificationFields>

public struct BackgroundTasksChangedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var tasks: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, tasks, uuid, sessionID = "session_id" }
}
public typealias BackgroundTasksChanged = Lossless<BackgroundTasksChangedFields>

// MARK: - hooks

public struct HookStartedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var hookID: String; public var hookName: String; public var hookEvent: String
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, hookID = "hook_id", hookName = "hook_name", hookEvent = "hook_event", uuid, sessionID = "session_id"
    }
}
public typealias HookStarted = Lossless<HookStartedFields>

public struct HookProgressFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var hookID: String; public var hookName: String; public var hookEvent: String
    public var stdout: String; public var stderr: String; public var output: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, hookID = "hook_id", hookName = "hook_name", hookEvent = "hook_event", stdout, stderr, output, uuid, sessionID = "session_id"
    }
}
public typealias HookProgress = Lossless<HookProgressFields>

public struct HookResponseFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var hookID: String; public var hookName: String; public var hookEvent: String
    public var output: String; public var stdout: String; public var stderr: String; public var exitCode: Int?; public var outcome: String
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, hookID = "hook_id", hookName = "hook_name", hookEvent = "hook_event", output, stdout, stderr,
             exitCode = "exit_code", outcome, uuid, sessionID = "session_id"
    }
}
public typealias HookResponse = Lossless<HookResponseFields>

// MARK: - turn lifecycle

public struct CompactBoundaryFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var compactMetadata: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, compactMetadata = "compact_metadata", uuid, sessionID = "session_id" }
}
public typealias CompactBoundary = Lossless<CompactBoundaryFields>

/// `status` is a string or `null` on the wire, so it is `JSONValue` rather than `String?`.
public struct StatusFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var status: JSONValue; public var permissionMode: String?
    public var compactResult: String?; public var compactError: String?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, status, permissionMode, compactResult = "compact_result", compactError = "compact_error", uuid, sessionID = "session_id"
    }
}
public typealias StatusFrame = Lossless<StatusFields>

/// `error_status` is an HTTP status or `null` for a connection error, so it is `JSONValue`.
public struct APIRetryFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var attempt: Int; public var maxRetries: Int; public var retryDelayMs: Int
    public var errorStatus: JSONValue; public var error: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, attempt, maxRetries = "max_retries", retryDelayMs = "retry_delay_ms", errorStatus = "error_status", error, uuid, sessionID = "session_id"
    }
}
public typealias APIRetry = Lossless<APIRetryFields>

public struct ControlRequestProgressFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var requestID: String; public var status: String
    public var attempt: Int?; public var maxRetries: Int?; public var retryDelayMs: Int?; public var errorStatus: JSONValue?
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, requestID = "request_id", status, attempt, maxRetries = "max_retries", retryDelayMs = "retry_delay_ms",
             errorStatus = "error_status", uuid, sessionID = "session_id"
    }
}
public typealias ControlRequestProgress = Lossless<ControlRequestProgressFields>

// MARK: - model fallbacks

/// `request_id` is nullable but always present (schema `i().nullable()`, unchanged in 2.1.257 and
/// 2.1.258): the server refusal lane emits it as null. Declared `String?` like `parent_tool_use_id`,
/// so `Lossless.explicitNulls` re-emits the null and the frame stays typed.
public struct ModelRefusalFallbackFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var trigger: String; public var direction: String; public var scope: String?
    public var originalModel: String; public var fallbackModel: String; public var requestID: String?
    public var apiRefusalCategory: String?; public var apiRefusalExplanation: String?
    public var retractedMessageUUIDs: [String]?; public var refusedUserMessageUUID: String?; public var content: String
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, trigger, direction, scope, originalModel = "original_model", fallbackModel = "fallback_model", requestID = "request_id",
             apiRefusalCategory = "api_refusal_category", apiRefusalExplanation = "api_refusal_explanation",
             retractedMessageUUIDs = "retracted_message_uuids", refusedUserMessageUUID = "refused_user_message_uuid", content, uuid, sessionID = "session_id"
    }
}
public typealias ModelRefusalFallback = Lossless<ModelRefusalFallbackFields>

/// `request_id` is nullable but always present, as on `model_refusal_fallback`.
public struct ModelRefusalNoFallbackFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var originalModel: String; public var requestID: String?
    public var apiRefusalCategory: String?; public var apiRefusalExplanation: String?; public var refusedUserMessageUUID: String?
    public var content: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, originalModel = "original_model", requestID = "request_id", apiRefusalCategory = "api_refusal_category",
             apiRefusalExplanation = "api_refusal_explanation", refusedUserMessageUUID = "refused_user_message_uuid", content, uuid, sessionID = "session_id"
    }
}
public typealias ModelRefusalNoFallback = Lossless<ModelRefusalNoFallbackFields>

/// Not in the public union; modelled from the bundle schema (spec §6.3).
public struct ModelConsentFallbackFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var choice: String; public var originalModel: String
    public var originalModelName: String?; public var fallbackModel: String; public var persistedAsDefault: Bool
    public var content: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, choice, originalModel = "original_model", originalModelName = "original_model_name", fallbackModel = "fallback_model",
             persistedAsDefault = "persisted_as_default", content, uuid, sessionID = "session_id"
    }
}
public typealias ModelConsentFallback = Lossless<ModelConsentFallbackFields>

// MARK: - local output, plugins, tokens, teardown

public struct LocalCommandOutputFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var content: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, content, uuid, sessionID = "session_id" }
}
public typealias LocalCommandOutput = Lossless<LocalCommandOutputFields>

public struct PluginInstallFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var status: String; public var name: String?; public var error: String?
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, status, name, error, uuid, sessionID = "session_id" }
}
public typealias PluginInstall = Lossless<PluginInstallFields>

public struct ThinkingTokensFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var estimatedTokens: Int; public var estimatedTokensDelta: Int
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, estimatedTokens = "estimated_tokens", estimatedTokensDelta = "estimated_tokens_delta", uuid, sessionID = "session_id"
    }
}
public typealias ThinkingTokens = Lossless<ThinkingTokensFields>

public struct WorkerShuttingDownFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var reason: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, reason, uuid, sessionID = "session_id" }
}
public typealias WorkerShuttingDown = Lossless<WorkerShuttingDownFields>

// MARK: - catalogue and notification surfaces

public struct CommandsChangedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var commands: JSONValue; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, commands, uuid, sessionID = "session_id" }
}
public typealias CommandsChanged = Lossless<CommandsChangedFields>

public struct NotificationFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var key: String; public var text: String; public var priority: String
    public var color: String?; public var timeoutMs: Int?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, key, text, priority, color, timeoutMs = "timeout_ms", uuid, sessionID = "session_id"
    }
}
public typealias NotificationFrame = Lossless<NotificationFields>

public struct FilesPersistedFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var files: JSONValue; public var failed: JSONValue
    public var processedAt: String; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, files, failed, processedAt = "processed_at", uuid, sessionID = "session_id"
    }
}
public typealias FilesPersisted = Lossless<FilesPersistedFields>

public struct MemoryRecallFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var mode: String; public var memories: JSONValue
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, mode, memories, uuid, sessionID = "session_id" }
}
public typealias MemoryRecall = Lossless<MemoryRecallFields>

public struct ElicitationCompleteFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var mcpServerName: String; public var elicitationID: String
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, mcpServerName = "mcp_server_name", elicitationID = "elicitation_id", uuid, sessionID = "session_id"
    }
}
public typealias ElicitationComplete = Lossless<ElicitationCompleteFields>

/// `key` is an object on the wire — `{projectKey, sessionId, subpath?}`
/// [2.1.258 `cli.pretty.js` schema `Kie`] — so it is `JSONValue`, not `String`.
public struct MirrorErrorFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var error: String; public var key: JSONValue
    public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, subtype, error, key, uuid, sessionID = "session_id" }
}
public typealias MirrorError = Lossless<MirrorErrorFields>

public struct InformationalFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String; public var content: String; public var level: String
    public var toolUseID: String?; public var preventContinuation: Bool?; public var uuid: String; public var sessionID: String
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, content, level, toolUseID = "tool_use_id", preventContinuation = "prevent_continuation", uuid, sessionID = "session_id"
    }
}
public typealias Informational = Lossless<InformationalFields>

// MARK: - the frame

public enum SystemFrame: Sendable {
    case initialize(SystemInit), sessionStateChanged(SessionStateChanged), permissionDenied(PermissionDenied)
    case taskStarted(TaskStarted), taskUpdated(TaskUpdated), taskProgress(TaskProgress), taskNotification(TaskNotification)
    case backgroundTasksChanged(BackgroundTasksChanged), hookStarted(HookStarted), hookProgress(HookProgress), hookResponse(HookResponse)
    case compactBoundary(CompactBoundary), status(StatusFrame), apiRetry(APIRetry), controlRequestProgress(ControlRequestProgress)
    case modelRefusalFallback(ModelRefusalFallback), modelRefusalNoFallback(ModelRefusalNoFallback), modelConsentFallback(ModelConsentFallback)
    case localCommandOutput(LocalCommandOutput), pluginInstall(PluginInstall), thinkingTokens(ThinkingTokens), workerShuttingDown(WorkerShuttingDown)
    case commandsChanged(CommandsChanged), notification(NotificationFrame), filesPersisted(FilesPersisted), memoryRecall(MemoryRecall)
    case elicitationComplete(ElicitationComplete), mirrorError(MirrorError), informational(Informational)
    case opaque(subtype: String, JSONValue)

    /// Declared keys per subtype, for the typings drift test (Task 11): subtype → Fields.declaredKeys.
    public static let declaredKeys: [String: [String]] = [
        "init": SystemInitFields.declaredKeys, "session_state_changed": SessionStateChangedFields.declaredKeys,
        "permission_denied": PermissionDeniedFields.declaredKeys, "task_started": TaskStartedFields.declaredKeys,
        "task_updated": TaskUpdatedFields.declaredKeys, "task_progress": TaskProgressFields.declaredKeys,
        "task_notification": TaskNotificationFields.declaredKeys, "background_tasks_changed": BackgroundTasksChangedFields.declaredKeys,
        "hook_started": HookStartedFields.declaredKeys, "hook_progress": HookProgressFields.declaredKeys, "hook_response": HookResponseFields.declaredKeys,
        "compact_boundary": CompactBoundaryFields.declaredKeys, "status": StatusFields.declaredKeys, "api_retry": APIRetryFields.declaredKeys,
        "control_request_progress": ControlRequestProgressFields.declaredKeys, "model_refusal_fallback": ModelRefusalFallbackFields.declaredKeys,
        "model_refusal_no_fallback": ModelRefusalNoFallbackFields.declaredKeys, "model_consent_fallback": ModelConsentFallbackFields.declaredKeys,
        "local_command_output": LocalCommandOutputFields.declaredKeys, "plugin_install": PluginInstallFields.declaredKeys,
        "thinking_tokens": ThinkingTokensFields.declaredKeys, "worker_shutting_down": WorkerShuttingDownFields.declaredKeys,
        "commands_changed": CommandsChangedFields.declaredKeys, "notification": NotificationFields.declaredKeys,
        "files_persisted": FilesPersistedFields.declaredKeys, "memory_recall": MemoryRecallFields.declaredKeys,
        "elicitation_complete": ElicitationCompleteFields.declaredKeys, "mirror_error": MirrorErrorFields.declaredKeys,
        "informational": InformationalFields.declaredKeys,
    ]

    /// The routing table: wire subtype → decoder. One entry per case above.
    static let routes: [String: @Sendable (Data) throws -> SystemFrame] = [
        "init": { .initialize(try JSONDecoder().decode(SystemInit.self, from: $0)) },
        "session_state_changed": { .sessionStateChanged(try JSONDecoder().decode(SessionStateChanged.self, from: $0)) },
        "permission_denied": { .permissionDenied(try JSONDecoder().decode(PermissionDenied.self, from: $0)) },
        "task_started": { .taskStarted(try JSONDecoder().decode(TaskStarted.self, from: $0)) },
        "task_updated": { .taskUpdated(try JSONDecoder().decode(TaskUpdated.self, from: $0)) },
        "task_progress": { .taskProgress(try JSONDecoder().decode(TaskProgress.self, from: $0)) },
        "task_notification": { .taskNotification(try JSONDecoder().decode(TaskNotification.self, from: $0)) },
        "background_tasks_changed": { .backgroundTasksChanged(try JSONDecoder().decode(BackgroundTasksChanged.self, from: $0)) },
        "hook_started": { .hookStarted(try JSONDecoder().decode(HookStarted.self, from: $0)) },
        "hook_progress": { .hookProgress(try JSONDecoder().decode(HookProgress.self, from: $0)) },
        "hook_response": { .hookResponse(try JSONDecoder().decode(HookResponse.self, from: $0)) },
        "compact_boundary": { .compactBoundary(try JSONDecoder().decode(CompactBoundary.self, from: $0)) },
        "status": { .status(try JSONDecoder().decode(StatusFrame.self, from: $0)) },
        "api_retry": { .apiRetry(try JSONDecoder().decode(APIRetry.self, from: $0)) },
        "control_request_progress": { .controlRequestProgress(try JSONDecoder().decode(ControlRequestProgress.self, from: $0)) },
        "model_refusal_fallback": { .modelRefusalFallback(try JSONDecoder().decode(ModelRefusalFallback.self, from: $0)) },
        "model_refusal_no_fallback": { .modelRefusalNoFallback(try JSONDecoder().decode(ModelRefusalNoFallback.self, from: $0)) },
        "model_consent_fallback": { .modelConsentFallback(try JSONDecoder().decode(ModelConsentFallback.self, from: $0)) },
        "local_command_output": { .localCommandOutput(try JSONDecoder().decode(LocalCommandOutput.self, from: $0)) },
        "plugin_install": { .pluginInstall(try JSONDecoder().decode(PluginInstall.self, from: $0)) },
        "thinking_tokens": { .thinkingTokens(try JSONDecoder().decode(ThinkingTokens.self, from: $0)) },
        "worker_shutting_down": { .workerShuttingDown(try JSONDecoder().decode(WorkerShuttingDown.self, from: $0)) },
        "commands_changed": { .commandsChanged(try JSONDecoder().decode(CommandsChanged.self, from: $0)) },
        "notification": { .notification(try JSONDecoder().decode(NotificationFrame.self, from: $0)) },
        "files_persisted": { .filesPersisted(try JSONDecoder().decode(FilesPersisted.self, from: $0)) },
        "memory_recall": { .memoryRecall(try JSONDecoder().decode(MemoryRecall.self, from: $0)) },
        "elicitation_complete": { .elicitationComplete(try JSONDecoder().decode(ElicitationComplete.self, from: $0)) },
        "mirror_error": { .mirrorError(try JSONDecoder().decode(MirrorError.self, from: $0)) },
        "informational": { .informational(try JSONDecoder().decode(Informational.self, from: $0)) },
    ]
    public static var knownSubtypes: Set<String> { Set(routes.keys) }

    /// Three outcomes, kept distinct so the drift counter can tell them apart:
    /// no identifiable subtype (key absent, or present but not a string) is the top-level `.opaque`
    /// with `.unknownSubtype`; an identified but unmodelled subtype is `.system(.opaque)`, a new
    /// subtype the counter can name; and a modelled subtype whose payload does not decode is the
    /// top-level `.opaque` with a `decodeFailure` reason — a known subtype with a new shape.
    static func decode(line: Data, value: JSONValue, subtype: String?) -> Frame {
        guard let subtype else {
            return .opaque(.init(raw: line, value: value, type: "system", subtype: nil, reason: .unknownSubtype))
        }
        guard let route = routes[subtype] else { return .system(.opaque(subtype: subtype, value)) }
        do { return .system(try route(line)) }
        catch {
            let f = DecodeFailure(error)
            return .opaque(.init(raw: line, value: value, type: "system", subtype: subtype, reason: .decodeFailure(field: f.field, description: f.description)))
        }
    }

    public var subtype: String {
        switch self {
        case .initialize: "init"; case .sessionStateChanged: "session_state_changed"; case .permissionDenied: "permission_denied"
        case .taskStarted: "task_started"; case .taskUpdated: "task_updated"; case .taskProgress: "task_progress"; case .taskNotification: "task_notification"
        case .backgroundTasksChanged: "background_tasks_changed"; case .hookStarted: "hook_started"; case .hookProgress: "hook_progress"; case .hookResponse: "hook_response"
        case .compactBoundary: "compact_boundary"; case .status: "status"; case .apiRetry: "api_retry"; case .controlRequestProgress: "control_request_progress"
        case .modelRefusalFallback: "model_refusal_fallback"; case .modelRefusalNoFallback: "model_refusal_no_fallback"; case .modelConsentFallback: "model_consent_fallback"
        case .localCommandOutput: "local_command_output"; case .pluginInstall: "plugin_install"; case .thinkingTokens: "thinking_tokens"; case .workerShuttingDown: "worker_shutting_down"
        case .commandsChanged: "commands_changed"; case .notification: "notification"; case .filesPersisted: "files_persisted"; case .memoryRecall: "memory_recall"
        case .elicitationComplete: "elicitation_complete"; case .mirrorError: "mirror_error"; case .informational: "informational"
        case .opaque(let s, _): s
        }
    }

    func encode() throws -> Data {
        let e = JSONEncoder()
        switch self {
        case .initialize(let v): return try e.encode(v)
        case .sessionStateChanged(let v): return try e.encode(v)
        case .permissionDenied(let v): return try e.encode(v)
        case .taskStarted(let v): return try e.encode(v)
        case .taskUpdated(let v): return try e.encode(v)
        case .taskProgress(let v): return try e.encode(v)
        case .taskNotification(let v): return try e.encode(v)
        case .backgroundTasksChanged(let v): return try e.encode(v)
        case .hookStarted(let v): return try e.encode(v)
        case .hookProgress(let v): return try e.encode(v)
        case .hookResponse(let v): return try e.encode(v)
        case .compactBoundary(let v): return try e.encode(v)
        case .status(let v): return try e.encode(v)
        case .apiRetry(let v): return try e.encode(v)
        case .controlRequestProgress(let v): return try e.encode(v)
        case .modelRefusalFallback(let v): return try e.encode(v)
        case .modelRefusalNoFallback(let v): return try e.encode(v)
        case .modelConsentFallback(let v): return try e.encode(v)
        case .localCommandOutput(let v): return try e.encode(v)
        case .pluginInstall(let v): return try e.encode(v)
        case .thinkingTokens(let v): return try e.encode(v)
        case .workerShuttingDown(let v): return try e.encode(v)
        case .commandsChanged(let v): return try e.encode(v)
        case .notification(let v): return try e.encode(v)
        case .filesPersisted(let v): return try e.encode(v)
        case .memoryRecall(let v): return try e.encode(v)
        case .elicitationComplete(let v): return try e.encode(v)
        case .mirrorError(let v): return try e.encode(v)
        case .informational(let v): return try e.encode(v)
        case .opaque(_, let value): return try e.encode(value)
        }
    }
}
