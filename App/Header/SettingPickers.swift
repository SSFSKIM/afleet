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

    /// Whether a picker has ever asked the engine for its options, and whether the last attempt came
    /// back complete. Both are needed and neither alone is: a channel with no process refuses the two
    /// requests, so an empty menu is either "nobody asked yet" or "asked and the process was not
    /// there", and only the second is worth re-asking on the next handshake.
    private(set) var hasAskedTheEngine = false
    private(set) var lastRefreshSucceeded = false

    /// The settings a restart did not carry across, by the fleet's own `Readback.verify` names.
    ///
    /// A list rather than a flag, because recovery is per setting: the banner promises that picking a
    /// value continues, and a gate that reopened on the first pick would release the field with the
    /// second setting still unanswered.
    private(set) var restartFailures: [String] = []

    /// The picker a routed command with no argument asked for, by `RouterTable`'s own surface name.
    /// Nil whenever nothing was asked for; the menu clears it when it closes.
    var presentedPicker: String?

    /// The two surface names that name a picker this model draws. The router's strings, compared and
    /// never re-spelled: `CommandRouter.picker(for:)` builds them from the command's own name.
    static let pickerSurfaces = ["modelPicker", "effortPicker"]

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
    /// A handshake that follows a refresh the channel could not answer reloads the pickers, because
    /// that handshake is the first moment there is a process to answer them: an archived channel the
    /// user opened has a menu that was drawn and populated with nothing, and nothing else ever asks
    /// again. A refresh that already came back complete is not repeated — that is the case this
    /// method's silence was written for, and it is still silent for it.
    func noteHandshake(_ initialize: InitializeResponse) async {
        handshakeMode = initialize.currentPermissionMode
        if let requested = requestedMode {
            requestedMode = nil
            if let reported = handshakeMode, reported != requested {
                disagreement = Self.disagreementNote(setting: "permission mode")
            }
        }
        if hasAskedTheEngine, !lastRefreshSucceeded { await refresh() }
    }

    /// Both readbacks: the options from `list_models` and the applied values from `get_settings`.
    ///
    /// Typed specs through `AnyControlRequest`, because ClaudeWire types both (contract Y5); the raw
    /// form is reserved for a subtype it does not type.
    ///
    /// Answers whether **both** came back. A caller that is deciding something — §7.4's readback gate
    /// is the one that does — needs the difference between a value that was read and a value that was
    /// merely kept: `readSettings` leaves the last readback in place when the channel does not answer,
    /// which is right for a display and wrong for a comparison.
    @discardableResult
    func refresh() async -> Bool {
        hasAskedTheEngine = true
        var complete = true
        if let models = await answer(to: AnyControlRequest(ListModels())) {
            modelOptions = ModelOption.options(in: models)
        } else {
            complete = false
        }
        if await readSettings() == nil { complete = false }
        lastRefreshSucceeded = complete
        return complete
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
    @discardableResult
    func selectModel(_ value: String) async -> Bool {
        guard await apply(Self.modelSetting, .string(value),
                          otherwise: AnyControlRequest(SetModel(model: value))) else { return false }
        await readSettings()
        let clicked = modelOptions.first { $0.value == value }?.canonical ?? value
        let shown = displayedModel?.canonical ?? appliedModel
        note(agrees: shown == clicked, setting: "model")
        clearRestartGate(for: Self.modelSetting)
        return true
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
    @discardableResult
    func selectEffort(_ level: String?) async -> Bool {
        let value = level.map(JSONValue.string) ?? .null
        let setting = JSONValue.object(["effortLevel": value])
        guard await apply(Self.effortSetting, value,
                          otherwise: AnyControlRequest(ApplyFlagSettings(settings: setting))) else { return false }
        await readSettings()
        note(agrees: appliedEffort == level, setting: "effort")
        clearRestartGate(for: Self.effortSetting)
        return true
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
            if await fleetIsHolding(Self.modeSetting) {
                try await lifecycle.resolveSetting(Self.modeSetting, to: .string(mode.rawValue), on: key)
            } else {
                _ = try await lifecycle.send(AnyControlRequest(SetPermissionMode(mode: mode)), on: key)
            }
        } catch {
            let reason = Self.reason(of: error)
            disagreement = reason
            return reason
        }
        requestedMode = mode
        clearRestartGate(for: Self.modeSetting)
        return nil
    }

    /// A routed `/model`, `/effort` or `/permissions <mode>`, taken through the click path the menu
    /// takes rather than sent straight out (§8.6 binds every path to the bypass gate, and §7.4 binds
    /// every change to a readback).
    ///
    /// Answers nil for every other subtype — including an `apply_flag_settings` that is not the effort
    /// picker's one key — which the composer sends itself. The three the pickers own are matched on
    /// the subtype and the payload the router already built, so nothing here re-parses a line.
    func apply(routed request: AnyControlRequest) async -> Bool? {
        switch request.subtype {
        case SetModel.subtype:
            guard let model = request.payload["model"]?.stringValue else { return nil }
            return await selectModel(model)
        case ApplyFlagSettings.subtype:
            guard let settings = request.payload["settings"]?.objectValue, settings.count == 1,
                  let level = settings["effortLevel"] else { return nil }
            return await selectEffort(level.stringValue)
        case SetPermissionMode.subtype:
            guard let mode = request.payload["mode"]?.stringValue.flatMap(PermissionMode.init(rawValue:))
            else { return nil }
            return await selectMode(mode) == nil
        default:
            return nil
        }
    }

    /// Whether this picker is the one a routed command asked to open, as a binding a popover reads.
    /// Dismissing it clears the request rather than leaving a surface the router would not re-open.
    func presenting(_ surface: String) -> Binding<Bool> {
        Binding(get: { self.presentedPicker == surface },
                set: { if !$0, self.presentedPicker == surface { self.presentedPicker = nil } })
    }

    /// A `.native` destination that names one of these pickers, opened. Answers whether it was one:
    /// `tasks`, `agents` and `switcher` are other surfaces' and this model says so rather than
    /// swallowing them.
    @discardableResult
    func present(_ surface: String) -> Bool {
        guard Self.pickerSurfaces.contains(surface) else { return false }
        presentedPicker = surface
        return true
    }

    /// One picker click, as either an ordinary request or the answer to a mismatch the **fleet** is
    /// holding the channel over.
    ///
    /// Both apply the value; only the second advances the fleet's own banner, and only the fleet may
    /// advance it — `resolveSetting` applies the value first and moves the banner on afterwards, so a
    /// channel is never released over a setting the engine did not receive. Sending the request and
    /// then advancing separately would be two decisions about one click, and the banner would move on
    /// a request the channel refused.
    private func apply(_ name: String, _ value: JSONValue, otherwise request: AnyControlRequest) async -> Bool {
        guard await fleetIsHolding(name) else { return await issue(request) }
        do {
            try await lifecycle.resolveSetting(name, to: value, on: key)
            return true
        } catch {
            disagreement = Self.reason(of: error)
            return false
        }
    }

    /// Whether the fleet is holding this channel connecting over exactly this setting.
    ///
    /// Read from the channel's own state and never inferred from this model's banner: the two gates
    /// are separate — `unresolvedSettings` keeps the channel connecting, `surface.isDisabled` closes
    /// the field — and a click that answered only the one it can see leaves the other one shut.
    private func fleetIsHolding(_ name: String) async -> Bool {
        guard case .settingDidNotSurvive(let held)? = await lifecycle.state(of: key)?.banner else { return false }
        return held == name
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
    /// The mode is the one the channel is **running**, which after a click is the one that was asked
    /// for and not the one the last handshake reported: permission mode has no readback except a
    /// handshake, `RuntimeStateUpdater` records the accepted mode the moment the request goes out, and
    /// the relaunch carries that record. Snapshotting the old handshake here made a correctly restored
    /// mode read as a mismatch and closed the composer over it.
    var currentSnapshot: RestartSnapshot {
        RestartSnapshot(model: displayedModel?.value, effort: appliedEffort,
                        permissionMode: requestedMode ?? handshakeMode)
    }

    /// The three settings this model can both verify and put back, by the fleet's own
    /// `Readback.verify` names. Spelled once, because they are also the names `resolveSetting` takes
    /// and the names the channel's banner carries.
    static let modelSetting = "model"
    static let effortSetting = "effort"
    static let modeSetting = "permissionMode"

    /// The same name as the banner says it. Only the mode's differs, because `permissionMode` is a
    /// key and *permission mode* is a sentence.
    static func label(of name: String) -> String { name == modeSetting ? "permission mode" : name }

    /// Closes the composer while a restart-required setting is being confirmed. Called before the
    /// restart is issued, so no keystroke reaches a process that is going away.
    func beginRestart(reason: String) {
        surface.isRestarting = true
        surface.isDisabled = true
        surface.disabledReason = reason
        restartBanner = nil
        restartFailures = []
    }

    /// Whether the state a `quiescentRestart` answered with is a process that was really replaced.
    ///
    /// **`perform` answers as soon as the change is recorded, not once it has run.** A channel that is
    /// not eligible — a turn running, a local shell still working — keeps the request as
    /// `pendingChange` for the dormant timer, and a change asked for while a restart is in flight
    /// merges into that pending one; both return success with the old process still on the other end.
    /// Confirming a readback there releases the field over settings nothing re-applied, and §8.6's
    /// mode switch would reach a process launched without the flag it needs.
    static func replacedTheProcess(_ after: ChannelState, from before: ChannelState?) -> Bool {
        guard after.pendingChange == nil, after.wedged == nil else { return false }
        return after.epoch != before?.epoch
    }

    /// A restart that was recorded rather than run. The process is still the one it was, so the field
    /// re-opens — nothing is being replaced and a closed field would be closed for as long as the
    /// channel stays busy — and the change is named as pending (§7.4's *applies when the current work
    /// finishes*).
    func noteQueuedRestart() {
        surface.isRestarting = false
        surface.isDisabled = false
        surface.disabledReason = nil
        restartBanner = "This channel is busy; the setting applies when the current work finishes."
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
        // **A comparison needs values that were read, not values that were kept.** `readSettings`
        // leaves the last readback in place when the channel does not answer — right for a display,
        // and wrong here: comparing the retained values against a snapshot taken from those same
        // values agrees with itself and releases the field without the new process having reported
        // anything at all.
        guard await refresh() else {
            restartFailures = []
            restartBanner = "The channel did not report its settings after the restart; "
                + "the field stays closed until it does."
            surface.isDisabled = true
            surface.disabledReason = restartBanner
            return false
        }
        var failed: [String] = []
        if let model = expected.model {
            let wanted = modelOptions.first { $0.value == model }?.canonical ?? model
            if (displayedModel?.canonical ?? appliedModel) != wanted { failed.append(Self.modelSetting) }
        }
        if expected.effort != appliedEffort { failed.append(Self.effortSetting) }
        if let mode = expected.permissionMode, handshakeMode != mode { failed.append(Self.modeSetting) }
        guard failed.isEmpty else {
            restartFailures = failed
            restartBanner = Self.banner(for: failed)
            surface.isDisabled = true
            surface.disabledReason = restartBanner
            return false
        }
        restartFailures = []
        restartBanner = nil
        surface.isDisabled = false
        surface.disabledReason = nil
        return true
    }

    /// The banner, over the settings that did not survive. Names, never the values on either side: a
    /// model id or an effort level is a value read off a process, and what the reader needs is which
    /// setting to look at (§11).
    static func banner(for failed: [String]) -> String {
        "\(failed.count) setting(s) did not survive the restart: "
            + failed.map(label(of:)).joined(separator: ", ") + ". Pick a value to continue."
    }

    /// The recovery the banner promises, for one setting the user has just picked a value for.
    ///
    /// The field re-opens only when the **last** one has been answered; until then the banner names
    /// what is left. The fleet's own half of the gate is answered where the click goes out, through
    /// `resolveSetting` — this is the surface's half, and a picker that moved one without the other
    /// would leave the channel connecting behind an open field or the field shut behind a ready
    /// channel.
    private func clearRestartGate(for name: String) {
        guard let index = restartFailures.firstIndex(of: name) else { return }
        restartFailures.remove(at: index)
        guard restartFailures.isEmpty else {
            restartBanner = Self.banner(for: restartFailures)
            surface.disabledReason = restartBanner
            return
        }
        restartBanner = nil
        surface.isDisabled = false
        surface.disabledReason = nil
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
            // A bare `/model` routes to the `modelPicker` surface, and this is that surface: the same
            // options as the menu, in a popover the router can open. Without it the row cleared the
            // line and nothing appeared (`CommandRouting`, `.native`).
            .popover(isPresented: model.presenting("modelPicker")) {
                PickerOptionsView(title: "Model") {
                    ForEach(model.modelOptions) { option in
                        Button(option.displayName) {
                            model.presentedPicker = nil
                            Task { await model.selectModel(option.value) }
                        }
                    }
                }
            }
            Menu(model.isEffortDefault ? "Default effort" : (model.displayedEffort ?? "Effort")) {
                Button("Default") { Task { await model.selectEffort(nil) } }
                ForEach(model.effortOptions, id: \.self) { level in
                    Button(level) { Task { await model.selectEffort(level) } }
                }
            }
            .popover(isPresented: model.presenting("effortPicker")) {
                PickerOptionsView(title: "Effort") {
                    Button("Default") {
                        model.presentedPicker = nil
                        Task { await model.selectEffort(nil) }
                    }
                    ForEach(model.effortOptions, id: \.self) { level in
                        Button(level) {
                            model.presentedPicker = nil
                            Task { await model.selectEffort(level) }
                        }
                    }
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

/// The options of one picker, as the popover a routed `/model` or `/effort` opens draws them.
///
/// A container and nothing else: every row it shows is passed in by the picker that owns the options,
/// so the popover and the menu offer one list and not two.
struct PickerOptionsView<Options: View>: View {

    let title: String
    @ViewBuilder let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            options
        }
        .buttonStyle(.plain)
        .padding(8)
        .frame(minWidth: 180)
    }
}
