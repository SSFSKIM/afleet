import AppKit
import Dispatch
import Foundation
import GhosttyTerminal
import Synchronization

private struct TerminalHandlers: Sendable {
    var onInput: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (TerminalSize) -> Void)?
}

/// The adapter is the sole owner of this box, and its `Mutex` serialises every read and write
/// made by the main-actor properties and libghostty's off-main session callbacks.
private final class TerminalHandlerBox: Sendable {
    private let handlers = Mutex(TerminalHandlers())

    var onInput: (@Sendable (Data) -> Void)? {
        get { handlers.withLock { $0.onInput } }
        set { handlers.withLock { $0.onInput = newValue } }
    }

    var onResize: (@Sendable (TerminalSize) -> Void)? {
        get { handlers.withLock { $0.onResize } }
        set { handlers.withLock { $0.onResize = newValue } }
    }

    func sendInput(_ data: Data) {
        let handler = handlers.withLock { $0.onInput }
        handler?(data)
    }

    func sendResize(_ viewport: InMemoryTerminalViewport) {
        let handler = handlers.withLock { $0.onResize }
        handler?(
            TerminalSize(
                rows: Int(viewport.rows),
                columns: Int(viewport.columns),
                pixelWidth: Int(viewport.widthPixels),
                pixelHeight: Int(viewport.heightPixels)
            )
        )
    }
}

typealias GhosttySessionFactory = (
    _ write: @escaping @Sendable (Data) -> Void,
    _ resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
    _ suppressesPixelOnlyResizes: Bool
) -> InMemoryTerminalSession

typealias GhosttySessionFinisher = @Sendable (
    _ session: InMemoryTerminalSession,
    _ exitCode: UInt32,
    _ runtimeMilliseconds: UInt64
) -> Void

/// Ghostty asks a host before it honours a protected clipboard request, and its callback
/// bridge denies every one of them when the view's delegate does not adopt
/// `TerminalSurfaceClipboardConfirmationDelegate` — including a paste the user asked for.
/// W2 has no confirmation-UI seam, so there is nobody to ask; this policy answers with the
/// dependency's own documented default (`TerminalViewState.onClipboardConfirmationRequest`):
/// a paste the user started is theirs to make, a program's OSC 52 read or write stays denied.
/// A later panel that owns confirmation UI replaces `allows(_:)`, not the wiring.
@MainActor
final class TerminalClipboardPolicy: TerminalSurfaceClipboardConfirmationDelegate {
    static func allows(_ kind: TerminalClipboardRequestKind) -> Bool {
        switch kind {
        case .paste: true
        case .osc52Read, .osc52Write: false
        }
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: Self.allows(request.kind))
    }
}

@MainActor
public final class GhosttyTerminalSurface: TerminalSurface {
    /// Pixel-only resize suppression stays off because `TerminalSize` carries pixels; otherwise
    /// a sub-cell change can leave the PTY's `TIOCSWINSZ` pixel metrics stale indefinitely.
    private static let suppressesPixelOnlyResizes = false

    /// Resize delivery stays unthrottled so a full-screen TUI receives each size. Revisit this
    /// only if the S1 harness shows that a live window drag outruns the TUI.
    private static let resizeThrottleMilliseconds: Double = 0

    private let handlers: TerminalHandlerBox
    let session: InMemoryTerminalSession
    /// Owned by this adapter alone; see the initializer for why it is not the shared one.
    let terminalController: TerminalController
    private let terminalView: AppTerminalView
    /// `AppTerminalView.delegate` is weak, so the adapter owns the policy's lifetime.
    let clipboardPolicy: TerminalClipboardPolicy
    private let finishSession: GhosttySessionFinisher
    private let runtimeMilliseconds: @Sendable () -> UInt64

    public let terminalDescription: TerminalDescription

    public var view: NSView { terminalView }

    public var onInput: (@Sendable (Data) -> Void)? {
        get { handlers.onInput }
        set { handlers.onInput = newValue }
    }

    public var onResize: (@Sendable (TerminalSize) -> Void)? {
        get { handlers.onResize }
        set { handlers.onResize = newValue }
    }

    public convenience init() {
        self.init(
            terminfoDirectory: GhosttyRuntimeResources.terminfoDirectoryURL,
            runtimeMilliseconds: Self.elapsedRuntimeMeasurement()
        )
    }

    init(
        terminfoDirectory: URL?,
        sessionFactory: GhosttySessionFactory = { write, resize, suppressesPixelOnlyResizes in
            InMemoryTerminalSession(
                write: write,
                resize: resize,
                suppressesPixelOnlyResizes: suppressesPixelOnlyResizes
            )
        },
        finishSession: @escaping GhosttySessionFinisher = { session, exitCode, runtimeMilliseconds in
            session.finish(exitCode: exitCode, runtimeMilliseconds: runtimeMilliseconds)
        },
        runtimeMilliseconds: @escaping @Sendable () -> UInt64 = GhosttyTerminalSurface.elapsedRuntimeMeasurement()
    ) {
        let handlers = TerminalHandlerBox()
        let session = sessionFactory(
            { handlers.sendInput($0) },
            { handlers.sendResize($0) },
            Self.suppressesPixelOnlyResizes
        )
        // One controller per surface, never `TerminalController.shared`: the controller owns
        // the resolved configuration, so a shared one makes `setAppearance` a process-wide
        // change every other surface inherits, new ones included.
        let terminalController = TerminalController()
        let terminalView = AppTerminalView(frame: .zero)
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            resizeThrottleMilliseconds: Self.resizeThrottleMilliseconds
        )
        // AppTerminalView's coordinator cannot construct a surface without a controller.
        terminalView.controller = terminalController
        let clipboardPolicy = TerminalClipboardPolicy()
        terminalView.delegate = clipboardPolicy

        self.handlers = handlers
        self.session = session
        self.terminalController = terminalController
        self.terminalView = terminalView
        self.clipboardPolicy = clipboardPolicy
        self.finishSession = finishSession
        self.runtimeMilliseconds = runtimeMilliseconds
        terminalDescription = Self.describeTerminal(terminfoDirectory: terminfoDirectory)
    }

    public func feed(_ output: Data) {
        session.receive(output)
    }

    public func processDidExit(code: Int32) {
        finishSession(session, UInt32(bitPattern: code), runtimeMilliseconds())
    }

    /// The rendered viewport, read back through the in-memory backend's own host-side read after
    /// every pending `receive` has been parsed. `nil` until a view has attached a surface, which
    /// is why it answers nothing in a headless test and everything in the S1 harness. Diagnostic
    /// only: it exists so "it rendered" can be an assertion rather than a recollection, and no
    /// pane path calls it.
    public func renderedViewportText() -> String? {
        session.waitForPendingOutput()
        return session.readViewportText()
    }

    public func setAppearance(_ appearance: TerminalAppearance) {
        let ghosttyAppearance = GhosttyAppearance(appearance)
        terminalController.setTheme(ghosttyAppearance.theme)
        terminalController.setTerminalConfiguration(ghosttyAppearance.configuration)
    }

    private static func describeTerminal(terminfoDirectory: URL?) -> TerminalDescription {
        guard let terminfoDirectory else {
            return TerminalDescription(term: "xterm-256color")
        }
        return TerminalDescription(
            term: "xterm-ghostty",
            terminfoDirectory: terminfoDirectory
        )
    }

    private static func elapsedRuntimeMeasurement() -> @Sendable () -> UInt64 {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        return {
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            guard finishedAt >= startedAt else { return 0 }
            return (finishedAt - startedAt) / 1_000_000
        }
    }
}
