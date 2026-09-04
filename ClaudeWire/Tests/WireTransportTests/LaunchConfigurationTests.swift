import XCTest
import AfleetCore
import WireFrames
import WireTransport

final class LaunchConfigurationTests: XCTestCase {
    private let bin = URL(fileURLWithPath: "/Users/x/.local/bin/claude")
    private let cwd = URL(fileURLWithPath: "/tmp/scratch")
    private let sid = SessionID("0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b")!

    func testNewChannelMinimalLineTokenForToken() throws {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        XCTAssertEqual(try c.arguments(), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--session-id", "0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b",
            "--enable-auth-status", "--session-mirror",
        ])
    }
    func testEveryOptionalFlagInOrder() throws {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .resume(sid, fork: true), model: "opus", permissionMode: .plan, agent: "reviewer",
                                    effort: "high", name: "fix-auth", addDirectories: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")],
                                    worktree: .named("wt1"), allowBypass: true, promptSuggestions: true, settingSources: [], strictMCPConfig: true)
        XCTAssertEqual(try c.arguments(), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--resume", "0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b", "--fork-session",
            "--model", "opus", "--permission-mode", "plan", "--agent", "reviewer", "--effort", "high",
            "-n", "fix-auth", "--add-dir", "/tmp/a", "--add-dir", "/tmp/b", "-w", "wt1",
            "--allow-dangerously-skip-permissions", "--enable-auth-status", "--session-mirror",
            "--prompt-suggestions", "true", "--setting-sources", "", "--strict-mcp-config",
        ])
        XCTAssertEqual(try LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid), worktree: .unnamed, settingSources: [.user, .project]).arguments().suffix(5),
                       ["-w", "--enable-auth-status", "--session-mirror", "--setting-sources", "user,project"])
    }

    /// The options whose value the caller writes, and which therefore reach the child as caller-chosen argv
    /// text. `testEveryCallerSuppliedArgvTokenIsAValidatedOne` asserts this set is complete; the test below
    /// asserts every member of it rejects an option-shaped value. Neither is worth much without the other.
    private static let optionsCarryingCallerText: Set<String> = ["--model", "--agent", "--effort", "-n", "--add-dir", "-w"]

    /// `-w` declares an optional value, so `worktree: .named("--allow-dangerously-skip-permissions")` used to
    /// put a real permission-bypass flag on the command line with `allowBypass` false and never consulted.
    /// The other five carry the same defect with a different name, so all six are pinned here.
    func testOptionShapedValuesAreRejectedOnEveryOptionThatCarriesCallerText() {
        let evil = "--allow-dangerously-skip-permissions"
        var configs: [String: LaunchConfiguration] = [:]
        var m = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); m.model = evil; configs["--model"] = m
        var a = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); a.agent = evil; configs["--agent"] = a
        var e = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); e.effort = evil; configs["--effort"] = e
        var n = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); n.name = evil; configs["-n"] = n
        var d = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); d.addDirectories = [URL(fileURLWithPath: "/tmp/a")]; configs["--add-dir"] = d
        var w = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)); w.worktree = .named(evil); configs["-w"] = w
        XCTAssertEqual(Set(configs.keys), Self.optionsCarryingCallerText)
        for (option, config) in configs where option != "--add-dir" {
            XCTAssertThrowsError(try config.arguments(), option) { error in
                guard case .invalidArgument(let o, _)? = error as? WireError else { return XCTFail("\(option): \(error)") }
                XCTAssertEqual(o, option)
            }
        }
        // `--add-dir` takes a URL, and `URL(fileURLWithPath:)` cannot produce a relative path, so its guard is
        // unreachable from the public type today. It is checked all the same and asserted benign here rather
        // than left out, because the guard is what keeps it unreachable if the field ever takes a String.
        XCTAssertEqual(try d.arguments().contains("/tmp/a"), true)
    }

    /// The completeness half: give every caller-supplied field a distinct marker, then assert that the set of
    /// options preceding a marker in the produced argv is exactly the set the rejection test covers. A field
    /// added later that forwards caller text without a guard fails here.
    func testEveryCallerSuppliedArgvTokenIsAValidatedOne() throws {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid), model: "MARKmodel", permissionMode: .plan,
                                    agent: "MARKagent", effort: "MARKeffort", name: "MARKname",
                                    addDirectories: [URL(fileURLWithPath: "/MARKdir")], worktree: .named("MARKworktree"),
                                    allowBypass: true, promptSuggestions: true, settingSources: [.user], strictMCPConfig: true)
        let argv = try c.arguments()
        let carrying = Set(argv.indices.filter { argv[$0].contains("MARK") }.map { argv[$0 - 1] })
        XCTAssertEqual(carrying, Self.optionsCarryingCallerText)
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
