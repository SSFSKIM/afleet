import AppKit
import Foundation
import TerminalCore

// MARK: - The leg

enum Leg: Sendable {
    case shell
    case flood(seconds: Double)
    case attach(short: String, stopPolicy: PTYStopPolicy, seconds: Double, sendsCtrlZ: Bool)
    case selftest

    static let usage = """
    usage: S1Harness selftest
           S1Harness flood [--seconds <n>]
           S1Harness shell
           S1Harness attach <short> [--detach] [--hold] [--seconds <n>]
    """

    enum Parsed {
        case success(Leg)
        case failure(String)
    }

    static func parse(_ arguments: [String]) -> Parsed {
        guard let name = arguments.first else { return .failure("no leg named") }
        let rest = Array(arguments.dropFirst())
        let seconds = value(of: "--seconds", in: rest).flatMap(Double.init) ?? 10
        switch name {
        case "shell":
            return .success(.shell)
        case "selftest":
            return .success(.selftest)
        case "flood":
            return .success(.flood(seconds: seconds))
        case "attach":
            guard let short = rest.first, !short.hasPrefix("--") else {
                return .failure("attach needs the job's short id")
            }
            // `.report` is the leg's default because it is the only policy that lets the run
            // observe what Ctrl+Z actually did: `.detach` answers a stop before it can be
            // reported as one. `--detach` runs the same leg under the pane's real policy.
            let policy: PTYStopPolicy = rest.contains("--detach") ? .detach : .report
            // `--hold` runs the same leg without the Ctrl+Z. It is the control the finding needs:
            // a client that ends anyway would make the byte look causal when it was not.
            return .success(.attach(
                short: short,
                stopPolicy: policy,
                seconds: seconds,
                sendsCtrlZ: !rest.contains("--hold")
            ))
        default:
            return .failure("unknown leg")
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

// MARK: - The child's environment

/// A pane's child gets an environment composed by name, never the host's own (X11). The harness
/// holds itself to the same rule for a second reason: `CLAUDE_CODE_CHILD_SESSION` is set in the
/// process that launched this one, and inheriting it would switch the engine's session
/// registration off in anything spawned here.
enum ChildEnvironment {
    /// `TERM` and `TERMINFO_DIRS` are deliberately absent: `PTYProcess` overlays them from the
    /// surface's own `TerminalDescription`, which is the behaviour under test.
    static let allowedNames = ["HOME", "PATH"]
    static let attachAllowedNames = ["HOME", "PATH", "CLAUDE_CONFIG_DIR"]

    enum Composed {
        case success([String: String])
        case missing(String)
    }

    static func compose(names: [String]) -> Composed {
        let host = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for name in names {
            guard let value = host[name] else { return .missing(name) }
            environment[name] = value
        }
        return .success(environment)
    }

    static func homeDirectory(in environment: [String: String]) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSTemporaryDirectory(), isDirectory: true)
    }
}

// MARK: - The main-run-loop heartbeat

struct HeartbeatMeasurements: Sendable {
    let scheduledCount: Int
    let deliveredCount: Int
    let medianLatencyMilliseconds: Double
    let maximumLatencyMilliseconds: Double
}

/// The same probe shape `TerminalCoreTests` uses for G3a, on the run loop rather than in a test
/// process: a `.common`-mode timer is serviced by the loop that also drags the window, so its
/// latency is the number a "the window stayed responsive" claim rests on. It is duplicated here
/// rather than shared because a spike cannot import a test target.
@MainActor
final class RunLoopHeartbeat {
    private let intervalSeconds: TimeInterval
    private var timer: Timer?
    private var startNanoseconds: UInt64 = 0
    private var nextExpectedNanoseconds: UInt64 = 0
    private var latenciesNanoseconds: [UInt64] = []

    init(intervalSeconds: TimeInterval) {
        self.intervalSeconds = intervalSeconds
    }

    func start() {
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        nextExpectedNanoseconds = 0
        latenciesNanoseconds.removeAll(keepingCapacity: true)
        let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(scheduledCount: Int) -> HeartbeatMeasurements {
        timer?.invalidate()
        timer = nil
        let sorted = latenciesNanoseconds.sorted()
        let median: Double
        if sorted.isEmpty {
            median = .infinity
        } else if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            median = Double(sorted[upper - 1] + sorted[upper]) / 2_000_000
        } else {
            median = Double(sorted[sorted.count / 2]) / 1_000_000
        }
        return HeartbeatMeasurements(
            scheduledCount: scheduledCount,
            deliveredCount: sorted.count,
            medianLatencyMilliseconds: median,
            maximumLatencyMilliseconds: Double(sorted.last ?? 0) / 1_000_000
        )
    }

    /// The expected time of a fire is carried forward from the clock, not from the number of
    /// fires already recorded. A run loop that is blocked past a whole interval does not queue
    /// the missed fire — the `Timer` simply skips it — so numbering the beats by how many
    /// arrived charges every later beat with the drift of the ones that never came, and turns a
    /// few dropped fires into a latency reading that grows without bound. The drop is counted as
    /// a drop instead.
    private func record() {
        let actual = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(intervalSeconds * 1_000_000_000)
        if nextExpectedNanoseconds == 0 { nextExpectedNanoseconds = startNanoseconds + interval }
        latenciesNanoseconds.append(
            actual > nextExpectedNanoseconds ? actual - nextExpectedNanoseconds : 0
        )
        repeat {
            nextExpectedNanoseconds += interval
        } while nextExpectedNanoseconds <= actual
    }
}

// MARK: - The harness

@MainActor
final class Harness {
    private let leg: Leg
    private var window: NSWindow!
    private let surface = GhosttyTerminalSurface()
    private var pty: PTYProcess?

    private var outputByteCount = 0
    private var outputDeliveryCount = 0
    private var inputByteCount = 0
    private var inputDeliveryCount = 0
    private var feedNanoseconds: UInt64 = 0
    private var longestFeedNanoseconds: UInt64 = 0
    private var gridReportCount = 0
    private var latestGrid: TerminalSize?
    /// What the PTY layer observed about the end of the child, in the order it observed it.
    /// These are the words the exit-or-stop finding is written from.
    private var observations: [String] = []
    private var sawStop = false
    private var sawEnd = false

    init(leg: Leg) {
        self.leg = leg
    }

    // MARK: Window

    func openWindow() {
        // The observer is installed before the view exists in a window: the surface reports its
        // first grid as soon as it lays out, and a handler installed afterwards misses it.
        observeGridBeforeSpawn()
        window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 960, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "afleet S1"
        window.contentView = surface.view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface.view)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Wiring

    private func wire(to pty: PTYProcess) {
        self.pty = pty
        surface.onInput = { [weak self] data in
            Task { @MainActor in self?.didReceiveInput(data) }
            Task { try? await pty.write(data) }
        }
        surface.onResize = { [weak self] size in
            Task { @MainActor in self?.didReceiveGrid(size) }
            Task { try? await pty.resize(to: size) }
        }
        Task { @MainActor in
            for await event in pty.events {
                switch event {
                case let .output(data):
                    outputByteCount += data.count
                    outputDeliveryCount += 1
                    let fedAt = DispatchTime.now().uptimeNanoseconds
                    surface.feed(data)
                    let spent = DispatchTime.now().uptimeNanoseconds - fedAt
                    feedNanoseconds += spent
                    longestFeedNanoseconds = max(longestFeedNanoseconds, spent)
                case let .stopped(signal):
                    sawStop = true
                    observations.append("stopped signal=\(signal)")
                case let .ended(termination):
                    sawEnd = true
                    switch termination {
                    case let .exited(code):
                        observations.append("ended exited code=\(code)")
                    case let .signalled(signal):
                        observations.append("ended signalled signal=\(signal)")
                    }
                    surface.processDidExit(code: termination.paneExitCode)
                }
            }
        }
    }

    private func didReceiveInput(_ data: Data) {
        inputByteCount += data.count
        inputDeliveryCount += 1
    }

    private func didReceiveGrid(_ size: TerminalSize) {
        gridReportCount += 1
        latestGrid = size
    }

    /// The surface reports its grid only once the view has laid out, and the PTY's initial size
    /// has to be that grid or the child's first paint is drawn for a window that does not exist.
    /// The first report is the view's pre-layout default (16x46 on this machine, the same pair
    /// the rendering probe recorded); the real grid follows once AppKit has laid the view out.
    /// Waiting for the reports to stop is what keeps a child from painting its first screen for
    /// a window that is not the one on the display.
    private func awaitFirstGrid() async -> TerminalSize? {
        for _ in 0 ..< 200 {
            if let latestGrid, latestGrid.rows > 0, latestGrid.columns > 0 { break }
            await settle(milliseconds: 25)
        }
        var lastSeenReports = -1
        while lastSeenReports != gridReportCount {
            lastSeenReports = gridReportCount
            await settle(milliseconds: 300)
        }
        return latestGrid
    }

    private func settle(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// The surface is wired before a child exists so the first grid report is not lost. Nothing
    /// is written to a pty that has not been spawned.
    private func observeGridBeforeSpawn() {
        surface.onResize = { [weak self] size in
            Task { @MainActor in self?.didReceiveGrid(size) }
        }
    }

    private func spawn(
        executable: String,
        arguments: [String],
        cwd: URL,
        environment: [String: String],
        size: TerminalSize,
        stopPolicy: PTYStopPolicy
    ) throws -> PTYProcess {
        let request = PTYSpawnRequest(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            size: size,
            terminal: surface.terminalDescription,
            stopPolicy: stopPolicy
        )
        return try PTYProcess(spawning: request)
    }

    // MARK: Run

    func run() async -> Int32 {
        switch leg {
        case .selftest:
            return await runSelftest()
        case let .flood(seconds):
            return await runFlood(seconds: seconds)
        case .shell:
            return await runShell()
        case let .attach(short, stopPolicy, seconds, sendsCtrlZ):
            return await runAttach(
                short: short,
                stopPolicy: stopPolicy,
                seconds: seconds,
                sendsCtrlZ: sendsCtrlZ
            )
        }
    }

    // MARK: selftest

    /// Two invented markers and the child's own reading of its window size. The markers prove the
    /// bytes reached the grid; `stty size` on `SIGWINCH` proves the resize travelled the whole
    /// way — view layout, `onResize`, `TIOCSWINSZ`, the child's signal — and came back rendered.
    private static let selftestScript = """
    printf 'afleet-selftest-alpha\\r\\nafleet-selftest-bravo\\r\\n'
    trap 'stty size' WINCH
    while : ; do sleep 0.1 ; done
    """

    private func runSelftest() async -> Int32 {
        guard case let .success(environment) = ChildEnvironment.compose(
            names: ChildEnvironment.allowedNames
        ) else {
            print("selftest: FAIL a required environment name is absent")
            return 1
        }
        guard let initialGrid = await awaitFirstGrid() else {
            print("selftest: FAIL the surface never reported a grid reports=\(gridReportCount)")
            return 1
        }

        let child: PTYProcess
        do {
            child = try spawn(
                executable: "/bin/sh",
                arguments: ["-c", Self.selftestScript],
                cwd: FileManager.default.temporaryDirectory,
                environment: environment,
                size: initialGrid,
                stopPolicy: .report
            )
        } catch {
            print("selftest: FAIL the child could not be spawned")
            return 1
        }
        wire(to: child)
        defer { Task { await child.teardown() } }

        var failures: [String] = []

        // (1) the fed bytes render.
        var rendered = ""
        for _ in 0 ..< 80 {
            await settle(milliseconds: 50)
            rendered = surface.renderedViewportText() ?? ""
            if rendered.contains("afleet-selftest-alpha"), rendered.contains("afleet-selftest-bravo") {
                break
            }
        }
        let alphaRendered = rendered.contains("afleet-selftest-alpha")
        let bravoRendered = rendered.contains("afleet-selftest-bravo")
        if !alphaRendered || !bravoRendered {
            failures.append("the viewport did not carry both fed markers")
        }
        print(
            "selftest: render markers=\(alphaRendered ? 1 : 0)+\(bravoRendered ? 1 : 0)/2"
                + " bytes=\(outputByteCount) deliveries=\(outputDeliveryCount)"
                + " grid rows=\(initialGrid.rows) columns=\(initialGrid.columns)"
        )

        // (2) a programmatic window resize reaches the child and comes back rendered.
        let reportsBeforeResize = gridReportCount
        let started = DispatchTime.now().uptimeNanoseconds
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.layoutIfNeeded()
        var resizedGrid: TerminalSize?
        for _ in 0 ..< 80 {
            await settle(milliseconds: 50)
            if gridReportCount > reportsBeforeResize,
               let grid = latestGrid,
               grid.rows != initialGrid.rows || grid.columns != initialGrid.columns
            {
                resizedGrid = grid
                break
            }
        }
        guard let resizedGrid else {
            failures.append("the resize was never reported as a new grid")
            report(failures)
            return failures.isEmpty ? 0 : 1
        }
        let resizeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        let expectedByChild = "\(resizedGrid.rows) \(resizedGrid.columns)"
        var childAgreed = false
        for _ in 0 ..< 80 {
            await settle(milliseconds: 50)
            if (surface.renderedViewportText() ?? "").contains(expectedByChild) {
                childAgreed = true
                break
            }
        }
        if !childAgreed {
            failures.append("the child never reported the grid the surface reported")
        }
        print(
            "selftest: resize rows=\(initialGrid.rows)->\(resizedGrid.rows)"
                + " columns=\(initialGrid.columns)->\(resizedGrid.columns)"
                + " reports=\(gridReportCount) childAgreed=\(childAgreed ? 1 : 0)"
                + String(format: " milliseconds=%.1f", resizeMilliseconds)
        )

        report(failures)
        return failures.isEmpty ? 0 : 1
    }

    private func report(_ failures: [String]) {
        if failures.isEmpty {
            print("selftest: PASS")
        } else {
            for failure in failures { print("selftest: FAIL \(failure)") }
        }
    }

    // MARK: flood

    private func runFlood(seconds: Double) async -> Int32 {
        guard case let .success(environment) = ChildEnvironment.compose(
            names: ChildEnvironment.allowedNames
        ) else {
            print("flood: FAIL a required environment name is absent")
            return 1
        }
        guard let initialGrid = await awaitFirstGrid() else {
            print("flood: FAIL the surface never reported a grid")
            return 1
        }

        let child: PTYProcess
        do {
            child = try spawn(
                executable: "/usr/bin/yes",
                arguments: ["afleet-flood"],
                cwd: FileManager.default.temporaryDirectory,
                environment: environment,
                size: initialGrid,
                stopPolicy: .report
            )
        } catch {
            print("flood: FAIL the child could not be spawned")
            return 1
        }
        wire(to: child)

        let interval = 0.05
        let heartbeat = RunLoopHeartbeat(intervalSeconds: interval)
        heartbeat.start()

        // Half way through, the window is moved and resized from the run loop. A drag is a
        // stream of run-loop events that changes the window's frame; this is the automatable
        // half of that, and it says nothing about how a drag *feels* — that stays with the human.
        await settle(milliseconds: Int(seconds * 500))
        let originBefore = window.frame.origin
        window.setFrameOrigin(NSPoint(x: originBefore.x + 40, y: originBefore.y + 24))
        let originMoved = window.frame.origin != originBefore

        await settle(milliseconds: Int(seconds * 500))
        let measurements = heartbeat.stop(scheduledCount: Int(seconds / interval))

        // The keystroke: a real `NSEvent` through the window, so it travels the responder chain
        // into the view's key handling and out through the session's write callback, rather than
        // being injected into the session directly.
        window.makeFirstResponder(surface.view)
        let inputBefore = inputByteCount
        let keyedAt = DispatchTime.now().uptimeNanoseconds
        sendKeystroke()
        var keystrokeMilliseconds = Double.infinity
        for _ in 0 ..< 100 {
            await settle(milliseconds: 20)
            if inputByteCount > inputBefore {
                keystrokeMilliseconds =
                    Double(DispatchTime.now().uptimeNanoseconds - keyedAt) / 1_000_000
                break
            }
        }
        let keystrokeAnswered = inputByteCount > inputBefore

        await child.teardown()

        print(
            String(
                format: "flood: heartbeat median=%.3fms maximum=%.3fms delivered=%d/%d",
                measurements.medianLatencyMilliseconds,
                measurements.maximumLatencyMilliseconds,
                measurements.deliveredCount,
                measurements.scheduledCount
            )
        )
        print(
            "flood: output bytes=\(outputByteCount) deliveries=\(outputDeliveryCount)"
                + " windowMoved=\(originMoved ? 1 : 0)"
        )
        // How much of the run loop's time the host's own `feed` took, against how much of it the
        // renderer took afterwards: the difference is what separates a delivery defect from a
        // rendering cost.
        print(
            String(
                format: "flood: feed total=%.1fms longest=%.1fms",
                Double(feedNanoseconds) / 1_000_000,
                Double(longestFeedNanoseconds) / 1_000_000
            )
        )
        print(
            "flood: keystroke answered=\(keystrokeAnswered ? 1 : 0)"
                + " bytes=\(inputByteCount - inputBefore)"
                + (keystrokeAnswered ? String(format: " milliseconds=%.1f", keystrokeMilliseconds) : "")
        )

        // G3b's claim, and only it: the window is still draggable and the pane still answers a
        // keystroke while a child floods it. The two latency bounds are G3a's, kept here as the
        // numbers that give "draggable" a meaning.
        //
        // The delivered/scheduled ratio is **printed as a measurement and is not a criterion**,
        // and the difference is not a convenience. G3a's ratio is about *delivery*: a headless
        // run loop that only receives bytes has nothing else to do, so a dropped tick means the
        // pty layer stole the loop. This loop also draws. A tick the renderer's own draw pass
        // displaced is a cost of rendering at full rate, not a delivery defect, and holding this
        // leg to G3a's ratio would report the renderer's frame budget as a backpressure bug.
        // What the ratio is good for is the honest reading of how a drag *feels*, which is why
        // the number is printed rather than dropped.
        let responsive = measurements.maximumLatencyMilliseconds < 500
            && measurements.medianLatencyMilliseconds < 50
        let flowed = outputByteCount > 1_000_000
        if responsive, flowed, keystrokeAnswered, originMoved {
            print("flood: PASS")
            return 0
        }
        print(
            "flood: FAIL responsive=\(responsive ? 1 : 0) flowed=\(flowed ? 1 : 0)"
                + " keystroke=\(keystrokeAnswered ? 1 : 0) moved=\(originMoved ? 1 : 0)"
        )
        return 1
    }

    /// `k`, keyCode 40 — one printable character, chosen only because it needs no modifier.
    private func sendKeystroke() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ) else { return }
        window.sendEvent(event)
    }

    // MARK: shell

    private func runShell() async -> Int32 {
        guard case let .success(environment) = ChildEnvironment.compose(
            names: ChildEnvironment.allowedNames
        ) else {
            print("shell: a required environment name is absent")
            return 1
        }
        guard let initialGrid = await awaitFirstGrid() else {
            print("shell: the surface never reported a grid")
            return 1
        }
        let child: PTYProcess
        do {
            child = try spawn(
                executable: "/bin/zsh",
                arguments: ["-il"],
                cwd: ChildEnvironment.homeDirectory(in: environment),
                environment: environment,
                size: initialGrid,
                stopPolicy: .report
            )
        } catch {
            print("shell: the child could not be spawned")
            return 1
        }
        wire(to: child)
        print("shell: grid rows=\(initialGrid.rows) columns=\(initialGrid.columns)")
        // The one thing this leg can check without a person: the shell's first paint filled rows
        // of the grid. Colour, a full-screen redraw, a live drag and an IME commit are not
        // checkable from here and are not claimed by this number.
        var paintedRows = 0
        for _ in 0 ..< 40 {
            await settle(milliseconds: 250)
            paintedRows = nonBlankRowCount(surface.renderedViewportText())
            if paintedRows > 0 { break }
        }
        print("shell: first paint rows=\(paintedRows) bytes=\(outputByteCount)")
        print("shell: the window is open — this leg's witness is a person. Ctrl-C to finish.")
        while !sawEnd {
            await settle(milliseconds: 500)
        }
        print("shell: output bytes=\(outputByteCount) deliveries=\(outputDeliveryCount)"
            + " input bytes=\(inputByteCount) grids=\(gridReportCount)")
        for observation in observations { print("shell: \(observation)") }
        return 0
    }

    // MARK: attach

    private func runAttach(
        short: String,
        stopPolicy: PTYStopPolicy,
        seconds: Double,
        sendsCtrlZ: Bool
    ) async -> Int32 {
        let environment: [String: String]
        switch ChildEnvironment.compose(names: ChildEnvironment.attachAllowedNames) {
        case let .success(composed):
            environment = composed
        case let .missing(name):
            print("attach: FAIL a required environment name is absent: \(name)")
            return 78
        }
        guard let initialGrid = await awaitFirstGrid() else {
            print("attach: FAIL the surface never reported a grid")
            return 1
        }

        let child: PTYProcess
        do {
            // `/usr/bin/env` resolves the client from the composed `PATH`, so no path to it is
            // written down here or printed anywhere.
            child = try spawn(
                executable: "/usr/bin/env",
                arguments: ["claude", "attach", short],
                cwd: ChildEnvironment.homeDirectory(in: environment),
                environment: environment,
                size: initialGrid,
                stopPolicy: stopPolicy
            )
        } catch {
            print("attach: FAIL the client could not be spawned")
            return 1
        }
        wire(to: child)

        // Let the client paint. What is asserted is that a screen arrived and filled rows — the
        // content is the engine's and is neither printed nor kept.
        let renderDeadline = max(4.0, seconds / 2)
        var renderedRows = 0
        for _ in 0 ..< Int(renderDeadline * 4) {
            await settle(milliseconds: 250)
            renderedRows = nonBlankRowCount(surface.renderedViewportText())
            if renderedRows >= 3 { break }
        }
        print(
            "attach: screen rows=\(renderedRows) bytes=\(outputByteCount)"
                + " deliveries=\(outputDeliveryCount)"
                + " grid rows=\(initialGrid.rows) columns=\(initialGrid.columns)"
        )

        // Ctrl+Z, as the byte a tty carries for it. The client puts the pty in raw mode, so this
        // is the same delivery a keypress makes: the line discipline passes it through and the
        // client's own input pump sees it.
        let sentAt = DispatchTime.now().uptimeNanoseconds
        if sendsCtrlZ {
            do {
                try await child.write(Data([0x1A]))
            } catch {
                print("attach: FAIL Ctrl+Z could not be written to the pty")
                return 1
            }
        }

        var observedMilliseconds = Double.infinity
        for _ in 0 ..< Int(seconds * 4) {
            await settle(milliseconds: 250)
            if sawStop || sawEnd {
                observedMilliseconds =
                    Double(DispatchTime.now().uptimeNanoseconds - sentAt) / 1_000_000
                break
            }
        }
        // A stop that the policy answers is followed by an end; give the sequence its moment.
        if sawStop, !sawEnd, stopPolicy == .detach {
            for _ in 0 ..< 20 where !sawEnd {
                await settle(milliseconds: 250)
            }
        }

        let policyName = stopPolicy == .detach ? "detach" : "report"
        print(
            "attach: ctrl-z sent=\(sendsCtrlZ ? 1 : 0) policy=\(policyName)"
                + " observations=\(observations.count)"
                + (observedMilliseconds.isFinite
                    ? String(format: " milliseconds=%.1f", observedMilliseconds)
                    : " milliseconds=none")
        )
        for observation in observations { print("attach: observed \(observation)") }
        if observations.isEmpty {
            print("attach: observed nothing — the PTY layer reported neither a stop nor an end")
        }

        // Nothing is left stopped on the machine: teardown continues the child before it hangs
        // it up. This signals only the pid this leg spawned, and only its own group (§7.8).
        await child.teardown()
        // `teardown` returns once the waiter has made the single `.ended` durable; the stream
        // still has to deliver it. Without this the leg can print its own record before the
        // event it is recording arrives.
        for _ in 0 ..< 20 where !sawEnd {
            await settle(milliseconds: 100)
        }
        print("attach: after teardown observations=\(observations.count)")
        for observation in observations { print("attach: final \(observation)") }
        // Without the byte the client is expected to still be running; with it, the leg has
        // something to report either way.
        return sendsCtrlZ ? (sawStop || sawEnd ? 0 : 1) : 0
    }

    private func nonBlankRowCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
