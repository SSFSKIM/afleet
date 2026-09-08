import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 7, gate **G7**: every picker's displayed value is an engine readback.
///
/// Every answer below is the `control-shapes` recording's own, read out of `frames.ndjson` **at run
/// time** and staged on the lifecycle double — the handshake's `current_permission_mode`, the
/// `list_models` rows, the `get_settings` body and the `apply_flag_settings` answer that carries no
/// `response` key at all. No engine byte is written into this file (§11), and the arms the recording
/// cannot produce — a readback that disagrees with the click, a settings body that disables the
/// bypass mode — are built by replacing one key of a recorded body and keeping the rest of it.
///
/// The gate's discriminating arm is `testAReadbackThatDisagreesWithTheClickShowsTheReadback`: a
/// picker that showed the right value for the wrong reason passes every other assertion here and
/// fails that one.
@MainActor
final class PickerReadbackTests: XCTestCase {

    // MARK: - Rig

    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("f"))
    }

    /// A pickers model over the double, with the recorded `list_models` and `get_settings` staged.
    private func makeModel(_ double: ComposerLifecycleDouble,
                           settings: JSONValue? = nil) async throws -> SettingPickersModel {
        await double.stageSend("list_models", .success(try Self.recordedBody("list_models")))
        let body = try settings ?? Self.recordedBody("get_settings")
        await double.stageSend("get_settings", .success(body))
        return SettingPickersModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    // MARK: - Options and displayed values

    /// The model picker's options are `list_models`' rows and its displayed value is
    /// `get_settings.applied.model`, matched after resolving the alias.
    ///
    /// The recording's `applied.model` is a canonical id that **no** row's `value` equals — it is one
    /// row's `resolvedModel` — so a picker that compared against `value` alone would show nothing
    /// here, which is what makes this an assertion about the resolution and not only about the read.
    func testModelOptionsComeFromListModelsAndTheDisplayedValueFromAppliedModel() async throws {
        let double = ComposerLifecycleDouble()
        let model = try await makeModel(double)

        await model.refresh()

        XCTAssertGreaterThan(model.modelOptions.count, 1,
                             "the recording offered \(model.modelOptions.count) model row(s); the gate needs more than one")
        let applied = try XCTUnwrap(try Self.recordedBody("get_settings")["applied"]?["model"]?.stringValue,
                                    "the recorded get_settings body carries no applied.model to read back")
        XCTAssertFalse(model.modelOptions.contains { $0.value == applied },
                       "the recorded applied model is one of the rows' `value`, so this arm does not exercise the alias resolution")
        let displayed = try XCTUnwrap(model.displayedModel, "no option matched the applied model")
        XCTAssertEqual(displayed.canonical, applied,
                       "the picker displays a row resolving to something other than the \(applied.count)-character applied id")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["list_models", "get_settings"],
                       "the readback took \(subtypes.count) request(s): " + subtypes.joined(separator: ", "))
    }

    /// `applied.effort: null` is the **default**, and `max` is not offered mid-session.
    ///
    /// The applied model is replaced with the canonical id of a row that carries effort levels — the
    /// recording's own model has none — so the exclusion is asserted against a non-empty list, which
    /// a picker offering nothing at all could otherwise pass.
    func testNullEffortIsTheDefaultAndMaxIsNotOfferedMidSession() async throws {
        let double = ComposerLifecycleDouble()
        let withEffort = try Self.settings(model: Self.canonicalOfARowWithEffortLevels())
        let model = try await makeModel(double, settings: withEffort)

        await model.refresh()

        XCTAssertNil(model.displayedEffort, "the picker read a level from an applied.effort the engine reported as null")
        XCTAssertTrue(model.isEffortDefault, "applied.effort: null did not read as the default")
        XCTAssertGreaterThan(model.effortOptions.count, 0,
                             "the effort picker offered \(model.effortOptions.count) level(s), so the exclusion below proves nothing")
        XCTAssertFalse(model.effortOptions.contains(SettingPickersModel.midSessionExcludedEffort),
                       "the effort picker offered the level that is not available mid-session")
        let offered = try XCTUnwrap(model.displayedModel?.supportedEffortLevels,
                                    "the applied model carries no supported effort levels")
        XCTAssertEqual(model.effortOptions.count, offered.count - 1,
                       "the picker dropped \(offered.count - model.effortOptions.count) of the model's \(offered.count) level(s), not exactly one")
    }

    /// The mode picker's displayed value is the handshake's `current_permission_mode`.
    func testTheModePickerDisplaysTheHandshakesCurrentPermissionMode() async throws {
        let double = ComposerLifecycleDouble()
        let model = try await makeModel(double)
        let initialize = InitializeResponse(raw: try Self.recordedInitializeBody())
        let recorded = try XCTUnwrap(initialize.currentPermissionMode,
                                     "the recorded handshake carries no current_permission_mode")

        await model.noteHandshake(initialize)

        XCTAssertEqual(model.displayedMode, recorded, "the mode picker displays something other than the handshake's mode")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes.count, 0, "noting a handshake sent \(subtypes.count) control request(s)")
    }

    /// A click on the mode picker does **not** become the displayed value. The next handshake settles
    /// it, and one that disagrees raises the disagreement while leaving its own value on screen.
    func testAModeClickIsNotDisplayedAndADisagreeingHandshakeRaisesIt() async throws {
        let double = ComposerLifecycleDouble()
        let model = try await makeModel(double)
        let recorded = InitializeResponse(raw: try Self.recordedInitializeBody())
        let reported = try XCTUnwrap(recorded.currentPermissionMode, "the recorded handshake carries no mode")
        let clicked = try XCTUnwrap(PermissionMode.allCases.first { $0 != reported && $0 != .bypassPermissions },
                                    "there is no second mode to click")
        await model.noteHandshake(recorded)

        await model.selectMode(clicked)

        XCTAssertEqual(model.displayedMode, reported, "the mode picker adopted the click instead of the readback")
        XCTAssertNil(model.disagreement, "the disagreement was raised before any handshake had answered")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["set_permission_mode"],
                       "the click sent \(subtypes.count) request(s): " + subtypes.joined(separator: ", "))

        await model.noteHandshake(recorded)

        XCTAssertEqual(model.displayedMode, reported, "the disagreeing handshake did not stay on screen")
        XCTAssertNotNil(model.disagreement, "a handshake disagreeing with the click raised nothing")
    }

    // MARK: - The discriminating arm

    /// **A readback that disagrees with the click leaves the readback on screen and raises it.**
    ///
    /// `set_model` is answered successfully and the `get_settings` that follows reports a *different*
    /// model. A picker holding the clicked value — even transiently — displays the click and fails
    /// here; the correct one displays the engine's and says the two disagree. Nothing is re-issued:
    /// the request count is asserted, so a picker that argued back fails too.
    func testAReadbackThatDisagreesWithTheClickShowsTheReadback() async throws {
        let double = ComposerLifecycleDouble()
        let rows = ModelOption.options(in: try Self.recordedBody("list_models"))
        let clicked = try XCTUnwrap(rows.first, "the recording offers no model to click")
        let reported = try XCTUnwrap(rows.first { $0.canonical != clicked.canonical },
                                     "every recorded row resolves to the same model, so no disagreement can be staged")
        let model = try await makeModel(double, settings: try Self.settings(model: reported.canonical))

        await model.refresh()
        await model.selectModel(clicked.value)

        XCTAssertEqual(model.displayedModel?.canonical, reported.canonical,
                       "the picker displays the clicked model rather than the one the engine reported")
        XCTAssertNotEqual(model.displayedModel?.canonical, clicked.canonical,
                          "the picker displays the click")
        XCTAssertNotNil(model.disagreement, "a readback disagreeing with the click raised nothing")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["list_models", "get_settings", "set_model", "get_settings"],
                       "the click sent \(subtypes.count) request(s): " + subtypes.joined(separator: ", "))
    }

    // MARK: - `apply_flag_settings` carries no answer

    /// The recorded `apply_flag_settings` success has **no `response` key at all** — not an empty
    /// object, not null — so the readback is always a fresh `get_settings`.
    ///
    /// Two arms. With a `get_settings` staged, the picker shows the level that readback reports. With
    /// the readback carrying no applied values, it shows nothing — which is exactly what a composer
    /// that read the request's own answer would show on **both** arms.
    func testTheEffortReadbackIsAFreshGetSettingsAndNeverTheAnswer() async throws {
        XCTAssertNil(try Self.recordedResponseKey("apply_flag_settings"),
                     "the recording's apply_flag_settings answer carries a response key, so this gate rests on a fact that has changed")

        let double = ComposerLifecycleDouble()
        let level = "low"
        await double.stageSend("get_settings", .success(try Self.settings(effort: level)))
        let model = SettingPickersModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())

        await model.selectEffort(level)

        XCTAssertEqual(model.displayedEffort, level,
                       "the picker shows \(model.displayedEffort?.count ?? 0) character(s) instead of the level the readback reported")
        XCTAssertNil(model.disagreement, "an agreeing readback raised a disagreement")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["apply_flag_settings", "get_settings"],
                       "the effort click sent \(subtypes.count) request(s): " + subtypes.joined(separator: ", "))

        let blind = ComposerLifecycleDouble()
        await blind.stageSend("get_settings", .success(.object([:])))
        let blindModel = SettingPickersModel(key: makeKey(), lifecycle: blind, surface: ChannelSurfaceState())

        await blindModel.selectEffort(level)

        XCTAssertNil(blindModel.displayedEffort,
                     "the picker showed a level no readback reported, which is the answer it must not read")
        XCTAssertNotNil(blindModel.disagreement, "a readback that did not report the clicked level raised nothing")
    }

    // MARK: - The bypass gate

    /// `bypassPermissions` is offered unless `permissions.disableBypassPermissionsMode` equals the
    /// **string** `"disable"` (2.1.263 `cli.pretty.js:455553`).
    ///
    /// Three arms: the key absent, the key present carrying another value, and the key equal to
    /// `"disable"` — the middle one is what separates the engine's string test from a boolean read,
    /// which would gate on truthiness and let `"disable"` through.
    func testTheBypassModeIsOfferedUnlessTheSettingEqualsTheStringDisable() async throws {
        for (value, offered) in [(nil, true), ("allow", true), ("disable", false)] as [(String?, Bool)] {
            for source in [Self.Source.effective, .sources] {
                let double = ComposerLifecycleDouble()
                let model = try await makeModel(double, settings: try Self.settings(bypass: value, in: source))

                await model.refresh()

                XCTAssertEqual(model.bypassDisabled, !offered,
                               "the gate read \(model.bypassDisabled ? "disabled" : "available") for a value of "
                                   + "\(value?.count ?? 0) character(s) in \(source.rawValue)")
                XCTAssertEqual(model.modeOptions.contains(.bypassPermissions), offered,
                               "the picker offered \(model.modeOptions.count) mode(s) for a value of "
                                   + "\(value?.count ?? 0) character(s) in \(source.rawValue)")
                XCTAssertGreaterThan(model.modeOptions.count, 1,
                                     "the picker offered \(model.modeOptions.count) mode(s), so its membership proves nothing")
            }
        }
    }

    // MARK: - §7.4's readback gate

    /// Every readback matching re-opens the composer; one that does not banners **and keeps it
    /// disabled**. Both arms, because a gate that always re-enabled would pass the first alone.
    func testTheComposerStaysDisabledUntilEveryReadbackMatchesAndBannersOnAMismatch() async throws {
        let rows = ModelOption.options(in: try Self.recordedBody("list_models"))
        let expected = try XCTUnwrap(rows.first, "the recording offers no model to snapshot")
        let other = try XCTUnwrap(rows.first { $0.canonical != expected.canonical },
                                  "every recorded row resolves to the same model")

        // The arm that survives.
        let double = ComposerLifecycleDouble()
        let surface = ChannelSurfaceState()
        await double.stageSend("list_models", .success(try Self.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try Self.settings(model: expected.canonical)))
        let model = SettingPickersModel(key: makeKey(), lifecycle: double, surface: surface)
        model.beginRestart(reason: "an invented restart")
        XCTAssertTrue(surface.isDisabled, "the composer was not disabled while the restart was in flight")

        let survived = await model.confirmReadback(of: .init(model: expected.value))

        XCTAssertTrue(survived, "a readback that matched was reported as a mismatch")
        XCTAssertFalse(surface.isDisabled, "the composer stayed disabled after every readback matched")
        XCTAssertNil(model.restartBanner, "a matching readback raised a banner")

        // The arm that does not.
        let lost = ComposerLifecycleDouble()
        let lostSurface = ChannelSurfaceState()
        await lost.stageSend("list_models", .success(try Self.recordedBody("list_models")))
        await lost.stageSend("get_settings", .success(try Self.settings(model: other.canonical)))
        let lostModel = SettingPickersModel(key: makeKey(), lifecycle: lost, surface: lostSurface)
        lostModel.beginRestart(reason: "an invented restart")

        let confirmed = await lostModel.confirmReadback(of: .init(model: expected.value))

        XCTAssertFalse(confirmed, "a readback that did not match was reported as surviving")
        XCTAssertTrue(lostSurface.isDisabled, "a setting that did not survive left the composer enabled")
        let banner = try XCTUnwrap(lostModel.restartBanner, "a mismatch raised no banner")
        XCTAssertTrue(banner.contains("model"), "the banner of \(banner.count) character(s) does not name the setting")
        XCTAssertEqual(lostSurface.disabledReason, banner, "the field's reason is not the banner's sentence")
    }

    /// While the readback gate holds the composer shut, a send reaches **nothing**.
    ///
    /// The view disables the text view, but that is a view: the refusal is asserted on the model, so
    /// a field re-enabled by any other path still cannot send into a process being replaced.
    func testASendReachesNothingWhileTheReadbackGateHoldsTheComposerShut() async throws {
        let double = ComposerLifecycleDouble()
        await double.alwaysSendPrompt(.success(UUID()))
        let surface = ChannelSurfaceState()
        let composer = ComposerModel(key: makeKey(), lifecycle: double, surface: surface)
        let typed = "an invented message typed during a restart"
        composer.draft = typed

        composer.pickers.beginRestart(reason: "an invented restart")
        await composer.send()

        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "a send during a restart reached \(members.count) lifecycle member(s)")
        XCTAssertEqual(composer.draft.count, typed.count,
                       "the disabled field kept \(composer.draft.count) of the \(typed.count) character(s) typed")

        composer.pickers.cancelRestart()
        await composer.send()

        let after = await double.memberSequence
        XCTAssertEqual(after, ["sendPrompt"],
                       "with the gate open the send reached \(after.count) member(s): " + after.joined(separator: ", "))
    }

    // MARK: - The recording

    /// Which half of `get_settings` a bypass value is written into.
    enum Source: String { case effective, sources }

    /// The recorded `get_settings` body with `applied.model` and `applied.effort` replaced. Every
    /// other key, `effective` and `sources` included, is the recording's own.
    static func settings(model: String? = nil, effort: String? = nil) throws -> JSONValue {
        guard case .object(var body) = try recordedBody("get_settings"),
              case .object(var applied)? = body["applied"] else { throw RigError.noRecordedBody }
        applied["model"] = model.map(JSONValue.string) ?? .null
        applied["effort"] = effort.map(JSONValue.string) ?? .null
        body["applied"] = .object(applied)
        return .object(body)
    }

    /// The recorded body with a `permissions.disableBypassPermissionsMode` written into one half of
    /// it. `nil` writes no key at all, which is the arm where the mode is available by default.
    static func settings(bypass value: String?, in source: Source) throws -> JSONValue {
        guard case .object(var body) = try recordedBody("get_settings") else { throw RigError.noRecordedBody }
        let permissions: JSONValue = value.map { .object(["permissions": .object(["disableBypassPermissionsMode": .string($0)])]) }
            ?? .object(["permissions": .object([:])])
        switch source {
        case .effective:
            var effective = body["effective"]?.objectValue ?? [:]
            effective["permissions"] = permissions["permissions"]
            body["effective"] = .object(effective)
        case .sources:
            var sources = body["sources"]?.arrayValue ?? []
            sources.append(.object(["source": .string("invented"), "settings": permissions]))
            body["sources"] = .array(sources)
        }
        return .object(body)
    }

    /// The canonical id of a recorded row that carries effort levels — the applied model the effort
    /// arm needs, since the recording's own model carries none.
    static func canonicalOfARowWithEffortLevels() throws -> String {
        let rows = ModelOption.options(in: try recordedBody("list_models"))
        guard let row = rows.first(where: { $0.supportedEffortLevels.contains(midSession) }) else {
            throw RigError.noRecordedBody
        }
        return row.canonical
    }

    private static let midSession = SettingPickersModel.midSessionExcludedEffort

    /// The recorded `control_response` body for the request of `subtype`.
    static func recordedBody(_ subtype: String) throws -> JSONValue {
        guard let body = try recordedResponseKey(subtype) else { throw RigError.noRecordedBody }
        return body
    }

    /// The recorded answer's `response` **key**, which for `apply_flag_settings` is absent — the fact
    /// the whole effort readback rests on.
    static func recordedResponseKey(_ subtype: String) throws -> JSONValue? {
        let records = try recordedFrames()
        guard let requestID = records.compactMap({ record -> String? in
            guard record["frame"]?["type"]?.stringValue == "control_request",
                  record["frame"]?["request"]?["subtype"]?.stringValue == subtype
            else { return nil }
            return record["frame"]?["request_id"]?.stringValue
        }).first else { throw RigError.noRecordedBody }
        for record in records {
            guard record["frame"]?["type"]?.stringValue == "control_response",
                  let response = record["frame"]?["response"],
                  response["request_id"]?.stringValue == requestID,
                  response["subtype"]?.stringValue == "success"
            else { continue }
            return response["response"]
        }
        throw RigError.noRecordedBody
    }

    /// The recorded `initialize` answer — the handshake, whose `current_permission_mode` is the mode
    /// picker's only readback.
    static func recordedInitializeBody() throws -> JSONValue {
        for record in try recordedFrames() {
            guard record["frame"]?["type"]?.stringValue == "control_response",
                  let response = record["frame"]?["response"],
                  let body = response["response"],
                  body["current_permission_mode"] != nil
            else { continue }
            return body
        }
        throw RigError.noRecordedBody
    }

    private static func recordedFrames() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures")
            .appending(path: "control-shapes").appending(path: "frames.ndjson")
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(JSONValue.self, from: data)
        }
    }

    enum RigError: Error { case noRecordedBody }
}
