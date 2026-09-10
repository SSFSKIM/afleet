import Foundation
import AfleetCore

/// A job's short id, as the roster and every `claude` job verb spell it.
public struct JobShort: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum PanePurpose: Hashable, Sendable {
    case hatch(SessionID)
    /// §6.11's *Review trust in terminal* on a channel with **no owned process** (§14 item 47,
    /// tracker 314, ruled 2026-09-11).
    ///
    /// It is deliberately not a `hatch`, and the difference is not cosmetic. A hatch is a handoff:
    /// afleet terminates its child, waits for the release and hands the session over, so the channel
    /// changes origin and comes back when the pane exits. An untrusted channel has no child to hand
    /// over — that is *why* the banner is drawn — so there is nothing to terminate, nothing to
    /// release and no ownership to change. The pane runs `claude` with **no arguments** in the
    /// channel's directory, which is what puts the engine's own trust dialog on screen, and the
    /// channel is exactly where it was when the pane ends.
    case trustReview(SessionID)
    case attach(JobShort)
    case logs(JobShort)
    case shell
    case command
}

/// Everything the Terminal panel needs to run one pane on X5's behalf. X5 does the ownership work; the panel
/// never spawns `claude` for a session on its own initiative.
public struct PaneRequest: Hashable, Sendable {
    /// Opaque and fresh per request: two requests with identical fields are two requests.
    public var id: UUID
    public var executable: URL
    public var arguments: [String]
    public var cwd: URL
    /// Composed by C4 through `LaunchConfiguration.childEnvironment` (§6.1, X11).
    public var environment: [String: String]
    public var purpose: PanePurpose

    public init(id: UUID = UUID(), executable: URL, arguments: [String], cwd: URL,
                environment: [String: String], purpose: PanePurpose) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.cwd = cwd
        self.environment = environment; self.purpose = purpose
    }
}

/// The panel's report. The lifecycle accepts an exit only when `exit.request.id` is the id it is waiting on;
/// a late exit from an older pane is discarded.
public struct PaneExit: Hashable, Sendable {
    public var request: PaneRequest
    public var code: Int32
    public var observedAt: Date
    public init(request: PaneRequest, code: Int32, observedAt: Date) {
        self.request = request; self.code = code; self.observedAt = observedAt
    }
}
