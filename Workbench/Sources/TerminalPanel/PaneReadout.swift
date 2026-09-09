// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import Darwin
import FleetKit
import Foundation

/// A button a pane offers. The set a pane offers is decided here and read by the view, so what is
/// asserted and what is clickable are the same list.
public enum PaneAction: Hashable, Sendable {
    /// Reopens a pane the panel made itself. Offered for a shell pane and for no `PaneRequest`
    /// pane at all — see ``PaneReadout/actions``.
    case restart
    /// `SIGCONT` to a child the user suspended.
    case resume
    case close
}

/// Everything the pane view draws, as a value.
///
/// It exists for the reason C5's `PlaceholderReadout` does: a rendered `Text` is not an assertion,
/// so the view formats these fields and nothing else, and a test on this value is a test on what
/// the window shows.
public struct PaneReadout: Hashable, Sendable {

    /// What happened to the pane's child, in the terms a person reads it in — which is why a
    /// signalled child names its signal rather than `paneExitCode`'s 128 + signal. That lossy
    /// number is what C4 is told, because X5 keys re-adoption on the event and not the number.
    public enum Status: Hashable, Sendable {
        case starting
        case running
        case suspended(signal: Int32)
        case exited(code: Int32)
        case signalled(signal: Int32)
        case failed
    }

    /// The pane's purpose in words: what the pane bar labels it and what the readout leads with.
    public let purpose: String
    public let status: Status
    /// One line, formatted from `status` alone.
    public let summary: String
    /// Why a spawn never executed, for a `.failed` pane and nobody else.
    public let failureDetail: String?
    /// Where a new pane comes from, for a `PaneRequest` pane that has ended. It is prose and not a
    /// button on purpose: the panel offers no *Restart pane* for a request, so what it can honestly
    /// do is name the action that mints a fresh one (spec Design §6).
    public let newPaneOrigin: String?
    public let actions: [PaneAction]

    public var isLive: Bool {
        switch status {
        case .starting, .running, .suspended: true
        case .exited, .signalled, .failed: false
        }
    }

    public init(request: PaneRequest?, state: PaneState) {
        purpose = Self.purpose(of: request)
        status = Self.status(of: state)
        summary = Self.summary(of: status)
        failureDetail = switch state {
        case let .failed(failure): Self.detail(of: failure)
        default: nil
        }

        let hasEnded = switch status {
        case .exited, .signalled, .failed: true
        case .starting, .running, .suspended: false
        }
        // *Restart pane* is a shell pane's button and nothing else's. W8 is binding — the panel
        // never spawns `claude` for a session on its own initiative — and item 47's `.command`
        // request *is* `claude`; the exit path agrees, since a restart could only re-report an id
        // C4 has already consumed or mint one that is X5's to mint.
        let isRestartable = request == nil && hasEnded
        var actions: [PaneAction] = []
        if isRestartable { actions.append(.restart) }
        if case .suspended = status { actions.append(.resume) }
        actions.append(.close)
        self.actions = actions
        newPaneOrigin = hasEnded ? request.map { Self.origin(of: $0.purpose) } : nil
    }

    @MainActor
    public init(pane: TerminalPane) {
        self.init(request: pane.request, state: pane.state)
    }

    // MARK: The words

    private static func purpose(of request: PaneRequest?) -> String {
        guard let request else { return "Shell" }
        return switch request.purpose {
        case .hatch: "Interactive session"
        case let .attach(job): "Attached to job \(job.rawValue)"
        case let .logs(job): "Logs for job \(job.rawValue)"
        case .shell: "Shell"
        case .command: "Command"
        }
    }

    private static func status(of state: PaneState) -> Status {
        switch state {
        case .starting: .starting
        case .running: .running
        case let .stopped(signal): .suspended(signal: signal)
        case let .exited(.exited(code)): .exited(code: code)
        case let .exited(.signalled(signal)): .signalled(signal: signal)
        case .failed: .failed
        }
    }

    private static func summary(of status: Status) -> String {
        switch status {
        case .starting:
            "Starting…"
        case .running:
            "Running"
        case let .suspended(signal):
            "Suspended by \(name(ofSignal: signal))"
        case let .exited(code):
            code == 0 ? "Exited with code 0" : "Exited with code \(code)"
        case let .signalled(signal):
            "Ended on \(name(ofSignal: signal)) (signal \(signal))"
        case .failed:
            "This pane never started."
        }
    }

    private static func detail(of failure: PaneSpawnFailure) -> String {
        switch failure {
        case let .pty(error): String(describing: error)
        case let .other(description): description
        }
    }

    /// Named rather than numbered, because a person reading a pane is owed the signal.
    static func name(ofSignal signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
            SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGBUS: "SIGBUS",
            SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
            SIGSTOP: "SIGSTOP", SIGTSTP: "SIGTSTP", SIGTTIN: "SIGTTIN", SIGTTOU: "SIGTTOU",
        ]
        return names[signal] ?? "signal \(signal)"
    }

    private static func origin(of purpose: PanePurpose) -> String {
        switch purpose {
        case .hatch:
            "Open in terminal, in the channel's header, opens a new one."
        case .attach:
            "Attach, in the Background section, opens a new one."
        case .logs:
            "Logs, in the Background section, opens a new one."
        case .shell, .command:
            "The action that asked for this pane opens a new one."
        }
    }
}
