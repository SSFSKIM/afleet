import Foundation
import FleetKit

/// A run in C3's `AgentRunTree`, which keys its nodes by the engine's `task_id`.
///
/// `AgentRunNode.id` is a plain `String` and nothing here wraps it: the seam names the type so its
/// signature reads as contract Y4 spells it, and C6.4 passes the node's own id straight through.
typealias AgentRunID = String

/// Contract Y4 — chip to run
/// (`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md`, "Contract Y4 — chip to run").
///
/// An `Agent` chip in the timeline (C6.1) navigates to the Agents tab at that run. It is a seam and
/// not a `WorkspaceLink` case: that enum is AfleetCore's and C7.2's router enumerates every case, so
/// a new one would be a mid-flight contract change for a navigation that never leaves the app.
///
/// C6.4 implements it — select the tab through the panel host, then select the node. Until then the
/// composition root installs `NoAgentNavigation`, so C6.1's chip compiles, is wired, and does
/// nothing when clicked.
@MainActor
protocol AgentNavigating {
    func show(run: AgentRunID, in key: ChannelKey)
}

/// The default the composition root installs, and the whole of Y4 until C6.4 replaces it.
@MainActor
struct NoAgentNavigation: AgentNavigating {
    func show(run: AgentRunID, in key: ChannelKey) {}
}
