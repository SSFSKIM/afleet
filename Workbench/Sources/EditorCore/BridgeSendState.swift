import Foundation

/// The bridge as a value: what is queued while it is not live, what the view owes a Monaco
/// instance the moment it says `ready`, and what to do with a message that arrives from it.
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

    /// The theme the host set, held by **name** and not merely as a flag. Until the host sets
    /// one the view follows the system appearance; after it, the host owns the theme and
    /// appearance changes are left alone. The name is what a reload needs: the fresh Monaco
    /// instance starts at its own default `vs` and has never heard of the host's choice.
    private var explicitTheme: String?

    /// Which navigation this state belongs to. Bumped by every `load()`, and carried into the
    /// page so that everything the page says can be attributed to one navigation.
    private(set) var generation = 0

    /// The document is loading: whatever the previous Monaco instance knew is gone.
    mutating func loading() {
        generation += 1
        isReady = false
    }

    // MARK: - Editor to host

    /// What the view does with one message that arrived on the `afleet` handler.
    enum Arrival: Equatable {
        /// Evaluate `drained` — empty unless the message was `ready` — and then tell the host.
        case deliver(EditorEvent, drained: [EditorCommand])
        /// The message belongs to a navigation this view has left, and is dropped in silence.
        case stale
        /// The body could not be decoded. Only its `type` field is named; the rest is payload.
        case undecodable(type: String?)
    }

    /// The field every event carries, and the page's own copy of ``generation``.
    static let generationKey = "generation"

    /// One message from the page. The decision is here rather than in the view because it is
    /// the part a test can drive: a `WKWebView` is not needed to ask what a message should do.
    ///
    /// A page is not gone when `load()` returns — its scripts run until WebKit tears the
    /// document down — so a message can arrive from a document the view has already left. Such
    /// a message is about a buffer nobody is showing: a late `ready` would mark the new
    /// navigation ready and drain the queue into a page that never received it, and a late
    /// `saveRequested` would offer the host a stale buffer to write. Attribution is by the
    /// generation the view stamped into the page it loaded, and nothing else is heard.
    mutating func receive(_ body: Any, defaultTheme: String) -> Arrival {
        guard (body as? [String: Any])?[Self.generationKey] as? Int == generation else {
            return .stale
        }
        guard let event = MonacoEditorView.decodeEvent(from: body) else {
            return .undecodable(type: (body as? [String: Any])?["type"] as? String)
        }
        guard case .ready = event else { return .deliver(event, drained: []) }
        return .deliver(event, drained: ready(defaultTheme: defaultTheme))
    }

    /// A command the host sent. Returns it to be evaluated, or `nil` when it was queued.
    mutating func send(_ command: EditorCommand) -> EditorCommand? {
        if case let .setTheme(name) = command { explicitTheme = name }
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
        // A theme already in the queue is the same command this would send, so the queue is
        // left to say it once rather than the theme arriving twice.
        let queuedSetsTheme = queued.contains { if case .setTheme = $0 { true } else { false } }
        if !queuedSetsTheme { commands.append(.setTheme(name: explicitTheme ?? defaultTheme)) }
        commands.append(contentsOf: queued)
        return commands
    }

    /// The system appearance changed: the theme to send, or `nil` while the host owns the theme.
    func appearanceChanged(defaultTheme: String) -> EditorCommand? {
        explicitTheme == nil ? .setTheme(name: defaultTheme) : nil
    }
}
