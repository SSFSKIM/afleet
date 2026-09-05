import Foundation
import AfleetCore
import WireFrames

/// Where a *Fork from here* truncates the source's records: `entryUUID` is the last record the fork keeps,
/// **inclusive**, and `dropsTurn` names the prompt uuid of the turn the truncation discards so the CLI can
/// refuse a fork point that swallows more (§7.4). Record uuids are plain wire strings.
public struct ForkPoint: Hashable, Sendable {
    public var entryUUID: String
    public var dropsTurn: String?
    public init(entryUUID: String, dropsTurn: String? = nil) { self.entryUUID = entryUUID; self.dropsTurn = dropsTurn }
}

/// `.forkFrom` keeps the source's records up to and including the named entry and drops everything after it;
/// the source session is left untouched.
public enum SessionStart: Hashable, Sendable {
    case new(SessionID)
    case resume(SessionID, fork: Bool)
    case forkFrom(SessionID, at: ForkPoint)
}
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
    /// Tests and recordings only: the config home to put in the child in place of the launch's own resolved
    /// one. `childEnvironment` sets `CLAUDE_CONFIG_DIR` on every launch (§6.9: one ConfigHome per launch, and
    /// the child is told which one); this field only redirects it, and is how a recording points a child at a
    /// scratch home instead of the user's.
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

    /// A caller-supplied string reaches the child as one argv token, and a token beginning with `-` is read
    /// by the CLI's parser as a further option rather than as the value it was meant to be.
    ///
    /// The hazard is not cosmetic. `-w` declares an **optional** value, so a worktree named
    /// `--allow-dangerously-skip-permissions` does not become the worktree's name — it becomes a real
    /// permission-bypass flag, with the `allowBypass` gate never consulted. Every option whose value the
    /// caller chooses goes through here, not only that one: the defect is the class, and `--model`,
    /// `--agent`, `--effort`, `-n` and `--add-dir` are the same mistake waiting for a different name.
    private static func token(_ value: String, for option: String) throws -> String {
        guard !value.hasPrefix("-") else {
            throw WireError.invalidArgument(option: option, reason: "a value beginning with '-' is parsed as an option: \(value)")
        }
        return value
    }

    /// Parent §6.1, fixed order. Throws rather than emitting a line the CLI would misparse.
    public func arguments() throws -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
                 "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        switch session {
        case .new(let id): a += ["--session-id", id.description]
        case .resume(let id, let fork): a += ["--resume", id.description]; if fork { a.append("--fork-session") }
        case .forkFrom(let id, let point):
            a += ["--resume", id.description, "--fork-session", "--resume-session-at", point.entryUUID]
            if let dropsTurn = point.dropsTurn { a += ["--resume-drops-turn", dropsTurn] }
        }
        if let model { a += ["--model", try Self.token(model, for: "--model")] }
        if let permissionMode { a += ["--permission-mode", permissionMode.rawValue] }
        if let agent { a += ["--agent", try Self.token(agent, for: "--agent")] }
        if let effort { a += ["--effort", try Self.token(effort, for: "--effort")] }
        if let name { a += ["-n", try Self.token(name, for: "-n")] }
        for d in addDirectories { a += ["--add-dir", try Self.token(d.path, for: "--add-dir")] }
        switch worktree { case .unnamed?: a.append("-w"); case .named(let n)?: a += ["-w", try Self.token(n, for: "-w")]; case nil: break }
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
    /// survives from the resolved environment, and what is added back afterwards is exactly the table's own
    /// entries, the resolved config home and the project directory name beside it, and
    /// `passedThroughConfiguration`. A list would need extending every time the engine gains a
    /// marker, and the markers reach afleet for real — §6.9's `.processFallback` arm returns afleet's
    /// own environment verbatim, so an afleet launched from inside a Claude Code session would
    /// otherwise hand `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_CHILD_SESSION` to the
    /// child, and the last of those turns transcript saving off.
    ///
    /// The scrub lives here rather than at capture because §6.9 derives ConfigHome from the captured
    /// `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME`.
    ///
    /// `configHome` is the home this launch resolved, and it is always put back after the scrub. A home is
    /// always chosen, so the child is always told which one: letting it re-derive its own default is how
    /// afleet's view of the config home and the child's come apart.
    public func childEnvironment(over base: ResolvedEnvironment, configHome: ConfigHome) -> [String: String] {
        var env = base.variables
        for key in Array(env.keys) where key.hasPrefix("CLAUDE") { env[key] = nil }
        // `ANTHROPIC_API_KEY` deliberately survives, per the parent Decision Log. afleet resolves the login
        // shell once and its sessions authenticate exactly as the user's terminal sessions do; scrubbing it
        // would split authentication so that owned channels used OAuth while adopted ones used the key, which
        // is the worse outcome. Whether a session is billing against a key at all is a separate question, and
        // it is answered separately, by `system/init.apiKeySource`.
        env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        env["CLAUDE_AUTO_BACKGROUND_TASKS"] = "1"
        env["CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK"] = "1"
        if let f = environment.questionPreviewFormat { env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"] = f }
        if environment.forkSubagents { env["CLAUDE_CODE_FORK_SUBAGENT"] = "1" }
        if environment.automodeDecisionLog { env["AUTOMODE_DECISION_LOG"] = "1" } else { env["AUTOMODE_DECISION_LOG"] = nil }
        // The scrub took the config home with it, so it is put back — always, and from the home this launch
        // resolved rather than from whatever the shell happened to hold. An override redirects it and nothing
        // else; that is what a recording uses to point a child at a scratch home.
        env["CLAUDE_CONFIG_DIR"] = (configHomeOverride ?? configHome.root).path
        // §6.9 reads the project directory name together with the config home, so it travels with the home
        // or not at all — and it is read from the **resolved record**, never from the captured environment.
        //
        // The engine honours this variable only when `CLAUDE_CONFIG_DIR` is present in the environment it
        // sees, and afleet now always injects that home, so inside an afleet child the engine's gate is
        // always open. `ConfigHome.derive` mirrors the same gate against the *captured* environment, where
        // the home is often absent: a default-home channel would therefore record no project name while
        // handing the shell's one to a child that would go on to honour it. Reading the record closes that —
        // the child gets the name exactly when afleet's own view of the home has one.
        if let projectDirName = configHome.projectDirName {
            env["CLAUDE_CODE_PROJECT_DIR_NAME"] = projectDirName
        }
        for name in Self.passedThroughConfiguration { env[name] = base.variables[name] }
        return env
    }

    /// User configuration the engine **reads** rather than sets, and which the login shell may legitimately
    /// hold: which provider a session talks to, and the output-token ceiling. The prefix scrub takes these
    /// with everything else, so they are named here to survive it.
    ///
    /// A list is right here and wrong for the markers, and the asymmetry is deliberate rather than an
    /// oversight to tidy up. A marker this list missed would make the child believe it is nested inside
    /// another session and change its behaviour silently; a provider variable this list misses produces a
    /// session talking to the wrong provider, which the very first readback shows.
    ///
    /// `CLAUDE_CODE_OAUTH_TOKEN` is deliberately absent. The engine *sets* it on its own children as a
    /// credential handoff, and an owned channel authenticates from its config home instead — inheriting it
    /// would hand a session someone else's credential.
    public static let passedThroughConfiguration: Set<String> = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_MANTLE",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
        "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
        "CLAUDE_CODE_SKIP_MANTLE_AUTH", "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH", "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
    ]
}
