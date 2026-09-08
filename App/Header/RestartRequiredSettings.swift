import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// A launch setting this header can change, named exactly as `LaunchSettingMatrix` names it
/// (§7.7's *Launch settings: mutable at runtime versus restart-required*).
///
/// **The matrix is the data that decides**, and the whole point of naming a setting by its matrix
/// key is that the header does not carry a list of its own: `takesARestart` is a lookup, so a
/// setting C4 moves between the two classes moves here with it and no line in this leaf changes.
enum HeaderLaunchSetting: String, CaseIterable, Hashable, Sendable {
    case promptSuggestions
    case allowBypass

    /// The matrix's key for this setting. The raw value, spelled once.
    var matrixKey: String { rawValue }

    /// Whether §7.7's matrix puts this setting in the restart-required class. Read, never asserted:
    /// a setting in neither set is a setting C4 does not know about, and the header refuses it
    /// rather than guessing which path it takes.
    var takesARestart: Bool { LaunchSettingMatrix.restartRequired.contains(matrixKey) }
    var isRuntimeMutable: Bool { LaunchSettingMatrix.runtimeMutable.contains(matrixKey) }

    /// What the field says while the process is being replaced for this setting. A setting's name,
    /// never a value (§11).
    var restartReason: String {
        switch self {
        case .promptSuggestions: "This channel is restarting to change prompt suggestions."
        case .allowBypass: "This channel is restarting to allow the bypass permission mode."
        }
    }
}

/// §7.4's quiescent-restart path, for every restart-required setting the header changes.
///
/// **One path, not one per setting.** A `RestartRequest`, then §7.4's readback wait with the
/// composer disabled behind the connecting glyph, then either release or a banner naming the setting
/// that did not survive. The gate itself is Task 7's, on `SettingPickersModel` over the
/// `ChannelSurfaceState` the header shares with the field; this file decides *when* it runs and
/// carries nothing of its own about how it works.
extension ChannelHeaderActionsModel {

    /// Applies one restart-required setting. Answers whether the change took **and** survived.
    ///
    /// A setting the matrix does not call restart-required never reaches `quiescentRestart` from
    /// here: it has a runtime mechanism (§7.7's table) and the pickers or the router own it. That
    /// refusal is spelled rather than assumed, because a restart issued for a setting that did not
    /// need one replaces a process — and kills its shells — for nothing.
    @discardableResult
    func apply(_ setting: HeaderLaunchSetting, _ request: RestartRequest) async -> Bool {
        guard gate() else { return false }
        guard setting.takesARestart else {
            say("That setting changes without a restart; the header does not replace the process for it.")
            return false
        }
        // The gate, asked here as every other entry point asks it. A restart-required change replaces
        // a process, and one may not begin over another, over a readback that is still out, or on a
        // channel that is still connecting.
        if let refusal = await pickers.refusal(of: .settingChange) {
            say(refusal)
            return false
        }
        // The process this channel is running *now*: the epoch is what separates a restart that ran
        // from one that was only recorded.
        let before = await lifecycle.state(of: key)
        let operation = pickers.beginRestart(reason: setting.restartReason,
                                             expecting: pickers.currentSnapshot)
        let after: ChannelState
        do {
            after = try await lifecycle.perform(.quiescentRestart(request), on: key)
        } catch {
            // **An error is not a claim that nothing happened.** `quiescentRestart` spawns the
            // replacement and only then restores the flag settings and reads them back, and both of
            // those throw: a channel left connecting has a new process on the other end. The gate is
            // kept for that one and re-opened for every other, where nothing was replaced.
            await pickers.restartFailed(await lifecycle.state(of: key), operation)
            say(Self.refusal(error))
            return false
        }
        countRestart()
        // **The restart has to have happened before anything is confirmed.** A busy channel keeps the
        // request for the dormant timer and answers success straight away, and so does a change that
        // merged into a restart already in flight: confirming there releases the field against the
        // old process, and §8.6's mode switch would follow it onto a process that was never launched
        // with the flag it needs.
        guard SettingPickersModel.replacedTheProcess(after, from: before) else {
            await pickers.noteQueuedRestart(operation)
            say(pickers.restartBanner)
            return false
        }
        // §7.4: the composer stays disabled until **every** readback matches; a mismatch banners,
        // names the setting that did not survive, and keeps it disabled until the user picks a value.
        let survived = await pickers.confirmReadback(operation)
        if !survived { say(pickers.restartBanner) }
        return survived
    }

    /// The per-channel *Prompt suggestions* toggle (§7.7's matrix: `--prompt-suggestions` is a launch
    /// flag, so it is a restart and not a control request).
    ///
    /// The composer's own flag moves only once the restart has been confirmed: a channel whose
    /// process was never replaced receives no `prompt_suggestion` frame, so a toggle that moved first
    /// would leave ghost text switched on against a process that can never produce any.
    func setPromptSuggestions(_ enabled: Bool) async {
        guard await apply(.promptSuggestions, RestartRequest(promptSuggestions: enabled)) else { return }
        composer.promptSuggestionsEnabled = enabled
        say("Prompt suggestions \(enabled ? "on" : "off") for this channel.")
    }
}
