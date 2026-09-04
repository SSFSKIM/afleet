import Foundation
import AfleetCore
import WireFrames

public enum SessionStart: Hashable, Sendable { case new(SessionID), resume(SessionID, fork: Bool) }
public enum Worktree: Hashable, Sendable { case unnamed, named(String) }
public enum SettingSource: String, Hashable, Sendable { case user, project, local }

public struct ChildEnvironmentOptions: Hashable, Sendable {
    public var forkSubagents: Bool
    public var automodeDecisionLog: Bool
    /// Parent §6.1 marks this "always" and pins `markdown`; `nil` omits the variable entirely,
    /// which is only ever wanted by a probe that is measuring the engine's own default.
    public var questionPreviewFormat: String?
    public init(forkSubagents: Bool = true, automodeDecisionLog: Bool = false, questionPreviewFormat: String? = "markdown") {
        self.forkSubagents = forkSubagents; self.automodeDecisionLog = automodeDecisionLog; self.questionPreviewFormat = questionPreviewFormat
    }
}

public struct LaunchConfiguration: Hashable, Sendable {
    public var binary: URL
    public var cwd: URL
    public var session: SessionStart
    public var model: String?
    public var permissionMode: PermissionMode?
    public var agent: String?
    public var effort: String?
    public var name: String?
    public var addDirectories: [URL]
    public var worktree: Worktree?
    public var allowBypass: Bool
    public var promptSuggestions: Bool
    public var settingSources: [SettingSource]?      // nil = CLI default; [] = --setting-sources ""
    public var strictMCPConfig: Bool
    public var environment: ChildEnvironmentOptions
    /// Tests and recordings only: sets CLAUDE_CONFIG_DIR in the child. FleetKit never sets it (§6.9: one ConfigHome per launch).
    public var configHomeOverride: URL?

    public init(binary: URL, cwd: URL, session: SessionStart, model: String? = nil, permissionMode: PermissionMode? = nil, agent: String? = nil,
                effort: String? = nil, name: String? = nil, addDirectories: [URL] = [], worktree: Worktree? = nil, allowBypass: Bool = false,
                promptSuggestions: Bool = false, settingSources: [SettingSource]? = nil, strictMCPConfig: Bool = false,
                environment: ChildEnvironmentOptions = .init(), configHomeOverride: URL? = nil) {
        self.binary = binary; self.cwd = cwd; self.session = session; self.model = model; self.permissionMode = permissionMode; self.agent = agent
        self.effort = effort; self.name = name; self.addDirectories = addDirectories; self.worktree = worktree; self.allowBypass = allowBypass
        self.promptSuggestions = promptSuggestions; self.settingSources = settingSources; self.strictMCPConfig = strictMCPConfig
        self.environment = environment; self.configHomeOverride = configHomeOverride
    }

    /// Parent §6.1, fixed order.
    public func arguments() -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
                 "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        switch session {
        case .new(let id): a += ["--session-id", id.description]
        case .resume(let id, let fork): a += ["--resume", id.description]; if fork { a.append("--fork-session") }
        }
        if let model { a += ["--model", model] }
        if let permissionMode { a += ["--permission-mode", permissionMode.rawValue] }
        if let agent { a += ["--agent", agent] }
        if let effort { a += ["--effort", effort] }
        if let name { a += ["-n", name] }
        for d in addDirectories { a += ["--add-dir", d.path] }
        switch worktree { case .unnamed?: a.append("-w"); case .named(let n)?: a += ["-w", n]; case nil: break }
        if allowBypass { a.append("--allow-dangerously-skip-permissions") }
        a += ["--enable-auth-status", "--session-mirror"]
        if promptSuggestions { a += ["--prompt-suggestions", "true"] }
        if let settingSources { a += ["--setting-sources", settingSources.map(\.rawValue).joined(separator: ",")] }
        if strictMCPConfig { a.append("--strict-mcp-config") }
        return a
    }

    /// Parent §6.1's table over the resolved environment.
    ///
    /// The scrub is a prefix rule, not a list: **no** variable whose name begins with `CLAUDE`
    /// survives from the resolved environment, and only the table's own entries plus, when chosen,
    /// `CLAUDE_CONFIG_DIR` are added back. A list would need extending every time the engine gains a
    /// marker, and the markers reach afleet for real — §6.9's `.processFallback` arm returns afleet's
    /// own environment verbatim, so an afleet launched from inside a Claude Code session would
    /// otherwise hand `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_CHILD_SESSION` to the
    /// child, and the last of those turns transcript saving off.
    ///
    /// The scrub lives here rather than at capture because §6.9 derives ConfigHome from the captured
    /// `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME`.
    public func childEnvironment(over base: ResolvedEnvironment) -> [String: String] {
        var env = base.variables
        for key in Array(env.keys) where key.hasPrefix("CLAUDE") { env[key] = nil }
        env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        env["CLAUDE_AUTO_BACKGROUND_TASKS"] = "1"
        env["CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK"] = "1"
        if let f = environment.questionPreviewFormat { env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"] = f }
        if environment.forkSubagents { env["CLAUDE_CODE_FORK_SUBAGENT"] = "1" }
        if environment.automodeDecisionLog { env["AUTOMODE_DECISION_LOG"] = "1" } else { env["AUTOMODE_DECISION_LOG"] = nil }
        if let configHomeOverride { env["CLAUDE_CONFIG_DIR"] = configHomeOverride.path }
        return env
    }
}
