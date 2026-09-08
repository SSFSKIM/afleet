import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import PanelHostAPI
import FleetKit
@testable import Afleet

/// C6.2 Task 8: the channel header's menus and actions.
///
/// Every action is asserted by the **X5 member and subtype it reaches**, on the double's one ordered
/// call log, so an extra call fails as loudly as a missing one. Nothing here compares an aggregate
/// that reaches a `ChannelKey`, a `ChannelContext` or an environment (§11); the failure messages
/// carry counts and member names.
///
/// **Tracker 74 closes in `testAReadOnlyRowOffersNoOwnedActionAtAll`:** this is the first surface in
/// the codebase to consume `ChannelRow.offersOwnedActions` or `readOnlyReason`, and that test is the
/// claim that consuming them means something.
@MainActor
final class HeaderActionTests: XCTestCase {

    // MARK: - Every action, by the member it reaches

    /// Each action of the spec's header table reaches exactly the X5 member and subtype the table
    /// names, and reaches nothing else.
    ///
    /// The expectation is a whole sequence and not a membership test, so an action that also took a
    /// readback, or performed twice, fails here.
    func testEveryHeaderActionReachesTheMemberTheTableNames() async throws {
        struct Case {
            let name: String
            let run: @MainActor (ChannelHeaderActionsModel) async -> Void
            let expected: [String]
        }
        let cases: [Case] = [
            Case(name: "mcp", run: { await $0.showMCPServers() }, expected: ["run"]),
            Case(name: "reload skills", run: { await $0.reloadSkills() }, expected: ["send:reload_skills"]),
            Case(name: "reload plugins", run: { await $0.reloadPlugins() }, expected: ["send:reload_plugins"]),
            Case(name: "rename", run: { await $0.rename(to: "an invented title") }, expected: ["send:rename_session"]),
            Case(name: "fork", run: { await $0.fork() }, expected: ["perform"]),
            // The census first: the handoff ends the channel's process, so it asks the fleet what is running
            // before it does. Nothing is staged as live here, so no confirm stands between the two.
            Case(name: "open in terminal", run: { await $0.openInTerminal() },
                 expected: ["liveTaskIDs", "openInTerminal"]),
        ]

        for scenario in cases {
            let double = ComposerLifecycleDouble()
            let key = HeaderRig.key()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            await double.stageRun(.success(.mcp(MCPPopover(servers: [MCPPopover.Server(name: "invented-server",
                                                                                       status: "connected")]))))
            await double.stagePane(.success(Self.paneRequest()))
            let header = HeaderRig.header(double, key: key)
            header.paneRunner = { _ in }

            await scenario.run(header)

            let members = await double.labelledSequence
            XCTAssertEqual(members, scenario.expected,
                           "\(scenario.name) reached \(members.count) member(s): " + members.joined(separator: ", "))
        }
    }

    /// **Tracker 74.** A read-only row offers no owned action: every one of them reaches the
    /// lifecycle **zero** times, and the header shows `readOnlyReason` in place of the actions.
    ///
    /// The two halves are both required. An empty call log alone would pass for a header that had
    /// simply not been wired up, so the same row is run through an owned mode first and every action
    /// is shown to reach something there — the floor that makes the zero mean what it says.
    func testAReadOnlyRowOffersNoOwnedActionAtAll() async throws {
        let actions: [(String, @MainActor (ChannelHeaderActionsModel) async -> Void)] = [
            ("mcp", { await $0.showMCPServers() }),
            ("reload skills", { await $0.reloadSkills() }),
            ("reload plugins", { await $0.reloadPlugins() }),
            ("rename", { await $0.rename(to: "an invented title") }),
            ("fork", { await $0.fork() }),
            ("send to background", { $0.sendToBackground() }),
            ("open in terminal", { await $0.openInTerminal() }),
            ("stop everything", { await $0.stopEverything() }),
            ("background all", { await $0.backgroundAll() }),
            ("prompt suggestions", { await $0.setPromptSuggestions(true) }),
            ("bypass", { await $0.selectBypassMode() }),
        ]

        // The floor: on an owned row every one of these does something observable.
        var reached = 0
        for (name, action) in actions {
            let double = ComposerLifecycleDouble()
            let key = HeaderRig.key()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            await double.stageRun(.success(.mcp(MCPPopover(servers: []))))
            await double.stagePane(.success(Self.paneRequest()))
            let owned = HeaderRig.header(double, key: key, mode: .ownedCandidate)
            owned.paneRunner = { _ in }
            await action(owned)
            let members = await double.memberSequence
            let acted = !members.isEmpty || owned.composer.pendingConfirmation != nil
                || owned.isShowingBypassDisclaimer || owned.note != nil
            XCTAssertTrue(acted, "\(name) did nothing observable on an owned row, so the read-only arm proves nothing")
            if acted { reached += 1 }
        }
        XCTAssertEqual(reached, actions.count,
                       "\(reached) of \(actions.count) action(s) did anything on an owned row")

        // The claim: on a read-only row not one of them reaches the lifecycle.
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let header = HeaderRig.header(double, key: key, mode: .readOnly(.teammate))
        header.paneRunner = { _ in XCTFail("a read-only row reached the pane runner") }

        XCTAssertFalse(header.offersOwnedActions, "a read-only row reported that it offers owned actions")
        let explanation = try XCTUnwrap(header.readOnlyExplanation,
                                        "a read-only row offered no reason to show in place of the actions")
        XCTAssertGreaterThan(explanation.count, 0, "the read-only reason is \(explanation.count) characters long")

        for (name, action) in actions {
            await action(header)
            let members = await double.memberSequence
            XCTAssertEqual(members.count, 0,
                           "\(name) on a read-only row reached \(members.count) lifecycle member(s)")
            XCTAssertNil(header.composer.pendingConfirmation,
                         "\(name) on a read-only row raised a confirmation")
            XCTAssertFalse(header.isShowingBypassDisclaimer,
                           "\(name) on a read-only row raised the bypass disclaimer")
        }
        XCTAssertEqual(header.note, explanation, "the header said something other than the read-only reason")
    }

    /// A row with no listing mode at all — the header before the column has handed one down — offers
    /// nothing either. `nil` is not "owned by default".
    func testAHeaderWithNoRowYetOffersNothing() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        let header = HeaderRig.header(double, key: key)
        header.adopt(row: nil)

        XCTAssertFalse(header.offersOwnedActions, "a header with no row reported that it offers owned actions")
        await header.fork()

        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "a header with no row reached \(members.count) lifecycle member(s)")
    }

    // MARK: - What the engine answered

    /// *Reload skills* and *Reload plugins* show the counts the engine answered with, and the plugin
    /// reload shows its `error_count` beside them.
    ///
    /// The two answers have different shapes on purpose — `reload_skills` carries an array and no
    /// count, `reload_plugins` carries five numbers — and both are read as the engine sends them.
    func testReloadSkillsAndPluginsShowTheCountsTheyAnswer() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.stageSend("reload_skills", .success(.object([
            "skills": .array([.object(["name": .string("invented-a")]),
                              .object(["name": .string("invented-b")]),
                              .object(["name": .string("invented-c")])]),
        ])))
        await double.stageSend("reload_plugins", .success(.object([
            "commands": .integer(7), "agents": .integer(2), "plugins": .integer(1),
            "mcpServers": .integer(4), "error_count": .integer(3),
        ])))
        let header = HeaderRig.header(double, key: key)

        await header.reloadSkills()
        let skills = try XCTUnwrap(header.note, "reloading skills said nothing")
        XCTAssertTrue(skills.contains("3"), "the skills note of \(skills.count) character(s) carries no count of 3")

        await header.reloadPlugins()
        let plugins = try XCTUnwrap(header.note, "reloading plugins said nothing")
        for number in ["7", "2", "1", "4", "3"] {
            XCTAssertTrue(plugins.contains(number),
                          "the plugins note of \(plugins.count) character(s) is missing one of the five counts")
        }
    }

    /// *Rename*'s confirmation is the **absence of an error** and never a readback.
    ///
    /// The engine answers a plain success with no body at all, which the double spells as `.null`
    /// exactly as the wire does. The discriminating half is the refusal arm: with the request refused
    /// the header must not report a rename, which a header that ignored the answer entirely would.
    func testARenameIsConfirmedByTheAbsenceOfAnErrorAndNeverByAReadback() async throws {
        let honoured = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        // Nothing staged: the double answers `.null`, which is the empty success body.
        let header = HeaderRig.header(honoured, key: key)

        await header.rename(to: "an invented title")

        let members = await honoured.labelledSequence
        XCTAssertEqual(members, ["send:rename_session"],
                       "the rename reached \(members.count) member(s): " + members.joined(separator: ", "))
        let note = try XCTUnwrap(header.note, "a rename the engine accepted was not confirmed")
        XCTAssertTrue(note.contains("an invented title"),
                      "the confirmation of \(note.count) character(s) does not carry the title that was typed")

        let refused = ComposerLifecycleDouble()
        await refused.stageSend("rename_session", .failure(.controlError("an invented refusal")))
        let refusedHeader = HeaderRig.header(refused, key: key)

        await refusedHeader.rename(to: "an invented title")

        let refusal = try XCTUnwrap(refusedHeader.note, "a refused rename said nothing")
        XCTAssertFalse(refusal.contains("an invented title"),
                       "a refused rename was reported as a rename")
    }

    /// The MCP menu renders `MCPPopover.servers` from the strategy's answer, and re-implements
    /// neither the request nor the mapping (X10).
    func testTheMCPMenuRendersTheServersTheStrategyAnswered() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.stageRun(.success(.mcp(MCPPopover(servers: [
            MCPPopover.Server(name: "invented-alpha", status: "connected"),
            MCPPopover.Server(name: "invented-beta", status: "failed"),
        ]))))
        let header = HeaderRig.header(double, key: key)

        await header.showMCPServers()

        let strategies = await double.strategies
        XCTAssertEqual(strategies.count, 1, "the MCP menu ran \(strategies.count) strategy(ies)")
        XCTAssertEqual(strategies.first, .mcpPopover, "the MCP menu ran a strategy other than the popover's")
        XCTAssertEqual(header.mcpServers.count, 2, "the popover holds \(header.mcpServers.count) server row(s)")
        XCTAssertEqual(header.mcpServers.map(\.name), ["invented-alpha", "invented-beta"],
                       "the popover reordered or renamed the servers the strategy answered with")
        XCTAssertTrue(header.isShowingMCP, "the popover was filled and not shown")
    }

    // MARK: - The confirms

    /// *Send to background* reaches nothing until the confirm is answered, and the confirm **names
    /// the live tasks** whose shells the handoff closes.
    ///
    /// The naming is asserted over the fold's items directly: a running task is named, a finished one
    /// is not, which is what separates "names the live tasks" from "names every task it ever saw".
    func testSendToBackgroundWaitsForItsConfirmAndNamesTheLiveTasks() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .backgroundJob)))
        let header = HeaderRig.header(double, key: key)

        header.sendToBackground()

        let before = await double.memberSequence
        XCTAssertEqual(before.count, 0, "the handoff reached \(before.count) member(s) before the confirm was answered")
        XCTAssertEqual(header.composer.pendingConfirmation, .sendToBackground, "no confirmation was raised")

        await header.composer.confirmPending()

        let after = await double.actions
        XCTAssertEqual(after.count, 1, "the answered confirm performed \(after.count) action(s)")
        guard case .sendToBackground = try XCTUnwrap(after.first, "the answered confirm performed nothing") else {
            return XCTFail("the answered confirm performed an action other than the handoff")
        }

        // The naming, over a fold that holds one running task and one that has finished.
        let ids = ChannelHeaderActionsModel.liveTaskIDs(in: [HeaderRig.task("invented-live", status: .running),
                                                             HeaderRig.task("invented-done", status: .completed)])
        XCTAssertEqual(ids, ["invented-live"],
                       "\(ids.count) task(s) were named as live; exactly one of the two was running")
        let named = ChannelHeaderActionsModel.confirmationDetail(forLiveTasks: ids)
        XCTAssertTrue(named.contains("invented-live"),
                      "the confirm of \(named.count) character(s) does not name the running task")
        XCTAssertFalse(named.contains("invented-done"),
                       "the confirm names a task that had already finished")
        let quiet = ChannelHeaderActionsModel.confirmationDetail(forLiveTasks: [])
        XCTAssertFalse(quiet.contains("invented"), "the empty confirm named a task")
    }

    /// *Stop everything* and *Background all* go through the composer's **one** confirmation gate —
    /// the same one the chord and a routed row raise — and reach nothing until it is answered.
    func testTheTwoStopActionsGoThroughTheComposersOneConfirmGate() async throws {
        for expected in [ComposerConfirmation.stopEverything, .backgroundAll] {
            let double = ComposerLifecycleDouble()
            let key = HeaderRig.key()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            let header = HeaderRig.header(double, key: key)

            if expected == .stopEverything { await header.stopEverything() } else { await header.backgroundAll() }

            let before = await double.memberSequence
            XCTAssertEqual(before.count, 0,
                           "\(expected.rawValue) reached \(before.count) member(s) before its confirm was answered")
            XCTAssertEqual(header.composer.pendingConfirmation, expected,
                           "\(expected.rawValue) raised a different confirmation, or none")

            await header.composer.confirmPending()
            let performed = await double.actions
            XCTAssertEqual(performed.count, 1, "\(expected.rawValue) performed \(performed.count) action(s)")
        }
    }

    // MARK: - Open in terminal

    /// *Open in terminal* is the first production caller of `PanelHostModel.run(_:)`, and surfaces
    /// `PanelHostError.noPaneRunner` as an inline note **naming the terminal** — item 47's
    /// degradation stated by the composite, not a silent skip.
    ///
    /// The request is handed to the runner **unchanged, `id` included**: C4 accepts a pane exit only
    /// when its `request.id` is the one it is waiting on, so a header that minted a fresh one would
    /// have every exit discarded with nothing to say why.
    func testOpenInTerminalHandsTheRequestOnAndSurfacesTheMissingPaneRunner() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        let request = Self.paneRequest()
        await double.stagePane(.success(request))
        let header = HeaderRig.header(double, key: key)
        var handed: [UUID] = []
        header.paneRunner = { handed.append($0.id) }

        await header.openInTerminal()

        XCTAssertEqual(handed, [request.id], "the runner was handed \(handed.count) request(s), and not this one")

        // The real host, until C7's Terminal leaf lands.
        let refusing = ComposerLifecycleDouble()
        await refusing.stagePane(.success(Self.paneRequest()))
        let refused = HeaderRig.header(refusing, key: key)
        let host = PanelHostModel()
        refused.paneRunner = { try await host.run($0) }

        await refused.openInTerminal()

        let note = try XCTUnwrap(refused.note, "a refused handoff said nothing")
        XCTAssertTrue(note.contains(PanelTabID.terminal.defaultTitle),
                      "the note of \(note.count) character(s) does not name the terminal")
        let members = await refusing.memberSequence
        XCTAssertEqual(members, ["liveTaskIDs", "openInTerminal"],
                       "the refused handoff reached \(members.count) member(s): " + members.joined(separator: ", "))
    }

    /// **A terminal handoff warns before it kills running background work.** `handOff` terminates the owned
    /// process before it answers the pane request, and stream close ends every still-running local shell (§7.4,
    /// X9) — so a channel with live tasks reaches nothing until the same confirm *Send to background* shows is
    /// answered, and the confirm names them.
    ///
    /// Deliberate break: call the handoff from `openInTerminal()` without reading the live tasks.
    func testOpenInTerminalWarnsAboutRunningTasksBeforeItHandsOff() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.stagePane(.success(Self.paneRequest()))
        await double.stageLiveTasks(["invented-live"], for: key)
        let header = HeaderRig.header(double, key: key)
        var handed: [UUID] = []
        header.paneRunner = { handed.append($0.id) }

        await header.openInTerminal()

        XCTAssertEqual(handed.count, 0, "the handoff ran \(handed.count) pane request(s) before the confirm")
        let before = await double.memberSequence
        XCTAssertEqual(before, ["liveTaskIDs"],
                       "the unanswered confirm reached \(before.count) member(s): " + before.joined(separator: ", "))
        XCTAssertEqual(header.composer.pendingConfirmation, .openInTerminal, "no confirmation was raised")
        let detail = try XCTUnwrap(header.composer.confirmationDetail, "the confirm named no running work")
        XCTAssertTrue(detail.contains("invented-live"),
                      "the confirm of \(detail.count) character(s) does not name the running task")

        await header.composer.confirmPending()

        XCTAssertEqual(handed.count, 1, "the answered confirm ran \(handed.count) pane request(s)")
        let after = await double.memberSequence
        XCTAssertEqual(after, ["liveTaskIDs", "openInTerminal"],
                       "the answered confirm reached \(after.count) member(s): " + after.joined(separator: ", "))
    }

    /// A cancelled warning hands off nothing, which is what makes the arm above about the answer.
    func testACancelledTerminalWarningHandsOffNothing() async {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.stagePane(.success(Self.paneRequest()))
        await double.stageLiveTasks(["invented-live"], for: key)
        let header = HeaderRig.header(double, key: key)
        var handed: [UUID] = []
        header.paneRunner = { handed.append($0.id) }

        await header.openInTerminal()
        header.composer.cancelPending()

        XCTAssertNil(header.composer.pendingConfirmation, "the cancelled confirm stayed up")
        XCTAssertEqual(handed.count, 0, "a cancelled warning ran \(handed.count) pane request(s)")
        let members = await double.memberSequence
        XCTAssertEqual(members, ["liveTaskIDs"],
                       "a cancelled warning reached \(members.count) member(s): " + members.joined(separator: ", "))
    }

    /// A window with no panel host at all says so, and hands the request nowhere.
    func testOpenInTerminalWithNoPanelHostSaysSo() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.stagePane(.success(Self.paneRequest()))
        let header = HeaderRig.header(double, key: key)
        header.paneRunner = nil

        await header.openInTerminal()

        let note = try XCTUnwrap(header.note, "a handoff with no host said nothing")
        XCTAssertTrue(note.contains(PanelTabID.terminal.defaultTitle),
                      "the note of \(note.count) character(s) does not name the terminal")
    }

    // MARK: - Restart-required settings

    /// **The matrix decides, and the header does not carry a list.** Every setting the header can
    /// change is looked up in `LaunchSettingMatrix`, and a setting the matrix calls restart-required
    /// takes the restart path while one it does not never reaches `quiescentRestart`.
    ///
    /// Enumerated over `HeaderLaunchSetting.allCases`, so a setting added here without a matrix entry
    /// fails rather than silently taking whichever path its author assumed.
    func testTheMatrixDecidesWhichSettingTakesTheRestartPath() async throws {
        XCTAssertGreaterThan(HeaderLaunchSetting.allCases.count, 0,
                             "the header changes \(HeaderLaunchSetting.allCases.count) launch setting(s)")
        for setting in HeaderLaunchSetting.allCases {
            XCTAssertTrue(LaunchSettingMatrix.restartRequired.contains(setting.matrixKey)
                          || LaunchSettingMatrix.runtimeMutable.contains(setting.matrixKey),
                          "\(setting.rawValue) is in neither class of §7.7's matrix")
            XCTAssertEqual(setting.takesARestart, LaunchSettingMatrix.restartRequired.contains(setting.matrixKey),
                           "\(setting.rawValue) answers the matrix's question differently from the matrix")

            let double = ComposerLifecycleDouble()
            let key = HeaderRig.key()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            let header = HeaderRig.header(double, key: key)

            await header.apply(setting, RestartRequest())

            let restarts = await double.actions.filter { if case .quiescentRestart = $0 { true } else { false } }
            XCTAssertEqual(restarts.count, setting.takesARestart ? 1 : 0,
                           "\(setting.rawValue) issued \(restarts.count) restart(s) for a setting the matrix "
                           + "\(setting.takesARestart ? "does" : "does not") call restart-required")
        }
    }

    /// A restart-required setting closes the field behind the connecting glyph, replaces the process,
    /// and re-opens the field only once **every** readback matches.
    ///
    /// The discriminating arm is the second half: the same call with a readback that disagrees leaves
    /// the field shut and raises a banner naming the setting that did not survive.
    func testARestartRequiredSettingWaitsForItsReadbackAndBannersOnAMismatch() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.setStates([SidebarFixtures.state(key, origin: .owned(.ready))])
        await double.alwaysPerform(.success(HeaderRig.replaced(key, epoch: ProcessEpoch.first.next())))
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()
        XCTAssertFalse(header.surface.isDisabled, "the field was closed before anything restarted")

        await header.setPromptSuggestions(true)

        XCTAssertFalse(header.surface.isDisabled, "the field stayed shut behind a restart every readback confirmed")
        XCTAssertTrue(header.composer.promptSuggestionsEnabled, "a confirmed restart did not move the flag")
        XCTAssertEqual(header.restartsIssued, 1, "the toggle issued \(header.restartsIssued) restart(s)")

        // The arm where the setting did not survive: the model comes back as something else.
        let lost = ComposerLifecycleDouble()
        await lost.alwaysPerform(.success(HeaderRig.replaced(key, epoch: ProcessEpoch.first.next())))
        await lost.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await lost.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let lostHeader = HeaderRig.header(lost, key: key)
        await lostHeader.pickers.refresh()
        await lost.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: "an-invented-other-model")))

        await lostHeader.setPromptSuggestions(true)

        XCTAssertTrue(lostHeader.surface.isDisabled, "a setting that did not survive left the field open")
        let banner = try XCTUnwrap(lostHeader.pickers.restartBanner, "a mismatch raised no banner")
        XCTAssertTrue(banner.contains("model"), "the banner of \(banner.count) character(s) does not name the setting")
        XCTAssertFalse(lostHeader.composer.promptSuggestionsEnabled,
                       "the flag moved for a restart whose readback did not confirm it")
    }

    /// A restart the lifecycle refused re-opens the field rather than leaving it shut behind a
    /// process that was never replaced.
    func testARefusedRestartReopensTheField() async throws {
        let double = ComposerLifecycleDouble()
        let key = HeaderRig.key()
        await double.alwaysPerform(.failure(.busy(.restart)))
        let header = HeaderRig.header(double, key: key)

        await header.setPromptSuggestions(true)

        XCTAssertFalse(header.surface.isDisabled, "a refused restart left the field shut")
        XCTAssertFalse(header.surface.isRestarting, "a refused restart left the connecting glyph up")
        XCTAssertEqual(header.restartsIssued, 0, "a refused restart was counted as \(header.restartsIssued)")
        let note = try XCTUnwrap(header.note, "a refused restart said nothing")
        XCTAssertGreaterThan(note.count, 0, "the refusal is \(note.count) characters long")
    }

    // MARK: - Rig

    /// An invented pane request. Every field is invented and nothing is spawned (§11, X9).
    static func paneRequest() -> PaneRequest {
        PaneRequest(executable: URL(fileURLWithPath: "/invented/bin/claude"),
                    arguments: ["--resume", "invented"],
                    cwd: URL(fileURLWithPath: "/invented/project"),
                    environment: ["PATH": "/usr/bin"],
                    purpose: .hatch(SidebarFixtures.session("a")))
    }
}
