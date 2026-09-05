import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// G4: the command router as data, the typed strategies and their executor, the flag matrix and refusal
/// interception (contract X10).
///
/// Every engine byte these tests assert against comes from a reviewed fixture under `Fixtures/`: `FixtureAnswers`
/// reads it out of `frames.ndjson` at run time and hands it to the replay as the engine's own answer. One recorded
/// value is also written out as a literal to be compared against — `/rewind`'s `prefillText` — which §11 permits
/// because it is a reviewed fixture's own byte; everything else is read rather than transcribed.
/// The replays run against `resume-no-replay`, the one fixture that stays alive after the handshake, because the
/// fixtures that recorded these answers each recorded them inside a longer scripted sequence whose remaining host
/// inputs a router test does not send — the replayer walks its recorded `in` lines in order and would block on the
/// first one the router never sends. The *answers* are therefore the recording's and the *sequence* is the test's,
/// which is what the acceptance asks for.
///
/// Where a step runs against a scripted answer rather than a recorded one, the test's own doc comment says so and
/// names why the corpus does not carry it. There are four such places, all called out below:
/// the `rewind_files` apply, a completed `claude_oauth_wait_for_completion`, a second `claude_authenticate` whose
/// two URLs differ, and a `get_context_usage` whose `memoryFiles` is non-empty.
final class RouterTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    private func newRig() throws -> Rig {
        let rig = try Rig()
        rigs.append(rig)
        return rig
    }

    /// The fixture whose replay stays alive after the handshake until the host asks it to stop.
    private static let idle = "resume-no-replay"
    private func scriptDirectory(_ rig: Rig) -> URL { rig.scratch.appending(path: "scripts") }

    /// A live channel replaying `idle`, answering the host's control requests from `steps`.
    private func liveChannel(_ rig: Rig, _ steps: [[String: Any]]) async throws -> ChannelSupervisor {
        let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
        let script = try ReplayScript.write(steps, fixture: Self.idle, into: scriptDirectory(rig))
        let supervisor = rig.supervisor(session: session, fixture: Self.idle, script: script)
        try await supervisor.open()
        return supervisor
    }

    // MARK: - The table

    /// The set of local commands is the parent's §7.7 set, and the table holds each exactly once. Both are asserted:
    /// a duplicated entry leaves the *set* equal and only the count sees it.
    func testTheLocalTableEqualsTheParentsRowsAsASet() {
        let expected: Set<String> = ["/model", "/permissions", "/effort", "/rename", "/add-dir", "/agent", "/cd",
                                     "/fast", "/config", "/login", "/logout", "/color", "/clear", "/rewind",
                                     "/fork", "/background", "/stop", "/tasks", "/mcp", "/memory", "/btw",
                                     "/agents", "/resume", "/compact", "/context", "/cost", "/usage"]
        XCTAssertEqual(Set(RouterTable.local.map(\.name)), expected)
        XCTAssertEqual(RouterTable.local.count, 27, "27 rows and no duplicates")
        for command in RouterTable.local {
            XCTAssertFalse(command.explanation.isEmpty, "\(command.name) has no explanation to render")
        }
    }

    // MARK: - The multi-step strategies

    /// `/rewind <uuid>`: the read-only dry run first, the counts surfaced for confirmation, then the **conversation**
    /// and only then, and only if the conversation moved and the user asked for them, the files.
    ///
    /// The order is the whole point. `rewind_files {dry_run: false}` reverts the user's working tree, and
    /// `rewind_conversation` refuses any target the running process did not itself send — which after a reopen is
    /// every earlier message — with `rewound: false` inside a *success* envelope. Applying the files first therefore
    /// leaves the ordinary refusal case with a reverted tree under a conversation that never moved, silently. The
    /// reorder is safe because `rewind_files` resolves its checkpoint through the engine's file history keyed by the
    /// message id and never through the message array (2.1.258 `cli.pretty.js:153445-153460`), so the checkpoint
    /// outlives the conversation rewind.
    ///
    /// Recorded: the `rewind_files {dry_run: true}` answer and the `rewind_conversation` answer are the
    /// `control-shapes` recording's own, read out of `frames.ndjson`, and the target uuid is the one that recording
    /// rewound to. Scripted, not recorded: the `rewind_files {dry_run: false}` **apply** — the corpus records only
    /// the dry run, because the recording's scenario deliberately did not roll the working tree back — so the apply
    /// answers `{canRewind, skippedLinks}`, the shape the bundle's own handler builds at `:153460`.
    ///
    /// Deliberate break: send `rewind_files {dry_run: false}` before `rewind_conversation` again → legs two and
    /// three fail, the refusal leg on the extra request that reverted the tree behind a refused rewind.
    func testRewindRewindsTheConversationFirstAndTheFilesOnlyOnceItIsHonoured() async throws {
        let rig = try newRig()
        let dryRun = try FixtureAnswers.exchange("control-shapes", "rewind_files")
        let target = try XCTUnwrap(dryRun.request["user_message_id"] as? String)
        let preview = try XCTUnwrap(dryRun.body)
        let rewound = try FixtureAnswers.body("control-shapes", "rewind_conversation")

        let steps = ReplayScript.exchange("rewind_files", matching: ["request.user_message_id": target,
                                                                     "request.dry_run": true], answer: preview)
            + ReplayScript.exchange("rewind_conversation", matching: ["request.target_message_uuid": target],
                                    answer: rewound)
            + ReplayScript.exchange("rewind_files", matching: ["request.dry_run": false],
                                    answer: ["canRewind": true, "skippedLinks": 2])
        let supervisor = try await liveChannel(rig, steps)

        guard case .strategy(let strategy, let arguments) = CommandRouter.route("/rewind \(target)") else {
            return XCTFail("/rewind did not route to a strategy")
        }
        XCTAssertEqual(strategy, .rewind)
        XCTAssertEqual(arguments, [target])

        let ui = ScriptedStrategyUI(answers: .conversationAndFiles)
        let outcome = try await StrategyExecutor.run(strategy, arguments: arguments, on: supervisor, ui: ui)
        guard case .rewind(let surfaced, let result) = outcome else {
            return XCTFail("the rewind gave \(outcome)")
        }
        XCTAssertEqual(surfaced, RewindPreview(canRewind: true, filesChanged: [], insertions: 0, deletions: 0))
        let previews = await ui.previews
        XCTAssertEqual(previews, [surfaced], "the counts were put in front of the user before anything applied")
        XCTAssertEqual(result, RewindOutcome(rewound: true, prefillText: "Reply with exactly the word: shapes",
                                             files: RewindFilesOutcome(canRewind: true, skippedLinks: 2)))

        // Leg two: the same happy path on the scripted handle, where the *order* is readable as a list. One
        // answer per subtype is all the scripted handle holds, so the two `rewind_files` legs share an answer
        // carrying both shapes' keys; the dry run reads its four and the apply reads its two.
        let orderRig = try newRig()
        orderRig.useScriptedHandle()
        orderRig.configureScriptedHandles { handle in
            handle.controlAnswers = [
                "rewind_files": Self.json(["canRewind": true, "filesChanged": ["a.swift"], "insertions": 3,
                                           "deletions": 1, "skippedLinks": 0]),
                "rewind_conversation": Self.json(["rewound": true, "prefillText": "put this back",
                                                  "targetMessageUuid": target]),
            ]
        }
        let ordered = orderRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await ordered.spawn(reason: .open)
        let orderedOutcome = try await StrategyExecutor.run(.rewind, arguments: [target], on: ordered,
                                                            ui: ScriptedStrategyUI(answers: .conversationAndFiles))
        guard case .rewind(_, let applied) = orderedOutcome else { return XCTFail("gave \(orderedOutcome)") }
        XCTAssertEqual(applied?.prefillText, "put this back")
        let orderedSent = orderRig.scriptedHandles[0].controlRequests
        XCTAssertEqual(orderedSent.map(\.subtype), ["rewind_files", "rewind_conversation", "rewind_files"],
                       "the conversation is rewound before the working tree is touched")
        XCTAssertEqual(orderedSent[0].payload["dry_run"]?.boolValue, true)
        XCTAssertEqual(orderedSent[2].payload["dry_run"]?.boolValue, false)

        // Leg three: the refusal. `rewound: false` with a body-level `error` inside a success envelope is the
        // ordinary case for any message the current process did not send, and no file may be touched behind it.
        let previewAnswer = Self.json(preview)
        let staleRig = try newRig()
        staleRig.useScriptedHandle()
        staleRig.configureScriptedHandles { handle in
            handle.controlAnswers = [
                "rewind_files": previewAnswer,
                "rewind_conversation": Self.json(["rewound": false, "prefillText": NSNull(),
                                                  "precedingAssistantUuid": NSNull(), "error": "stale target"]),
            ]
        }
        let stale = staleRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await stale.spawn(reason: .open)
        let staleOutcome = try await StrategyExecutor.run(.rewind, arguments: [target], on: stale,
                                                          ui: ScriptedStrategyUI(answers: .conversationAndFiles))
        guard case .rewind(_, let refused) = staleOutcome else { return XCTFail("gave \(staleOutcome)") }
        XCTAssertEqual(refused?.rewound, false)
        XCTAssertEqual(refused?.error, "stale target", "the engine's own reason is surfaced, not swallowed")
        XCTAssertEqual(refused?.offersForkFromHere, true, "the affordance parent §8.5 item 13 designs")
        XCTAssertNil(refused?.files, "no file was touched behind a refused rewind")
        XCTAssertEqual(staleRig.scriptedHandles[0].controlRequests.map(\.subtype),
                       ["rewind_files", "rewind_conversation"],
                       "a refused rewind sends no apply")

        // Leg four: the cancelled confirmation. Nothing but the read-only dry run goes out.
        let declineRig = try newRig()
        declineRig.useScriptedHandle()
        declineRig.configureScriptedHandles { handle in
            handle.controlAnswers = ["rewind_files": previewAnswer]
        }
        let declined = declineRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await declined.spawn(reason: .open)
        let declineUI = ScriptedStrategyUI(answers: .cancel)
        let declinedOutcome = try await StrategyExecutor.run(.rewind, arguments: [target], on: declined,
                                                             ui: declineUI)
        guard case .rewind(_, let none) = declinedOutcome else { return XCTFail("declined gave \(declinedOutcome)") }
        XCTAssertNil(none, "a cancelled rewind rewinds nothing")
        let sent = declineRig.scriptedHandles[0].controlRequests
        XCTAssertEqual(sent.map(\.subtype), ["rewind_files"], "nothing else is sent until the sheet is answered")
        XCTAssertEqual(sent[0].payload["dry_run"]?.boolValue, true)

        // Leg five: the conversation alone. The user asked for the messages back and their working tree left as it
        // is, so the apply never runs even though the rewind was honoured.
        let conversationRig = try newRig()
        conversationRig.useScriptedHandle()
        conversationRig.configureScriptedHandles { handle in
            handle.controlAnswers = ["rewind_files": previewAnswer,
                                     "rewind_conversation": Self.json(["rewound": true, "prefillText": "back"])]
        }
        let conversationOnly = conversationRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await conversationOnly.spawn(reason: .open)
        let conversationOutcome = try await StrategyExecutor.run(
            .rewind, arguments: [target], on: conversationOnly, ui: ScriptedStrategyUI(answers: .conversationOnly))
        guard case .rewind(_, let messagesOnly) = conversationOutcome else {
            return XCTFail("gave \(conversationOutcome)")
        }
        XCTAssertEqual(messagesOnly, RewindOutcome(rewound: true, prefillText: "back"))
        XCTAssertEqual(conversationRig.scriptedHandles[0].controlRequests.map(\.subtype),
                       ["rewind_files", "rewind_conversation"],
                       "the files the user did not ask for were left alone")
    }

    /// `/login`: the two URLs, the automatic one handed to the Browser tab, then the wait.
    ///
    /// Recorded: the `claude_authenticate` answer and the `claude_oauth_wait_for_completion` **error** are the
    /// `control-shapes` recording's own. Scripted, not recorded: the *completed* wait — the recording's only answer
    /// for it is that error, because a probe may start no real login flow — so the second leg answers it with
    /// `{account: {email, ...}}`, the shape the bundle's own handler builds (2.1.258 `cli.pretty.js:152468`), over
    /// invented identifiers. The second leg's `claude_authenticate` answer is scripted for the same reason the
    /// break needs it: redaction rule 6 replaced both recorded URLs' queries, so the recorded `manualUrl` and
    /// `automaticUrl` are byte-identical and no assertion could tell one from the other.
    func testLoginReturnsTheTwoURLsThenWaitsForCompletion() async throws {
        let rig = try newRig()
        let recorded = try FixtureAnswers.body("control-shapes", "claude_authenticate")
        let noFlow = try FixtureAnswers.error("control-shapes", "claude_oauth_wait_for_completion")
        let distinct: [String: Any] = ["manualUrl": "https://claude.example/router-probe-manual",
                                       "automaticUrl": "https://claude.example/router-probe-automatic"]
        let account: [String: Any] = ["account": ["email": "router-probe@example.invalid",
                                                  "organization": "router-probe-org",
                                                  "subscriptionType": "router-probe-plan"]]

        let steps = ReplayScript.exchange("claude_authenticate", answer: recorded)
            + ReplayScript.failure("claude_oauth_wait_for_completion", error: noFlow)
            + ReplayScript.exchange("claude_authenticate", answer: distinct)
            + ReplayScript.exchange("claude_oauth_wait_for_completion", answer: account)
        let supervisor = try await liveChannel(rig, steps)

        guard case .strategy(let strategy, let arguments) = CommandRouter.route("/login") else {
            return XCTFail("/login did not route to a strategy")
        }
        XCTAssertEqual(strategy, .login)
        XCTAssertEqual(arguments, [])

        let ui = ScriptedStrategyUI(answers: .conversationAndFiles)
        let first = try await StrategyExecutor.run(strategy, arguments: arguments, on: supervisor, ui: ui)
        guard case .login(let prompt, let outcome) = first else { return XCTFail("/login gave \(first)") }
        XCTAssertEqual(prompt.manualURL, recorded["manualUrl"] as? String)
        XCTAssertEqual(prompt.automaticURL, recorded["automaticUrl"] as? String)
        guard case .noActiveFlow(let reason) = outcome else { return XCTFail("the wait gave \(outcome)") }
        XCTAssertEqual(reason, noFlow, "the recorded error, offered back as a retry")

        let second = try await StrategyExecutor.run(strategy, arguments: arguments, on: supervisor, ui: ui)
        guard case .login(let prompt2, let outcome2) = second else { return XCTFail("/login gave \(second)") }
        XCTAssertEqual(outcome2, .signedIn(account: "router-probe@example.invalid"))
        let opened = await ui.opened
        XCTAssertEqual(opened, [prompt.automaticURL, prompt2.automaticURL],
                       "the Browser tab is handed the automatic URL, never the manual one")
        XCTAssertEqual(opened.last, distinct["automaticUrl"] as? String)
    }

    /// Bare `/permissions` opens the read-only rules view off `get_settings` and changes nothing; `/permissions plan`
    /// is the setter instead.
    ///
    /// Recorded: the `get_settings` answer is the `zero-cost` recording's own. Its `applied` object is the whole of
    /// the settings state that recording carries — the corpus records no permission-rule listing on any answer — so
    /// the rules view is built from the keys the engine reported as applied, and the test asserts exactly those.
    func testBarePermissionsOpensTheRulesViewFromGetSettings() async throws {
        let rig = try newRig()
        let settings = try FixtureAnswers.body("zero-cost", "get_settings")
        let supervisor = try await liveChannel(rig, ReplayScript.exchange("get_settings", answer: settings))

        guard case .strategy(let strategy, _) = CommandRouter.route("/permissions") else {
            return XCTFail("bare /permissions did not route to a strategy")
        }
        XCTAssertEqual(strategy, .permissionsView)

        let ui = ScriptedStrategyUI(answers: .conversationAndFiles)
        let outcome = try await StrategyExecutor.run(strategy, on: supervisor, ui: ui)
        guard case .permissions(let view) = outcome else { return XCTFail("bare /permissions gave \(outcome)") }
        XCTAssertEqual(view.settings, Self.json(settings), "the whole answer, verbatim")
        let applied = try XCTUnwrap(settings["applied"] as? [String: Any])
        XCTAssertEqual(Set(view.applied.keys), Set(applied.keys))
        XCTAssertFalse(view.applied.isEmpty)

        guard case .controlRequest(let request) = CommandRouter.route("/permissions plan") else {
            return XCTFail("/permissions plan did not route to a control request")
        }
        XCTAssertEqual(request.subtype, SetPermissionMode.subtype)
        XCTAssertEqual(request.payload, .object(["mode": .string("plan")]))

        // "and nothing else" on the host side, not only through the replay refusing an unexpected frame: the same
        // strategy on the scripted handle, whose ordered request list the test can read directly.
        let scriptedRig = try newRig()
        scriptedRig.useScriptedHandle()
        let recorded = Self.json(settings)
        scriptedRig.configureScriptedHandles { handle in handle.controlAnswers = ["get_settings": recorded] }
        let scripted = scriptedRig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await scripted.spawn(reason: .open)
        _ = try await StrategyExecutor.run(.permissionsView, on: scripted,
                                           ui: ScriptedStrategyUI(answers: .conversationAndFiles))
        XCTAssertEqual(scriptedRig.scriptedHandles[0].controlRequests.map(\.subtype), ["get_settings"],
                       "the bare form reads and changes nothing")

        // A typo in the mode is refused with the modes named, not quietly turned into the bare form.
        guard case .refusedLocally(let explanation) = CommandRouter.route("/permissions paln") else {
            return XCTFail("an unknown permission mode was not refused")
        }
        XCTAssertTrue(explanation.contains("paln"), "the explanation names what was typed; got \(explanation)")
        XCTAssertTrue(explanation.contains("plan"), "and the modes that exist; got \(explanation)")
    }

    /// `/mcp` builds the popover from `mcp_status`: one row per recorded server, with its name and its status word.
    ///
    /// Recorded: the `mcp_status` answer is the `zero-cost` recording's own.
    func testMCPBuildsThePopoverFromMCPStatus() async throws {
        let rig = try newRig()
        let status = try FixtureAnswers.body("zero-cost", "mcp_status")
        let supervisor = try await liveChannel(rig, ReplayScript.exchange("mcp_status", answer: status))

        guard case .strategy(let strategy, _) = CommandRouter.route("/mcp") else {
            return XCTFail("/mcp did not route to a strategy")
        }
        XCTAssertEqual(strategy, .mcpPopover)

        let outcome = try await StrategyExecutor.run(strategy, on: supervisor,
                                                     ui: ScriptedStrategyUI(answers: .conversationAndFiles))
        guard case .mcp(let popover) = outcome else { return XCTFail("/mcp gave \(outcome)") }
        let recorded = try XCTUnwrap(status["mcpServers"] as? [[String: Any]])
        XCTAssertEqual(popover.servers.map(\.name), recorded.map { $0["name"] as? String })
        XCTAssertEqual(popover.servers.map(\.status), recorded.map { $0["status"] as? String })
        XCTAssertFalse(popover.servers.isEmpty)
    }

    /// `/memory` opens the memory files from `get_context_usage`, in the order the answer listed them.
    ///
    /// Recorded: the `get_context_usage` answer is the `zero-cost` recording's own, and its `memoryFiles` is empty —
    /// that recording ran in a directory with no memory file. An empty list cannot tell a correct read from a wrong
    /// one, so a second run answers a scripted `get_context_usage` carrying three invented relative paths in a fixed
    /// order; that is the leg the order and the decode are asserted from.
    func testMemoryOpensTheMemoryFilesFromGetContextUsage() async throws {
        let rig = try newRig()
        let recorded = try FixtureAnswers.body("zero-cost", "get_context_usage")
        let invented = ["router-probe/CLAUDE.md", "router-probe/nested/CLAUDE.md", "router-probe/AGENTS.md"]
        var scripted = recorded
        scripted["memoryFiles"] = invented
        let supervisor = try await liveChannel(rig, ReplayScript.exchange("get_context_usage", answer: recorded)
            + ReplayScript.exchange("get_context_usage", answer: scripted))

        guard case .strategy(let strategy, _) = CommandRouter.route("/memory") else {
            return XCTFail("/memory did not route to a strategy")
        }
        XCTAssertEqual(strategy, .memoryFiles)

        let ui = ScriptedStrategyUI(answers: .conversationAndFiles)
        let first = try await StrategyExecutor.run(strategy, on: supervisor, ui: ui)
        guard case .memory(let files) = first else { return XCTFail("/memory gave \(first)") }
        XCTAssertEqual(files, recorded["memoryFiles"] as? [String] ?? [])

        let second = try await StrategyExecutor.run(strategy, on: supervisor, ui: ui)
        guard case .memory(let scriptedFiles) = second else { return XCTFail("/memory gave \(second)") }
        XCTAssertEqual(scriptedFiles, invented, "the recorded order, unsorted and unfiltered")
    }

    // MARK: - The single-request commands

    /// The router is the front door Task 6's runtime record is fed through: a `/model` and a `/permissions` routed
    /// here reach the engine through `supervisor.perform`, so the runtime state is updated on the way and the
    /// quiescent restart relaunches with what the user picked.
    ///
    /// Scripted, not recorded: `set_model` and `set_permission_mode` have no recorded counterpart anywhere under
    /// `Fixtures/`; both are answered with the bare success every setter is answered with, and their payloads are
    /// composed by FleetKit, so no engine byte is invented.
    func testRouteChangeThenRestartCarriesTheChangedValuesEndToEnd() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(session, fork: false))
        template.model = "sonnet"
        template.permissionMode = .default

        let script = try ReplayScript.write(
            ReplayScript.exchange("set_model") + ReplayScript.exchange("set_permission_mode"),
            fixture: Self.idle, into: scriptDirectory(rig))
        let relaunch = try ReplayScript.write(
            ReplayScript.exchange("get_settings", answer: ["applied": [:], "effective": [:], "sources": []]),
            fixture: Self.idle, into: scriptDirectory(rig))
        let supervisor = rig.supervisor(session: session, fixture: Self.idle, template: template,
                                        script: script, relaunchScript: relaunch)
        try await supervisor.open()

        guard case .controlRequest(let model) = CommandRouter.route("/model opus"),
              case .controlRequest(let mode) = CommandRouter.route("/permissions plan") else {
            return XCTFail("the two changes did not route to control requests")
        }
        _ = try await StrategyExecutor.send(model, on: supervisor)
        _ = try await StrategyExecutor.send(mode, on: supervisor)

        let runtime = await supervisor.runtimeState()
        XCTAssertEqual(runtime.model, "opus")
        XCTAssertEqual(runtime.permissionMode, .plan)

        try await rig.steppingClock { try await supervisor.quiescentRestart(RestartRequest()) }
        XCTAssertEqual(rig.launches[1].model, "opus")
        XCTAssertEqual(rig.launches[1].permissionMode, .plan)
        XCTAssertEqual(rig.launches[0].model, "sonnet", "the template still reads what the channel was opened with")
    }

    /// `/effort low` is an `apply_flag_settings` whose readback is `get_settings.effective`.
    ///
    /// Recorded: both answers are the `control-shapes` recording's own — the bare success with no `response` key at
    /// all, and the `get_settings` whose `effective` object names the flag just applied.
    func testEffortSendsApplyFlagSettingsAndReadsBackEffective() async throws {
        let rig = try newRig()
        let settings = try FixtureAnswers.body("control-shapes", "get_settings")
        let supervisor = try await liveChannel(
            rig,
            ReplayScript.exchange("apply_flag_settings", matching: ["request.settings.effortLevel": "low"])
                + ReplayScript.exchange("get_settings", answer: settings))

        guard case .controlRequest(let request) = CommandRouter.route("/effort low") else {
            return XCTFail("/effort did not route to a control request")
        }
        XCTAssertEqual(request.subtype, ApplyFlagSettings.subtype)
        XCTAssertEqual(request.payload, .object(["settings": .object(["effortLevel": .string("low")])]))

        let answer = try await StrategyExecutor.send(request, on: supervisor)
        XCTAssertEqual(answer, .object([:]), "the engine answers a bare success with no response key")

        let readback = try await supervisor.perform(GetSettings())
        let keys = readback["effective"]?.objectValue.map { Array($0.keys) } ?? []
        XCTAssertTrue(keys.contains("effortLevel"), "the readback names the key the flag set; got \(keys)")
        let runtime = await supervisor.runtimeState()
        XCTAssertEqual(runtime.flagSettings["effortLevel"], .string("low"))
    }

    /// `/cd` into an untrusted directory: the bare call is answered `needs_trust`, and the follow-up the router
    /// builds after the user's trust answer carries the original path, `trust_accepted` and the directory the answer
    /// named — compared key for key and value for value against the frame the recording captured.
    ///
    /// Recorded: both `set_cwd` answers and both recorded host requests are `session-mirror-relocation`'s own, the
    /// fixture that recorded the accepted continuation. `control-shapes` records a bare `set_cwd {path}` retry after
    /// its `needs_trust` and so cannot serve this comparison.
    func testCDIntoAnUntrustedDirectoryRepeatsWithTrustAcceptedAndTrustedDirectory() async throws {
        let rig = try newRig()
        let fixture = "session-mirror-relocation"
        let first = try FixtureAnswers.exchange(fixture, "set_cwd", occurrence: 0)
        let second = try FixtureAnswers.exchange(fixture, "set_cwd", occurrence: 1)
        let path = try XCTUnwrap(first.request["path"] as? String)
        let needsTrust = try XCTUnwrap(first.body)
        let directory = try XCTUnwrap(needsTrust["directory"] as? String)

        let supervisor = try await liveChannel(rig, ReplayScript.exchange("set_cwd", answer: needsTrust)
            + ReplayScript.exchange("set_cwd", answer: try XCTUnwrap(second.body)))

        guard case .controlRequest(let request) = CommandRouter.route("/cd \(path)") else {
            return XCTFail("/cd did not route to a control request")
        }
        XCTAssertEqual(request.payload, .object(["path": .string(path)]), "the first call carries the path alone")
        let answer = try await StrategyExecutor.send(request, on: supervisor)
        XCTAssertEqual(answer["status"]?.stringValue, "needs_trust")
        XCTAssertEqual(answer["directory"]?.stringValue, directory)

        // The whole payload, keys and values: fake-claude matches a recorded control request by subtype alone
        // (`fake_claude.py` `_input_pred`), so the replay would accept any second `set_cwd` and this is the test.
        let follow = CommandRouter.continueCD(afterNeedsTrust: directory, path: path)
        var recorded = second.request
        recorded.removeValue(forKey: "subtype")
        XCTAssertEqual(follow.payload, Self.json(recorded))
        let accepted = try await StrategyExecutor.send(AnyControlRequest(follow), on: supervisor)
        XCTAssertEqual(accepted["status"]?.stringValue, "ok")
    }

    /// The two plainest mappings, asserted on the payload rather than on the case.
    func testRenameAndModelMapToTheirRequests() {
        guard case .controlRequest(let rename) = CommandRouter.route("/rename hello"),
              case .controlRequest(let model) = CommandRouter.route("/model sonnet") else {
            return XCTFail("the two commands did not route to control requests")
        }
        XCTAssertEqual(rename.subtype, RenameSession.subtype)
        XCTAssertEqual(rename.payload, .object(["title": .string("hello")]))
        XCTAssertEqual(model.subtype, SetModel.subtype)
        XCTAssertEqual(model.payload, .object(["model": .string("sonnet")]))
    }

    // MARK: - Refusal, fall-through and the matrix

    /// A command the engine says belongs to the terminal is hidden from autocomplete and refused here with the
    /// explanation, rather than being sent as text for the engine to refuse.
    ///
    /// The lists are fed in the form the engine actually sends them: `system/init.slash_commands` and
    /// `terminal_slash_commands` carry **bare** names (`vim`, `doctor`) on every one of the recorded fixtures and in
    /// the bundle that builds them, while the composer's line and the local table are slash-prefixed. Comparing the
    /// two spellings makes the terminal-only refusal dead code and leaves every engine command missing from
    /// autocomplete's subtraction, so both sides are normalised on ingestion.
    ///
    /// Deliberate break: drop the normalisation from `route` → `/vim` falls through as text; drop it from
    /// `autocomplete` → `/doctor` is offered and the engine's own commands are offered unslashed.
    func testTerminalOnlyCommandsAreHiddenAndRefusedWithAnExplanation() throws {
        let systemInit = try Self.systemInit(commands: ["model", "vim", "doctor"], terminalOnly: ["vim", "doctor"])
        guard case .refusedLocally(let explanation) = CommandRouter.route("/vim", systemInit: systemInit) else {
            return XCTFail("/vim was not refused locally")
        }
        XCTAssertTrue(explanation.contains("/vim"), "the explanation names the command; got \(explanation)")
        let completions = CommandRouter.autocomplete(systemInit: systemInit)
        XCTAssertFalse(completions.contains("/vim"), "a terminal-only command is not offered")
        XCTAssertFalse(completions.contains("vim"), "nor is its unslashed spelling")
        XCTAssertFalse(completions.contains("/doctor"), "a terminal-only command survives the subtraction only "
                       + "when the two lists are spelled the same way")
        XCTAssertTrue(completions.contains("/model"))
        XCTAssertTrue(completions.allSatisfy { $0.hasPrefix("/") },
                      "autocomplete offers one spelling; got \(completions)")
    }

    /// A command whose value the user did not type opens the surface's picker. Nothing is sent: an
    /// `apply_flag_settings` carrying an empty string would write `""` into the session's flag settings, and the
    /// engine would have no way to tell that from a value the user chose.
    func testCommandsWithNoArgumentOpenAPickerAndSendNothing() {
        for (line, surface) in [("/model", "modelPicker"), ("/effort", "effortPicker"), ("/agent", "agentPicker")] {
            guard case .native(let opened) = CommandRouter.route(line) else {
                return XCTFail("bare \(line) did not open a picker")
            }
            XCTAssertEqual(opened, surface)
        }
        // `/fast` is the exception and is right to be: it is a toggle over what the channel is already running.
        guard case .controlRequest(let toggled) = CommandRouter.route("/fast") else {
            return XCTFail("bare /fast did not route to a control request")
        }
        XCTAssertEqual(toggled.payload, .object(["settings": .object(["fastMode": .bool(true)])]))
        var running = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp"))
        running.fastModeObserved = true
        guard case .controlRequest(let off) = CommandRouter.route("/fast", runtime: running) else {
            return XCTFail("bare /fast did not route to a control request")
        }
        XCTAssertEqual(off.payload, .object(["settings": .object(["fastMode": .bool(false)])]))
    }

    /// Anything the table does not name and the engine does not call terminal-only goes to the engine as text.
    func testUnknownLocalCommandFallsThroughAsText() {
        guard case .text(let text) = CommandRouter.route("/definitely-not-a-command x") else {
            return XCTFail("an unknown command did not fall through as text")
        }
        XCTAssertEqual(text, "/definitely-not-a-command x")
    }

    /// The bare drift refusal — the whole assistant answer and nothing more — is replaced and counted; the same
    /// sentence inside a longer answer is the model talking about the command and is left alone.
    func testTheBareRefusalIsInterceptedReplacedAndCounted() async {
        let interceptor = RefusalInterceptor()
        let bare = "/vim isn't available in this environment."
        let hit = await interceptor.intercept(bare)
        XCTAssertEqual(hit?.command, "/vim")
        XCTAssertEqual(hit?.replacement, RouterTable.explanation(forTerminalOnly: "/vim"))
        var counted = await interceptor.driftCount
        XCTAssertEqual(counted, 1)

        let embedded = "I tried, but \(bare) You could open a terminal instead."
        let miss = await interceptor.intercept(embedded)
        XCTAssertNil(miss, "the sentence inside a longer answer is the model talking, not the engine refusing")
        counted = await interceptor.driftCount
        XCTAssertEqual(counted, 1)
    }

    /// `/add-dir` is a restart, not a runtime change, and the matrix says which settings are which.
    func testAddDirBuildsARestartRequestAndTheMatrixClassifiesEverySetting() {
        guard case .restart(let request) = CommandRouter.route("/add-dir /tmp") else {
            return XCTFail("/add-dir did not route to a restart")
        }
        XCTAssertEqual(request.addDirectories, [URL(fileURLWithPath: "/tmp")])

        // A relative path is the user's, and the user's directory is the *channel's* cwd — never the directory
        // afleet's own process happens to have been started in, which is what an unbased `fileURLWithPath` reads.
        //
        // Deliberate break: drop `relativeTo: runtime?.cwd` -> the launch carries afleet's own cwd + `/sub`.
        let runtime = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/project"))
        guard case .restart(let relative) = CommandRouter.route("/add-dir sub", runtime: runtime) else {
            return XCTFail("/add-dir did not route to a restart")
        }
        let resolved = (relative.addDirectories ?? []).map { (url: URL) in url.path(percentEncoded: false) }
        XCTAssertEqual(resolved, ["/tmp/project/sub"], "a relative add-dir resolves against the channel's cwd")
        XCTAssertEqual(LaunchSettingMatrix.runtimeMutable,
                       ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode",
                        "cwd"])
        XCTAssertEqual(LaunchSettingMatrix.restartRequired,
                       ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources",
                        "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"])
        XCTAssertTrue(LaunchSettingMatrix.runtimeMutable.isDisjoint(with: LaunchSettingMatrix.restartRequired))
    }

    // MARK: - Helpers

    /// A `system/init` carrying the two command lists and nothing a router reads beside them.
    ///
    /// Decoded rather than constructed: `SystemInitFields`' memberwise initialiser is internal to ClaudeWire, so a
    /// consumer builds one the way the wire does — from the frame's own keys.
    private static func systemInit(commands: [String], terminalOnly: [String]) throws -> SystemInitFields {
        let object: [String: Any] = [
            "type": "system", "subtype": "init", "cwd": "/tmp", "session_id": SessionID().description,
            "tools": [], "mcp_servers": [], "model": "haiku", "permissionMode": "default",
            "slash_commands": commands, "terminal_slash_commands": terminalOnly, "apiKeySource": "none",
            "claude_code_version": "0.0.0", "output_style": "default", "skills": [], "plugins": [],
            "uuid": UUID().uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(SystemInitFields.self, from: data)
    }

    /// A `JSONSerialization` object, as the `JSONValue` the wire speaks in.
    static func json(_ object: [String: Any]) -> JSONValue {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
    }
}

/// The app's `StrategyUI`, scripted: it records what it was handed and answers the confirmation the test chose.
actor ScriptedStrategyUI: StrategyUI {
    private(set) var opened: [String] = []
    private(set) var previews: [RewindPreview] = []
    private let answer: RewindChoice

    init(answers: RewindChoice) { self.answer = answers }

    func open(url: String) async { opened.append(url) }
    func confirm(preview: RewindPreview) async -> RewindChoice {
        previews.append(preview)
        return answer
    }
}
