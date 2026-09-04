import XCTest
import AfleetCore
import WireFrames
import WireTransport

final class LaunchConfigurationTests: XCTestCase {
    private let bin = URL(fileURLWithPath: "/Users/x/.local/bin/claude")
    private let cwd = URL(fileURLWithPath: "/tmp/scratch")
    private let sid = SessionID("0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b")!

    func testNewChannelMinimalLineTokenForToken() {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        XCTAssertEqual(c.arguments(), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--session-id", "0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b",
            "--enable-auth-status", "--session-mirror",
        ])
    }
    func testEveryOptionalFlagInOrder() {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .resume(sid, fork: true), model: "opus", permissionMode: .plan, agent: "reviewer",
                                    effort: "high", name: "fix-auth", addDirectories: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")],
                                    worktree: .named("wt1"), allowBypass: true, promptSuggestions: true, settingSources: [], strictMCPConfig: true)
        XCTAssertEqual(c.arguments(), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--resume", "0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b", "--fork-session",
            "--model", "opus", "--permission-mode", "plan", "--agent", "reviewer", "--effort", "high",
            "-n", "fix-auth", "--add-dir", "/tmp/a", "--add-dir", "/tmp/b", "-w", "wt1",
            "--allow-dangerously-skip-permissions", "--enable-auth-status", "--session-mirror",
            "--prompt-suggestions", "true", "--setting-sources", "", "--strict-mcp-config",
        ])
        XCTAssertEqual(LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid), worktree: .unnamed, settingSources: [.user, .project]).arguments().suffix(5),
                       ["-w", "--enable-auth-status", "--session-mirror", "--setting-sources", "user,project"])
    }
    func testChildEnvironmentTableAndForbiddenVariables() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CODE_REMOTE": "1", "CLAUDE_CODE_CONTAINER_ID": "c", "CLAUDE_CODE_ENTRYPOINT": "cli"],
                                       shell: "/bin/zsh", capturedAt: .init(), mode: .login)
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base)
        XCTAssertEqual(env["PATH"], "/usr/bin"); XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "1"); XCTAssertEqual(env["CLAUDE_AUTO_BACKGROUND_TASKS"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK"], "1"); XCTAssertEqual(env["CLAUDE_CODE_FORK_SUBAGENT"], "1")
        XCTAssertNil(env["AUTOMODE_DECISION_LOG"])
        // Parent spec section 6.1 marks CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=markdown "always", and the probe
        // harness that recorded the sixteen fixtures carries it in DEFAULT_ENV_TABLE. The plan's table had it
        // opt-in and default-absent; the spec and the harness agree against the plan, so it is always set.
        XCTAssertEqual(env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"], "markdown")
        XCTAssertNil(env["CLAUDE_CODE_REMOTE"]); XCTAssertNil(env["CLAUDE_CODE_CONTAINER_ID"]); XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        let opts = ChildEnvironmentOptions(forkSubagents: false, automodeDecisionLog: true, questionPreviewFormat: "markdown")
        let env2 = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid), environment: opts).childEnvironment(over: base)
        XCTAssertNil(env2["CLAUDE_CODE_FORK_SUBAGENT"]); XCTAssertEqual(env2["AUTOMODE_DECISION_LOG"], "1"); XCTAssertEqual(env2["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"], "markdown")
        XCTAssertEqual(env2["CLAUDE_CONFIG_DIR"], nil)
    }
    func testConfigHomeOverrideInjectsConfigDir() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: "/bin/zsh", capturedAt: .init(), mode: .login)
        var c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        c.configHomeOverride = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
        XCTAssertEqual(c.childEnvironment(over: base)["CLAUDE_CONFIG_DIR"], "/tmp/afleet-fixtures/config-home")
    }

    /// Parent spec section 6.1: the child carries no variable beginning with CLAUDE from the resolved
    /// environment. The exposure path is section 6.9's `.processFallback` arm, which returns afleet's own
    /// environment verbatim; when afleet is itself launched from inside a Claude Code session that
    /// environment carries the parent's session markers, and a child that inherits
    /// CLAUDE_CODE_CHILD_SESSION stops saving its transcript.
    func testEveryInheritedClaudePrefixedVariableIsScrubbed() {
        let base = ResolvedEnvironment(
            variables: ["PATH": "/usr/bin",
                        "CLAUDECODE": "1",
                        "CLAUDE_CODE_SESSION_ID": "abc",
                        "CLAUDE_CODE_CHILD_SESSION": "1",
                        "CLAUDE_CONFIG_DIR": "/Users/x/.claude",
                        "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "0",
                        "CLAUDE_SOMETHING_INVENTED_LATER": "1",
                        "ANTHROPIC_API_KEY": "keep-me"],
            shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base)
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SESSION_ID"])
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(env["CLAUDE_SOMETHING_INVENTED_LATER"])
        // Derived, never inherited: section 6.9 gives one ConfigHome per launch, and only an explicit
        // override puts it in the child.
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        // A non-CLAUDE variable is untouched, and the deliberate table wins over an inherited same-named value.
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "keep-me")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "1")
        XCTAssertEqual(env["CLAUDE_AUTO_BACKGROUND_TASKS"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"], "markdown")
        XCTAssertEqual(env["CLAUDE_CODE_FORK_SUBAGENT"], "1")
        var withOverride = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        withOverride.configHomeOverride = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
        XCTAssertEqual(withOverride.childEnvironment(over: base)["CLAUDE_CONFIG_DIR"], "/tmp/afleet-fixtures/config-home")
    }
}
