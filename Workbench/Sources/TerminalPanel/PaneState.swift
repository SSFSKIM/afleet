import Foundation
import TerminalCore

/// Why a pane never got a child. §10 is binding — "PTY failures: panel-local error states that
/// never take the channel down" — so a spawn that throws becomes this rather than an error the
/// caller has to catch.
public enum PaneSpawnFailure: Equatable, Sendable {
    /// The pty layer refused, and named which precondition it refused on.
    case pty(PTYError)
    /// Anything else the spawn threw, kept as text because there is nothing else to keep.
    case other(String)
}

/// ```
/// .starting → .running(pid)  → .exited(PTYTermination)
///                            ↘ .stopped(signal)
///           ↘ .failed(PaneSpawnFailure)
/// ```
///
/// `.stopped` is reachable only under `PTYStopPolicy.report`, which is every pane except an
/// attach pane; see ``PaneSpawn/stopPolicy(for:)`` for why an attach pane never sees one.
public enum PaneState: Equatable, Sendable {
    case starting
    case running(pid_t)
    case stopped(signal: Int32)
    case exited(PTYTermination)
    case failed(PaneSpawnFailure)
}
