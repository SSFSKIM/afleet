import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// The bypass gate, exactly §8.6 — and **the order is the whole content** (gate G5).
///
/// 1. `bypassPermissions` is offered only when `get_settings` carries no
///    `permissions.disableBypassPermissionsMode` equal to the **string** `"disable"`. That gating is
///    `SettingPickersModel`'s (Task 7) and is read here, not reimplemented: it is the engine's own
///    test (2.1.263 `cli.pretty.js:455553`) and one copy of it is one place for it to be wrong.
/// 2. First selection shows the disclaimer. **Declining** leaves the mode unavailable, restarts
///    nothing and writes nothing — no store write and no lifecycle call of any kind.
/// 3. **Accepting**, in this order with nothing between: the acceptance is written to
///    `FleetKitKeys.bypassAccepted` in the **`fleetKit`** namespace (§7.8 puts it there; afleet never
///    writes the CLI's user settings), then exactly one
///    `perform(.quiescentRestart(RestartRequest(allowBypass: true)))`, then exactly one
///    `set_permission_mode {mode: "bypassPermissions"}`.
///
///    **The order is load-bearing and not a preference.** The binary refuses the mode outright when
///    the process was not launched with the flag — `isBypassPermissionsModeAvailable` is set from
///    the launch line alone (2.1.263 `cli.pretty.js:750921-750931`) — so a mode switch issued before
///    the restart is a request that cannot succeed. The validator has three refusal arms (a
///    restricted session, the settings disable, and the missing launch flag) and this file renders
///    whichever error string comes back rather than guessing which of them fired.
/// 4. A later selection, with the acceptance already stored, sends `set_permission_mode` and
///    restarts nothing. §8.6's reason is that later owned spawns carry the flag from the start; the
///    residual case — a channel that somehow does not — is answered by the engine's own refusal
///    reaching the note above, which is exactly what item 3 says this surface does with it.
///
/// `settings.json` is never touched, by anything, on any arm: the only byte this gate puts on disk
/// is one value in afleet's own store (X9).
extension ChannelHeaderActionsModel {

    /// Whether the picker offers the mode at all — Task 7's `get_settings` gating, read.
    var offersBypassMode: Bool { pickers.modeOptions.contains(.bypassPermissions) }

    /// What the store says, read once and recorded. Nothing infers it: an acceptance is a fact about
    /// this machine and the only place it lives is the `fleetKit` namespace.
    @discardableResult
    func refreshBypassAcceptance() async -> Bool {
        guard let store else { return bypassAccepted }
        let accepted = try? await store.read(Bool.self, namespace: .fleetKit, key: FleetKitKeys.bypassAccepted)
        noteBypassAccepted((accepted ?? nil) ?? false)
        return bypassAccepted
    }

    /// The mode picker's bypass row, selected.
    ///
    /// With no acceptance in the store this only raises the disclaimer — nothing is written and
    /// nothing is performed until it is answered. With one, it is §8.6's fourth arm: the mode alone.
    func selectBypassMode() async {
        guard gate() else { return }
        guard offersBypassMode else {
            say("This account does not allow the bypass permission mode.")
            return
        }
        if await refreshBypassAcceptance() {
            await sendBypassPermissionMode()
            return
        }
        isShowingBypassDisclaimer = true
    }

    /// *Decline*. The mode stays unavailable, nothing restarts and **nothing is written** — not to
    /// afleet's store, not anywhere. The assertion this arm exists for is an empty call log.
    func declineBypassMode() {
        isShowingBypassDisclaimer = false
        say("The bypass permission mode stays unavailable in this channel.")
    }

    /// *Accept*: the three steps of §8.6, in order, with nothing between them.
    ///
    /// Each step is awaited before the next begins, which is what makes the recorded sequence an
    /// ordering and not a set. A failure at any step stops there: a restart that did not happen
    /// leaves a mode switch that could only be refused, and a store write that failed leaves an
    /// acceptance the next launch would not know about.
    func acceptBypassMode() async {
        isShowingBypassDisclaimer = false
        guard gate() else { return }

        // 1. The acceptance, in afleet's own store. Never the CLI's user settings (§7.8).
        guard let store else {
            say("afleet has no store to record the acceptance in; nothing was changed.")
            return
        }
        do {
            try await store.write(true, namespace: .fleetKit, key: FleetKitKeys.bypassAccepted)
        } catch {
            say("The acceptance could not be recorded; nothing was changed.")
            return
        }
        noteBypassAccepted(true)

        // 2. Exactly one quiescent restart, with the launch flag. §7.4's readback wait comes with it.
        guard await apply(.allowBypass, RestartRequest(allowBypass: true)) else { return }

        // 3. Exactly one `set_permission_mode`, and only now — the process it reaches is the one that
        //    was launched with the flag.
        await sendBypassPermissionMode()
    }

    /// `set_permission_mode {mode: "bypassPermissions"}`, through the picker so the click is not
    /// adopted as a displayed value: the only readback permission mode has is the handshake's
    /// `current_permission_mode`, and the next handshake either confirms it or raises the
    /// disagreement (Task 7).
    private func sendBypassPermissionMode() async {
        if let refusal = await pickers.issueMode(.bypassPermissions) {
            // Whichever of the validator's three arms fired, in the engine's own words.
            say(refusal)
        } else {
            say("The bypass permission mode was requested; the next handshake reports what the engine applied.")
        }
    }
}
