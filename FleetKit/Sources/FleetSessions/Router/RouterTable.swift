import Foundation
import AfleetCore
import ClaudeWire

/// What a local command does, as a value the executor interprets. Single-request strategies name their spec; multi-step
/// strategies name the sequence, so a test checks each against the fixture that recorded it rather than checking that an
/// enum case is an enum case.
public enum RouteStrategy: Hashable, Sendable {
    case applyFlagSetting(key: String)            // apply_flag_settings {settings: {key: value}} then get_settings.effective_keys
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
public enum ReadbackSource: String, Hashable, Sendable { case getSettingsApplied, getSettingsEffectiveKeys, handshakePermissionMode, fastModeState, none }
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
        .init(name: "/effort", strategy: .applyFlagSetting(key: "effortLevel"), readback: .getSettingsEffectiveKeys, explanation: "Changes the effort level; max cannot be set mid-session."),
        .init(name: "/rename", strategy: .renameSession, readback: .none, explanation: "Renames the channel and the transcript's title."),
        .init(name: "/add-dir", strategy: .restart, readback: .none, explanation: "Adds a directory by restarting this channel under the same session id."),
        .init(name: "/agent", strategy: .applyFlagSetting(key: "agent"), readback: .getSettingsEffectiveKeys, explanation: "Switches the agent from the next turn."),
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
    public static let bareRefusalPattern = #"^/([A-Za-z0-9:_-]+) isn't available in this environment\.$"#

    /// The one row of that name, or nil. The composer looks a typed command up here and renders its explanation;
    /// it re-implements no mapping (contract X10).
    public static func command(named name: String) -> LocalCommand? { local.first { $0.name == name } }

    /// afleet's copy for a command the engine reports in `terminal_slash_commands`: the router refuses it here
    /// rather than sending it for the engine to refuse, and `RefusalInterceptor` puts the same sentence in place of
    /// the engine's bare refusal when one gets through anyway.
    /// afleet's copy for `/permissions <something that is not a mode>`. The modes are named so the user can see
    /// what they meant to type; they are `PermissionMode`'s own cases, so this list cannot drift from the engine's.
    public static func explanation(forUnknownMode mode: String) -> String {
        "\(mode) is not a permission mode. The modes are " + PermissionMode.allCases.map(\.rawValue).joined(separator: ", ")
            + ". Send /permissions on its own to see the current settings."
    }

    public static func explanation(forTerminalOnly name: String) -> String {
        "\(name) belongs to Claude Code's terminal interface and has no effect here. Open this session in your terminal to use it."
    }
}
public enum LaunchSettingMatrix {
    public static let runtimeMutable: Set<String> = ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode", "cwd"]
    public static let restartRequired: Set<String> = ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources", "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"]
}
