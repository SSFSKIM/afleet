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

    /// The channel's epoch when that request went out, which is what makes a **retained** handshake
    /// answerable: a report from the same process is older than the request by construction — a mode
    /// switch produces no handshake of its own — and only a report from a later epoch is the
    /// replacement's and can settle it.
    @ObservationIgnored private var requestedModeEpoch: ProcessEpoch?

    /// Whether a picker has ever asked the engine for its options, and whether the last attempt came
    /// back complete. Both are needed and neither alone is: a channel with no process refuses the two
    /// requests, so an empty menu is either "nobody asked yet" or "asked and the process was not
    /// there", and only the second is worth re-asking on the next handshake.
    private(set) var hasAskedTheEngine = false
    private(set) var lastRefreshSucceeded = false

    /// The picker a routed command with no argument asked for, by `RouterTable`'s own surface name.
    /// Nil whenever nothing was asked for; the menu clears it when it closes.
    var presentedPicker: String?

    /// The restart-required change this model is running, if it is running one.
    ///
    /// **At most one, and it carries its own generation, expected snapshot and phase.** Every entry
    /// point that begins a restart is handed the generation back and gives it to whichever transition
    /// closes the operation; every continuation that resumes after an await checks it before it
    /// touches anything, and drops itself when a newer operation has replaced it. A count of restarts
    /// in flight and a free-standing owed snapshot were one fact spread over two fields nothing kept
    /// in step — which is how four review rounds each found another decision taken on a reading an
    /// await had already made stale.
    private(set) var operation: RestartOperation?

    /// Where the next generation comes from. Monotonic for the life of this model, so a number is
    /// never reused and a superseded continuation cannot match by accident.
    @ObservationIgnored private var generationsMinted = 0

    /// Whether §8.6's acceptance — the store write, the restart, the mode switch — is running now.
    /// Read by `BypassGate`, which refuses to re-enter while it is true.
    private(set) var isAcceptingBypass = false

    /// The settings the user has picked a value for since the banner went up. The fleet resolves its
    /// own unresolved settings **in order**, so a correction made out of that order applies the value
    /// and leaves the fleet's list where it was; this is what lets the surface answer the fleet's
    /// banner again with the value the engine now reports rather than asking the user to pick twice.
    @ObservationIgnored private var corrected: Set<String> = []

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

    /// The first readback, taken as part of drawing this channel's pickers. **Idempotent**, and the
    /// reason it exists at all: the header's slot keeps its SwiftUI identity across a channel switch,
    /// so a `.task` attached to the picker row runs once — for the first channel's model — and never
    /// again for the second's, which would then draw an empty menu for a perfectly live channel and
    /// never ask. The same answer the composer's own mount gives (Decision Log, 2026-09-08): resolve
    /// and start on draw, rather than key a view identity no test in this tree can see.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        await note(initialize, settling: true)
    }

    /// The same handshake, when it comes from the fleet's **retained** copy rather than off the
    /// stream — a late surface seeding itself (`seedEngineReports`).
    ///
    /// A retained report is not news. Remounting re-runs the seeding, so a handshake this model has
    /// already seen is handed to it again, and reading that as the answer to a mode the user asked
    /// for since would report a successful change as a disagreement and leave `currentSnapshot`
    /// carrying the mode the process no longer runs — which closes the composer over a restart that
    /// restored it correctly. It settles the request only when the fleet's channel has moved to a
    /// later epoch, which is the one case where the retained report is the replacement's.
    func noteRetainedHandshake(_ initialize: InitializeResponse) async {
        await note(initialize, settling: await reportIsNewerThanTheRequest())
    }

    private func note(_ initialize: InitializeResponse, settling settlesTheRequest: Bool) async {
        handshakeMode = initialize.currentPermissionMode
        if settlesTheRequest, let requested = requestedMode {
            requestedMode = nil
            requestedModeEpoch = nil
            if let reported = handshakeMode, reported != requested {
                disagreement = Self.disagreementNote(setting: "permission mode")
            }
        }
        if hasAskedTheEngine, !lastRefreshSucceeded { await refresh() }
        // A handshake is also the moment an owed confirmation can be settled: it is the replacement
        // reporting, and the readback that could not be taken when the restart returned is taken now.
        if let operation, case .owed = operation.phase {
            await confirm(operation.generation)
            return
        }
        // And it is the moment a channel that was left connecting can have become ready, which is one
        // of the gate's own inputs. The release is asked again rather than assumed: a confirmation
        // that completed against a connecting replacement left the field closed on purpose, and
        // nothing else would ever come back to open it.
        await releaseOrHold()
    }

    /// Whether the process the fleet is running now is a later one than the process the mode request
    /// went to. With no request outstanding there is nothing to settle and the answer is yes; with no
    /// epoch on either side the report cannot be shown to be newer, and the request is kept.
    private func reportIsNewerThanTheRequest() async -> Bool {
        guard requestedMode != nil else { return true }
        guard let asked = requestedModeEpoch, let now = await lifecycle.state(of: key)?.epoch else { return false }
        return now > asked
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
        guard await permitted(.settingChange) else { return false }
        guard await apply(Self.modelSetting, .string(value),
                          otherwise: AnyControlRequest(SetModel(model: value))) else { return false }
        // **A correction resolves on a readback that was taken, never on one that was kept.**
        // `readSettings` leaves the last values in place when the channel does not answer, so a click
        // on the value already displayed would agree with itself — erasing the refusal `answer(to:)`
        // just raised and clearing an outstanding setting nothing re-read.
        guard await readSettings() != nil else { return false }
        let clicked = modelOptions.first { $0.value == value }?.canonical ?? value
        let shown = displayedModel?.canonical ?? appliedModel
        note(agrees: shown == clicked, setting: "model")
        await resolveCorrection(of: Self.modelSetting)
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
        guard await permitted(.settingChange) else { return false }
        let value = level.map(JSONValue.string) ?? .null
        let setting = JSONValue.object(["effortLevel": value])
        guard await apply(Self.effortSetting, value,
                          otherwise: AnyControlRequest(ApplyFlagSettings(settings: setting))) else { return false }
        // The same rule as the model's: a readback the channel did not answer resolves nothing.
        guard await readSettings() != nil else { return false }
        note(agrees: appliedEffort == level, setting: "effort")
        await resolveCorrection(of: Self.effortSetting)
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

    /// The request itself. §8.6's third step calls this directly, after the acceptance is written and
    /// the restart has been confirmed — and, like every other entry point that changes a setting, it
    /// asks the gate first. It was the one that did not: the permission menu changed the mode of a
    /// process a restart was replacing, and the relaunch then restored the mode the restart had
    /// captured, losing the change silently (review round 4, sweep#1).
    @discardableResult
    func issueMode(_ mode: PermissionMode) async -> String? {
        if let why = await refusal(of: .settingChange) {
            disagreement = why
            return why
        }
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
        // The process the request went to, so a retained handshake handed to this model later can be
        // told from the replacement's.
        requestedModeEpoch = await lifecycle.state(of: key)?.epoch
        await resolveCorrection(of: Self.modeSetting)
        return nil
    }

    /// Whether §7.4's gate is holding a restart: one still replacing a process, one whose readbacks
    /// are out, or a readback owed by one that already replaced it. Read by `BypassGate` (§8.6),
    /// which may not let a mode switch reach a process that is on its way out — the replacement
    /// restores the snapshot the restart captured, and a switch that raced it is simply lost.
    var isRestartPending: Bool {
        guard let phase = operation?.phase else { return false }
        switch phase {
        case .replacing, .confirming, .owed: return true
        case .failed, .done: return false
        }
    }

    /// §8.6's acceptance, claimed. Answers false when one is already running, which is what makes a
    /// second bypass selection wait rather than take the stored-acceptance path: the acceptance is
    /// written before the restart it needs, so a second click that read it would send the mode to a
    /// process that was never launched with the flag.
    func beginBypassAcceptance() -> Bool {
        guard !isAcceptingBypass else { return false }
        isAcceptingBypass = true
        return true
    }

    /// The acceptance finished — on every arm, including the ones that stopped early.
    func endBypassAcceptance() { isAcceptingBypass = false }

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
        await fleetHeldSetting() == name
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

    /// One restart-required change, from the entry point that began it to the readback that closed it.
    ///
    /// **The generation is the whole point.** Every transition and every continuation inside one
    /// names the generation it belongs to, so a completion that resumes after an await and finds a
    /// newer operation in its place drops itself instead of writing over the newer one's state.
    struct RestartOperation: Sendable {

        /// Where the operation is. The field is closed for the first three and for `failed`; only
        /// `done` — with nothing outstanding on this surface and none on the fleet's — can open it.
        enum Phase: Sendable, Equatable {
            /// `quiescentRestart` is out: a process is being replaced.
            case replacing
            /// The comparison is out: `list_models`, `get_settings`, the handshake the fleet retained.
            case confirming
            /// A replacement exists and has not reported; the next handshake re-runs the comparison.
            case owed
            /// The settings that did not survive, by the fleet's own `Readback.verify` names.
            case failed([String])
            /// Nothing further is owed to this operation.
            case done
        }

        let generation: RestartGeneration
        /// The values the replacement is expected to carry across (§7.4's snapshot), captured by the
        /// entry point that began the operation and never re-derived afterwards.
        let expected: RestartSnapshot
        /// What the field says while the process is being replaced.
        let reason: String
        var phase: Phase
    }

    /// Which operation a caller is talking about. Opaque and only ever minted by `beginRestart`, so a
    /// transition cannot be issued for an operation that was never opened.
    struct RestartGeneration: Hashable, Sendable { fileprivate let value: Int }

    /// **The gate, as one operation and one predicate.** `allows(_:)` is the only question any entry
    /// point asks, `releaseOrHold` is the only place `surface.isDisabled` goes back to false, and
    /// both are evaluated after the last await of whichever completion is asking.
    ///
    /// | phase | field | setting changes |
    /// | --- | --- | --- |
    /// | none / `done` | open, unless the fleet names a setting | allowed |
    /// | `replacing` | closed | refused: a process is being replaced |
    /// | `confirming` | closed | refused: the replacement's readbacks are out |
    /// | `owed` | closed | refused: the replacement has not reported |
    /// | `failed` | closed | allowed — picking a value is the recovery the banner promises |
    ///
    /// Beside the phase the predicate reads two more inputs: the setting the **fleet** still holds the
    /// channel connecting over, and the channel's own readiness. A channel left `.owned(.connecting)`
    /// keeps the field closed whatever the banners say — a restart that threw after spawning leaves
    /// exactly that, and a send into a connecting process's queued input has no readiness transition
    /// to flush it (review round 4, scalpel-1#1).
    ///
    /// Opens an operation and closes the composer with it. Called before the restart is issued, so no
    /// keystroke reaches a process that is going away, and answers the generation every transition of
    /// this operation is issued under.
    @discardableResult
    func beginRestart(reason: String, expecting expected: RestartSnapshot) -> RestartGeneration {
        generationsMinted += 1
        let generation = RestartGeneration(value: generationsMinted)
        // A newer operation supersedes an older one rather than joining it: every entry point asks
        // the predicate first, so a second one arriving here means the first was already terminal or
        // two entry points raced past the same verdict — and in both the newer process is the one the
        // field must be held for. The older operation's continuations find their generation gone.
        operation = RestartOperation(generation: generation, expected: expected, reason: reason,
                                     phase: .replacing)
        surface.isRestarting = true
        surface.isDisabled = true
        surface.disabledReason = reason
        restartBanner = nil
        corrected = []
        return generation
    }

    /// Whether `generation` still names the operation this model is running.
    ///
    /// **Asked again after every await, never once at entry.** Every await is a fresh chance for a
    /// newer restart to have replaced this one, and a completion that acted on the older reading is
    /// precisely the race that survived three fix waves.
    private func isCurrent(_ generation: RestartGeneration) -> Bool {
        operation?.generation == generation
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

    /// A restart that was recorded rather than run. This operation's process is still the one it was,
    /// so *this* operation stops holding the field — and the change is named as pending (§7.4's
    /// *applies when the current work finishes*).
    ///
    /// It does **not** follow that the field re-opens, which is why it goes through the one release
    /// like every other transition: the fleet may still be holding the channel over an unresolved
    /// setting, and the channel may not be ready.
    func noteQueuedRestart(_ generation: RestartGeneration) async {
        guard isCurrent(generation) else { return }
        operation?.phase = .done
        let pending = "This channel is busy; the setting applies when the current work finishes."
        await releaseOrHold()
        if !surface.isDisabled { restartBanner = pending }
    }

    /// A restart that never happened: this operation stops holding the field, which re-opens unless
    /// something else still holds it.
    func cancelRestart(_ generation: RestartGeneration) async {
        guard isCurrent(generation) else { return }
        operation?.phase = .done
        await releaseOrHold()
    }

    /// A restart that **threw**, judged by the channel it threw over.
    ///
    /// `quiescentRestart` spawns the replacement and then restores the flag settings and reads them
    /// back, and both of those throw: an error is therefore not a claim that nothing happened. A
    /// channel left connecting has a new process on the other end that has not reported, so the gate
    /// stays closed and the readback stays owed — re-opening it would let a send into the queued
    /// input of a process with no readiness transition to flush it. Any other state is a restart that
    /// did not replace anything, which is `cancelRestart`.
    func restartFailed(_ state: ChannelState?, _ generation: RestartGeneration) async {
        guard isCurrent(generation) else { return }
        guard case .owned(.connecting)? = state?.origin else {
            await cancelRestart(generation)
            return
        }
        hold(saying: Self.stillConnectingBanner)
    }

    /// §7.4's readback rule. Driven by the composer's own `.restart` route (`CommandRouting`) and by
    /// the header's restart-required settings.
    ///
    /// The composer stays disabled behind the connecting glyph until **every** readback matches; a
    /// mismatch raises a banner naming the setting that did not survive and keeps it disabled until
    /// the user picks a value. Answers whether every readback matched **and** the field is open.
    ///
    /// The banner names settings, never the values on either side: the engine's model id or effort
    /// level is a value read off a process, and the reader needs to know which setting to look at.
    @discardableResult
    func confirmReadback(_ generation: RestartGeneration) async -> Bool {
        guard isCurrent(generation) else { return false }
        // **The operation moves to *confirming*, and that phase holds the field on its own.** The
        // comparison below is several awaits long — `list_models`, `get_settings`, the handshake the
        // fleet retained — and for every one of them the replacement has reported nothing yet. An
        // operation that ended the moment `perform` answered would leave the gate reading *open*
        // while its readbacks were still out, and a picker click landing in that window would release
        // the field over a process nothing had verified.
        operation?.phase = .confirming
        // The process is no longer being replaced, so the connecting glyph goes even though the field
        // does not: the readbacks, not the spawn, are what is being waited on now.
        surface.isRestarting = false
        return await confirm(generation)
    }

    /// The comparison itself. Re-run from `noteHandshake` for a confirmation that was owed, which is
    /// why it takes the generation rather than opening an operation of its own.
    @discardableResult
    private func confirm(_ generation: RestartGeneration) async -> Bool {
        guard let expected = operation?.expected, isCurrent(generation) else { return false }
        // **A comparison needs values that were read, not values that were kept.** `readSettings`
        // leaves the last readback in place when the channel does not answer — right for a display,
        // and wrong here: comparing the retained values against a snapshot taken from those same
        // values agrees with itself and releases the field without the new process having reported
        // anything at all.
        let readbacksTaken = await refresh()
        // The first fence: `refresh` is two control requests, and a newer restart begun across them
        // owns the field now. This continuation's answers are about a process that is already gone.
        guard isCurrent(generation) else { return false }
        guard readbacksTaken else {
            hold(saying: "The channel did not report its settings after the restart; "
                 + "the field stays closed until it does.")
            return false
        }
        var failed: [String] = []
        if let model = expected.model {
            let wanted = modelOptions.first { $0.value == model }?.canonical ?? model
            if (displayedModel?.canonical ?? appliedModel) != wanted { failed.append(Self.modelSetting) }
        }
        if expected.effort != appliedEffort { failed.append(Self.effortSetting) }
        if let mode = expected.permissionMode {
            // **The replacement's own report, and not the one the subscription happens to have
            // delivered.** The mode has no readback but a handshake, that handshake reaches this
            // model through the composer's `events(of:)` loop, and this comparison runs the moment
            // `perform` returns — so a mode compared against `handshakeMode` is compared against
            // whichever process last got through, which on a slow delivery is the old one. X5's
            // `engineReports(of:)` answers the handshake the fleet has **retained** for the channel,
            // which after a replaced epoch is the replacement's; a fleet with none to report has not
            // resolved the mode yet, and the gate stays closed rather than releasing on a stale match.
            let running = await modeOfTheRunningProcess()
            // The second fence, and the one review round 4 found open (scalpel-1#2): this question
            // suspends, and a newer restart taken across it has already installed its own operation.
            // Clearing the owed snapshot here would clear *that* one's.
            guard isCurrent(generation) else { return false }
            guard let reported = running else {
                hold(saying: Self.unresolvedModeBanner)
                return false
            }
            handshakeMode = reported
            if reported != mode { failed.append(Self.modeSetting) }
        }
        operation?.phase = failed.isEmpty ? .done : .failed(failed)
        restartBanner = failed.isEmpty ? nil : Self.banner(for: failed)
        await releaseOrHold()
        return failed.isEmpty && !surface.isDisabled
    }

    /// The permission mode the process the fleet is running reports, from the handshake X5 retained
    /// for the channel. Nil when the fleet owns no supervisor for it or has no handshake to report.
    private func modeOfTheRunningProcess() async -> PermissionMode? {
        await lifecycle.engineReports(of: key)?.handshake?.currentPermissionMode
    }

    /// A confirmation that could not be completed: the snapshot stays owed, the field stays closed,
    /// and the next handshake re-runs the comparison against it. Without the snapshot the field would
    /// stay disabled for ever — a recovered readback has nothing left to confirm against, and
    /// `clearRestartGate` cannot act on an empty failure list.
    private func hold(saying banner: String) {
        operation?.phase = .owed
        restartBanner = banner
        surface.isRestarting = false
        surface.isDisabled = true
        surface.disabledReason = banner
    }

    static let stillConnectingBanner =
        "The channel is still connecting after the restart; the field stays closed until it reports."

    static let unresolvedModeBanner =
        "The channel has not reported its permission mode since the restart; the field stays closed "
        + "until it does."

    /// The banner, over the settings that did not survive. Names, never the values on either side: a
    /// model id or an effort level is a value read off a process, and what the reader needs is which
    /// setting to look at (§11).
    static func banner(for failed: [String]) -> String {
        "\(failed.count) setting(s) did not survive the restart: "
            + failed.map(label(of:)).joined(separator: ", ") + ". Pick a value to continue."
    }

    /// The recovery the banner promises, for one setting the user has just picked a value for.
    ///
    /// The field re-opens only when the **last** one has been answered — this surface's and the
    /// fleet's both. A picker that moved one without the other would leave the channel connecting
    /// behind an open field or the field shut behind a ready channel.
    private func resolveCorrection(of name: String) async {
        corrected.insert(name)
        if case .failed(var names)? = operation?.phase {
            names.removeAll { $0 == name }
            operation?.phase = names.isEmpty ? .done : .failed(names)
            restartBanner = names.isEmpty ? nil : Self.banner(for: names)
        }
        await releaseOrHold()
    }

    // MARK: - One predicate, one release

    /// What an entry point is asking to do.
    enum GateAction: Sendable, Equatable {
        /// A change to one of the settings this surface owns, from wherever it was asked for: a
        /// picker click, the permission menu, a routed `set_model`, `apply_flag_settings` or
        /// `set_permission_mode`, Shift+Tab's cycle, or a restart-required launch setting.
        case settingChange
        /// §8.6's bypass selection or its acceptance, which is a setting change plus the acceptance
        /// this gate may only have one of at a time.
        case bypassMode
        /// The composer's field itself. The strictest of the three: it opens only when nothing at all
        /// holds, this surface's outstanding settings and the fleet's included.
        case editing
    }

    /// What the gate answered, and — when it refused — which of its inputs is holding.
    enum GateVerdict: Sendable, Equatable {
        case allowed
        case refused(String)

        var isAllowed: Bool { self == .allowed }
        /// The sentence, for a caller that renders it. Nil when nothing was refused.
        var refusal: String? {
            guard case .refused(let why) = self else { return nil }
            return why
        }
    }

    /// **The one question every entry point asks.** Its inputs are the current operation's phase, the
    /// setting the fleet still holds this channel connecting over, and the channel's readiness; a
    /// refusal names whichever of them is holding, and no value (§11).
    ///
    /// A pure read: it changes nothing, so an entry point may ask it as often as it has awaits.
    func allows(_ action: GateAction) async -> GateVerdict {
        if action == .bypassMode, isAcceptingBypass { return .refused(Self.acceptanceInFlight) }
        switch operation?.phase {
        case .replacing:
            return .refused(Self.restartInFlight)
        case .confirming:
            return .refused(Self.readbacksOutstanding)
        case .owed:
            return .refused(Self.replacementHasNotReported)
        case .failed(let names):
            // The banner promises that picking a value continues, so a setting change is exactly what
            // is allowed here — and the field is exactly what is not.
            if action == .editing { return .refused(Self.banner(for: names)) }
        case .done, nil:
            break
        }
        let isConnecting: Bool
        if case .owned(.connecting)? = await lifecycle.state(of: key)?.origin { isConnecting = true }
        else { isConnecting = false }
        let held = await fleetHeldSetting()
        if isConnecting {
            // **A connecting channel keeps the field closed whatever the banners say.** The one way
            // out of a channel the fleet is holding over an unresolved setting is to answer it —
            // `ChannelSupervisor` stays connecting until its list empties — so a setting change is
            // still allowed for exactly that case, and nothing else is.
            guard action == .settingChange, held != nil else { return .refused(Self.stillConnecting) }
            return .allowed
        }
        if action == .editing, let held { return .refused(Self.banner(for: [held])) }
        return .allowed
    }

    /// **The predicate, asked by an entry point that is about to act.** Answers the refusal when
    /// there is one, and nil when there is not.
    ///
    /// It also brings the field into line with the verdict: a reason to refuse a setting change is a
    /// reason the field must not be editable either, and the two are the same predicate. A channel
    /// that went connecting on its own — a restart that threw after spawning, judged on the fleet's
    /// own state — has nothing else that would come back and close it.
    func refusal(of action: GateAction) async -> String? {
        guard let why = await allows(action).refusal else { return nil }
        if !surface.isDisabled { await releaseOrHold() }
        return why
    }

    /// The same question, for a click that renders the refusal as its own disagreement.
    private func permitted(_ action: GateAction) async -> Bool {
        guard let why = await refusal(of: action) else { return true }
        disagreement = why
        return false
    }

    /// **The one place the field re-opens**, and the only writer of `surface.isDisabled` outside the
    /// transitions above.
    ///
    /// The fleet's banner is settled first, because settling it is an await and the verdict has to be
    /// taken *after* it: a `beginRestart` that landed inside that question has already closed the
    /// field over a process being replaced right now, and releasing on the older reading would open
    /// the field for that restart's whole duration.
    private func releaseOrHold() async {
        _ = await settleFleetBanner()
        guard case .refused(let why) = await allows(.editing) else {
            corrected = []
            restartBanner = nil
            surface.isRestarting = false
            surface.isDisabled = false
            surface.disabledReason = nil
            return
        }
        closeField(why)
    }

    /// The field, closed over whichever input is holding. *Restarting* keeps the reason the operation
    /// was opened with — the restart is the thing being waited on, and a banner belongs to a readback.
    private func closeField(_ why: String) {
        let isReplacing = operation?.phase == .replacing
        surface.isRestarting = isReplacing
        surface.isDisabled = true
        surface.disabledReason = isReplacing ? operation?.reason : (restartBanner ?? why)
    }

    /// What a refused entry is told, by the input that is holding. Sentences about this channel and
    /// its settings, naming no value (§11).
    static let restartInFlight =
        "This channel is being restarted; nothing was changed. Try again once it has reported."
    static let readbacksOutstanding =
        "This channel has not finished reporting what the restart carried across; nothing was changed."
    static let replacementHasNotReported =
        "This channel has not reported since it was restarted; nothing was changed."
    static let stillConnecting =
        "This channel is still connecting; nothing was changed. Try again once it has reported."
    static let acceptanceInFlight =
        "The bypass permission mode is already being enabled in this channel; nothing was changed."

    /// The setting the fleet is still holding this channel connecting over, after every correction
    /// the user has already made has been re-offered to it. Nil when it holds none.
    ///
    /// **The fleet resolves its unresolved settings strictly in order** (`ChannelSupervisor` advances
    /// only when the name it is given is the head of the list). A correction made out of that order
    /// therefore applies the value and leaves the fleet's list where it was, and resolving the head
    /// afterwards advances the banner onto a setting the user has already answered — the channel stays
    /// connecting while this surface has nothing outstanding left to hold the field with. So each
    /// setting the fleet still names that has already been corrected here is answered again, with the
    /// value the **engine now reports** and never a click, until the fleet names one the user has not
    /// answered or names none at all. Bounded by the number of settings this model owns, so a fleet
    /// that does not advance ends the loop rather than driving it.
    private func settleFleetBanner() async -> String? {
        for _ in 0..<Self.settleRounds {
            guard let held = await fleetHeldSetting() else { return nil }
            guard corrected.contains(held), let value = readbackValue(of: held) else { return held }
            corrected.remove(held)
            do {
                try await lifecycle.resolveSetting(held, to: value, on: key)
            } catch {
                disagreement = Self.reason(of: error)
                return held
            }
        }
        return await fleetHeldSetting()
    }

    /// The three settings this model owns, which is how many times the fleet's banner can advance.
    private static let settleRounds = 3

    /// The setting the channel's own banner names, when it names one.
    private func fleetHeldSetting() async -> String? {
        guard case .settingDidNotSurvive(let held)? = await lifecycle.state(of: key)?.banner else { return nil }
        return held
    }

    /// What the engine now reports for one setting, in the shape `resolveSetting` takes. The readback
    /// and never the click, so re-answering the fleet cannot re-apply a value the engine refused.
    private func readbackValue(of name: String) -> JSONValue? {
        switch name {
        case Self.modelSetting:
            return (displayedModel?.value ?? appliedModel).map(JSONValue.string)
        case Self.effortSetting:
            return appliedEffort.map(JSONValue.string) ?? .null
        case Self.modeSetting:
            return (requestedMode ?? handshakeMode).map { .string($0.rawValue) }
        default:
            return nil
        }
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
        // The readback is taken as part of drawing this channel's pickers, and not from a `.task`
        // attached here: the header's slot keeps its structural identity across a channel switch, so
        // that task runs once for the first channel's model and never for the second's, which would
        // draw an empty menu against a live channel and never ask. `start()` is idempotent per model.
        model.start()
        return HStack(spacing: 8) {
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
