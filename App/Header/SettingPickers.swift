import SwiftUI
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// One row of `list_models.models[]`, as the picker offers it.
///
/// The keys are the engine's own (`control-shapes`): `value` is what a request carries, `resolvedModel`
/// is the canonical id an alias like `default` or `opus[1m]` stands for, and `supportedEffortLevels`
/// is what the effort picker may offer while this model is current.
struct ModelOption: Hashable, Sendable, Identifiable {
    var value: String
    var resolvedModel: String?
    var displayName: String
    var supportsEffort: Bool
    var supportedEffortLevels: [String]

    var id: String { value }

    /// The canonical id this row stands for: `resolvedModel` when the engine gave one, otherwise the
    /// value itself, which is already canonical.
    var canonical: String { resolvedModel ?? value }

    static func options(in answer: JSONValue?) -> [ModelOption] {
        (answer?["models"]?.arrayValue ?? []).compactMap { row in
            guard let value = row["value"]?.stringValue else { return nil }
            return ModelOption(value: value,
                               resolvedModel: row["resolvedModel"]?.stringValue,
                               displayName: row["displayName"]?.stringValue ?? value,
                               supportsEffort: row["supportsEffort"]?.boolValue ?? false,
                               supportedEffortLevels: row["supportedEffortLevels"]?.arrayValue?
                                   .compactMap(\.stringValue) ?? [])
        }
    }
}

/// The three pickers — permission mode, model, effort — and §7.4's readback gate they share
/// (spec C6.2 *The pickers, and readbacks over clicks*, gate **G7**).
///
/// **Every displayed value is an engine readback and never the last thing the user clicked.** That
/// is the whole design, and it is not a preference about accuracy: `apply_flag_settings` answers
/// success with **no `response` key at all** (`control-shapes`), the engine's validator refuses a
/// permission mode outright when the launch flag is missing (§8.6), and `--resume` restores neither
/// mode nor flag settings (§7.4) — so in each case a picker that showed the click would be showing
/// something that may simply not be true of the process.
///
/// A click therefore issues its request and then **re-reads**: a fresh `get_settings` for model and
/// effort, the handshake for permission mode, which is the only readback the engine offers for it. A
/// readback that disagrees with the click leaves the readback on screen and raises the disagreement;
/// it does not silently re-issue, because a picker that argued with the engine would loop against a
/// setting the engine has a reason to refuse.
///
/// What lives here and what does not: this model owns the options, the displayed values, the bypass
/// **gating** and the readback gate's mechanism. The bypass disclaimer, the store write, the
/// quiescent restart itself and the header's restart actions are Task 8's, and call in here.
@MainActor
@Observable
final class SettingPickersModel {

    let key: ChannelKey
    /// Shared with the composer and the header: §7.4 closes the field through it while a readback is
    /// unconfirmed.
    let surface: ChannelSurfaceState
    @ObservationIgnored private let lifecycle: any LifecycleAPI

    /// The model picker's options, from `list_models`.
    private(set) var modelOptions: [ModelOption] = []

    /// `get_settings.applied.model` exactly as the engine reported it — the canonical id, which is
    /// why the comparison against an option resolves the alias first.
    private(set) var appliedModel: String?

    /// `get_settings.applied.effort`. **Nil means the default**, which is a value the engine
    /// deliberately reports as `null` and not an absence of information (§7.4, 2026-09-06).
    private(set) var appliedEffort: String?

    /// The handshake's `current_permission_mode`, and the only readback permission mode has.
    private(set) var handshakeMode: PermissionMode?

    /// True when `get_settings` reports the bypass mode disabled. See `bypassIsDisabled(in:)`.
    private(set) var bypassDisabled = false

    /// Set when a readback disagreed with a click: a sentence naming the setting, never a value the
    /// engine chose (§11). Cleared by the next agreeing readback.
    private(set) var disagreement: String?

    /// §7.4's banner: a setting that did not survive a quiescent restart, named. The composer stays
    /// disabled while this is set.
    private(set) var restartBanner: String?

    /// How many `get_settings` readbacks this model has taken. A count, and the floor a test needs to
    /// tell "read nothing" from "read and found nothing".
    private(set) var readbacksTaken = 0

    /// Where a click on `bypassPermissions` goes when something has claimed it — the header's §8.6
    /// gate. Nil leaves the click going straight to the engine.
    @ObservationIgnored var bypassRoute: (@MainActor () async -> Void)?

    /// The mode the user last asked for, held only until the next handshake can be compared against
    /// it. **Not a displayed value** — nothing reads it to draw with — and cleared as soon as a
    /// handshake settles the question.
    @ObservationIgnored private var requestedMode: PermissionMode?

    init(key: ChannelKey, lifecycle: any LifecycleAPI, surface: ChannelSurfaceState) {
        self.key = key
        self.lifecycle = lifecycle
        self.surface = surface
    }

    // MARK: - What each picker displays

    /// The model picker's selected row: the option whose canonical id is `applied.model`, matched
    /// after resolving the alias through `models[].resolvedModel`.
    ///
    /// Nil when the engine's applied model is not one of the rows it offered, which is a state worth
    /// showing as it is rather than rounding to the nearest option.
    var displayedModel: ModelOption? {
        guard let appliedModel else { return nil }
        if let exact = modelOptions.first(where: { $0.value == appliedModel }) { return exact }
        return modelOptions.first { $0.canonical == appliedModel }
    }

    /// What the model picker shows: the matched option's `value`, or the applied id itself when no
    /// option matched. Either way it is the readback.
    var displayedModelValue: String? { displayedModel?.value ?? appliedModel }

    /// The effort picker's options: the current model's `supportedEffortLevels`, **minus `max`**.
    ///
    /// `max` is not offered mid-session — every channel afleet draws a picker for is a running
    /// process, so the exclusion is unconditional here rather than a mode this model tracks.
    var effortOptions: [String] {
        (displayedModel?.supportedEffortLevels ?? []).filter { $0 != Self.midSessionExcludedEffort }
    }

    static let midSessionExcludedEffort = "max"

    /// What the effort picker shows. **Nil is the default**, and `isEffortDefault` is how a view says
    /// so without inventing a level name the engine does not use.
    var displayedEffort: String? { appliedEffort }
    var isEffortDefault: Bool { appliedEffort == nil }

    /// The mode picker's selected value: the handshake's, always.
    var displayedMode: PermissionMode? { handshakeMode }

    /// The modes the picker offers. `bypassPermissions` is gated on the readback below; every other
    /// mode is `PermissionMode.allCases` in its own order, which is C2's list and not a copy.
    var modeOptions: [PermissionMode] {
        PermissionMode.allCases.filter { $0 != .bypassPermissions || !bypassDisabled }
    }

    // MARK: - Reading the engine

    /// Records the handshake: the mode readback, and the disagreement arm for a mode that was clicked
    /// and did not take.
    ///
    /// No lifecycle call is made here. A handshake arrives on every connect and every quiescent
    /// restart, and querying two control requests off it would spend them on channels no picker has
    /// been opened for.
    func noteHandshake(_ initialize: InitializeResponse) {
        handshakeMode = initialize.currentPermissionMode
        if let requested = requestedMode {
            requestedMode = nil
            if let reported = handshakeMode, reported != requested {
                disagreement = Self.disagreementNote(setting: "permission mode")
            }
        }
    }

    /// Both readbacks: the options from `list_models` and the applied values from `get_settings`.
    ///
    /// Typed specs through `AnyControlRequest`, because ClaudeWire types both (contract Y5); the raw
    /// form is reserved for a subtype it does not type.
    func refresh() async {
        if let models = await answer(to: AnyControlRequest(ListModels())) {
            modelOptions = ModelOption.options(in: models)
        }
        await readSettings()
    }

    /// One `get_settings`, folded into the applied values and the bypass gate. Answers the body so a
    /// caller comparing against a click reads the same object this model displayed.
    @discardableResult
    func readSettings() async -> JSONValue? {
        guard let settings = await answer(to: AnyControlRequest(GetSettings())) else { return nil }
        readbacksTaken += 1
        let applied = settings["applied"]
        appliedModel = applied?["model"]?.stringValue
        appliedEffort = applied?["effort"]?.stringValue
        bypassDisabled = Self.bypassIsDisabled(in: settings)
        return settings
    }

    /// **The engine's own test, and it is a string comparison** (2.1.263 `cli.pretty.js:455553`):
    /// `permissions.disableBypassPermissionsMode` equal to `"disable"`. Any other value, and the key's
    /// absence, both leave the mode available — a boolean read here would gate on `true` and let
    /// `"disable"` through, which is the whole reason the fact is written down.
    ///
    /// Read from `effective.permissions` and from every `sources[].settings.permissions`, because a
    /// source can carry it while the merged view does not.
    static func bypassIsDisabled(in settings: JSONValue) -> Bool {
        func disabled(_ permissions: JSONValue?) -> Bool {
            permissions?["disableBypassPermissionsMode"]?.stringValue == "disable"
        }
        if disabled(settings["effective"]?["permissions"]) { return true }
        for source in settings["sources"]?.arrayValue ?? [] {
            if disabled(source["settings"]?["permissions"]) { return true }
        }
        return false
    }

    // MARK: - The clicks

    /// The model picker clicked: `set_model`, then a fresh `get_settings`.
    ///
    /// The comparison resolves both sides through `models[].resolvedModel` before it decides, so
    /// clicking the alias `default` and reading back the canonical id it stands for is agreement and
    /// not a mismatch.
    func selectModel(_ value: String) async {
        guard await issue(AnyControlRequest(SetModel(model: value))) else { return }
        await readSettings()
        let clicked = modelOptions.first { $0.value == value }?.canonical ?? value
        let shown = displayedModel?.canonical ?? appliedModel
        note(agrees: shown == clicked, setting: "model")
    }

    /// The effort picker clicked: `apply_flag_settings {settings: {effortLevel}}`, then a fresh
    /// `get_settings`.
    ///
    /// **The readback is never the answer.** `apply_flag_settings` answers success with no `response`
    /// key at all, so a composer that displayed what the request returned would display nothing and
    /// look broken; the value comes from the `get_settings` that follows.
    ///
    /// `nil` asks for the default, which the engine spells as a null flag value and reports back as
    /// `applied.effort: null`.
    func selectEffort(_ level: String?) async {
        let setting = JSONValue.object(["effortLevel": level.map(JSONValue.string) ?? .null])
        guard await issue(AnyControlRequest(ApplyFlagSettings(settings: setting))) else { return }
        await readSettings()
        note(agrees: appliedEffort == level, setting: "effort")
    }

    /// The mode picker clicked: `set_permission_mode`.
    ///
    /// There is no re-read to take. The only readback permission mode has is the handshake's
    /// `current_permission_mode`, and a handshake arrives on connect and on quiescent restart — so
    /// the click is remembered, the displayed value does **not** move, and the next handshake either
    /// confirms it or raises the disagreement. A picker that adopted the click here would report a
    /// mode the engine's validator may have refused outright (§8.6's three refusal arms).
    /// It answers the engine's **own** refusal string when the mode was refused, and nil when the
    /// request went out. §8.6's validator has three refusal arms — a restricted session, the settings
    /// disable and the missing launch flag — and afleet renders whichever string comes back rather
    /// than guessing which of them fired, so a caller needs the sentence and not a boolean.
    ///
    /// `bypassPermissions` is the one row that does not go straight out: §8.6 puts a disclaimer, a
    /// store write and a quiescent restart in front of it, and that gate is the header's
    /// (`BypassGate`). The picker routes the click there when a route is installed and issues the
    /// request itself when none is — a channel drawn with no header still has a mode picker, and the
    /// engine's own validator is what refuses a mode the process cannot take.
    @discardableResult
    func selectMode(_ mode: PermissionMode) async -> String? {
        if mode == .bypassPermissions, let bypassRoute {
            await bypassRoute()
            return nil
        }
        return await issueMode(mode)
    }

    /// The request itself, with no gate in front of it. §8.6's third step calls this directly, after
    /// the acceptance is written and the restart has been confirmed.
    @discardableResult
    func issueMode(_ mode: PermissionMode) async -> String? {
        do {
            _ = try await lifecycle.send(AnyControlRequest(SetPermissionMode(mode: mode)), on: key)
        } catch {
            let reason = Self.reason(of: error)
            disagreement = reason
            return reason
        }
        requestedMode = mode
        return nil
    }

    /// The engine's sentence, when the error carries one. `WireError.controlError` holds the wire's
    /// own `error` string; anything else is afleet's transport failing, which the engine did not say.
    static func reason(of error: any Error) -> String {
        if case WireError.controlError(let sentence) = error, !sentence.isEmpty { return sentence }
        return "The channel did not answer; what is shown is the last value it reported."
    }

    // MARK: - §7.4's readback gate

    /// The values a quiescent restart is expected to carry across (§7.4's snapshot). Every field is
    /// optional because a restart verifies what it re-passed and nothing else.
    struct RestartSnapshot: Sendable, Hashable {
        var model: String?
        var effort: String?
        var permissionMode: PermissionMode?
        init(model: String? = nil, effort: String? = nil, permissionMode: PermissionMode? = nil) {
            self.model = model; self.effort = effort; self.permissionMode = permissionMode
        }
    }

    /// What the pickers last read, as the snapshot a restart is expected to carry across.
    ///
    /// The readbacks and nothing else: `RestartRequest` carries the launch flags and the fleet
    /// snapshots the runtime values itself, so what this leaf can verify is that the new process
    /// reports the same model, effort and mode the old one did — which is exactly what §7.4 asks it
    /// to verify. A field nothing has read yet is nil and is not compared.
    var currentSnapshot: RestartSnapshot {
        RestartSnapshot(model: displayedModel?.value, effort: appliedEffort, permissionMode: handshakeMode)
    }

    /// Closes the composer while a restart-required setting is being confirmed. Called before the
    /// restart is issued, so no keystroke reaches a process that is going away.
    func beginRestart(reason: String) {
        surface.isRestarting = true
        surface.isDisabled = true
        surface.disabledReason = reason
        restartBanner = nil
    }

    /// A restart that never happened: the field re-opens rather than staying shut behind a process
    /// that was never replaced.
    func cancelRestart() {
        surface.isRestarting = false
        surface.isDisabled = false
        surface.disabledReason = nil
    }

    /// §7.4's readback rule. Driven by the composer's own `.restart` route (`CommandRouting`) and, at
    /// Task 8, by the header's restart-required settings.
    ///
    /// The composer stays disabled behind the connecting glyph until **every** readback matches; a
    /// mismatch raises a banner naming the setting that did not survive and keeps it disabled until
    /// the user picks a value. Answers whether every readback matched.
    ///
    /// The banner names settings, never the values on either side: the engine's model id or effort
    /// level is a value read off a process, and the reader needs to know which setting to look at.
    @discardableResult
    func confirmReadback(of expected: RestartSnapshot) async -> Bool {
        surface.isRestarting = false
        await refresh()
        var failed: [String] = []
        if let model = expected.model {
            let wanted = modelOptions.first { $0.value == model }?.canonical ?? model
            if (displayedModel?.canonical ?? appliedModel) != wanted { failed.append("model") }
        }
        if expected.effort != appliedEffort { failed.append("effort") }
        if let mode = expected.permissionMode, handshakeMode != mode { failed.append("permission mode") }
        guard failed.isEmpty else {
            restartBanner = "\(failed.count) setting(s) did not survive the restart: "
                + failed.joined(separator: ", ") + ". Pick a value to continue."
            surface.isDisabled = true
            surface.disabledReason = restartBanner
            return false
        }
        restartBanner = nil
        surface.isDisabled = false
        surface.disabledReason = nil
        return true
    }

    // MARK: - Plumbing

    /// One control request through X5, answering its body. A refusal is surfaced as a disagreement
    /// rather than thrown on: a picker whose request the channel refused has nothing new to display,
    /// and the displayed value is still the last readback, which is still true.
    private func answer(to request: AnyControlRequest) async -> JSONValue? {
        do {
            return try await lifecycle.send(request, on: key)
        } catch {
            disagreement = "The channel did not answer; what is shown is the last value it reported."
            return nil
        }
    }

    /// One control request whose body is not read. Answers whether it went out.
    private func issue(_ request: AnyControlRequest) async -> Bool {
        do {
            _ = try await lifecycle.send(request, on: key)
            return true
        } catch {
            disagreement = "The channel did not answer; what is shown is the last value it reported."
            return false
        }
    }

    private func note(agrees: Bool, setting: String) {
        disagreement = agrees ? nil : Self.disagreementNote(setting: setting)
    }

    static func disagreementNote(setting: String) -> String {
        "The engine reports a different \(setting) than the one selected; what is shown is the engine's."
    }
}

/// The three pickers, as menus. Each draws its options and its **readback**, and holds no click of
/// its own — a `Picker` with a two-way binding would store the selection, which is precisely the
/// state this design refuses to keep.
///
/// Presentation is advisory (spec *Design inheritance*); the readback rule above is not.
struct SettingPickersView: View {

    @Bindable var model: SettingPickersModel

    var body: some View {
        HStack(spacing: 8) {
            Menu(model.displayedModel?.displayName ?? model.displayedModelValue ?? "Model") {
                ForEach(model.modelOptions) { option in
                    Button(option.displayName) { Task { await model.selectModel(option.value) } }
                }
            }
            Menu(model.isEffortDefault ? "Default effort" : (model.displayedEffort ?? "Effort")) {
                Button("Default") { Task { await model.selectEffort(nil) } }
                ForEach(model.effortOptions, id: \.self) { level in
                    Button(level) { Task { await model.selectEffort(level) } }
                }
            }
            Menu(model.displayedMode?.rawValue ?? "Permission mode") {
                ForEach(model.modeOptions, id: \.self) { mode in
                    Button(mode.rawValue) { Task { await model.selectMode(mode) } }
                }
            }
            if let disagreement = model.disagreement {
                Text(disagreement).font(.callout).foregroundStyle(.secondary)
            }
            if let banner = model.restartBanner {
                Label(banner, systemImage: "exclamationmark.triangle").font(.callout)
            }
        }
        .task { await model.refresh() }
    }
}
