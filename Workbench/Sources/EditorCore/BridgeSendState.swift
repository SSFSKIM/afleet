import Foundation

/// The host-to-editor side of ``MonacoEditorView``, as a value: what is queued while the bridge
/// is not live, and what the view owes a Monaco instance the moment it says `ready`.
///
/// It lives apart from the view because it is the part that can be wrong in a way a test can
/// see — the same reason `EditorResourceLocator` does (spec Design §6). A `WKWebView` is not
/// needed to ask what a reload should send, and a test that needed one would be a test of
/// WebKit.
struct BridgeSendState {

    /// Whether the bridge has reported `ready` since the last load.
    private(set) var isReady = false

    /// Commands that arrived before `ready`. Opening a file immediately after `load()` is the
    /// normal case, not an edge one, so they queue rather than erroring.
    private var pending: [EditorCommand] = []

    /// Set once the host sends its own `setTheme`. Until then the view follows the system
    /// appearance; after it, the host owns the theme and appearance changes are left alone.
    private var hasExplicitTheme = false

    /// The document is loading: whatever the previous Monaco instance knew is gone.
    mutating func loading() {
        isReady = false
    }

    /// A command the host sent. Returns it to be evaluated, or `nil` when it was queued.
    mutating func send(_ command: EditorCommand) -> EditorCommand? {
        if case .setTheme = command { hasExplicitTheme = true }
        return deliver(command)
    }

    /// A command the view originated itself — the appearance-driven theme — which does not hand
    /// the theme over to the host.
    mutating func deliver(_ command: EditorCommand) -> EditorCommand? {
        guard isReady else {
            pending.append(command)
            return nil
        }
        return command
    }

    /// `ready` arrived: the commands to evaluate, in order.
    mutating func ready(defaultTheme: String) -> [EditorCommand] {
        isReady = true
        let queued = pending
        pending.removeAll()
        var commands: [EditorCommand] = []
        if !hasExplicitTheme { commands.append(.setTheme(name: defaultTheme)) }
        commands.append(contentsOf: queued)
        return commands
    }

    /// The system appearance changed: the theme to send, or `nil` while the host owns the theme.
    func appearanceChanged(defaultTheme: String) -> EditorCommand? {
        hasExplicitTheme ? nil : .setTheme(name: defaultTheme)
    }
}
