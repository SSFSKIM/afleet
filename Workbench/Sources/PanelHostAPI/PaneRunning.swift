import Foundation
import FleetKit

/// The Terminal panel's side of X5. X5 does the ownership work; a panel never spawns `claude`
/// for a session on its own initiative.
public protocol PaneRunning: Sendable {
    /// Runs the request in that channel's context and reports its exit through the context's
    /// `reportPaneExit`, echoing `request` unchanged so X5 can match the exit to the request it is
    /// waiting on.
    ///
    /// The context is a parameter because the reporter lives on it and nowhere else: a runner given
    /// only the request could not discharge the obligation this sentence states. It also says which
    /// channel the pane belongs to, which the request does not — a `.attach`, `.logs`, `.command` or
    /// `.shell` request names a directory and a purpose, and no channel is recoverable from it.
    func run(_ request: PaneRequest, in context: ChannelContext) async
}
