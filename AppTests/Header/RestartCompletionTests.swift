import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// §7.4's readback gate, on the four things it has to get right that its own gate (G7) did not reach:
/// **that the restart happened**, that the snapshot is of what the channel is running, that the
/// confirmation rests on values that were read, and that picking a value really does recover.
///
/// Each arm here failed on the code as it stood before Task 11, and each fails again if its fix is
/// reverted. Every value is invented or the `control-shapes` recording's own, and every assertion is
/// on member names, counts and setting names (§11).
@MainActor
final class RestartCompletionTests: XCTestCase {

    // MARK: - Rig

    private var trees: [TempTree] = []

    override func tearDown() async throws {
        trees = []
        try await super.tearDown()
    }

    private func key() -> ChannelKey { HeaderRig.key() }

    /// The recorded handshake with one key replaced: the mode it reports.
    private func initialize(mode: PermissionMode) throws -> InitializeResponse {
        guard case .object(var body) = try PickerReadbackTests.recordedInitializeBody() else {
            throw XCTSkip("the recording carries no initialize body")
        }
        body["current_permission_mode"] = .string(mode.rawValue)
        return InitializeResponse(raw: .object(body))
    }

    /// The recorded handshake with one key replaced, as the event the fleet retains it from.
    private func handshakeEvent(mode: PermissionMode) throws -> WireEvent {
        .handshakeCompleted(Handshake(initialize: try initialize(mode: mode), pending: []), .first)
    }

    /// A header whose channel is running a process, with both readbacks staged.
    private func header(_ double: ComposerLifecycleDouble, key: ChannelKey,
                        answering perform: ChannelState) async throws -> ChannelHeaderActionsModel {
        await double.setStates([HeaderRig.replaced(key)])
        await double.alwaysPerform(.success(perform))
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()
        return header
    }

    // MARK: - 1. A restart that was recorded is not a restart that ran

    /// A channel that is not eligible keeps the change as `pendingChange` and `perform` answers
    /// success immediately. Nothing may be confirmed against that: the process on the other end is
    /// still the old one.
    ///
    /// Failed before the fix: `apply` reported the change as applied, took both readbacks against the
    /// old process — which of course agreed — and re-opened the field.
    func testAQueuedRestartIsNotConfirmedAndTakesNoReadback() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let header = try await header(double, key: key, answering: HeaderRig.queued(key))
        let before = await double.sentSubtypes.count

        let applied = await header.apply(.promptSuggestions, RestartRequest(promptSuggestions: true))

        XCTAssertFalse(applied, "a restart that was only recorded was reported as applied")
        let after = await double.sentSubtypes.count
        XCTAssertEqual(after, before,
                       "the readback made \(after - before) request(s) against a process that was never replaced")
        XCTAssertFalse(header.surface.isDisabled,
                       "the field stayed shut behind a restart that has not happened yet")
        XCTAssertNotNil(header.pickers.restartBanner, "nothing said the change is still pending")
        XCTAssertFalse(header.composer.promptSuggestionsEnabled,
                       "the flag moved for a restart that has not happened")
    }

    /// §8.6's third step, behind the same fact: with the restart only queued, the process was never
    /// launched with the flag, so the mode switch must not go out. The engine would refuse it — the
    /// availability is read from the launch line alone — and the user would be shown a refusal for a
    /// request afleet should not have made.
    ///
    /// Failed before the fix: the log held the store write, the restart and the mode switch.
    func testTheBypassModeIsNotIssuedWhenTheRestartWasOnlyQueued() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let tree = try TempTree()
        trees.append(tree)
        let store = try FileStateStore(baseDirectory: tree.directory("store"),
                                       configHomes: TempTree.configHomes())
        await double.setStates([HeaderRig.replaced(key)])
        await double.alwaysPerform(.success(HeaderRig.queued(key)))
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let header = HeaderRig.header(double, key: key, store: store)
        await header.pickers.refresh()

        await header.acceptBypassMode()

        let subtypes = await double.sentSubtypes
        XCTAssertFalse(subtypes.contains(SetPermissionMode.subtype),
                       "the mode was issued to a process the restart never replaced")
        let performed = await double.actions.count
        XCTAssertEqual(performed, 1, "the acceptance performed \(performed) action(s); §8.6 performs one restart")
    }

    // MARK: - 2. Recovery by selection

    /// The banner promises that picking a value continues. Two gates hold the channel — the fleet's
    /// `unresolvedSettings`, which keeps it connecting, and the surface's, which closes the field —
    /// and a correction has to answer both.
    ///
    /// Failed before the fix: the click went out as a bare `set_model`, so the fleet kept the channel
    /// connecting, and the surface stayed disabled with the banner still up.
    func testAPickerCorrectionAnswersBothHalvesOfTheGate() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let rows = ModelOption.options(in: try PickerReadbackTests.recordedBody("list_models"))
        let expected = try XCTUnwrap(rows.first, "the recording offers no model row")
        let other = try XCTUnwrap(rows.first { $0.canonical != expected.canonical },
                                  "every recorded row resolves to the same model")
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: other.canonical)))
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: double, surface: surface)
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: .init(model: expected.value))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertFalse(survived, "a model the readback did not report was taken as surviving")
        XCTAssertTrue(surface.isDisabled, "a mismatch left the field open")

        // The fleet is holding the same channel over the same setting, which is the state the banner
        // is promising recovery from.
        var held = HeaderRig.replaced(key)
        held.banner = .settingDidNotSurvive(SettingPickersModel.modelSetting)
        await double.setStates([held])
        // The fleet clears its own banner when the correction resolves its last unresolved setting,
        // which is what the surface reads before it re-opens the field.
        await double.stageBannersAfterResolve([nil])
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: expected.canonical)))

        await pickers.selectModel(expected.value)

        let members = await double.memberSequence
        XCTAssertTrue(members.contains("resolveSetting"),
                      "the correction reached \(members.count) member(s) and none of them was the fleet's")
        let subtypes = await double.sentSubtypes
        XCTAssertFalse(subtypes.contains(SetModel.subtype),
                       "the correction went out as a bare request, which leaves the channel connecting")
        XCTAssertFalse(surface.isDisabled, "the field stayed shut after the value the banner asked for was picked")
        XCTAssertNil(pickers.restartBanner, "the banner survived the value it asked for")
    }

    // MARK: - 3. The snapshot is of what the channel is running

    /// A mode that was accepted and has not been handshaken yet is what the relaunch carries — the
    /// runtime record holds it — so it is what the snapshot must hold too.
    ///
    /// Failed before the fix: the snapshot carried the old handshake's mode, so a new process that
    /// restored the accepted one read as a mismatch and closed the composer over it.
    func testTheSnapshotCarriesTheModeTheChannelIsRunning() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let old = try initialize(mode: .default)
        let clicked = try XCTUnwrap(PermissionMode.allCases.first { $0 != .default && $0 != .bypassPermissions },
                                    "there is no second mode to accept")
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings()))
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: double, surface: surface)
        await pickers.noteHandshake(old)

        await pickers.selectMode(clicked)
        let snapshot = pickers.currentSnapshot

        XCTAssertEqual(snapshot.permissionMode, clicked,
                       "the snapshot carried a mode the relaunch does not pass")

        // The restart, and a new process reporting exactly what the runtime record relaunched with.
        // The report is the **fleet's** retained handshake, which is where the mode readback is taken
        // from: the subscription's copy is whatever last got through, and the replacement's is this.
        await double.openEvents(of: key)
        await double.stageEngineReport(handshake: try handshakeEvent(mode: clicked), systemInitFrom: nil)
        let operation = pickers.beginRestart(reason: "an invented restart", expecting: snapshot)
        await pickers.noteHandshake(try initialize(mode: clicked))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertTrue(survived, "a correctly restored mode was reported as a mismatch")
        XCTAssertFalse(surface.isDisabled, "the field stayed shut behind a restart every readback confirmed")
    }

    // MARK: - 4. Confirmed on values that were read

    /// `readSettings` keeps the last readback when the channel does not answer, which is right for a
    /// display and wrong for a comparison: the retained values agree with the snapshot taken from
    /// those same values.
    ///
    /// Failed before the fix: the failed `get_settings` was swallowed, every comparison agreed with
    /// itself, and the field re-opened with the flag moved — over a process that had reported nothing.
    func testARestartIsNotConfirmedWithoutASettingsReadThatSucceeded() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.setStates([HeaderRig.replaced(key)])
        await double.alwaysPerform(.success(HeaderRig.replaced(key, epoch: ProcessEpoch.first.next())))
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSendSequence("get_settings", [
            .success(try PickerReadbackTests.recordedBody("get_settings")),
            .failure(WireError.controlError("an invented refusal")),
        ])
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()

        await header.setPromptSuggestions(true)

        XCTAssertTrue(header.surface.isDisabled,
                      "the field re-opened over a process that never reported its settings")
        XCTAssertNotNil(header.pickers.restartBanner, "an unread readback raised no banner")
        XCTAssertFalse(header.composer.promptSuggestionsEnabled,
                       "the flag moved on a readback that was never taken")
    }
}

// MARK: - The gate's remaining states

/// §7.4's gate is a state machine, and these are the transitions six local patches would have left
/// open: a readback that could not be taken, a mode read off the wrong process, a restart that threw
/// after the replacement had spawned, a second change merging into a restart already running, and a
/// correction made in an order the fleet does not resolve in.
///
/// Every value is invented or the `control-shapes` recording's own, and every assertion is on
/// counts, member names and setting names (§11).
@MainActor
final class RestartGateStateTests: XCTestCase {

    private func key() -> ChannelKey { HeaderRig.key() }

    private func rows() throws -> [ModelOption] {
        ModelOption.options(in: try PickerReadbackTests.recordedBody("list_models"))
    }

    private func makePickers(_ double: ComposerLifecycleDouble, key: ChannelKey,
                             surface: ChannelSurfaceState) -> SettingPickersModel {
        SettingPickersModel(key: key, lifecycle: double, surface: surface)
    }

    private func handshakeEvent(mode: PermissionMode) throws -> WireEvent {
        guard case .object(var body) = try PickerReadbackTests.recordedInitializeBody() else {
            throw XCTSkip("the recording carries no initialize body")
        }
        body["current_permission_mode"] = .string(mode.rawValue)
        return .handshakeCompleted(Handshake(initialize: InitializeResponse(raw: .object(body)), pending: []), .first)
    }

    // MARK: - A readback that could not be taken

    /// A `get_settings` the channel did not answer leaves the confirmation **owed**, and the next
    /// handshake — the replacement reporting — settles it.
    ///
    /// Failed before the fix: the failure cleared the outstanding list without retaining what was
    /// expected, so nothing repeated the confirmation and nothing could act on an empty list. The
    /// recovered readback left the field disabled for the rest of the channel's life.
    func testAReadbackTheChannelCouldNotAnswerIsConfirmedWhenTheReplacementReports() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let expected = try XCTUnwrap(try rows().first, "the recording offers no model row")
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSendSequence("get_settings", [
            .failure(WireError.controlError("an invented refusal")),
            .success(try PickerReadbackTests.settings(model: expected.canonical)),
        ])
        let surface = ChannelSurfaceState()
        let pickers = makePickers(double, key: key, surface: surface)
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: .init(model: expected.value))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertFalse(survived, "a readback that was never taken was reported as surviving")
        XCTAssertTrue(surface.isDisabled, "an unread readback left the field open")
        XCTAssertTrue(pickers.restartFailures.isEmpty,
                      "an unread readback named \(pickers.restartFailures.count) setting(s) as lost")
        XCTAssertNotNil(pickers.awaitedRestart, "nothing was left to confirm the readback against")

        await pickers.noteHandshake(InitializeResponse(raw: try PickerReadbackTests.recordedInitializeBody()))

        XCTAssertFalse(surface.isDisabled, "the recovered readback left the field disabled")
        XCTAssertNil(pickers.restartBanner, "the banner survived the readback that answered it")
        XCTAssertNil(pickers.awaitedRestart, "the confirmation stayed owed after it was settled")
    }

    // MARK: - The mode is read off the replacement

    /// The mode's only readback is a handshake, and the handshake this model holds is whatever the
    /// composer's subscription last delivered. The comparison therefore asks the **fleet** what the
    /// process it is running reported, and holds the gate when the fleet has nothing to report.
    ///
    /// Failed before the fix: the stale handshake matched the snapshot, every readback "agreed", and
    /// the composer re-opened against a process whose mode nothing had confirmed.
    func testTheModeIsConfirmedFromTheProcessTheFleetIsRunning() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let stale = try XCTUnwrap(InitializeResponse(raw: try PickerReadbackTests.recordedInitializeBody())
            .currentPermissionMode, "the recorded handshake carries no mode")
        let running = try XCTUnwrap(PermissionMode.allCases.first { $0 != stale },
                                    "there is no second mode for the replacement to report")
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings()))
        await double.openEvents(of: key)
        await double.stageEngineReport(handshake: try handshakeEvent(mode: running), systemInitFrom: nil)
        let surface = ChannelSurfaceState()
        let pickers = makePickers(double, key: key, surface: surface)
        await pickers.noteHandshake(InitializeResponse(raw: try PickerReadbackTests.recordedInitializeBody()))
        XCTAssertEqual(pickers.handshakeMode, stale, "the arm starts from a handshake that is not the replacement's")
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: .init(permissionMode: stale))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertFalse(survived, "the mode was confirmed against a handshake the replacement never sent")
        XCTAssertTrue(surface.isDisabled, "the field re-opened over an unconfirmed mode")
        let banner = try XCTUnwrap(pickers.restartBanner, "a mode that did not survive raised no banner")
        XCTAssertTrue(banner.contains(SettingPickersModel.label(of: SettingPickersModel.modeSetting)),
                      "the banner of \(banner.count) character(s) does not name the setting")
        XCTAssertEqual(pickers.handshakeMode, running,
                       "the picker kept displaying a mode the running process does not report")

        // The fleet with no handshake to report: unresolved is not a match, and the gate stays shut.
        let silent = ComposerLifecycleDouble()
        await silent.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await silent.stageSend("get_settings", .success(try PickerReadbackTests.settings()))
        let silentSurface = ChannelSurfaceState()
        let silentPickers = makePickers(silent, key: key, surface: silentSurface)
        await silentPickers.noteHandshake(InitializeResponse(raw: try PickerReadbackTests.recordedInitializeBody()))
        let silentOperation = silentPickers.beginRestart(reason: "an invented restart",
                                                         expecting: .init(permissionMode: stale))

        let confirmed = await silentPickers.confirmReadback(silentOperation)

        XCTAssertFalse(confirmed, "an unresolved mode was reported as surviving")
        XCTAssertTrue(silentSurface.isDisabled, "an unresolved mode left the field open")
        XCTAssertNotNil(silentPickers.awaitedRestart, "the unresolved mode left nothing owed")
    }

    // MARK: - A restart that threw after the replacement spawned

    /// `quiescentRestart` spawns the replacement and **then** restores the flag settings and reads
    /// them back; both of those throw. An error is therefore not a claim that nothing happened, and
    /// the channel's own state is what says which it was.
    ///
    /// Failed before the fix: every error cancelled the gate, so the field re-opened while the
    /// replacement was still connecting and a send could enter its queued input with no readiness
    /// transition to flush it.
    func testARestartThatThrewWithTheChannelConnectingKeepsTheFieldClosed() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await double.setStates([HeaderRig.replaced(key)])
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()
        // The spawn happened; the restoration that follows it did not.
        var connecting = SidebarFixtures.state(key, origin: .owned(.connecting))
        connecting.epoch = ProcessEpoch.first.next()
        await double.setStates([connecting])
        await double.alwaysPerform(.failure(.notOwned))

        let applied = await header.apply(.promptSuggestions, RestartRequest(promptSuggestions: true))

        XCTAssertFalse(applied, "a restart that threw was reported as applied")
        XCTAssertTrue(header.surface.isDisabled,
                      "the field re-opened while the replacement was still connecting")
        header.composer.draft = "an invented message typed at a connecting replacement"
        await header.composer.send()
        let members = await double.memberSequence
        XCTAssertFalse(members.contains("sendPrompt"),
                       "a send reached the wire across \(members.count) member(s) while the gate should have held")

        // The other arm: a channel that is not connecting was not replaced, and the field re-opens.
        let refused = ComposerLifecycleDouble()
        await refused.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await refused.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await refused.setStates([HeaderRig.replaced(key)])
        let refusedHeader = HeaderRig.header(refused, key: key)
        await refusedHeader.pickers.refresh()
        await refused.alwaysPerform(.failure(.notOwned))

        await refusedHeader.apply(.promptSuggestions, RestartRequest(promptSuggestions: true))

        XCTAssertFalse(refusedHeader.surface.isDisabled,
                       "the field stayed shut behind a restart that replaced nothing")
    }

    // MARK: - Two changes, one restart

    /// Two restart-required changes are **one** restart on the fleet's side — and the surface no
    /// longer lets the second one begin. Every entry point asks the predicate first, so a change
    /// asked for while a restart is replacing the process is refused rather than performed, merged
    /// and answered *queued*.
    ///
    /// **This arm replaces the one that asserted the merged change must not release the first's
    /// gate.** That claim was about a count of restarts in flight; with one operation and one
    /// predicate there is no second operation to reconcile, which is the stronger property. The
    /// first restart still confirms and still opens the field on its own.
    ///
    /// Failed before the redesign: nothing gated the second change, so it reached `perform`.
    func testASecondRestartRequiredChangeIsRefusedWhileOneIsRunning() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let expected = try XCTUnwrap(try rows().first, "the recording offers no model row")
        await double.setStates([HeaderRig.replaced(key)])
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: expected.canonical)))
        let header = HeaderRig.header(double, key: key)
        let surface = header.surface
        let first = header.pickers.beginRestart(reason: "the first invented restart",
                                                expecting: .init(model: expected.value))

        let applied = await header.apply(.promptSuggestions, RestartRequest(promptSuggestions: true))

        XCTAssertFalse(applied, "a change asked for over a running restart was reported as applied")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 0, "the refused change performed \(actions.count) action(s)")
        XCTAssertTrue(surface.isDisabled, "the refused change released the gate the first restart holds")
        XCTAssertTrue(surface.isRestarting, "the refused change reported the channel as no longer restarting")
        XCTAssertNotNil(header.note, "the refused change said nothing")

        let survived = await header.pickers.confirmReadback(first)

        XCTAssertTrue(survived, "the restart that did run was not confirmed")
        XCTAssertFalse(surface.isDisabled, "the field stayed shut after the last operation finished")
    }

    // MARK: - Corrections in an order the fleet does not resolve in

    /// The fleet resolves **its** unresolved settings in order, and the user picks in whichever order
    /// they like. Answering the second setting first applies the value and leaves the fleet's list
    /// where it was, so resolving the first afterwards advances the fleet's banner onto a setting this
    /// surface has already answered — and nothing of the surface's own is left to hold the field.
    ///
    /// Failed before the fix: the field opened with the channel still connecting behind it, over a
    /// setting the user had in fact already picked a value for.
    func testACorrectionMadeOutOfTheFleetsOrderStillAnswersBothHalves() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let rows = try rows()
        let expected = try XCTUnwrap(rows.first, "the recording offers no model row")
        let other = try XCTUnwrap(rows.first { $0.canonical != expected.canonical },
                                  "every recorded row resolves to the same model")
        let level = "low"
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: other.canonical)))
        let surface = ChannelSurfaceState()
        let pickers = makePickers(double, key: key, surface: surface)
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: .init(model: expected.value, effort: level))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertFalse(survived, "a restart that lost two settings was reported as surviving")
        XCTAssertEqual(pickers.restartFailures.count, 2,
                       "\(pickers.restartFailures.count) setting(s) were named as lost")

        // The fleet is holding the same channel, and its own list starts at the model.
        var held = HeaderRig.replaced(key)
        held.banner = .settingDidNotSurvive(SettingPickersModel.modelSetting)
        await double.setStates([held])
        await double.stageBannersAfterResolve([.settingDidNotSurvive(SettingPickersModel.effortSetting), nil])

        // The user answers the effort first — the fleet cannot advance on it, and does not.
        await double.stageSend("get_settings",
                               .success(try PickerReadbackTests.settings(model: other.canonical, effort: level)))
        await pickers.selectEffort(level)

        XCTAssertTrue(surface.isDisabled, "the field opened with the model still unanswered")

        // And then the model, which is the one the fleet was waiting for.
        await double.stageSend("get_settings",
                               .success(try PickerReadbackTests.settings(model: expected.canonical, effort: level)))
        await pickers.selectModel(expected.value)

        XCTAssertFalse(surface.isDisabled, "the field stayed shut after every setting the banner named was answered")
        let banner = await double.state(of: key)?.banner
        XCTAssertNil(banner, "the field opened while the fleet was still holding the channel connecting")
        let resolved = await double.calls.filter { if case .resolveSetting = $0 { true } else { false } }
        XCTAssertEqual(resolved.count, 2,
                       "the corrections reached the fleet \(resolved.count) time(s) for two settings")
    }

    // MARK: - 3. The holders are read after every await, not before the first

    /// **The release consults the fleet across an await, and the machine can move inside it.** A
    /// restart begun while that question is out has already closed the field over a process being
    /// replaced right now; the older release must not open it again on the reading it took before
    /// the await.
    ///
    /// Deliberate break: drop the second `nothingHolds` guard in `releaseOrHold`. The field then
    /// opens, and a send goes to the process the newer restart is replacing.
    func testARestartBegunInsideTheFleetsQuestionKeepsTheFieldClosed() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.setStates([HeaderRig.replaced(key)])
        let gated = GatedLifecycle(double)
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: gated, surface: surface)
        let first = pickers.beginRestart(reason: "an invented restart",
                                         expecting: pickers.currentSnapshot)

        // The first operation ends without a replacement, and its release parks inside the fleet's
        // own banner question.
        await gated.holdStates()
        let releasing = Task { await pickers.cancelRestart(first) }
        try await waitFor("the release to reach the fleet's banner") { await gated.callersParked > 0 }

        // A second restart, begun while that release is still out.
        pickers.beginRestart(reason: "a second invented restart", expecting: pickers.currentSnapshot)
        XCTAssertTrue(surface.isDisabled, "the newer restart did not close the field to begin with")

        await gated.release()
        await releasing.value

        XCTAssertTrue(surface.isDisabled,
                      "the older release opened the field over a restart that is still replacing the process")
        XCTAssertTrue(surface.isRestarting, "the field opened its glyph over a restart that is still running")
    }

    /// **A confirmation holds the gate for as long as its readbacks are out.** Closing the operation
    /// the moment `perform` answered, with the comparison's several requests still in flight, leaves
    /// the machine reading *open* — and a picker click landing there releases the field over a
    /// process whose settings nothing has verified.
    ///
    /// Deliberate break: drop the `awaitedRestart = expected` from `confirmReadback`. The click then
    /// finds no holder and opens the field mid-confirmation.
    func testAPickerClickTakenDuringAConfirmationDoesNotOpenTheField() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let rows = try rows()
        let picked = try XCTUnwrap(rows.first, "the recording offers no model row")
        await double.setStates([HeaderRig.replaced(key)])
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let gated = GatedLifecycle(double)
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: gated, surface: surface)
        await pickers.refresh()
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: pickers.currentSnapshot)

        // The confirmation parks on the first of its readbacks: the replacement has reported nothing.
        await gated.hold(subtype: "list_models")
        let confirming = Task { await pickers.confirmReadback(operation) }
        try await waitFor("the confirmation to reach its first readback") { await gated.callersParked > 0 }

        // And the user clicks a picker, which is not itself disabled.
        await pickers.selectModel(picked.value)

        XCTAssertTrue(surface.isDisabled,
                      "a picker click opened the field while the restart's readbacks were still out")

        await gated.release()
        _ = await confirming.value
    }

    /// A bounded wait on a condition another task reaches. Counts and never a value (§11).
    private func waitFor(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }
}

// MARK: - The four holes round 4 found, closed by construction

/// §7.4's gate rebuilt as **one operation with a generation and one predicate** (Decision Log,
/// 2026-09-09, the fourth fix wave). Round 4 found four more instances of the same two kinds — a
/// completion acting on a state a newer operation had replaced, and an entry point changing a
/// setting without asking the gate — and each of them has an arm here.
///
/// Every value is invented or the `control-shapes` recording's own, and every assertion is on
/// counts, member names and setting names (§11).
@MainActor
final class RestartOperationTests: XCTestCase {

    private func key() -> ChannelKey { HeaderRig.key() }

    private func rows() throws -> [ModelOption] {
        ModelOption.options(in: try PickerReadbackTests.recordedBody("list_models"))
    }

    /// A channel the fleet left connecting: the replacement spawned and the restoration that follows
    /// it did not.
    private func connecting(_ key: ChannelKey) -> ChannelState {
        var state = SidebarFixtures.state(key, origin: .owned(.connecting))
        state.epoch = ProcessEpoch.first.next()
        return state
    }

    // MARK: - Readiness is one of the predicate's inputs (scalpel-1#1, P1)

    /// **A channel left `.owned(.connecting)` keeps the field closed and keeps setting changes
    /// refused, whatever the banners say.** `quiescentRestart` spawns the replacement and only then
    /// restores and re-reads the flag settings; when that throws there is a new process on the other
    /// end that has not reported, and a send into its queued input has no readiness transition to
    /// flush it.
    ///
    /// The seeding a late surface does hands the pickers the handshake the fleet retained, which
    /// settles the owed confirmation — and every readback agrees, because nothing about the settings
    /// changed. Readiness is what still holds.
    ///
    /// Failed before the redesign: the settled confirmation released the gate, the field re-opened
    /// over the connecting process, and a picker click went out to it.
    func testAConnectingReplacementKeepsTheFieldClosedAndRefusesSettingChanges() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let picked = try XCTUnwrap(try rows().first, "the recording offers no model row")
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await double.setStates([HeaderRig.replaced(key)])
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()
        await double.alwaysPerform(.failure(.notOwned))
        // The channel is ready when the change is asked for, and the restart replaces its process
        // before the restoration that follows the spawn throws: the state the error is judged by is
        // the one the fleet has *then*, which is a replacement that is still connecting.
        await double.holdPerform()
        let applying = Task { @MainActor in
            await header.apply(.promptSuggestions, RestartRequest(promptSuggestions: true))
        }
        while await double.callersHeldInPerform == 0 { await Task.yield() }
        await double.setStates([connecting(key)])
        await double.releasePerform()
        _ = await applying.value

        XCTAssertTrue(header.surface.isDisabled, "the restart that threw left the field open")

        await header.pickers.noteRetainedHandshake(
            InitializeResponse(raw: try PickerReadbackTests.recordedInitializeBody()))

        XCTAssertTrue(header.surface.isDisabled,
                      "the seeded report re-opened the field over a process that is still connecting")
        let before = await double.sentSubtypes.count
        await header.pickers.selectModel(picked.value)
        let after = await double.sentSubtypes.count
        XCTAssertEqual(after, before,
                       "a setting change reached \(after - before) request(s) on a connecting process")
        XCTAssertNotNil(header.pickers.disagreement, "the refused change said nothing")
    }

    // MARK: - Every entry point asks the predicate (sweep#1, P2)

    /// **The permission menu is an entry point like any other.** It changed the mode with no restart
    /// guard at all, so a mode asked for while a restart was replacing the process reached the
    /// outgoing one — and the relaunch then restored the mode the restart had captured, losing the
    /// change with no sign that anything had happened.
    ///
    /// Failed before the redesign: `set_permission_mode` went to the wire and the click answered nil.
    func testThePermissionMenuIsRefusedWhileARestartIsReplacingTheProcess() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.setStates([HeaderRig.replaced(key)])
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: double, surface: surface)
        let mode = try XCTUnwrap(PermissionMode.allCases.first { $0 != .bypassPermissions },
                                 "there is no non-bypass mode for the menu to pick")
        pickers.beginRestart(reason: "an invented restart", expecting: pickers.currentSnapshot)

        let refusal = await pickers.selectMode(mode)

        XCTAssertNotNil(refusal, "the menu changed the mode over a process that is being replaced")
        let subtypes = await double.sentSubtypes
        XCTAssertFalse(subtypes.contains(SetPermissionMode.subtype),
                       "the mode reached the outgoing process, which the relaunch restores over")
        XCTAssertNotNil(pickers.disagreement, "the refused menu said nothing")
    }

    // MARK: - The generation fence (scalpel-1#2, P2)

    /// **A confirmation that resumes after a newer restart has begun drops itself.** The comparison
    /// suspends twice — `refresh`, then the fleet's retained handshake — and the older continuation
    /// used to clear the *owed* snapshot it found there, which by then belonged to the newer
    /// operation. The field then opened over a replacement that had reported nothing.
    ///
    /// The older confirmation parks on the mode readback; the newer restart runs and is left owed by
    /// a `get_settings` the channel refuses; and only then does the older one resume.
    ///
    /// Failed before the redesign: the older continuation cleared the newer operation's snapshot and
    /// released the field.
    func testAConfirmationOvertakenByANewerRestartDoesNotClearItsOwedReadback() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        guard case .object(var body) = try PickerReadbackTests.recordedInitializeBody() else {
            throw XCTSkip("the recording carries no initialize body")
        }
        let running = try XCTUnwrap(PermissionMode.allCases.first { $0 != .bypassPermissions },
                                    "there is no mode for the replacement to report")
        body["current_permission_mode"] = .string(running.rawValue)
        let initialize = InitializeResponse(raw: .object(body))
        await double.setStates([HeaderRig.replaced(key)])
        await double.openEvents(of: key)
        await double.stageEngineReport(
            handshake: .handshakeCompleted(Handshake(initialize: initialize, pending: []), .first),
            systemInitFrom: nil)
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSendSequence("get_settings", [
            .success(try PickerReadbackTests.settings()),                  // the first draw
            .success(try PickerReadbackTests.settings()),                  // the older confirmation
            .failure(WireError.controlError("an invented refusal")),       // the newer one
        ])
        let gated = GatedLifecycle(double)
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: gated, surface: surface)
        await pickers.refresh()
        await pickers.noteHandshake(initialize)
        let older = pickers.beginRestart(reason: "the older invented restart",
                                         expecting: .init(permissionMode: running))

        await gated.holdReports()
        let confirming = Task { await pickers.confirmReadback(older) }
        try await waitFor("the older confirmation to reach the mode readback") { await gated.callersParked > 0 }

        // The newer restart, whose own confirmation the channel cannot answer: it is left owed.
        let newer = pickers.beginRestart(reason: "the newer invented restart",
                                         expecting: .init(permissionMode: running))
        let confirmed = await pickers.confirmReadback(newer)
        XCTAssertFalse(confirmed, "a readback the channel refused was reported as surviving")
        XCTAssertNotNil(pickers.awaitedRestart, "the newer restart left nothing owed to confirm against")

        await gated.release()
        _ = await confirming.value

        XCTAssertNotNil(pickers.awaitedRestart,
                        "the older confirmation cleared the newer restart's owed readback")
        XCTAssertTrue(surface.isDisabled,
                      "the older confirmation opened the field over a replacement that has not reported")
        XCTAssertNotNil(pickers.restartBanner, "the older confirmation cleared the newer restart's banner")
    }

    // MARK: - A correction resolves only on a readback that was taken (scalpel-1#3, P2)

    /// **A correction whose readback the channel did not answer resolves nothing.** `readSettings`
    /// leaves the last values in place when the request is refused, so picking the value already on
    /// screen agreed with itself: the refusal was erased, the setting left the outstanding list and
    /// the field opened over a value nothing had re-read.
    ///
    /// Failed before the redesign: all three assertions below.
    func testACorrectionWhoseReadbackFailedDoesNotResolveTheSetting() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let rows = try rows()
        let expected = try XCTUnwrap(rows.first, "the recording offers no model row")
        let other = try XCTUnwrap(rows.first { $0.canonical != expected.canonical },
                                  "every recorded row resolves to the same model")
        await double.setStates([HeaderRig.replaced(key)])
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSendSequence("get_settings", [
            .success(try PickerReadbackTests.settings(model: other.canonical)),
            .failure(WireError.controlError("an invented refusal")),
        ])
        let surface = ChannelSurfaceState()
        let pickers = SettingPickersModel(key: key, lifecycle: double, surface: surface)
        let operation = pickers.beginRestart(reason: "an invented restart",
                                             expecting: .init(model: expected.value))

        let survived = await pickers.confirmReadback(operation)

        XCTAssertFalse(survived, "a model the readback did not report was taken as surviving")
        XCTAssertEqual(pickers.restartFailures, [SettingPickersModel.modelSetting],
                       "\(pickers.restartFailures.count) setting(s) were named as lost")

        // The user picks the value the picker is already displaying, and the readback that would
        // confirm it is refused.
        let displayed = try XCTUnwrap(pickers.displayedModel?.value, "the picker displays no model to re-pick")
        await pickers.selectModel(displayed)

        XCTAssertEqual(pickers.restartFailures.count, 1,
                       "a correction whose readback failed resolved \(1 - pickers.restartFailures.count) setting(s)")
        XCTAssertTrue(surface.isDisabled, "the field opened on a correction nothing read back")
        XCTAssertNotNil(pickers.disagreement,
                        "the refusal was erased by a click that agreed with the values it was kept from")
    }

    /// A bounded wait on a condition another task reaches. Counts and never a value (§11).
    private func waitFor(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }
}

/// A `LifecycleAPI` that can hold one member open — the fleet's `state(of:)`, or a control request of
/// one subtype — and forwards everything else, unchanged, to the double the assertions read.
///
/// The hold is what makes a race a test: both defects above are a second caller arriving inside an
/// await the model takes, and a double that answers at once closes the window before a test can
/// reach it. Suspension rather than a delay, so nothing here is a bounded wait on the clock.
private actor GatedLifecycle: LifecycleAPI {

    private nonisolated let inner: ComposerLifecycleDouble
    private var holdsStates = false
    private var holdsReports = false
    private var heldSubtype: String?
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// How many callers have parked in the gate. A count, never a caller (§11).
    private(set) var callersParked = 0

    init(_ inner: ComposerLifecycleDouble) { self.inner = inner }

    func holdStates() { holdsStates = true }
    func hold(subtype: String) { heldSubtype = subtype }
    /// The mode's readback, held: `engineReports(of:)` is the last await a confirmation takes, and a
    /// newer restart arriving inside it is the generation race in its own right.
    func holdReports() { holdsReports = true }

    func release() {
        holdsStates = false
        holdsReports = false
        heldSubtype = nil
        let waiting = parked
        parked = []
        for caller in waiting { caller.resume() }
    }

    private func park() async {
        callersParked += 1
        await withCheckedContinuation { parked.append($0) }
    }

    func state(of key: ChannelKey) async -> ChannelState? {
        if holdsStates { await park() }
        return await inner.state(of: key)
    }

    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        if request.subtype == heldSubtype { await park() }
        return try await inner.send(request, on: key)
    }

    func states() async -> [ChannelState] { await inner.states() }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { await inner.preconditions(for: key) }
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        try await inner.perform(action, on: key)
    }
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID {
        try await inner.sendPrompt(input, on: key)
    }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey {
        try await inner.fork(at: point, on: key)
    }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey {
        await inner.resolvedForkKey(of: provisional)
    }
    func route(_ text: String, on key: ChannelKey) async -> Routed { await inner.route(text, on: key) }
    func engineReports(of key: ChannelKey) async -> EngineReports? {
        let reports = await inner.engineReports(of: key)
        if holdsReports { await park() }
        return reports
    }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        try await inner.resolveSetting(name, to: value, on: key)
    }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome {
        try await inner.run(strategy, arguments: arguments, on: key, ui: ui)
    }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { try await inner.openInTerminal(key) }
    func attach(_ job: JobShort) async throws -> PaneRequest { try await inner.attach(job) }
    func logs(_ job: JobShort) async throws -> PaneRequest { try await inner.logs(job) }
    func paneExited(_ exit: PaneExit) async { await inner.paneExited(exit) }
    func jobs() async -> [JobEntry] { await inner.jobs() }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { try await inner.performJob(verb, short) }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { await inner.isDormantEligible(key) }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { await inner.liveTaskIDs(of: key) }
    func declineProjectServers(_ names: [String], project: URL) async throws {
        try await inner.declineProjectServers(names, project: project)
    }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {
        await inner.acceptProjectServers(servers, project: project)
    }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { await inner.events(of: key) }
    nonisolated var updates: AsyncStream<ChannelState> { inner.updates }
    nonisolated var jobUpdates: AsyncStream<[JobEntry]> { inner.jobUpdates }
}
