import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The four keys this leaf declares, and no others (spec §8.5 *The field*, §8.7).
///
/// C5's `AfleetApp` declares five — Cmd+K, Cmd+Shift+A and Cmd+1…7 — and leaves Esc, Cmd+Enter,
/// Shift+Tab and Cmd+Shift+Esc undeclared for the composer, in a comment naming them. They are a
/// value here rather than four literals scattered over three views so the disjointness from C5's set
/// is something a test can read rather than something a reviewer has to notice.
///
/// `send` is the odd one: it is answered inside `ComposerField.keyDown` rather than by a
/// `.keyboardShortcut`, because Return has to mean three things depending on its modifiers and a
/// command-table binding cannot see the two that are not sends. It is listed here anyway — the
/// collision question is about the key, not about who answers it.
enum ComposerShortcut: String, CaseIterable, Sendable {
    case send
    case interrupt
    case cyclePermissionMode
    case stopEverything

    var key: KeyEquivalent {
        switch self {
        case .send: .return
        case .interrupt, .stopEverything: .escape
        case .cyclePermissionMode: .tab
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .send: .command
        case .interrupt: []
        case .cyclePermissionMode: .shift
        case .stopEverything: [.command, .shift]
        }
    }

    /// The label the action carries wherever it is offered.
    var title: String {
        switch self {
        case .send: "Send"
        case .interrupt: "Interrupt"
        case .cyclePermissionMode: "Next Permission Mode"
        case .stopEverything: "Stop Everything…"
        }
    }
}

/// The three composer keys that are not the field's Return.
///
/// Buttons with `.keyboardShortcut` rather than an `onKeyPress`, because that is what puts a binding
/// in the same command table C5's five live in — a key that collided would collide for real, and the
/// disjointness test above is then about something that exists rather than about a convention.
struct ComposerShortcutBar: View {

    @Bindable var model: ComposerModel

    var body: some View {
        ZStack {
            Button(ComposerShortcut.interrupt.title) { Task { await model.interrupt() } }
                .keyboardShortcut(ComposerShortcut.interrupt.key, modifiers: ComposerShortcut.interrupt.modifiers)
            Button(ComposerShortcut.cyclePermissionMode.title) { Task { await model.cyclePermissionMode() } }
                .keyboardShortcut(ComposerShortcut.cyclePermissionMode.key,
                                  modifiers: ComposerShortcut.cyclePermissionMode.modifiers)
            Button(ComposerShortcut.stopEverything.title) { model.requestStopEverything() }
                .keyboardShortcut(ComposerShortcut.stopEverything.key,
                                  modifiers: ComposerShortcut.stopEverything.modifiers)
        }
        // Off screen, not out of the responder chain: `.hidden()` would take the bindings with it.
        // Task 8 gives all three a visible home in the header's menu and this bar keeps the keys.
        .frame(width: 0, height: 0)
        .opacity(0)
        // One dialog for all three confirmed actions (`ComposerConfirmation`), whether the chord or a
        // routed row raised it: two dialogs would let one of them be answered while the other stayed
        // up over the same channel.
        .confirmationDialog(model.pendingConfirmation?.title ?? "",
                            isPresented: Binding(get: { model.pendingConfirmation != nil },
                                                 set: { if !$0 { model.cancelPending() } })) {
            if let pending = model.pendingConfirmation {
                // **Claimed here, synchronously, and run in the `Task`.** SwiftUI sets the presentation binding
                // false — which is `cancelPending()` — as the affirmative fires, so an action that read
                // `pendingConfirmation` when its task began read a value the dismissal had already cleared and did
                // nothing. The claim takes the answer whole before that can happen.
                Button(pending.confirmTitle, role: .destructive) { model.answerPending() }
            }
            Button("Cancel", role: .cancel) { model.cancelPending() }
        } message: {
            // The header's *Send to background* names the live background tasks whose shells the
            // handoff closes; every other confirm has nothing to add to its own sentence.
            Text(model.confirmationDetail ?? model.pendingConfirmation?.message ?? "")
        }
    }
}

extension ComposerModel {

    /// The modes Shift+Tab cycles through.
    ///
    /// `PermissionMode.allCases` minus `bypassPermissions`: §8.6 puts that one behind a disclaimer
    /// and a quiescent restart, and a key that could land on it by being pressed once too often
    /// would walk straight past the gate. Task 8 owns whether the picker offers it at all — the
    /// `permissions.disableBypassPermissionsMode` readback decides that — and this list follows
    /// whatever it decides rather than carrying a second opinion.
    static var cyclablePermissionModes: [PermissionMode] {
        PermissionMode.allCases.filter { $0 != .bypassPermissions }
    }

    /// Esc: stop the running turn.
    ///
    /// Routed as the composer routes a typed `/stop`, so the mapping from that command to an
    /// `interrupt` request stays C4's table's (contract X10). Building an `Interrupt` here would be
    /// this leaf's second opinion about a row the table already owns.
    func interrupt() async {
        await dispatch(routing: "/stop")
    }

    /// Shift+Tab: the next permission mode.
    ///
    /// Also through `route`, as `/permissions <mode>`, for the same reason: the row that turns that
    /// line into `set_permission_mode` — and that refuses a mode the engine does not know — is C4's.
    ///
    /// **The cycle starts from the mode the channel is actually in, which is the pickers' value and not a cursor of
    /// this leaf's own.** Task 7's `SettingPickersModel` holds the handshake's `permissionMode` readback and the
    /// mode a click or a routed line last requested; a second store here started every channel at `.default`, so the
    /// first Shift+Tab on a channel launched in `acceptEdits` — or on one whose mode the header just changed —
    /// asked the engine for the mode it was already in, and the user pressed the key and saw nothing happen.
    ///
    /// §7.4's readback rule is why the *displayed* value is the pickers': there is one place a mode comes from and
    /// this reads it rather than keeping a second opinion. Nothing is written back here either — the routed
    /// `/permissions <mode>` reaches `SettingPickersModel.apply(routed:)`, which is what records the request.
    func cyclePermissionMode() async {
        let modes = Self.cyclablePermissionModes
        // A channel whose engine has not reported a mode yet is in the engine's own default, which is what the
        // launch line asked for; and a channel sitting in `bypassPermissions` is not in the cycle at all, so it
        // wraps to the first mode rather than staying where a gate put it.
        let current = pickers.currentSnapshot.permissionMode ?? .default
        let index = modes.firstIndex(of: current) ?? modes.count - 1
        let next = modes[(index + 1) % modes.count]
        await dispatch(routing: "/permissions \(next.rawValue)")
    }

    /// Cmd+Shift+Esc, first half: raise the confirm. Nothing reaches the lifecycle here.
    ///
    /// The chord goes through the same `pendingConfirmation` gate a routed `.lifecycle` action does
    /// (`CommandRouting`), so *Stop everything* is one gate whether it was typed or pressed — and the
    /// second half is `confirmPending()`, shared with it. Task 2's three stop-everything-specific
    /// members are gone with the generalisation: two gates over one channel could be answered apart.
    func requestStopEverything() { pendingConfirmation = .stopEverything }
}
