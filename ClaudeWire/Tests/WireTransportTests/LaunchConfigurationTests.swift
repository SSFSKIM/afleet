import XCTest
import AfleetCore
import WireEnvironment
import WireFrames
import WireTransport

final class LaunchConfigurationTests: XCTestCase {
    private let bin = URL(fileURLWithPath: "/Users/x/.local/bin/claude")
    private let cwd = URL(fileURLWithPath: "/tmp/scratch")
    private let sid = SessionID("0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b")!
    /// The home this launch resolved. Deliberately *not* `<HOME>/.claude`, so a child that re-derived its
    /// own default rather than being told this one lands somewhere else and the difference is visible.
    private let resolved = ConfigHome(root: URL(fileURLWithPath: "/Users/x/.claude-scratch"), source: .environment)

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

    /// Invented uuids: never a record uuid copied from a fixture or a transcript.
    private let forkEntry = "b7c41d02-5e38-4a91-9f60-2d8ac31be745"
    private let droppedPrompt = "3e91f7a4-0c62-4d18-8b53-6af02d9c1e87"

    private func assertContainsSubsequence(_ argv: [String], _ needle: [String], _ message: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let found = argv.indices.contains { i in
            i + needle.count <= argv.count && Array(argv[i ..< i + needle.count]) == needle
        }
        XCTAssertTrue(found, "\(message): \(needle) not contiguous in \(argv)", file: file, line: line)
    }

    /// *Fork from here* (§7.4): `--resume-session-at` is inclusive of the entry it names and
    /// `--resume-drops-turn` is the CLI's guard on what the truncation discards. Both are refused
    /// without `--resume`, so the case emits the whole group or nothing.
    func testForkFromEmitsResumeSessionAtAndOptionalDropsTurn() throws {
        let both = try LaunchConfiguration(binary: bin, cwd: cwd,
                                           session: .forkFrom(sid, at: .init(entryUUID: forkEntry, dropsTurn: droppedPrompt))).arguments()
        assertContainsSubsequence(both, ["--resume", sid.description, "--fork-session",
                                         "--resume-session-at", forkEntry, "--resume-drops-turn", droppedPrompt],
                                  "fork point with a declared discarded turn")

        let entryOnly = try LaunchConfiguration(binary: bin, cwd: cwd,
                                                session: .forkFrom(sid, at: .init(entryUUID: forkEntry))).arguments()
        assertContainsSubsequence(entryOnly, ["--resume", sid.description, "--fork-session", "--resume-session-at", forkEntry],
                                  "fork point without a declared discarded turn")
        XCTAssertFalse(entryOnly.contains("--resume-drops-turn"))
    }

    func testPlainResumeAndNewChannelCarryNoForkPointFlags() throws {
        for session in [SessionStart.resume(sid, fork: true), .resume(sid, fork: false)] {
            let argv = try LaunchConfiguration(binary: bin, cwd: cwd, session: session).arguments()
            XCTAssertFalse(argv.contains("--resume-session-at"), "\(session)")
            XCTAssertFalse(argv.contains("--resume-drops-turn"), "\(session)")
        }
        let fresh = try LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).arguments()
        for flag in ["--resume", "--fork-session", "--resume-session-at", "--resume-drops-turn"] {
            XCTAssertFalse(fresh.contains(flag), flag)
        }
    }

    /// The options whose value the caller writes, and which therefore reach the child as caller-chosen argv
    /// text. `testEveryCallerSuppliedArgvTokenIsAValidatedOne` asserts this set is complete; the test below
    /// asserts every member of it rejects an option-shaped value. Neither is worth much without the other.
    private static let optionsCarryingCallerText: Set<String> = ["--model", "--agent", "--effort", "-n", "--add-dir", "-w",
                                                                  "--resume-session-at", "--resume-drops-turn"]

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
        let entry = LaunchConfiguration(binary: bin, cwd: cwd, session: .forkFrom(sid, at: .init(entryUUID: evil, dropsTurn: droppedPrompt)))
        configs["--resume-session-at"] = entry
        let drops = LaunchConfiguration(binary: bin, cwd: cwd, session: .forkFrom(sid, at: .init(entryUUID: forkEntry, dropsTurn: evil)))
        configs["--resume-drops-turn"] = drops
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
        // `session` is a single field, so the fork-point marks need their own config alongside `c`'s.
        let fork = LaunchConfiguration(binary: bin, cwd: cwd,
                                       session: .forkFrom(sid, at: .init(entryUUID: "MARKentry", dropsTurn: "MARKdropsturn")))
        let argv = try c.arguments() + fork.arguments()
        let carrying = Set(argv.indices.filter { argv[$0].contains("MARK") }.map { argv[$0 - 1] })
        XCTAssertEqual(carrying, Self.optionsCarryingCallerText)
    }

    func testChildEnvironmentTableAndForbiddenVariables() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CODE_REMOTE": "1", "CLAUDE_CODE_CONTAINER_ID": "c", "CLAUDE_CODE_ENTRYPOINT": "cli"],
                                       shell: "/bin/zsh", capturedAt: .init(), mode: .login)
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base, configHome: resolved)
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
        let env2 = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid), environment: opts).childEnvironment(over: base, configHome: resolved)
        XCTAssertNil(env2["CLAUDE_CODE_FORK_SUBAGENT"]); XCTAssertEqual(env2["AUTOMODE_DECISION_LOG"], "1"); XCTAssertEqual(env2["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"], "markdown")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-scratch")
        XCTAssertEqual(env2["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-scratch")
    }
    /// An explicit override still wins over the resolved home: that is the whole of what it does now.
    func testConfigHomeOverrideInjectsConfigDir() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: "/bin/zsh", capturedAt: .init(), mode: .login)
        var c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        c.configHomeOverride = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
        XCTAssertEqual(c.childEnvironment(over: base, configHome: resolved)["CLAUDE_CONFIG_DIR"], "/tmp/afleet-fixtures/config-home")
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
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base, configHome: resolved)
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SESSION_ID"])
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(env["CLAUDE_SOMETHING_INVENTED_LATER"])
        // Derived, never inherited — but present. The scrub removes the shell's value; what the child is
        // given is the home this launch resolved, which here is not the inherited one.
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-scratch")
        // A non-CLAUDE variable is untouched, and the deliberate table wins over an inherited same-named value.
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "keep-me")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "1")
        XCTAssertEqual(env["CLAUDE_AUTO_BACKGROUND_TASKS"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_QUESTION_PREVIEW_FORMAT"], "markdown")
        XCTAssertEqual(env["CLAUDE_CODE_FORK_SUBAGENT"], "1")
        var withOverride = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        withOverride.configHomeOverride = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
        XCTAssertEqual(withOverride.childEnvironment(over: base, configHome: resolved)["CLAUDE_CONFIG_DIR"], "/tmp/afleet-fixtures/config-home")
    }

    /// The child's config home equals afleet's by construction, with no test override anywhere.
    ///
    /// Asserted twice over, and the second half is the one that names the old defect. Deriving §6.9's rule
    /// over the environment the child is actually handed is exactly what the child itself does at startup:
    /// with the home absent it fell through to `<HOME>/.claude`, so afleet was reading one home while the
    /// session it launched wrote to another. The two roots differ here precisely so that gap is visible.
    func testResolvedConfigHomeReachesTheChildWithNoOverride() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "/Users/x/.claude"],
                                       shell: "/bin/zsh", capturedAt: .init(), mode: .login)
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        XCTAssertNil(c.configHomeOverride)
        let env = c.childEnvironment(over: base, configHome: resolved)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], resolved.root.path)
        let asTheChildSeesIt = ConfigHome.derive(from: ResolvedEnvironment(variables: env, shell: "/bin/zsh", capturedAt: .init(), mode: .login))
        XCTAssertEqual(asTheChildSeesIt.root.path, resolved.root.path,
                       "the child re-derives a different home from the environment it was given")
    }

    /// §6.9 reads the project directory name together with the config home, and the source is the resolved
    /// record rather than the captured environment.
    ///
    /// This test previously asserted the opposite — that a captured `CLAUDE_CODE_PROJECT_DIR_NAME` reaches
    /// the child whatever the record says — and that rule is now wrong rather than merely superseded. The
    /// engine honours the name only when it also sees `CLAUDE_CONFIG_DIR`, and afleet always injects one, so
    /// the engine's gate is open inside every afleet child. A default-home channel handed the shell's name
    /// would honour it while `ConfigHome.derive`, which applies the same gate to the captured environment
    /// where the home was absent, recorded nothing: afleet's view of the session and the session's own
    /// behaviour would disagree, which is the split the config-home fix just closed, displaced by one field.
    func testTheProjectDirNameComesFromTheResolvedRecordNotTheCapture() {
        let c = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid))
        let captured = ResolvedEnvironment(variables: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CODE_PROJECT_DIR_NAME": "afleet-work"],
                                           shell: "/bin/zsh", capturedAt: .init(), mode: .login)

        // A default home records no project name, and the captured one must not leak past it.
        let defaultHome = ConfigHome.derive(from: captured)
        XCTAssertEqual(defaultHome.source, .default)
        XCTAssertNil(defaultHome.projectDirName)
        let defaultChild = c.childEnvironment(over: captured, configHome: defaultHome)
        XCTAssertNil(defaultChild["CLAUDE_CODE_PROJECT_DIR_NAME"],
                     "a record with no project name handed the child the shell's one")
        XCTAssertEqual(defaultChild["CLAUDE_CONFIG_DIR"], defaultHome.root.path,
                       "and the home is injected regardless, which is what opens the engine's gate")

        // A home that came from the environment records the name, and the child is given both.
        let named = ConfigHome.derive(from: ResolvedEnvironment(
            variables: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "/Users/x/.claude-scratch",
                        "CLAUDE_CODE_PROJECT_DIR_NAME": "afleet-work"],
            shell: "/bin/zsh", capturedAt: .init(), mode: .login))
        XCTAssertEqual(named.projectDirName, "afleet-work")
        let namedChild = c.childEnvironment(over: captured, configHome: named)
        XCTAssertEqual(namedChild["CLAUDE_CODE_PROJECT_DIR_NAME"], "afleet-work")
        XCTAssertEqual(namedChild["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-scratch")

        // And the record, not the capture, decides which name: a capture that disagrees does not win.
        let other = ConfigHome(root: URL(fileURLWithPath: "/Users/x/.claude-scratch"), source: .environment, projectDirName: "from-the-record")
        XCTAssertEqual(c.childEnvironment(over: captured, configHome: other)["CLAUDE_CODE_PROJECT_DIR_NAME"], "from-the-record")
    }

    /// Configuration the engine reads survives the scrub; a marker it sets on its own children does not.
    /// One assertion, because the two halves are the same decision seen from either side.
    func testProviderConfigurationSurvivesTheScrubAndAMarkerDoesNot() {
        let base = ResolvedEnvironment(variables: ["PATH": "/usr/bin", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_CHILD_SESSION": "1"],
                                       shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base, configHome: resolved)
        XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
    }

    /// The twelve, written out. An allowlist that grows by accident is the failure mode this guards, so the
    /// set is pinned by name and then pinned again by behaviour: everything beginning with `CLAUDE` that
    /// reaches the child is exactly the launch table, the config home, and these twelve.
    ///
    /// `CLAUDE_CODE_OAUTH_TOKEN` is in the captured environment here and must not be among them: the engine
    /// sets it on its own children as a credential handoff, and an owned channel authenticates from its
    /// config home.
    func testPassThroughSetIsExactlyTheseTwelveNames() {
        let twelve: Set<String> = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                                   "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
                                   "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
                                   "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
                                   "CLAUDE_CODE_SKIP_MANTLE_AUTH", "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH",
                                   "CLAUDE_CODE_MAX_OUTPUT_TOKENS"]
        XCTAssertEqual(LaunchConfiguration.passedThroughConfiguration, twelve)
        var variables = ["PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-secret",
                         "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_INVENTED_NEXT_RELEASE": "1"]
        for name in twelve { variables[name] = "1" }
        let base = ResolvedEnvironment(variables: variables, shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
        let env = LaunchConfiguration(binary: bin, cwd: cwd, session: .new(sid)).childEnvironment(over: base, configHome: resolved)
        let table: Set<String> = ["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "CLAUDE_AUTO_BACKGROUND_TASKS",
                                  "CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK", "CLAUDE_CODE_QUESTION_PREVIEW_FORMAT",
                                  "CLAUDE_CODE_FORK_SUBAGENT"]
        XCTAssertEqual(Set(env.keys.filter { $0.hasPrefix("CLAUDE") }), twelve.union(table).union(["CLAUDE_CONFIG_DIR"]))
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
    }
}
