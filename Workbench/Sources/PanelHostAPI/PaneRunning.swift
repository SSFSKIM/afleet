import Foundation
import FleetKit

/// The Terminal panel's side of X5. X5 does the ownership work; a panel never spawns `claude`
/// for a session on its own initiative.
public protocol PaneRunning: Sendable {
    /// Runs the request and reports its exit through the context's `reportPaneExit`, echoing
    /// `request` unchanged so X5 can match the exit to the request it is waiting on.
    func run(_ request: PaneRequest) async
}
