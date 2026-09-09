import Foundation
import FleetKit

/// Everything one node of the Agents tree draws, sanitised once, at the boundary where the content
/// is built (child spec D11, root §12).
///
/// **Why the sanitising happens here and nowhere else.** `agentType`, `description`, `activityLine`
/// and `lastToolName` all come off the wire — a subagent names itself, and the engine's progress
/// frames carry the model's own sentence about what the run is doing. C6.1's wave H settled the
/// rule for the timeline: strip once where the content value is built, so a row that draws a string
/// inherits the sanitised value rather than each drawing site remembering to ask. A tree with a
/// status glyph, a badge, an activity line and a parked marker is four such sites on one node.
///
/// **A task id is drawable and never printable** (root §11). `id` is on this value because the tree
/// shows it and *Copy agent id* hands it to the user; no report, log or failure message built from
/// this type states one.
struct AgentNodeContent: Hashable, Sendable, Identifiable {

    /// The engine's `task_id`, unsanitised on purpose: it is an identifier the tree keys by and the
    /// selection store round-trips, so a stripped copy would no longer name the node it came from.
    /// It is drawn, never printed.
    let id: AgentRunID
    let agentType: String?
    let description: String
    let model: String?
    let status: TaskStatus
    let depth: Int
    let elapsedOrigin: Date
    let endedAt: Date?
    let activityLine: String?
    let lastToolName: String?
    let toolUseID: String?
    /// How many `task_started` frames this id has carried. Two is a re-armed run, not a second node.
    let startedCount: Int
    /// C3's reading: this run is not running and a child of it is (child spec D13).
    let isParked: Bool
    /// Pending decisions the engine is waiting on *for this run*, as a count (§11: a count, never a
    /// request id).
    let waitingCount: Int

    init(node: AgentRunNode, isParked: Bool, waitingCount: Int) {
        self.id = node.id
        self.agentType = node.agentType.map(TextSanitiser.sanitise)
        self.description = TextSanitiser.sanitise(node.description)
        self.model = node.model.map(TextSanitiser.sanitise)
        self.status = node.status
        self.depth = node.depth
        self.elapsedOrigin = node.elapsedOrigin
        self.endedAt = node.endedAt
        self.activityLine = node.activityLine.map(TextSanitiser.sanitise)
        self.lastToolName = node.lastToolName.map(TextSanitiser.sanitise)
        self.toolUseID = node.toolUseID
        self.startedCount = node.startedCount
        self.isParked = isParked
        self.waitingCount = waitingCount
    }
}
