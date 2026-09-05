import Foundation
import WireFrames

/// The 33 hook events of sdk.d.ts 0.3.259; raw values are the wire names.
public enum HookEvent: String, Hashable, Sendable, CaseIterable {
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure", postToolBatch = "PostToolBatch"
    case notification = "Notification", userPromptSubmit = "UserPromptSubmit", userPromptExpansion = "UserPromptExpansion"
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", stop = "Stop", stopFailure = "StopFailure"
    case subagentStart = "SubagentStart", subagentStop = "SubagentStop", preCompact = "PreCompact", postCompact = "PostCompact"
    case preModelSwitch = "PreModelSwitch", postModelSwitch = "PostModelSwitch", permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied"
    case setup = "Setup", teammateIdle = "TeammateIdle", taskCreated = "TaskCreated", taskCompleted = "TaskCompleted"
    case elicitation = "Elicitation", elicitationResult = "ElicitationResult", configChange = "ConfigChange"
    case worktreeCreate = "WorktreeCreate", worktreeRemove = "WorktreeRemove", instructionsLoaded = "InstructionsLoaded"
    case cwdChanged = "CwdChanged", fileChanged = "FileChanged", directoryAdded = "DirectoryAdded", messageDisplay = "MessageDisplay"
}
public struct HookCallbackMatcher: Hashable, Sendable {
    public var matcher: String?; public var hookCallbackIds: [String]; public var timeout: Int?
    public init(matcher: String? = nil, hookCallbackIds: [String], timeout: Int? = nil) { self.matcher = matcher; self.hookCallbackIds = hookCallbackIds; self.timeout = timeout }
    var jsonValue: JSONValue {
        var o: [String: JSONValue] = ["hookCallbackIds": .array(hookCallbackIds.map(JSONValue.string))]
        if let matcher { o["matcher"] = .string(matcher) }
        if let timeout { o["timeout"] = .integer(Int64(timeout)) }
        return .object(o)
    }
}
public extension Dictionary where Key == HookEvent, Value == [HookCallbackMatcher] {
    static var afleetDefaults: [HookEvent: [HookCallbackMatcher]] {
        [.notification: [HookCallbackMatcher(hookCallbackIds: ["afleet.notification"])],
         .configChange: [HookCallbackMatcher(hookCallbackIds: ["afleet.config-change"])]]
    }
}

public struct InitializeConfiguration: Hashable, Sendable {
    public var supportedDialogKinds: [String]
    public var perTaskStopAffordance: Bool
    public var agentProgressSummaries: Bool
    public var sdkMcpServers: [String]
    public var hooks: [HookEvent: [HookCallbackMatcher]]
    public init(supportedDialogKinds: [String] = ["refusal_fallback_prompt", "fable_overage_consent_prompt"], perTaskStopAffordance: Bool = true,
                agentProgressSummaries: Bool = true, sdkMcpServers: [String] = ["afleet"], hooks: [HookEvent: [HookCallbackMatcher]] = .afleetDefaults) {
        self.supportedDialogKinds = supportedDialogKinds; self.perTaskStopAffordance = perTaskStopAffordance
        self.agentProgressSummaries = agentProgressSummaries; self.sdkMcpServers = sdkMcpServers; self.hooks = hooks
    }
    public var registeredHookCallbackIDs: Set<String> { Set(hooks.values.flatMap { $0.flatMap(\.hookCallbackIds) }) }
    /// The "request" object of parent §6.2.
    public func payload() -> JSONValue {
        .object(["subtype": .string("initialize"),
                 "supportedDialogKinds": .array(supportedDialogKinds.map(JSONValue.string)),
                 "perTaskStopAffordance": .bool(perTaskStopAffordance),
                 "agentProgressSummaries": .bool(agentProgressSummaries),
                 "sdkMcpServers": .array(sdkMcpServers.map(JSONValue.string)),
                 "sdkMcpServerConfigs": .object(Dictionary(uniqueKeysWithValues: sdkMcpServers.map { ($0, JSONValue.object([:])) })),
                 "hooks": .object(Dictionary(uniqueKeysWithValues: hooks.map { ($0.key.rawValue, JSONValue.array($0.value.map(\.jsonValue))) }))])
    }
    public func requestLine(requestID: RequestID) throws -> Data {
        try JSONValue.object(["type": .string("control_request"), "request_id": .string(requestID.rawValue), "request": payload()]).canonicalData()
    }
}
