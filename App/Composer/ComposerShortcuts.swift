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
        .confirmationDialog("Stop everything in this channel?",
                            isPresented: $model.isConfirmingStopEverything) {
            Button("Stop Everything", role: .destructive) { Task { await model.confirmStopEverything() } }
            Button("Cancel", role: .cancel) { model.cancelStopEverything() }
        } message: {
            Text("The running turn and every background task in this channel stop. Their shells close.")
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
    /// The cursor advances only when the request was accepted. It is a local cursor and **not** a
    /// displayed value: §7.4's readback rule says what the picker shows comes from the engine, and
    /// Task 7 replaces this with the handshake's `permissionMode` readback.
    func cyclePermissionMode() async {
        let modes = Self.cyclablePermissionModes
        let index = modes.firstIndex(of: permissionMode) ?? modes.count - 1
        let next = modes[(index + 1) % modes.count]
        if await dispatch(routing: "/permissions \(next.rawValue)") { permissionMode = next }
    }

    /// Cmd+Shift+Esc, first half: raise the confirm. Nothing reaches the lifecycle here.
    func requestStopEverything() { isConfirmingStopEverything = true }

    func cancelStopEverything() { isConfirmingStopEverything = false }

    /// Cmd+Shift+Esc, second half. The only place `.stopEverything` is issued, and it is reachable
    /// only from the accepted confirm: the action kills every background task's shell in the channel
    /// (§7.4), which is not something a mistyped chord may do.
    func confirmStopEverything() async {
        isConfirmingStopEverything = false
        do {
            _ = try await lifecycle.perform(.stopEverything, on: key)
        } catch let error as LifecycleError {
            refusal = Self.explanation(of: error)
        } catch {
            refusal = "Stop everything did not run."
        }
    }

    /// Routes one line and dispatches the case it came back as.
    ///
    /// **Task 3 generalises this** into the dispatcher G1 enumerates over all seven `Routed` cases.
    /// The two keys above need exactly one of them, and a speculative switch written before the gate
    /// that constrains it would be a mapping nothing tests. Anything else coming back is reported
    /// rather than guessed at.
    @discardableResult
    private func dispatch(routing line: String) async -> Bool {
        let routed = await lifecycle.route(line, on: key)
        guard case .controlRequest(let request) = routed else {
            refusal = "afleet did not run that here; it is not a request this channel answers."
            return false
        }
        do {
            _ = try await lifecycle.send(request, on: key)
            return true
        } catch let error as LifecycleError {
            refusal = Self.explanation(of: error)
            return false
        } catch {
            refusal = "The channel did not answer."
            return false
        }
    }
}
