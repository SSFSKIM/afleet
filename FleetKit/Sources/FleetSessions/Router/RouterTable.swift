import Foundation
import AfleetCore
import ClaudeWire

/// What a local command does, as a value the executor interprets. Single-request strategies name their spec; multi-step
/// strategies name the sequence, so a test checks each against the fixture that recorded it rather than checking that an
/// enum case is an enum case.
public enum RouteStrategy: Hashable, Sendable {
    case applyFlagSetting(key: String)            // apply_flag_settings {settings: {key: value}} then get_settings.effective
    case setModel                                  // set_model {model}
    case setPermissionMode                         // set_permission_mode {mode}; the bare form is `.permissionsView`
    case renameSession                             // rename_session {title}
    case setCwd                                    // set_cwd {path}; needs_trust → repeat with trust_accepted + trusted_directory
    case interrupt                                 // interrupt
    case sideQuestion                              // side_question {prompt}
    case rewind                                    // rewind_files dry_run → confirm → rewind_files apply → rewind_conversation
    case login                                     // claude_authenticate → open automaticUrl → claude_oauth_wait_for_completion
    case permissionsView                           // get_settings → read-only rules view
    case mcpPopover                                // mcp_status → popover
    case memoryFiles                               // get_context_usage.memoryFiles → Files tab
    case lifecycle(LifecycleActionName)            // fork, sendToBackground, stopEverything, backgroundAll, logout
    case restart                                   // a RestartRequest built from the arguments
    case text                                      // pass through; frames render the result
    case native(String)                            // UI-only: picker, focus, tasks list, agents list
}
public enum LifecycleActionName: String, Hashable, Sendable { case fork, sendToBackground, stopEverything, backgroundAll, logout }
public enum ReadbackSource: String, Hashable, Sendable { case getSettingsApplied, getSettingsEffective, handshakePermissionMode, fastModeState, none }
public struct LocalCommand: Hashable, Sendable {
    public let name: String; public let strategy: RouteStrategy; public let readback: ReadbackSource; public let explanation: String
    public init(name: String, strategy: RouteStrategy, readback: ReadbackSource, explanation: String) {
        self.name = name; self.strategy = strategy; self.readback = readback; self.explanation = explanation
    }
}
public enum RouterTable {
    public static let local: [LocalCommand] = [
        .init(name: "/model", strategy: .setModel, readback: .getSettingsApplied, explanation: "Changes the model for this channel without a Claude turn."),
        .init(name: "/permissions", strategy: .setPermissionMode, readback: .handshakePermissionMode, explanation: "Changes the permission mode; on its own opens the read-only rules view."),
        .init(name: "/effort", strategy: .applyFlagSetting(key: "effortLevel"), readback: .getSettingsEffective, explanation: "Changes the effort level; max cannot be set mid-session."),
        .init(name: "/rename", strategy: .renameSession, readback: .none, explanation: "Renames the channel and the transcript's title."),
        .init(name: "/add-dir", strategy: .restart, readback: .none, explanation: "Adds a directory by restarting this channel under the same session id."),
        .init(name: "/agent", strategy: .applyFlagSetting(key: "agent"), readback: .getSettingsEffective, explanation: "Switches the agent from the next turn."),
        .init(name: "/cd", strategy: .setCwd, readback: .none, explanation: "Changes the working directory; an untrusted directory asks for trust first."),
        .init(name: "/fast", strategy: .applyFlagSetting(key: "fastMode"), readback: .fastModeState, explanation: "Turns fast mode on or off."),
        .init(name: "/config", strategy: .text, readback: .none, explanation: "Runs in the engine; the persisted setting is read back with get_settings."),
        .init(name: "/login", strategy: .login, readback: .none, explanation: "Signs in through the Browser tab."),
        .init(name: "/logout", strategy: .lifecycle(.logout), readback: .none, explanation: "Signs out every owned channel and afleet-launched job on this machine."),
        .init(name: "/color", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/clear", strategy: .text, readback: .none, explanation: "Clears the conversation; the timeline resets on conversation_reset."),
        .init(name: "/rewind", strategy: .rewind, readback: .none, explanation: "Rewinds the conversation and, after a dry run you confirm, the files."),
        .init(name: "/fork", strategy: .lifecycle(.fork), readback: .none, explanation: "Opens a new channel forked from this session."),
        .init(name: "/background", strategy: .lifecycle(.sendToBackground), readback: .none, explanation: "Hands this session to a background job."),
        .init(name: "/stop", strategy: .interrupt, readback: .none, explanation: "Stops the current turn; Stop everything also stops background tasks."),
        .init(name: "/tasks", strategy: .native("tasks"), readback: .none, explanation: "Shows the running tasks with per-task Stop."),
        .init(name: "/mcp", strategy: .mcpPopover, readback: .none, explanation: "Shows MCP servers and their state."),
        .init(name: "/memory", strategy: .memoryFiles, readback: .none, explanation: "Opens the memory files in the Files tab."),
        .init(name: "/btw", strategy: .sideQuestion, readback: .none, explanation: "Asks a side question without affecting the conversation."),
        .init(name: "/agents", strategy: .native("agents"), readback: .none, explanation: "Lists the agents from the handshake."),
        .init(name: "/resume", strategy: .native("switcher"), readback: .none, explanation: "Focuses the channel switcher."),
        .init(name: "/compact", strategy: .text, readback: .none, explanation: "Compacts in the engine; renders as a divider."),
        .init(name: "/context", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/cost", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/usage", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
    ]
    /// The engine's refusal of a slash command it will not run headless, of which there are **two** shapes, both
    /// anchored at both ends because the match is against the whole assistant text (`RefusalInterceptor`).
    ///
    /// `bareRefusalPattern` is the plain one, built at 2.1.263 `cli.pretty.js:540254` for any command missing from
    /// the headless dispatcher (*A-28*). `interactivePanelRefusalPattern` is the second, built at 2.1.263
    /// `cli.pretty.js:540305` for a command whose UX is a full-screen panel; it is a *different* sentence, and it
    /// ends by telling the user to run the command from the Claude Code terminal — the one thing §7.7 says afleet
    /// never shows. Matching only the first left that instruction reaching the channel and the drift log reading
    /// zero for the whole class (C6.2's `[parent-impact]` against X10).
    public static let bareRefusalPattern = #"^/([A-Za-z0-9:_-]+) isn't available in this environment\.$"#
    public static let interactivePanelRefusalPattern =
        #"^/([A-Za-z0-9:_-]+) opens an interactive panel and isn't available in this environment\. Run it from the Claude Code terminal instead\.$"#

    /// The one row of that name, or nil. The composer looks a typed command up here and renders its explanation;
    /// it re-implements no mapping (contract X10).
    public static func command(named name: String) -> LocalCommand? { local.first { $0.name == name } }

    /// afleet's copy for `/permissions <something that is not a mode>`. The modes are named so the user can see
    /// what they meant to type; they are `PermissionMode`'s own cases, so this list cannot drift from the engine's.
    public static func explanation(forUnknownMode mode: String) -> String {
        "\(mode) is not a permission mode. The modes are " + PermissionMode.allCases.map(\.rawValue).joined(separator: ", ")
            + ". Send /permissions on its own to see the current settings."
    }

    /// What each terminal-only command does on the terminal's own screen, and why afleet carries no equivalent.
    ///
    /// The three keys are the names the recorded `system/init.terminal_slash_commands` actually lists (fixtures
    /// `control-shapes`, `zero-cost`); anything else the engine tags takes the fallback below. §7.7 asks for what
    /// the command does or why it is absent, so a name whose reason is known says the reason rather than the
    /// generic sentence — and no line here sends the user out of the app.
    private static let terminalOnlyReasons: [String: String] = [
        "/doctor": "/doctor draws the CLI's installation and health report on the terminal's own screen, which afleet has no equivalent of yet.",
        "/color": "/color repaints the CLI's terminal theme, and afleet's channels are drawn by the app rather than by that screen.",
        "/reload-plugins": "/reload-plugins reloads plugins into a running terminal screen; afleet picks a plugin change up when the channel next restarts.",
    ]

    /// afleet's copy for a command the engine reports in `terminal_slash_commands`: the router refuses it here
    /// rather than sending it for the engine to refuse.
    public static func explanation(forTerminalOnly name: String) -> String {
        terminalOnlyReasons[name]
            ?? "\(name) drives a screen Claude Code draws in the terminal itself, and afleet has no equivalent of that screen."
    }

    /// afleet's copy for a refusal the engine got to send anyway — the drift path, where a command afleet does not
    /// route locally was passed through as text and refused (§7.7).
    ///
    /// It is *not* the terminal-only sentence: this command may be one afleet is expected to run here, so the row's
    /// own explanation is preferred when the table carries one, then a known terminal-only reason, and only then a
    /// sentence per refusal shape saying why it is absent.
    public static func explanation(forDrift name: String, shape: RefusalShape) -> String {
        if let command = command(named: name) { return command.explanation }
        if let reason = terminalOnlyReasons[name] { return reason }
        switch shape {
        case .bare:
            return "\(name) is not one of the commands afleet runs here, and this engine offers no headless form of it."
        case .interactivePanel:
            return "\(name) opens one of Claude Code's full-screen panels, which afleet has no equivalent of here."
        }
    }
}

/// Which of the engine's two refusal sentences was replaced, so the drift log counts the two classes apart.
public enum RefusalShape: String, Hashable, Sendable, CaseIterable {
    /// 2.1.263 `cli.pretty.js:540254`, parent *A-28*.
    case bare
    /// 2.1.263 `cli.pretty.js:540305`.
    case interactivePanel = "interactive_panel"
}
public enum LaunchSettingMatrix {
    public static let runtimeMutable: Set<String> = ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode", "cwd"]
    public static let restartRequired: Set<String> = ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources", "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"]
}
