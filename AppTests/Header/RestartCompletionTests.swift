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
        pickers.beginRestart(reason: "an invented restart")

        let survived = await pickers.confirmReadback(of: .init(model: expected.value))

        XCTAssertFalse(survived, "a model the readback did not report was taken as surviving")
        XCTAssertTrue(surface.isDisabled, "a mismatch left the field open")

        // The fleet is holding the same channel over the same setting, which is the state the banner
        // is promising recovery from.
        var held = HeaderRig.replaced(key)
        held.banner = .settingDidNotSurvive(SettingPickersModel.modelSetting)
        await double.setStates([held])
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
        pickers.beginRestart(reason: "an invented restart")
        await pickers.noteHandshake(try initialize(mode: clicked))

        let survived = await pickers.confirmReadback(of: snapshot)

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
