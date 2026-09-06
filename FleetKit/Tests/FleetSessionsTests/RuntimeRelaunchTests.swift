import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Group D: every relaunch of a channel runs what the channel *is running*, not what it was opened with.
///
/// `SessionRuntimeState` exists because `--resume` restores the conversation and nothing else. The quiescent
/// restart already composes its line from it, and every other path back to a process — a dormant resume, a crash
/// respawn, a reopen, an adopt, a pane re-adoption — read the launch template, whose `--model`, `--permission-mode`,
/// `--effort`, working directory and `--add-dir` are the values of the *first* launch. So did the two handoffs and
/// the fork. A `/model` or a `/cd` therefore survived exactly one kind of relaunch and silently reverted on the rest.
final class RuntimeRelaunchTests: XCTestCase {
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

    private static let idle = "resume-no-replay"

    /// A channel opened on one model, mode, effort and directory, moved to another of each through the control
    /// channel, then reaped and resumed. The resumed child's line is the moved one.
    ///
    /// Scripted, not recorded: the answers are shaped as `control-shapes` records them — `set_model` and
    /// `set_permission_mode` are bare successes, `set_cwd` answers `{status, cwd}`, `get_settings` answers
    /// `{applied, effective, sources}` — with invented values.
    ///
    /// Deliberate break: compose the spawn from `launchTemplate` again instead of from `runtime`.
    func testADormantResumeCarriesTheRuntimeModelModeEffortAndDirectory() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let moved = rig.scratch.appending(path: "moved-project")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        rig.configureScriptedHandles { handle in
            handle.controlAnswers = [
                "set_cwd": .object(["status": .string("ok"), "cwd": .string(moved.path)]),
                "get_settings": .object(["applied": .object(["effort": .string("high")]),
                                         "effective": .object([:]), "sources": .array([])]),
            ]
        }
        let session = SessionID()
        var template = FakeClaudeLaunch.launch(fixture: Self.idle, cwd: rig.cwd,
                                               session: .resume(session, fork: false))
        template.model = "sonnet"
        template.permissionMode = .default
        template.effort = "low"
        let supervisor = rig.supervisor(session: session, origin: .owned(.connecting), template: template)
        try await supervisor.spawn(reason: .open)

        _ = try await supervisor.perform(SetModel(model: "opus"))
        _ = try await supervisor.perform(SetPermissionMode(mode: .plan))
        _ = try await supervisor.perform(SetCwd(path: moved.path))
        _ = try await supervisor.perform(GetSettings())

        await supervisor.reap()
        try await rig.waitUntil(supervisor, "dormant") { $0.origin == .owned(.dormant) }
        _ = try await supervisor.send(UserInput(text: "again"))
        try await rig.waitUntil(supervisor, "the resumed channel to be ready") { $0.origin == .owned(.ready) }

        XCTAssertEqual(rig.launches.count, 2)
        XCTAssertEqual(rig.launches[1].model, "opus", "the resume runs the model the user chose")
        XCTAssertEqual(rig.launches[1].permissionMode, .plan)
        XCTAssertEqual(rig.launches[1].effort, "high")
        XCTAssertEqual(rig.launches[1].cwd.standardizedFileURL, moved.standardizedFileURL,
                       "and in the directory the channel was moved to")
        XCTAssertEqual(rig.launches[0].model, "sonnet",
                       "the template still reads what the channel was opened with")
    }

    /// The two handoffs hand the session to something else, and that something else has to start where the channel
    /// actually is. `claude --bg --resume` in the directory the channel was opened in re-creates the project the
    /// user moved out of; so does the terminal hatch.
    ///
    /// Deliberate break: read `launchTemplate.cwd` in `sendToBackground` and `openInTerminal` again.
    func testBothHandoffsRunInTheRuntimeWorkingDirectory() async throws {
        for hatch in [false, true] {
            let rig = try newRig()
            rig.useScriptedHandle()
            let moved = rig.scratch.appending(path: "moved-project")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            rig.configureScriptedHandles { handle in
                handle.controlAnswers = ["set_cwd": .object(["status": .string("ok"),
                                                             "cwd": .string(moved.path)])]
            }
            let session = SessionID()
            let supervisor = rig.supervisor(session: session, origin: .owned(.connecting))
            try await supervisor.spawn(reason: .open)
            _ = try await supervisor.perform(SetCwd(path: moved.path))

            if hatch {
                let request = try await rig.steppingClock { try await supervisor.openInTerminal() }
                XCTAssertEqual(request.cwd.standardizedFileURL, moved.standardizedFileURL,
                               "the hatch opens where the channel is")
            } else {
                _ = try await rig.steppingClock { try await supervisor.sendToBackground() }
                let directories = rig.runnerCalls.directoriesUsed.compactMap { $0 }
                XCTAssertTrue(directories.contains { $0.standardizedFileURL == moved.standardizedFileURL },
                              "the background job is created where the channel is; ran in \(directories)")
            }
        }
    }
}
