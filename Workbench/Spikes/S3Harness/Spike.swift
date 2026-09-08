import AppKit
@preconcurrency import EditorCore
import Foundation
import WebKit

/// One run of S3 against one ``WorkerLoadingRoute``.
///
/// The route is a constructor argument to `MonacoEditorView` and nothing else changes between
/// runs, which is the whole point of the enum existing: the spike advances by re-running, not by
/// editing the view.
@MainActor
final class Spike: NSObject, WKNavigationDelegate {

    let route: WorkerLoadingRoute
    private let processStart: Date
    private let options: Options

    private var view: MonacoEditorView!
    private var window: HarnessWindow!

    private var navigationStart: Date?
    private var readyAt: Date?
    private var editorErrors: [String] = []
    private var navigationFailure: String?

    /// Written as the run goes, emitted as one JSON object at the end.
    private var report: [String: Any] = [:]

    struct Options {
        var holdOpen = false
        var sourceBytes = 5 * 1024 * 1024
        var diffLines = 2000
        var scrollFrames = 180
        var readyTimeout: TimeInterval = 30
    }

    init(route: WorkerLoadingRoute, processStart: Date, options: Options) {
        self.route = route
        self.processStart = processStart
        self.options = options
    }

    // MARK: - The window

    /// Opened before anything is measured, and opened *visible*: `requestAnimationFrame` in an
    /// occluded window is throttled by the system, so a frame-time histogram taken behind
    /// another window would be a measurement of AppKit's power management and not of Monaco.
    func openWindow() {
        view = MonacoEditorView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), route: route)
        view.onEvent = { [weak self] event in self?.record(event) }
        view.webView.navigationDelegate = self

        window = HarnessWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1280, height: 860),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "afleet S3 — \(route.rawValue)"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
    }

    /// Puts the window on screen and keeps it there. Called after `NSApplication` has finished
    /// launching, which is the first moment ordering has an effect that survives.
    func bringWindowForward() {
        // `.screenSaver`, not `.floating`. An executable with no app bundle cannot reliably
        // activate itself — `NSApp.activate` returns with the app still inactive — so the window
        // has to win by level rather than by focus, and a full-screen app in front of it beats
        // `.floating`. This is a harness, not a panel: nothing here is a claim about how the app
        // should behave.
        window.level = .screenSaver
        // Joining every Space is what makes this work when the shell that launched the harness
        // is a full-screen app: a full-screen app owns its own Space, and a floating window that
        // cannot follow it there is occluded no matter how high its level.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Trace.log("window: visible=\(window.isVisible) key=\(window.isKeyWindow)"
                  + " onActiveSpace=\(window.isOnActiveSpace) appActive=\(NSApp.isActive)"
                  + " screens=\(NSScreen.screens.count) frame=\(window.frame)"
                  + " occluded=\(!window.occlusionState.contains(.visible))")
    }

    private func record(_ event: EditorEvent) {
        switch event {
        case .ready:
            if readyAt == nil { readyAt = Date() }
        case let .error(message):
            editorErrors.append(message)
            Trace.log("editor error: \(message)")
        default:
            break
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The document exists and none of its scripts have run: the one moment an error capture
        // can be installed from outside without a user script.
        MainActor.assumeIsolated {
            view.webView.evaluateJavaScript(ProbeScripts.bootErrorCapture, completionHandler: nil)
            Trace.log("navigation committed")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { navigationFailure = "didFail: \(error.localizedDescription)" }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { navigationFailure = "didFailProvisionalNavigation: \(error.localizedDescription)" }
    }

    // MARK: - The run

    /// Returns the exit status: 0 when this route carries every load path, 2 when it does not.
    func run() async -> Int32 {
        report["route"] = route.rawValue
        report["monacoBundle"] = bundleFacts()

        navigationStart = Date()
        Trace.log("navigating")
        view.load()

        let ready = await waitForReady()
        Trace.log("ready=\(ready)")
        report["coldLoad"] = coldLoadReport(ready: ready)

        guard ready else {
            report["outcome"] = "the document never reported ready"
            report["documentLoaded"] = false
            report["navigationFailure"] = navigationFailure ?? "none: the navigation itself did not fail"
            report["editorErrors"] = editorErrors
            report["postMortem"] = (try? await call(ProbeScripts.postMortem))
                ?? ["error": "the post-mortem probe could not run in the page"]
            report["verdict"] = verdict(document: false, chunk: false, workers: false)
            return 2
        }

        report["documentLoaded"] = true
        Trace.log("installing hooks")
        _ = try? await call(ProbeScripts.installHooks)
        report["environment"] = (try? await call(ProbeScripts.environmentProbe)) ?? ["error": "environment probe threw"]

        // Every timing below this line is counted in animation frames, so whether the window is
        // getting any is checked first and reported as a fact of the run rather than assumed.
        let frames = (try? await call(ProbeScripts.frameLivenessProbe, ["windowMs": 1000])) as? [String: Any] ?? [:]
        report["frameLiveness"] = frames
        var frameReport = frames
        frameReport["windowOccluded"] = !window.occlusionState.contains(.visible)
        frameReport["occlusionOverridden"] = false
        var framesSeen = frames["frames"] as? Int ?? 0
        Trace.log("frame liveness: \(framesSeen) frames, occluded=\(frameReport["windowOccluded"] ?? "?")")

        if framesSeen == 0 {
            // A window nothing can see is given no frames, and on this machine the thing in
            // front of it was the lock screen. Overriding the window's reported occlusion makes
            // WebKit resume driving the compositor, which is enough for the render and scroll
            // numbers to mean something — they measure the work, at the display's own rate. It
            // is not enough for the acceptance clause's other half: "no visible jank" is a
            // human's word about pixels a human saw, and no override can supply that. So the
            // override is recorded in the report, and the human witness stays outstanding.
            window.forcesVisible = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let retried = (try? await call(ProbeScripts.frameLivenessProbe, ["windowMs": 1000])) as? [String: Any] ?? [:]
            framesSeen = retried["frames"] as? Int ?? 0
            frameReport = retried
            frameReport["windowOccluded"] = !window.occlusionState.contains(.visible)
            frameReport["occlusionOverridden"] = true
            Trace.log("frame liveness after the occlusion override: \(framesSeen) frames")
        }
        frameReport["framesAvailable"] = framesSeen > 0
        report["frameLiveness"] = frameReport
        let framesAvailable = framesSeen > 0

        // The chunk path, before anything large is in the buffer: Swift's Monarch grammar is a
        // lazy chunk, and Swift is a language whose services are *not* eager, which is what the
        // brief asks the probe to use.
        Trace.log("chunk probe")
        let chunk = (try? await call(ProbeScripts.chunkProbe, [
            "language": "swift", "fileExtension": "swift", "sample": Self.chunkSample, "timeoutMs": 8000,
        ])) ?? ["loaded": false, "error": "chunk probe threw"]
        report["chunk"] = chunk

        Trace.log("5 MB file")
        report["fiveMegabyteFile"] = await measureLargeFile()
        Trace.log("scroll histogram")
        report["scroll"] = framesAvailable
            ? ((try? await call(ProbeScripts.scrollHistogram, [
                "frameCount": options.scrollFrames, "stepPixels": 420, "budgetMs": 20000,
              ])) ?? ["error": "scroll probe threw"])
            : ["skipped": "the window is given no animation frames"]

        Trace.log("diff")
        report["diff"] = await measureDiff()

        Trace.log("workers")
        report["workers"] = await measureWorkers()
        Trace.log("done")
        report["editorErrors"] = editorErrors

        let chunkLoaded = (chunk as? [String: Any])?["loaded"] as? Bool ?? false
        let workersStarted = (report["workers"] as? [String: Any])?["allFiveStarted"] as? Bool ?? false
        var outcome = verdict(document: true, chunk: chunkLoaded, workers: workersStarted)
        let withinBudget = (report["coldLoad"] as? [String: Any])?["withinBudget"] as? Bool ?? false
        outcome["coldLoadWithinBudget"] = withinBudget
        report["verdict"] = outcome
        report["humanWitnessOutstanding"] = true
        report["renderTimingsTrustworthy"] = framesAvailable

        // Three statuses, because the two failures mean different things and a script that sees
        // only "not zero" would advance the route search over a cold load that is too slow — a
        // number no other route changes.
        guard chunkLoaded, workersStarted else { return 2 }
        return withinBudget ? 0 : 5
    }

    private static let chunkSample = """
    struct Probe { let value: Int
      func run(_ n: Int) -> Int { return n &* 3 }
    }
    """

    private func waitForReady() async -> Bool {
        let deadline = Date().addingTimeInterval(options.readyTimeout)
        while readyAt == nil, navigationFailure == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return readyAt != nil
    }

    private func coldLoadReport(ready: Bool) -> [String: Any] {
        guard ready, let readyAt, let navigationStart else {
            return ["reachedReady": false]
        }
        let fromProcess = readyAt.timeIntervalSince(processStart) * 1000
        let fromNavigation = readyAt.timeIntervalSince(navigationStart) * 1000
        return [
            "reachedReady": true,
            // The gate. It is the stricter of the two and the one the composite names.
            "processStartToReadyMs": fromProcess,
            "navigationStartToReadyMs": fromNavigation,
            "budgetMs": 1000,
            "withinBudget": fromProcess < 1000,
        ]
    }

    // MARK: - The 5 MB file

    private func measureLargeFile() async -> [String: Any] {
        let source = Fixtures.swiftSource(ofAtLeast: options.sourceBytes)
        let bytes = source.utf8.count
        Trace.log("fixture generated: \(bytes) bytes")

        // Warm, not cold: the buffer is replaced in an editor that is already up, which is the
        // case the acceptance clause describes ("opens warm").
        view.send(.open(path: "s3/warmup.swift", language: "swift", text: "// warm-up\n", line: nil))
        try? await Task.sleep(nanoseconds: 400_000_000)

        _ = try? await call(ProbeScripts.arm)
        let hostStart = Date()
        view.send(.setText(text: source))
        let hostElapsed = Date().timeIntervalSince(hostStart) * 1000
        Trace.log("setText dispatched in \(Int(hostElapsed)) ms; waiting on the recorder")

        let recorded = (try? await call(ProbeScripts.awaitRecorded, ["type": "setText", "timeoutMs": 30000])) ?? [:]
        var out = recorded as? [String: Any] ?? ["raw": recorded]
        out["bytes"] = bytes
        out["lines"] = source.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        // The host-side number includes `evaluateJavaScript`'s own dispatch of a 5 MB script, so
        // it is larger than the in-page one and is reported beside it rather than instead of it.
        out["hostSendToReturnMs"] = hostElapsed
        return out
    }

    // MARK: - The diff

    private func measureDiff() async -> [String: Any] {
        let pair = Fixtures.diffPair(lines: options.diffLines)
        _ = try? await call(ProbeScripts.arm)
        let hostStart = Date()
        view.send(.showDiff(path: "s3/diff.swift", original: pair.original, modified: pair.modified, language: "swift"))
        let hostElapsed = Date().timeIntervalSince(hostStart) * 1000

        let timings = (try? await call(ProbeScripts.awaitRecorded, ["type": "showDiff", "timeoutMs": 30000])) as? [String: Any] ?? [:]
        let result = (try? await call(ProbeScripts.diffProbe, ["timeoutMs": 20000])) as? [String: Any] ?? ["computed": false]

        var out = result
        out["timings"] = timings
        out["hostSendToReturnMs"] = hostElapsed
        out["generatedChangedRegions"] = pair.expectedChangedRegions
        out["originalBytes"] = pair.original.utf8.count
        out["modifiedBytes"] = pair.modified.utf8.count
        return out
    }

    // MARK: - The workers

    private static let workerFiles = ["editor.worker.js", "ts.worker.js", "json.worker.js",
                                      "css.worker.js", "html.worker.js"]

    private func measureWorkers() async -> [String: Any] {
        let direct = (try? await call(ProbeScripts.directWorkerProbe, [
            "files": Self.workerFiles, "route": route.javaScriptNameForProbe, "settleMs": 2500,
        ])) as? [[String: Any]] ?? []

        let functional = (try? await call(ProbeScripts.languageWorkerProbe, ["timeoutMs": 12000])) as? [String: Any] ?? [:]

        let started = Dictionary(uniqueKeysWithValues: direct.compactMap { entry -> (String, Bool)? in
            guard let file = entry["file"] as? String else { return nil }
            return (file, entry["started"] as? Bool ?? false)
        })
        let allFive = Self.workerFiles.allSatisfy { started[$0] == true }

        return [
            "instantiation": direct,
            "functional": functional,
            "allFiveStarted": allFive,
            "startedByFile": started,
            // Named so the report never reads as if silence proved life.
            "note": "instantiation records the module worker's `error` event; `started: true` means"
                + " no load error inside the settle window. The functional block is the positive"
                + " claim: editor.worker is witnessed by the diff's computed line changes.",
        ]
    }

    // MARK: - Facts and plumbing

    private func bundleFacts() -> [String: Any] {
        guard let root = EditorResources.monacoDirectoryURL,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return ["available": false] }

        var count = 0
        var bytes = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            count += 1
            bytes += size
        }
        let version = (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)) ?? ""
        return [
            "available": true,
            "fileCount": count,
            "totalBytes": bytes,
            "version": version.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "; "),
        ]
    }

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await view.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) as Any
    }

    private func verdict(document: Bool, chunk: Bool, workers: Bool) -> [String: Any] {
        [
            "documentLoaded": document,
            "dynamicImportChunkLoaded": chunk,
            "allFiveWorkersStarted": workers,
            "routeCarriesEveryLoadPath": document && chunk && workers,
        ]
    }

    var finalReport: [String: Any] { report }
    var holdsOpen: Bool { options.holdOpen }
}

private extension WorkerLoadingRoute {
    /// The same three names the bootstrap branches on. Read here rather than reached for through
    /// the module's internal accessor, because the probe is not the bootstrap.
    var javaScriptNameForProbe: String {
        switch self {
        case .schemeForEverything: return "scheme"
        case .blobWorkers: return "blob"
        case .fileURLForEverything: return "file"
        }
    }
}


/// An `NSWindow` that can be told to report itself visible.
///
/// The harness runs from a shell, and a shell session can be locked: `loginwindow`'s own window
/// sits above every application window, so AppKit reports occlusion and WebKit stops driving
/// frames. Nothing about that is a fact about Monaco. The override is off by default, turned on
/// only when the frame-liveness probe has already found zero frames, and recorded in the report
/// wherever it was used.
final class HarnessWindow: NSWindow {
    var forcesVisible = false
    override var occlusionState: NSWindow.OcclusionState {
        forcesVisible ? [.visible] : super.occlusionState
    }
}
