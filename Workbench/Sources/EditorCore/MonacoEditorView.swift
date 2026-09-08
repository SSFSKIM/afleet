import AppKit
import Foundation
import OSLog
import WebKit

/// How the bundle reaches the page, and above all how the five Monaco workers are constructed.
///
/// S3 (spec Design §7) tries these in order and promotes the first that starts the document, a
/// dynamic-import chunk and all five workers. It exists as one value rather than three edits so
/// the spike changes a parameter and re-runs, instead of rewriting this file at each step.
///
/// The fourth resort the spec names — `MonacoEnvironment.getWorker` returning nothing, language
/// services on the main thread — is deliberately **not** a case here. The 2026-09-08 revision
/// ruled it a stop, not a fallback: reaching it is a report to the architect, and a route this
/// enum offers is a route something could take by accident.
public enum WorkerLoadingRoute: String, Sendable, CaseIterable {

    /// Route 1, the default: document, chunks and workers all on `afleet-editor:`.
    case schemeForEverything

    /// Route 2: workers built from Blob URLs by the bootstrap; document and chunks still on the
    /// scheme. Note the hazard the split build introduced — a Blob module worker's base URL is
    /// `blob:`, so a relative chunk specifier inside it does not resolve back onto the scheme.
    case blobWorkers

    /// Route 3: `loadFileURL(_:allowingReadAccessTo:)` for everything, no custom scheme in play.
    case fileURLForEverything

    /// The name the bootstrap branches on, in `window.afleetEditorConfig.workerRoute`.
    var javaScriptName: String {
        switch self {
        case .schemeForEverything: return "scheme"
        case .blobWorkers: return "blob"
        case .fileURLForEverything: return "file"
        }
    }

    /// Whether the document itself is loaded from `file:` rather than from the custom scheme.
    var loadsDocumentFromFileURL: Bool { self == .fileURLForEverything }
}

/// An `NSView` owning a `WKWebView` that hosts Monaco, speaking contract W4's vocabulary and no
/// other (spec Design §5, §6).
///
/// The host sends `EditorCommand`s with ``send(_:)`` and receives `EditorEvent`s through
/// ``onEvent``. Nothing above this view needs to know that a `WKURLSchemeHandler`, a message
/// handler or a worker route exist: C7.5 opens a file at a line, C7.7 shows a diff, and both go
/// through the same six commands.
///
/// This view is not exercised by `swift test` — a web view in a package test buys a slow test
/// that proves WebKit works. Its verification is the S3 harness (spec Design §6, §8). What *is*
/// unit-tested is `EditorResourceLocator`, the part that can be wrong in a way a test can see.
@MainActor
public final class MonacoEditorView: NSView {

    /// The seam a host receives editor events on. C7.5 owns what to do with them; the S3 harness
    /// is the first caller.
    public typealias EventHandler = @MainActor @Sendable (EditorEvent) -> Void

    /// Called for every event the bridge posts, in arrival order, on the main actor.
    public var onEvent: EventHandler?

    /// The route this view was built for. Fixed at construction: the configuration and the
    /// injected bootstrap config are both derived from it.
    public let route: WorkerLoadingRoute

    /// The web view, exposed for the spike and for diagnostics — S3 measures navigation timing
    /// against it. Nothing in a panel should reach through here.
    public let webView: WKWebView

    private let logger = Logger(subsystem: "com.afleet.app", category: "EditorCore")
    private let resourceRoot: URL

    /// The queue-and-theme half of the send side, held apart from the view so it can be tested
    /// without a `WKWebView`.
    private var sendState = BridgeSendState()

    // MARK: - Construction

    public init(
        frame frameRect: NSRect = .zero,
        route: WorkerLoadingRoute = .schemeForEverything,
        onEvent: EventHandler? = nil
    ) {
        self.route = route
        self.onEvent = onEvent
        self.resourceRoot = EditorResources.resourceRootURL ?? Bundle.module.bundleURL

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            EditorSchemeHandler(root: resourceRoot),
            forURLScheme: EditorSchemeHandler.scheme
        )

        let controller = WKUserContentController()
        controller.addUserScript(Self.configurationScript(for: route))
        configuration.userContentController = controller

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        let relay = BridgeMessageRelay()
        relay.owner = self
        controller.add(relay, name: Self.messageHandlerName)

        #if DEBUG
        webView.isInspectable = true
        #endif

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MonacoEditorView is created in code, never from a nib")
    }

    /// The `WKScriptMessageHandler` name contract W4 fixes.
    static let messageHandlerName = "afleet"

    // MARK: - The Web Inspector

    /// Whether the Web Inspector can attach.
    ///
    /// `true` under `#if DEBUG`. In Release the app sets it from its Developer setting: this
    /// module reads no setting of its own (spec Design §6).
    public var isWebInspectorEnabled: Bool {
        get { webView.isInspectable }
        set { webView.isInspectable = newValue }
    }

    // MARK: - Loading

    /// Load the bootstrap document by the route this view was built for.
    public func load() {
        sendState.loading()

        guard route.loadsDocumentFromFileURL else {
            webView.load(URLRequest(url: EditorSchemeHandler.url(forResourcePath: Self.bootstrapDocumentPath)))
            return
        }

        guard let documentURL = EditorResources.bootstrapDocumentURL else {
            report(.error(message: "the bootstrap document is missing from Bundle.module"))
            return
        }
        webView.loadFileURL(documentURL, allowingReadAccessTo: resourceRoot)
    }

    private static let bootstrapDocumentPath = "bootstrap/index.html"

    // MARK: - Host to editor

    /// Send one command to the editor. Commands sent before `ready` are queued and delivered in
    /// order once the bridge is live.
    public func send(_ command: EditorCommand) {
        guard let ready = sendState.send(command) else { return }
        evaluate(ready)
    }

    private func evaluate(_ command: EditorCommand) {
        guard let script = Self.script(for: command) else {
            report(.error(message: "a command could not be encoded for the bridge"))
            return
        }

        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            // The message names the failure, never the command's payload: a path or a buffer in
            // a log is what §11 forbids.
            MainActor.assumeIsolated {
                self.report(.error(message: "the bridge could not be reached: \((error as NSError).code)"))
            }
        }
    }

    /// `window.afleetBridge.receive(JSON.parse("…"))` rather than a JavaScript object literal:
    /// the payload carries file contents, and `JSON.parse` of a string literal is both the
    /// faster parse and the one with no expression-level escaping hazards.
    static func script(for command: EditorCommand) -> String? {
        guard let payload = try? JSONEncoder().encode(command),
              let json = String(data: payload, encoding: .utf8),
              let literal = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]),
              let literalText = String(data: literal, encoding: .utf8)
        else { return nil }
        return "window.afleetBridge.receive(JSON.parse(\(literalText)));"
    }

    // MARK: - Editor to host

    fileprivate func receive(_ body: Any) {
        guard let event = Self.decodeEvent(from: body) else {
            // Undecodable is reported, never fatal. Only the `type` field is named — it is this
            // module's own vocabulary — and never the rest of the body.
            let named = (body as? [String: Any])?["type"] as? String
            report(.error(message: "an undecodable message arrived from the bridge: \(named ?? "no type")"))
            return
        }

        if case .ready = event {
            for command in sendState.ready(defaultTheme: Self.defaultThemeName()) {
                evaluate(command)
            }
        }

        report(event)
    }

    static func decodeEvent(from body: Any) -> EditorEvent? {
        let data: Data?
        switch body {
        case let text as String:
            data = text.data(using: .utf8)
        case let object as [String: Any]:
            data = try? JSONSerialization.data(withJSONObject: object)
        default:
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(EditorEvent.self, from: data)
    }

    private func report(_ event: EditorEvent) {
        if case let .error(message) = event {
            logger.error("editor: \(message, privacy: .public)")
        }
        onEvent?(event)
    }

    // MARK: - Theme

    /// The Monaco built-in that matches the current system appearance. `setTheme` passes a
    /// built-in through — `vs`, `vs-dark`, `hc-black`, `hc-light` — and any UI over that choice
    /// is C7.5's, not this module's.
    public static func defaultThemeName() -> String {
        let appearance = NSApplication.shared.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "vs-dark" : "vs"
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let command = sendState.appearanceChanged(defaultTheme: Self.defaultThemeName()),
              let ready = sendState.deliver(command)
        else { return }
        evaluate(ready)
    }

    // MARK: - The bootstrap's configuration

    /// Injected at document start, before `bridge.js` runs, so the bootstrap knows which route
    /// it is being asked to take. The Monaco base URL is *not* passed: the bootstrap derives it
    /// from `document.baseURI`, which is correct under every route by construction and cannot
    /// disagree with the URL the document was actually loaded from.
    private static func configurationScript(for route: WorkerLoadingRoute) -> WKUserScript {
        WKUserScript(
            source: "window.afleetEditorConfig = { workerRoute: \"\(route.javaScriptName)\" };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

/// Holds the `WKScriptMessageHandler` conformance away from the view, and holds the view weakly:
/// the user content controller retains its handlers for as long as the configuration lives, and
/// the configuration lives inside the web view the view owns.
private final class BridgeMessageRelay: NSObject, WKScriptMessageHandler {

    weak var owner: MonacoEditorView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            owner?.receive(message.body)
        }
    }
}
