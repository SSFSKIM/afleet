import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The quiescent restart: the runtime-state record it carries, the launch it composes from a snapshot of that
/// record, the flag union it re-sends, and the readbacks that gate `.ready`.
///
/// Where a step runs against a scripted answer rather than a recorded frame, the test says so: the corpus's
/// `control-shapes` recording carries the shapes of `apply_flag_settings`, `get_settings` and `set_cwd`, but its
/// recorded host-input line for the section that holds them is a `user` frame the restart never sends, so a replay
/// of it cannot serve a relaunch. These tests therefore replay `resume-no-replay` — the fixture that stays alive
/// after the handshake — and answer the host's control requests from a `FAKE_CLAUDE_SCRIPT` whose answers take
/// their *shape* from the `control-shapes` recording and their values from the test.
///
/// Four request shapes have no recorded counterpart anywhere under `Fixtures/` and are the host's own: `set_model`,
/// `set_permission_mode`, `add_directory`, and a `get_settings` answer carrying an `output_style`. The first three
/// are answered with the bare success every setter is answered with, and their payloads are composed by FleetKit,
/// so no engine byte is invented in any of them; the fourth adds one key to the recorded `applied` object.
final class RestartTests: XCTestCase {
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

    /// The `get_settings` answer, in the live shape the `control-shapes` recording carries:
    /// `{applied: {...}, effective: {key: value}, sources: [{source, settings: {key: value}}]}`. The engine reports
    /// `effective` as an *object* of applied settings, and the reader takes its keys; a fixture's own values are
    /// redacted, so the ones here are invented and only the shape is the recording's.
    private static func settingsAnswer(applied: [String: Any], effective keys: [String]) -> [String: Any] {
        let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, "invented-\($0)") })
        return ["applied": applied, "effective": values,
                "sources": [["source": "flagSettings", "settings": values]]]
    }

    /// The fixture's own initialize response with one key replaced — the `FAKE_CLAUDE_INIT` override, which is a
    /// whole-body replacement, so it is built from the recording rather than composed.
    private func initOverride(_ rig: Rig, permissionMode: String) throws -> URL {
        let lines = try String(contentsOf: FakeClaudeLaunch.fixture(Self.idle).appending(path: "frames.ndjson"),
                               encoding: .utf8)
        var body: [String: Any]?
        for line in lines.split(separator: "\n") where !line.isEmpty {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["dir"] as? String == "out",
                  let frame = record["frame"] as? [String: Any],
                  let response = frame["response"] as? [String: Any],
                  let inner = response["response"] as? [String: Any], inner["commands"] != nil else { continue }
            body = inner
            break
        }
        var override = try XCTUnwrap(body, "the fixture records no initialize response")
        override["current_permission_mode"] = permissionMode
        let directory = scriptDirectory(rig)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "init-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: override, options: [.sortedKeys]).write(to: url)
        return url
    }

    // MARK: - The launch the restart composes

    /// Every launch field comes from the runtime record and none from the template: the template is opened with
    /// model `sonnet` and `agent: "reviewer"`, and the relaunch carries `opus`, `plan`, `low` and no agent at all.
    ///
    /// Scripted, not recorded: both children's control answers come from a `FAKE_CLAUDE_SCRIPT`. The relaunch's
    /// `expect` for `apply_flag_settings` is the assertion that the request arrived carrying the flag union — a
    /// replay that never sees it fails with exit 3.
    func testRestartCarriesRuntimeValuesAndNeverAgent() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(session, fork: false))
        template.model = "sonnet"
        template.permissionMode = .default
        template.agent = "reviewer"
        template.addDirectories = [URL(fileURLWithPath: "/tmp/a")]

        let applied = Self.settingsAnswer(applied: ["model": "opus", "effort": "low"],
                                          effective: ["fastMode"])
        let script = try ReplayScript.write(
            ReplayScript.exchange("set_permission_mode")
                + ReplayScript.exchange("set_model")
                + ReplayScript.exchange("apply_flag_settings")
                + ReplayScript.exchange("get_settings", answer: applied),
            fixture: Self.idle, into: scriptDirectory(rig))
        let relaunch = try ReplayScript.write(
            ReplayScript.exchange("apply_flag_settings", matching: ["request.settings.fastMode": true])
                + ReplayScript.exchange("get_settings", answer: applied),
            fixture: Self.idle, into: scriptDirectory(rig))

        let supervisor = rig.supervisor(session: session, fixture: Self.idle, template: template,
                                        script: script, relaunchScript: relaunch)
        try await supervisor.open()

        _ = try await supervisor.perform(SetPermissionMode(mode: .plan))
        _ = try await supervisor.perform(SetModel(model: "opus"))
        _ = try await supervisor.perform(ApplyFlagSettings(settings: .object(["fastMode": .bool(true)])))
        _ = try await supervisor.perform(GetSettings())

        let runtime = await supervisor.runtimeState()
        XCTAssertEqual(runtime.permissionMode, .plan)
        XCTAssertEqual(runtime.model, "opus")
        XCTAssertEqual(runtime.effort, "low")
        XCTAssertEqual(runtime.outputStyle, "default", "seeded from the handshake the fixture recorded")
        XCTAssertEqual(runtime.flagSettings, ["fastMode": .bool(true)])

        let request = RestartRequest(addDirectories: [URL(fileURLWithPath: "/tmp/a"),
                                                      URL(fileURLWithPath: "/tmp/b")])
        try await rig.steppingClock { try await supervisor.quiescentRestart(request) }

        XCTAssertEqual(rig.launches.count, 2)
        let relaunched = rig.launches[1]
        XCTAssertEqual(relaunched.permissionMode, .plan)
        XCTAssertEqual(relaunched.model, "opus")
        XCTAssertEqual(relaunched.effort, "low")
        // Booleans over `--add-dir` and cwd lists throughout this file: the values here are invented, but the
        // shape is the one tracker entry 75 sweeps for, and a rig-rooted directory reaches these same assertions.
        XCTAssertTrue(relaunched.addDirectories.map(\.path)
                          == [URL(fileURLWithPath: "/tmp/a").path, URL(fileURLWithPath: "/tmp/b").path],
                      "the relaunch carries \(relaunched.addDirectories.count) add-dirs, not the 2 the request named")
        XCTAssertNil(relaunched.agent, "a restart never re-passes --agent")
        XCTAssertEqual(relaunched.session, .resume(session, fork: false))
        let state = await supervisor.state
        XCTAssertEqual(state.epoch?.rawValue, 2, "the epoch advanced")
        // The fixture's own handshake reports `default`, so the permission-mode readback does not match and the
        // channel correctly stays connecting behind the banner; the mismatch half has its own test.
        XCTAssertEqual(state.origin, .owned(.connecting))
        XCTAssertEqual(state.banner, .settingDidNotSurvive("permissionMode"))
    }

    // MARK: - Queueing behind running work

    /// A channel with a running task is not dormant-eligible: the change is queued, nothing is terminated, and the
    /// dormant timer runs the restart once the task is gone.
    ///
    /// Scripted, not recorded: the channel runs on the scripted handle, whose `get_settings` answer is the test's.
    func testRestartWaitsForDormantEligibilityAndQueuesTheChange() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let eligibility = EligibilityBox()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting),
                                        eligibility: eligibility)
        try await supervisor.spawn(reason: .open)
        let handle = rig.scriptedHandles[0]
        eligibility.mirror = [MirrorEntryStandIn(taskID: "t-1", isRunning: true, isBackground: true)]

        let request = RestartRequest(addDirectories: [URL(fileURLWithPath: "/tmp/b")])
        try await supervisor.quiescentRestart(request)

        let queued = await supervisor.state
        XCTAssertEqual(queued.pendingChange, request, "the change applies when the current work finishes")
        XCTAssertEqual(handle.terminateCount, 0, "nothing was terminated while the task ran")
        XCTAssertEqual(rig.spawnCount, 1)

        eligibility.mirror = []
        try await rig.waitForSleeper(due: ChannelSupervisor.dormantAfter)
        let relaunched = rig.expectScriptedHandles(2, description: "the queued restart built its child")
        await rig.clock.advance(by: ChannelSupervisor.dormantAfter)

        try await TestTiming.awaitDelivery([relaunched])
        guard rig.launches.count >= 2 else { return XCTFail("the queued restart built no second child") }
        XCTAssertEqual(handle.terminateCount, 1)
        let restarted = await supervisor.state
        XCTAssertNil(restarted.pendingChange)
        XCTAssertTrue(rig.launches[1].addDirectories.map(\.path) == [URL(fileURLWithPath: "/tmp/b").path],
                      "the queued restart's relaunch carries \(rig.launches[1].addDirectories.count) add-dirs, not 1")
    }

    // MARK: - The readbacks

    /// The permission mode the new handshake reports is the source for that readback: a handshake that answers the
    /// snapshot's mode lets the channel become ready, and one that answers a different mode raises the banner and
    /// keeps the channel connecting until the user picks a value.
    ///
    /// Scripted, not recorded: `get_settings` is answered by the script. The handshake is the fixture's own
    /// recorded initialize response with `current_permission_mode` replaced through `FAKE_CLAUDE_INIT`.
    func testAReadbackMismatchRaisesTheBannerAndKeepsConnecting() async throws {
        for (reported, survives) in [("plan", true), ("default", false)] {
            let rig = try newRig()
            let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
            let script = try ReplayScript.write(ReplayScript.exchange("set_permission_mode"),
                                                fixture: Self.idle, into: scriptDirectory(rig))
            let relaunch = try ReplayScript.write(
                ReplayScript.exchange("get_settings",
                                      answer: Self.settingsAnswer(applied: [:], effective: [])),
                fixture: Self.idle, into: scriptDirectory(rig))
            let supervisor = rig.supervisor(session: session, fixture: Self.idle, script: script,
                                            relaunchScript: relaunch,
                                            initOverride: try initOverride(rig, permissionMode: reported))
            try await supervisor.open()
            _ = try await supervisor.perform(SetPermissionMode(mode: .plan))

            rig.forgetTransitions()
            try await rig.steppingClock { try await supervisor.quiescentRestart(RestartRequest()) }

            // The restart's route is the reap plus the dormant resume, and the table has no row of its own for it:
            // terminate with no replacement is `readyDormantEligible`, the relaunch is `dormantSent`, and the
            // readbacks are what let `connectingClean` run. Pinned here so the composition cannot drift silently.
            let composition: Set<LifecycleTable.Transition> = [
                .init(.readyDormantEligible, .ready, .dormantTimerFired, .dormant),
                .init(.dormantSent, .dormant, .userSent, .connecting),
                .init(.connectingClean, .connecting, .handshakeClean, .ready),
            ]
            let state = await supervisor.state
            if survives {
                XCTAssertEqual(state.origin, .owned(.ready), "every readback matched")
                XCTAssertNil(state.banner)
                rig.assertObserved(composition)
                continue
            }
            rig.assertObserved(composition.subtracting([
                .init(.connectingClean, .connecting, .handshakeClean, .ready)]))
            XCTAssertEqual(state.origin, .owned(.connecting), "the composer stays disabled")
            XCTAssertEqual(state.banner, .settingDidNotSurvive("permissionMode"))
            try await rig.drainPublished(of: supervisor)
            XCTAssertFalse(rig.published(of: supervisor).contains {
                $0.origin == .owned(.ready) && $0.epoch?.rawValue == 2
            }, "no ready state was published for the relaunched epoch")

            await supervisor.resolveSetting("permissionMode")
            let resolved = await supervisor.state
            XCTAssertEqual(resolved.origin, .owned(.ready))
            XCTAssertNil(resolved.banner)
            rig.assertObserved(composition)
        }
    }

    /// The values a `/model` and a `/permissions` change put into the runtime record are the values the relaunch
    /// carries, not the ones the channel was opened with. Task 8 routes the same change through the command router.
    ///
    /// Scripted, not recorded: both children's control answers come from a `FAKE_CLAUDE_SCRIPT`.
    func testControlAnswersThenRestartCarryTheChangedValues() async throws {
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
            ReplayScript.exchange("get_settings", answer: Self.settingsAnswer(applied: [:], effective: [])),
            fixture: Self.idle, into: scriptDirectory(rig))
        let supervisor = rig.supervisor(session: session, fixture: Self.idle, template: template,
                                        script: script, relaunchScript: relaunch)
        try await supervisor.open()

        _ = try await supervisor.perform(SetModel(model: "opus"))
        _ = try await supervisor.perform(SetPermissionMode(mode: .plan))
        let runtime = await supervisor.runtimeState()
        XCTAssertEqual(runtime.model, "opus")
        XCTAssertEqual(runtime.permissionMode, .plan)

        let request = RestartRequest(addDirectories: [URL(fileURLWithPath: "/tmp/b")])
        try await rig.steppingClock { try await supervisor.quiescentRestart(request) }

        XCTAssertEqual(rig.launches[1].model, "opus")
        XCTAssertEqual(rig.launches[1].permissionMode, .plan)
        XCTAssertEqual(rig.launches[0].model, "sonnet", "the template still reads what the channel was opened with")
        XCTAssertEqual(rig.launches[0].permissionMode, .default)
    }

    /// A `set_cwd` the host made mid-session is where the relaunch's working directory comes from.
    ///
    /// Scripted, not recorded: the `set_cwd` answer is the script's, in the shape the `control-shapes` recording
    /// carries for an accepted change (`{status: "ok", cwd: <resolved>}`).
    func testRestartRelaunchesTheCWDChangedBySetCwd() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
        let a = rig.scratch.appending(path: "a")
        let b = rig.scratch.appending(path: "b")
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: a, session: .resume(session, fork: false))
        template.cwd = a

        let script = try ReplayScript.write(
            ReplayScript.exchange("set_cwd", answer: ["status": "ok", "cwd": b.path, "changed": true]),
            fixture: Self.idle, into: scriptDirectory(rig))
        let relaunch = try ReplayScript.write(
            ReplayScript.exchange("get_settings", answer: Self.settingsAnswer(applied: [:], effective: [])),
            fixture: Self.idle, into: scriptDirectory(rig))
        let supervisor = rig.supervisor(session: session, fixture: Self.idle, template: template,
                                        script: script, relaunchScript: relaunch)
        try await supervisor.open()

        _ = try await supervisor.perform(SetCwd(path: b.path))
        try await rig.steppingClock { try await supervisor.quiescentRestart(RestartRequest()) }

        // Both directories are under the rig's scratch root, so an equality here would print it twice.
        XCTAssertTrue(rig.launches[1].cwd.path == b.path, "the relaunch did not run in the set_cwd directory")
        XCTAssertTrue(rig.launches[0].cwd.path == a.path, "the template's cwd still reads a")
    }

    /// The cumulative `--add-dir` list is the template's plus every accepted `add_directory`; a request that names
    /// a list replaces it instead.
    ///
    /// Scripted, not recorded: the corpus records no `add_directory` frame at all — it is a cloud-container staging
    /// call with no local equivalent — so the request and its accepting answer are both the script's.
    func testAnAddDirectoryMadeMidSessionSurvivesRestart() async throws {
        let rig = try newRig()
        let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(session, fork: false))
        template.addDirectories = [URL(fileURLWithPath: "/tmp/a")]

        let script = try ReplayScript.write(
            ReplayScript.exchange("add_directory", answer: ["directory": "/tmp/mid"]),
            fixture: Self.idle, into: scriptDirectory(rig))
        let relaunch = try ReplayScript.write(
            ReplayScript.exchange("get_settings", answer: Self.settingsAnswer(applied: [:], effective: [])),
            fixture: Self.idle, into: scriptDirectory(rig))
        let supervisor = rig.supervisor(session: session, fixture: Self.idle, template: template,
                                        script: script, relaunchScript: relaunch)
        try await supervisor.open()

        _ = try await supervisor.perform(RawControlRequest(subtype: "add_directory",
                                                           payload: .object(["directory": .string("/tmp/mid")])))
        try await rig.steppingClock { try await supervisor.quiescentRestart(RestartRequest()) }
        XCTAssertTrue(rig.launches[1].addDirectories.map(\.path)
                          == [URL(fileURLWithPath: "/tmp/a").path, URL(fileURLWithPath: "/tmp/mid").path],
                      "the cumulative list is not the template's plus the accepted add_directory")

        let replacing = RestartRequest(addDirectories: [URL(fileURLWithPath: "/tmp/a"),
                                                        URL(fileURLWithPath: "/tmp/b")])
        try await rig.steppingClock { try await supervisor.quiescentRestart(replacing) }
        XCTAssertTrue(rig.launches[2].addDirectories.map(\.path)
                          == [URL(fileURLWithPath: "/tmp/a").path, URL(fileURLWithPath: "/tmp/b").path],
                      "a request that names a list replaces the cumulative one")
    }

    /// The whole flag union goes out in one `apply_flag_settings`, and every key of it must come back in
    /// `get_settings.effective`.
    ///
    /// Scripted, not recorded: the answers are the script's. Their shapes are the `control-shapes` recording's —
    /// `apply_flag_settings` is answered with a bare success there, and its `get_settings` answer carries
    /// `effective: {effortLevel: …}`; the script's answer carries `fastMode` beside it.
    func testEveryFlagSettingKeyIsReappliedAndPresentInEffectiveKeys() async throws {
        for (keys, survives) in [(["effortLevel", "fastMode"], true), (["effortLevel"], false)] {
            let rig = try newRig()
            let session = try FakeClaudeLaunch.sessionID(of: Self.idle)
            let script = try ReplayScript.write(
                ReplayScript.exchange("apply_flag_settings", matching: ["request.settings.effortLevel": "low"])
                    + ReplayScript.exchange("apply_flag_settings", matching: ["request.settings.fastMode": true]),
                fixture: Self.idle, into: scriptDirectory(rig))
            let relaunch = try ReplayScript.write(
                ReplayScript.exchange("apply_flag_settings",
                                      matching: ["request.settings.effortLevel": "low",
                                                 "request.settings.fastMode": true])
                    + ReplayScript.exchange("get_settings",
                                            answer: Self.settingsAnswer(applied: [:], effective: keys)),
                fixture: Self.idle, into: scriptDirectory(rig))
            let supervisor = rig.supervisor(session: session, fixture: Self.idle, script: script,
                                            relaunchScript: relaunch)
            try await supervisor.open()

            _ = try await supervisor.perform(
                ApplyFlagSettings(settings: .object(["effortLevel": .string("low")])))
            _ = try await supervisor.perform(ApplyFlagSettings(settings: .object(["fastMode": .bool(true)])))
            let runtime = await supervisor.runtimeState()
            XCTAssertEqual(runtime.flagSettings, ["effortLevel": .string("low"), "fastMode": .bool(true)])

            try await rig.steppingClock { try await supervisor.quiescentRestart(RestartRequest()) }

            let state = await supervisor.state
            if survives {
                XCTAssertEqual(state.origin, .owned(.ready))
                XCTAssertNil(state.banner)
            } else {
                XCTAssertEqual(state.origin, .owned(.connecting))
                XCTAssertEqual(state.banner, .settingDidNotSurvive("flagSettings.fastMode"))
            }
        }
    }

    // MARK: - The updater and the readback matrix, as tables

    /// Every answer and every frame that changes a value, one row at a time.
    ///
    /// Scripted, not recorded, for two rows: the corpus records no `add_directory` frame, and no `get_settings`
    /// answer that carries an `output_style`; those two rows use invented values in the recorded shape. Every other
    /// row's shape and values are the `control-shapes` recording's.
    func testRuntimeStateIsUpdatedByEachAnswerAndFrame() throws {
        var seeded = false
        var state = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/one"))

        RuntimeStateUpdater.apply(subtype: "set_model", payload: .object(["model": .string("opus")]),
                                  answer: .object([:]), to: &state)
        XCTAssertEqual(state.model, "opus")

        RuntimeStateUpdater.apply(subtype: "set_permission_mode", payload: .object(["mode": .string("plan")]),
                                  answer: .object([:]), to: &state)
        XCTAssertEqual(state.permissionMode, .plan)

        // The `control-shapes` answer carries `model`, `effort`, `advisor` and `ultracode` and no fast-mode key.
        RuntimeStateUpdater.apply(
            subtype: "get_settings", payload: .object([:]),
            answer: .object(["applied": .object(["model": .string("haiku"), "effort": .string("low"),
                                                 "advisor": .null, "ultracode": .bool(false),
                                                 "output_style": .string("Concise")]),
                             "effective": .object(["effortLevel": .string("low")]),
                             "sources": .array([])]),
            to: &state)
        XCTAssertEqual(state.model, "haiku")
        XCTAssertEqual(state.effort, "low")
        XCTAssertEqual(state.outputStyle, "Concise")
        XCTAssertNil(state.fastModeObserved, "no `get_settings` answer carries fast mode")

        // Present-and-null is the engine's "back to the default" and clears the value, exactly as `set_model` two
        // rows above reads it; a reader that took only the string would leave a stale effort in the record and a
        // restart would re-send a level the user has since cleared.
        //
        // Deliberate break: read `applied["effort"]?.stringValue` under an `if let` again -> the cleared effort
        // stays "low" and the next relaunch carries it.
        RuntimeStateUpdater.apply(
            subtype: "get_settings", payload: .object([:]),
            answer: .object(["applied": .object(["effort": .null])]), to: &state)
        XCTAssertNil(state.effort, "present-and-null clears the effort")
        RuntimeStateUpdater.apply(
            subtype: "get_settings", payload: .object([:]),
            answer: .object(["applied": .object(["model": .string("haiku")])]), to: &state)
        XCTAssertNil(state.effort, "an answer that does not mention effort is not a statement about it")
        RuntimeStateUpdater.apply(
            subtype: "get_settings", payload: .object([:]),
            answer: .object(["applied": .object(["effort": .string("low")])]), to: &state)
        XCTAssertEqual(state.effort, "low")

        RuntimeStateUpdater.apply(subtype: "apply_flag_settings",
                                  payload: .object(["settings": .object(["effortLevel": .string("low")])]),
                                  answer: .object([:]), to: &state)
        RuntimeStateUpdater.apply(subtype: "apply_flag_settings",
                                  payload: .object(["settings": .object(["fastMode": .bool(true)])]),
                                  answer: .object([:]), to: &state)
        XCTAssertEqual(state.flagSettings, ["effortLevel": .string("low"), "fastMode": .bool(true)],
                       "the union of every payload")
        RuntimeStateUpdater.apply(subtype: "apply_flag_settings",
                                  payload: .object(["settings": .object(["fastMode": .bool(false)])]),
                                  answer: .object([:]), to: &state)
        XCTAssertEqual(state.flagSettings["fastMode"], .bool(false), "the later value wins")

        RuntimeStateUpdater.apply(subtype: "set_cwd", payload: .object(["path": .string("/tmp/two")]),
                                  answer: .object(["status": .string("ok"), "cwd": .string("/tmp/two")]),
                                  to: &state)
        XCTAssertTrue(state.cwd.path == URL(fileURLWithPath: "/tmp/two").path,
                      "an accepted set_cwd did not move the recorded cwd")

        RuntimeStateUpdater.apply(subtype: "add_directory", payload: .object(["directory": .string("/tmp/mid")]),
                                  answer: .object(["directory": .string("/tmp/mid")]), to: &state)
        XCTAssertTrue(state.addDirectories.map(\.path) == [URL(fileURLWithPath: "/tmp/mid").path],
                      "an accepted add_directory did not land in the recorded list")

        let before = state
        RuntimeStateUpdater.apply(subtype: "list_models", payload: .object([:]),
                                  answer: .object(["models": .array([])]), to: &state)
        XCTAssertEqual(state, before, "an unrelated answer changes nothing")

        // `fast_mode_state` rides on the initialize response and on `result`, and on no other frame.
        RuntimeStateUpdater.apply(handshake: InitializeResponse(raw: .object(["fast_mode_state": .string("off")])),
                                  to: &state)
        XCTAssertEqual(state.fastModeObserved, false)
        RuntimeStateUpdater.apply(frame: try Self.resultFrame(fastModeState: "on"), to: &state,
                                  seededFromInit: &seeded)
        XCTAssertEqual(state.fastModeObserved, true, "a toggle made mid-turn is reported on `result`")

        var fresh = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/one"))
        var freshSeeded = false
        // `effort` is a typed field of `system/init` and the engine emits it. Left out of the seeding block it is
        // missed for ever, because the block runs once: the record then reports no effort for a channel launched
        // with one, and the restart's readback compares against nothing.
        //
        // Deliberate break: drop `state.effort = initFrame.effort` -> the seed reads nil and the second init,
        // which seeds nothing, cannot recover it.
        RuntimeStateUpdater.apply(frame: try Self.systemInitFrame(model: "haiku", permissionMode: "acceptEdits",
                                                                  outputStyle: "Concise", cwd: "/tmp/three",
                                                                  agent: "reviewer", effort: "high"),
                                  to: &fresh, seededFromInit: &freshSeeded)
        XCTAssertEqual(fresh.effort, "high", "the first system/init seeds the effort it reports")
        XCTAssertEqual(fresh.model, "haiku")
        XCTAssertEqual(fresh.permissionMode, .acceptEdits)
        XCTAssertEqual(fresh.outputStyle, "Concise")
        XCTAssertTrue(fresh.cwd.path == URL(fileURLWithPath: "/tmp/three").path,
                      "the first system/init did not seed the cwd it reports")
        XCTAssertEqual(fresh.agent, "reviewer")
        RuntimeStateUpdater.apply(frame: try Self.systemInitFrame(model: "opus", permissionMode: "plan",
                                                                  outputStyle: "default", cwd: "/tmp/four",
                                                                  agent: nil, effort: "low"),
                                  to: &fresh, seededFromInit: &freshSeeded)
        XCTAssertEqual(fresh.model, "haiku", "only the first system/init seeds")
        XCTAssertEqual(fresh.effort, "high", "and the effort with it")
    }

    /// Each value is read back from its own source and from no other, and a mismatch names exactly that setting.
    func testReadbackReadsEachValueFromItsOwnSource() throws {
        // The handshake deliberately reports a *different* model from `applied`, so a check that read the model
        // from the handshake would pass the matching row and fail the mismatching one.
        func handshake(model: String = "from-the-handshake", permissionMode: String = "plan",
                       outputStyle: String = "default", fastMode: String = "off") -> InitializeResponse {
            InitializeResponse(raw: .object(["current_model": .string(model),
                                             "current_permission_mode": .string(permissionMode),
                                             "output_style": .string(outputStyle),
                                             "fast_mode_state": .string(fastMode)]))
        }
        var snapshot = SessionRuntimeState(permissionMode: .plan, model: "opus", effort: "low",
                                           outputStyle: "default", cwd: URL(fileURLWithPath: "/tmp/one"))
        let applied = JSONValue.object(["model": .string("opus"), "effort": .string("low")])

        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(), settingsApplied: applied,
                                       effectiveKeys: []), [])
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(),
                                       settingsApplied: .object(["model": .string("sonnet"),
                                                                 "effort": .string("low")]),
                                       effectiveKeys: []), ["model"])
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(),
                                       settingsApplied: .object(["model": .string("opus"),
                                                                 "effort": .string("high")]),
                                       effectiveKeys: []), ["effort"])
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(permissionMode: "default"),
                                       settingsApplied: applied, effectiveKeys: []), ["permissionMode"])
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(outputStyle: "Concise"),
                                       settingsApplied: applied, effectiveKeys: []), ["outputStyle"])

        snapshot.flagSettings = ["effortLevel": .string("low")]
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(), settingsApplied: applied,
                                       effectiveKeys: []), ["flagSettings.effortLevel"])
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(), settingsApplied: applied,
                                       effectiveKeys: ["effortLevel"]), [])

        snapshot.flagSettings = [:]
        snapshot.fastModeObserved = true
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(fastMode: "off"),
                                       settingsApplied: applied, effectiveKeys: []), ["fastMode"])

        // Two at once: the order is fixed, and it is what decides which setting the banner names.
        snapshot.fastModeObserved = nil
        snapshot.flagSettings = ["effortLevel": .string("low")]
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake(permissionMode: "default"),
                                       settingsApplied: .object(["model": .string("sonnet"),
                                                                 "effort": .string("low")]),
                                       effectiveKeys: []),
                       ["model", "permissionMode", "flagSettings.effortLevel"])
    }

    /// The model the host set is an *alias*; `get_settings.applied.model` reports the model the engine resolved it
    /// to. Comparing the two raw fails a restart that put the model back exactly right, and the banner it raises
    /// never clears. The handshake's `models` table is the engine's own alias-to-resolution map, so the snapshot's
    /// value is resolved through it before the comparison; an alias the table does not carry compares raw.
    ///
    /// Scripted, not recorded, in shape only: `models[].{value, resolvedModel}` and the resolved id are the
    /// `control-shapes` recording's own key names and its own resolution of `opus[1m]`.
    ///
    /// Deliberate break: compare `snapshot.model` with `applied["model"]` directly again.
    func testTheModelReadbackResolvesTheAliasThroughTheHandshakeTable() throws {
        let table = JSONValue.array([
            .object(["value": .string("default"), "resolvedModel": .string("claude-opus-5[1m]")]),
            .object(["value": .string("opus[1m]"), "resolvedModel": .string("claude-opus-5[1m]")]),
        ])
        let handshake = InitializeResponse(raw: .object(["models": table,
                                                         "current_permission_mode": .string("plan")]))
        let resolved = JSONValue.object(["model": .string("claude-opus-5[1m]")])

        var snapshot = SessionRuntimeState(model: "opus[1m]", cwd: URL(fileURLWithPath: "/tmp/one"))
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake, settingsApplied: resolved,
                                       effectiveKeys: []), [],
                       "the alias resolves to the id the engine reported, so the model did survive")

        snapshot.model = "sonnet"
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake, settingsApplied: resolved,
                                       effectiveKeys: []), ["model"],
                       "an alias the table does not carry is compared raw, and this one really did not survive")

        snapshot.model = "claude-opus-5[1m]"
        XCTAssertEqual(Readback.verify(snapshot: snapshot, handshake: handshake, settingsApplied: resolved,
                                       effectiveKeys: []), [],
                       "a resolved id is not in the table's `value` column and compares raw, which matches")
    }

    /// Fast mode has two sources and they must not be confused: `get_settings.effective` when the host applied it, the new
    /// handshake when it was only observed, and nothing at all when neither holds.
    func testFastModeIsVerifiedFromEffectiveKeysWhenHostAppliedAndFromTheHandshakeWhenObserved() throws {
        let off = InitializeResponse(raw: .object(["fast_mode_state": .string("off")]))
        let on = InitializeResponse(raw: .object(["fast_mode_state": .string("on")]))

        // (a) host-applied: the handshake is not consulted, whatever it says.
        var applied = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/one"),
                                          flagSettings: ["fastMode": .bool(true)])
        XCTAssertEqual(Readback.verify(snapshot: applied, handshake: off, settingsApplied: .object([:]),
                                       effectiveKeys: ["fastMode"]), [])
        XCTAssertEqual(Readback.verify(snapshot: applied, handshake: on, settingsApplied: .object([:]),
                                       effectiveKeys: []), ["flagSettings.fastMode"])
        // The engine reports a host toggle lazily: the last state it reported can contradict the new handshake while
        // `effective` names the key as applied. That is a correct restart, and consulting the handshake here
        // would fail it.
        applied.fastModeObserved = true
        XCTAssertEqual(Readback.verify(snapshot: applied, handshake: off, settingsApplied: .object([:]),
                                       effectiveKeys: ["fastMode"]), [],
                       "an engine that has not caught up with a host toggle does not fail a correct restart")

        // (b) observed only: the new handshake answers for it.
        let observed = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/one"), fastModeObserved: true)
        XCTAssertEqual(Readback.verify(snapshot: observed, handshake: on, settingsApplied: .object([:]),
                                       effectiveKeys: []), [])
        XCTAssertEqual(Readback.verify(snapshot: observed, handshake: off, settingsApplied: .object([:]),
                                       effectiveKeys: []), ["fastMode"])

        // (c) neither: nothing about fast mode is checked.
        let neither = SessionRuntimeState(cwd: URL(fileURLWithPath: "/tmp/one"))
        XCTAssertEqual(Readback.verify(snapshot: neither, handshake: off, settingsApplied: .object([:]),
                                       effectiveKeys: []), [])
        XCTAssertEqual(Readback.verify(snapshot: neither, handshake: on, settingsApplied: .object([:]),
                                       effectiveKeys: []), [])
    }

    // MARK: - Ready comes last

    /// No `.ready` is published between the new handshake and the `get_settings` answer, and none at all when the
    /// answer does not match.
    ///
    /// Scripted, not recorded: the channel runs on the scripted handle, which is what lets the test hold the
    /// `get_settings` answer open and read the published states while the restart is inside it.
    func testReadyIsNotPublishedBeforeTheReadbacks() async throws {
        for matching in [true, false] {
            let rig = try newRig()
            rig.useScriptedHandle()
            let held = HeldAnswer(), entered = HeldAnswer()
            let reachedReadback = entered.expectation(description: "the restart reached get_settings")
            // Every child of this channel is scripted before it spawns, the one the restart launches included: a
            // handshake is read the instant `spawn` returns, so a handle configured afterwards is configured late.
            rig.configureScriptedHandles { handle in
                handle.initialize = .object(["current_permission_mode": .string(matching ? "plan" : "default")])
                handle.controlAnswers = ["get_settings": .object(["applied": .object([:]),
                                                                  "effective": .object([:]),
                                                                  "sources": .array([])])]
                handle.controlGate = { subtype in
                    guard subtype == "get_settings" else { return }
                    entered.release()
                    await held.wait()
                }
            }
            let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
            try await supervisor.spawn(reason: .open)
            _ = try await supervisor.perform(SetPermissionMode(mode: .plan))

            let relaunched = rig.expectScriptedHandles(2, description: "the restart built its child")
            let restart = Task { try await supervisor.quiescentRestart(RestartRequest()) }
            defer { held.release(); restart.cancel() }
            try await TestTiming.awaitDelivery([relaunched, reachedReadback])
            try await rig.drainPublished(of: supervisor)
            XCTAssertFalse(rig.published(of: supervisor).contains {
                $0.epoch?.rawValue == 2 && $0.origin == .owned(.ready)
            }, "no ready state between the new handshake and the get_settings answer")

            held.release()
            try await restart.value

            let state = await supervisor.state
            XCTAssertEqual(state.origin, matching ? .owned(.ready) : .owned(.connecting))
            if !matching {
                try await rig.drainPublished(of: supervisor)
                XCTAssertFalse(rig.published(of: supervisor).contains {
                    $0.epoch?.rawValue == 2 && $0.origin == .owned(.ready)
                }, "a mismatching answer never publishes ready")
            }
        }
    }

    // MARK: - The door a restart has to come through

    /// A restart refuses what `handOff` refuses. A wedged channel is told so rather than being handed a change it
    /// would queue forever — a wedged channel is never dormant-eligible, so "applies when the current work
    /// finishes" would never come true — and a channel that owns nothing terminates nothing and spawns nothing.
    ///
    /// Scripted, not recorded: SIGKILL cannot be refused, so the wedged half runs on the scripted handle.
    func testARestartIsRefusedOnAWedgedChannelAndOnOneThatOwnsNothing() async throws {
        let rig = try newRig()
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: nil, steps: ["exit_not_observed"]))
        let wedged = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await wedged.spawn(reason: .open)
        await wedged.reap()
        let handle = rig.scriptedHandles[0]
        XCTAssertEqual(handle.terminateCount, 1, "the reap is what wedged it")
        let spawnsBefore = rig.spawnCount

        var thrown: (any Error)?
        do { try await wedged.quiescentRestart(RestartRequest()) } catch { thrown = error }
        guard case .wedged? = thrown as? LifecycleError else {
            return XCTFail("a wedged channel gave \(String(describing: thrown))")
        }
        let wedgedState = await wedged.state
        XCTAssertNil(wedgedState.pendingChange, "no change is queued behind a ghost")
        XCTAssertEqual(handle.terminateCount, 1, "nothing else was terminated")
        XCTAssertEqual(rig.spawnCount, spawnsBefore)

        let archived = rig.supervisor(session: SessionID(), origin: .archived)
        var refusal: (any Error)?
        do { try await archived.quiescentRestart(RestartRequest()) } catch { refusal = error }
        XCTAssertEqual(refusal as? LifecycleError, .notOwned)
        XCTAssertEqual(rig.spawnCount, spawnsBefore, "a channel that owns nothing spawns nothing")
        let archivedState = await archived.state
        XCTAssertEqual(archivedState.origin, .archived)
        XCTAssertNil(archivedState.pendingChange)
    }

    // MARK: - What a crash after a restart respawns from

    /// The line a restart composed becomes the channel's line: a crash after it respawns from the restarted values,
    /// and still without `--agent` — re-passing it replays the agent's `initialPrompt` as a user turn, which is the
    /// thing the restart's own rule exists to prevent, arriving one crash later.
    ///
    /// Scripted, not recorded: the channel runs on the scripted handle so the crash and the backoff are the test's.
    func testACrashAfterARestartRespawnsFromTheRestartedLine() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        rig.configureScriptedHandles { handle in
            handle.controlAnswers = ["get_settings": .object(["applied": .object(["model": .string("opus")]),
                                                              "effective": .object([:]),
                                                                  "sources": .array([])])]
        }
        let session = SessionID()
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(session, fork: false))
        template.model = "sonnet"
        template.agent = "reviewer"
        let supervisor = rig.supervisor(session: session, origin: .owned(.connecting), template: template)
        try await supervisor.spawn(reason: .open)
        _ = try await supervisor.perform(SetModel(model: "opus"))
        try await supervisor.quiescentRestart(RestartRequest(addDirectories: [URL(fileURLWithPath: "/tmp/b")]))
        let ready = await supervisor.state
        XCTAssertEqual(ready.origin, .owned(.ready))

        let second = rig.scriptedHandles[1]
        let published = await supervisor.publishedCount
        second.push(.exited(.code(1, stderrTail: ""), second.epoch))
        try await rig.waitForPublish(supervisor, above: published)
        try await rig.waitForSleeper(due: ChannelSupervisor.backoffs[0])
        let thirdChild = rig.expectScriptedHandles(3, description: "the crash respawn built its child")
        await rig.clock.advance(by: ChannelSupervisor.backoffs[0])
        try await TestTiming.awaitDelivery([thirdChild])
        guard rig.launches.count >= 3 else { return XCTFail("the crash respawn built no third child") }

        let respawned = rig.launches[2]
        XCTAssertEqual(respawned.model, "opus", "the respawn continues from the restarted line")
        XCTAssertNil(respawned.agent, "and still never re-passes --agent")
        XCTAssertTrue(respawned.addDirectories.map(\.path) == [URL(fileURLWithPath: "/tmp/b").path],
                      "the respawn carries \(respawned.addDirectories.count) add-dirs, not the restarted line's 1")
    }

    // MARK: - A control answer that never arrives

    /// `perform` is bounded on the injected clock, so an engine that never answers cannot hang a restart in
    /// `.connecting` with no way out and no test can be made to sleep on wall time to reach that case.
    ///
    /// Scripted, not recorded: the channel runs on the scripted handle, whose `get_settings` answer never comes.
    func testAControlAnswerThatNeverArrivesTimesOutOnTheInjectedClock() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let held = HeldAnswer(), entered = HeldAnswer()
        let reachedReadback = entered.expectation(description: "the restart reached get_settings")
        rig.configureScriptedHandles { handle in
            handle.controlGate = { subtype in
                guard subtype == "get_settings" else { return }
                entered.release()
                await held.wait()
            }
        }
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)

        let restart = Task { try await supervisor.quiescentRestart(RestartRequest()) }
        defer { held.release(); restart.cancel() }
        try await TestTiming.awaitDelivery([reachedReadback])
        try await rig.waitForSleeper(due: ChannelSupervisor.controlTimeout)
        await rig.clock.advance(by: ChannelSupervisor.controlTimeout)

        var thrown: (any Error)?
        do { try await restart.value } catch { thrown = error }
        XCTAssertEqual(thrown as? WireError,
                       .controlError("timeout after \(ChannelSupervisor.controlTimeout) waiting for get_settings"))
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.connecting), "the restart did not become ready on no answer")
        held.release()
    }

    // MARK: - Frames the updater table drives

    private static func resultFrame(fastModeState: String) throws -> Frame {
        let line = try JSONValue.object(["type": .string("result"), "subtype": .string("success"),
                                         "is_error": .bool(false), "duration_ms": .integer(1),
                                         "duration_api_ms": .integer(1), "num_turns": .integer(1),
                                         "session_id": .string("s-1"), "uuid": .string("u-1"),
                                         "total_cost_usd": .number(0), "usage": .object([:]),
                                         "fast_mode_state": .string(fastModeState)]).canonicalData()
        return FrameDecoder.decode(line: line)
    }

    private static func systemInitFrame(model: String, permissionMode: String, outputStyle: String, cwd: String,
                                        agent: String?, effort: String? = nil) throws -> Frame {
        var object: [String: JSONValue] = [
            "type": .string("system"), "subtype": .string("init"), "cwd": .string(cwd),
            "session_id": .string("s-1"), "tools": .array([]), "mcp_servers": .array([]),
            "model": .string(model), "permissionMode": .string(permissionMode), "slash_commands": .array([]),
            "apiKeySource": .string("none"), "claude_code_version": .string("0.0.0"),
            "output_style": .string(outputStyle), "skills": .array([]), "plugins": .array([]),
            "uuid": .string("u-1"),
        ]
        if let agent { object["agent"] = .string(agent) }
        if let effort { object["effort"] = .string(effort) }
        return FrameDecoder.decode(line: try JSONValue.object(object).canonicalData())
    }
}

/// A one-shot barrier a test parks an engine answer behind, and a signal for the exact moment it is released.
final class HeldAnswer: @unchecked Sendable {   // `lock` serialises every field
    private let lock = NSLock()
    private var released = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var expectations: [XCTestExpectation] = []

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let waiting = Array(waiters.values)
        let expected = expectations
        waiters = [:]
        expectations = []
        lock.unlock()
        for waiter in waiting { waiter.resume() }
        for expectation in expected { expectation.fulfill() }
    }

    /// Registers under the same lock as `release`, so a delivery immediately before registration is not lost.
    func expectation(description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        let alreadyReleased = released
        if !alreadyReleased { expectations.append(expectation) }
        lock.unlock()
        if alreadyReleased { expectation.fulfill() }
        return expectation
    }

    private func reserveWaiterID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextWaiterID += 1
        return nextWaiterID
    }

    /// The held operation parks without polling, but cancellation still releases it: bounded control requests
    /// cancel their gate when the injected timeout wins and must not leave a task group open forever.
    func wait() async {
        let id = reserveWaiterID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume()
        }
    }
}
