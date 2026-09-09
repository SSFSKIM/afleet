// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import FleetKit
import Foundation
import TerminalCore

/// The two mappings between X5's pane contract and C7.1's pty layer, and nothing else.
///
/// They are free functions rather than methods on a pane because they are the seam: everything a
/// pane does with a request is downstream of these answers, and a mapping that can be asserted
/// without a pty is a mapping a regression cannot hide behind a live child.
public enum PaneSpawn {
    /// What C4 is told when a pane's spawn never executed (spec Design §2, Decision Log).
    ///
    /// 127 is the shell's own convention for "could not execute", and it is the one status the
    /// panel synthesises rather than observes. It exists because C4 is waiting on the request's
    /// id: a hatch whose pane never started would otherwise leave its channel released for ever.
    public static let unexecutableExitCode: Int32 = 127

    /// `PaneRequest` → `PTYSpawnRequest`. Executable, arguments, cwd and environment pass through
    /// untouched: C4 composed the environment through `LaunchConfiguration.childEnvironment` and
    /// X11 says that composition *is* the child's environment, so the panel merges nothing into
    /// it. `size` and `terminal` are the renderer's, because they describe the screen the child
    /// is about to paint and nothing in the request knows about it.
    public static func spawnRequest(
        for request: PaneRequest,
        size: TerminalSize,
        terminal: TerminalDescription
    ) -> PTYSpawnRequest {
        PTYSpawnRequest(
            executable: request.executable,
            arguments: request.arguments,
            cwd: request.cwd,
            environment: request.environment,
            size: size,
            terminal: terminal,
            stopPolicy: stopPolicy(for: request.purpose)
        )
    }

    /// An attach pane detaches on a stop; every other pane reports one.
    ///
    /// A user who typed Ctrl+Z into their own shell suspended a job on purpose, so a `.report`
    /// pane shows *Suspended* and offers *Continue*. An attach pane is the CLI's own client and
    /// takes `.detach`, which is C7.1's rule: the pty layer answers a stopped client with SIGCONT
    /// then SIGHUP and the pane sees the single `.ended`.
    public static func stopPolicy(for purpose: PanePurpose) -> PTYStopPolicy {
        switch purpose {
        case .attach:
            .detach
        case .hatch, .logs, .shell, .command:
            .report
        }
    }

    /// `PTYTermination` → `PaneExit`, with the request echoed **by value, `id` included**.
    ///
    /// The panel constructs no `PaneRequest` of its own for an X5-originated pane and edits no
    /// field of one. C4 accepts an exit only when `exit.request.id` is the id it is waiting on and
    /// discards any other silently, so a re-minted id is not a visible failure — it is a channel
    /// that stays released.
    ///
    /// That the result cannot tell `.signalled(7)` from `.exited(135)` is C7.1's recorded
    /// observation and is accepted here: X5's re-adoption keys on the event, not the number.
    public static func exit(
        of request: PaneRequest,
        termination: PTYTermination,
        at date: Date
    ) -> PaneExit {
        PaneExit(request: request, code: termination.paneExitCode, observedAt: date)
    }
}
