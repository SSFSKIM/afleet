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

    /// Whether the panel can need this key for itself (spec §8.5, tracker 350).
    ///
    /// Escape and Shift+Tab are ordinary keys: a full-screen TUI in a Terminal pane reads Escape,
    /// an editor reads Shift+Tab, and the pane's renderer declines every ordinary key it has not
    /// bound in `performKeyEquivalent` — correctly, because a command table is consulted *before*
    /// the first responder is. A binding that exists therefore wins, so these two have to be absent
    /// while the keyboard is in the panel rather than declined after the fact.
    ///
    /// **Cmd+Shift+Esc is not in this set, and that is a decision rather than an oversight.** It is
    /// a Command chord, which no terminal child receives and which the renderer never competes for,
    /// and it is the panic stop: the user whose pane has run away is the one most likely to press
    /// it, and it would be missing exactly then. `send` is not in it either — Return is answered
    /// inside the field's own `keyDown`, which fires only while the field holds the keyboard.
    var standsDownForPanelKeyboard: Bool {
        switch self {
        case .interrupt, .cyclePermissionMode: true
        case .send, .stopEverything: false
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
///
/// **And that is also why the bar has to stand down.** A command table is consulted before the key
/// event reaches the first responder, so while a Terminal pane held the keyboard this bar's Escape
/// interrupted the turn instead of reaching the child and its Shift+Tab cycled the permission mode
/// instead of completing — the pane read as broken (tracker 350). The bar stays mounted, because
/// the actions and the confirmation below are the channel's whichever window is key; what moves is
/// which of the three carry a key equivalent, and `PanelKeyboardFocus` is the one fact that says so.
struct ComposerShortcutBar: View {

    @Bindable var model: ComposerModel

    /// Where the keyboard is, published by `AfleetApp` above the window.
    ///
    /// Optional, and that is load-bearing: `ComposerMountTests` walks this body by reflection with
    /// no environment installed, and a non-optional read would trap there. Nothing published means
    /// no panel is drawing, which is the same answer as a keyboard that is not in one.
    @Environment(PanelKeyboardFocus.self) private var keyboard: PanelKeyboardFocus?

    var body: some View {
        let offered = Self.offered(keyboardIsInPanel: keyboard?.keyboardIsInPanel ?? false)
        ZStack {
            Button(ComposerShortcut.interrupt.title) { Task { await model.interrupt() } }
                .keyboardShortcut(Self.binding(.interrupt, offered: offered))
            Button(ComposerShortcut.cyclePermissionMode.title) { Task { await model.cyclePermissionMode() } }
                .keyboardShortcut(Self.binding(.cyclePermissionMode, offered: offered))
            Button(ComposerShortcut.stopEverything.title) { model.requestStopEverything() }
                .keyboardShortcut(Self.binding(.stopEverything, offered: offered))
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

    /// The three keys this bar can carry, in the order it draws them.
    static let barShortcuts: [ComposerShortcut] = [.interrupt, .cyclePermissionMode, .stopEverything]

    /// Which of the three this bar is offering, given where the keyboard is.
    ///
    /// **A function, and the whole of the decision.** The bindings themselves live inside a `body`,
    /// which no test in this tree can press; this is the same answer, asked without a window, and it
    /// is what the panel-focus tests assert. The body below has no second opinion.
    static func offered(keyboardIsInPanel: Bool) -> [ComposerShortcut] {
        guard keyboardIsInPanel else { return barShortcuts }
        return barShortcuts.filter { !$0.standsDownForPanelKeyboard }
    }

    /// The key equivalent one button carries, or nil while it is standing down. SwiftUI's
    /// `keyboardShortcut(_:)` takes an optional for exactly this: a nil is a button with no binding
    /// in the command table at all, which is what has to be true of Escape while a pane holds the
    /// keyboard — a binding that merely refused would still have consumed the key.
    static func binding(_ shortcut: ComposerShortcut, offered: [ComposerShortcut]) -> KeyboardShortcut? {
        guard offered.contains(shortcut) else { return nil }
        return KeyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
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
