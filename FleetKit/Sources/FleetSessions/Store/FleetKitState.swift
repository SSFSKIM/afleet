import Foundation
import AfleetCore

/// The fleetKit namespace's own values (parent §7.8). FleetKit never models Workbench or Afleet state.
public enum FleetKitKeys {
    public static let grouping = "sidebar.grouping"            // SidebarGrouping
    public static let unreadCursors = "channels.unread"        // [String: String]  channel key description -> last seen item uuid
    public static let desiredOwnership = "channels.desired"    // [String: DesiredOwnership]
    public static let projectServerAcceptances = "mcp.accepted"   // [ProjectServerAcceptance]
    public static let ownJobShorts = "jobs.own"                // [String]  shorts afleet itself sent to background
    public static let bypassAccepted = "bypass.accepted"       // Bool
    public static let recordedBaseline = "baseline.recorded"   // String  the CLI version the fixtures were recorded on
    public static let lastCensus = "census.last"               // CensusSummary
    public static let timelineIndex = "timeline.index"         // C3's index snapshot, through IndexStorage (Task 11)
}
public struct SidebarGrouping: Codable, Hashable, Sendable {
    public var pinned: [SessionID]; public var sectionOrder: [String]; public var collapsed: Set<String>
    public init(pinned: [SessionID] = [], sectionOrder: [String] = [], collapsed: Set<String> = []) { self.pinned = pinned; self.sectionOrder = sectionOrder; self.collapsed = collapsed }
}
public struct ProjectServerAcceptance: Codable, Hashable, Sendable {
    public var projectRoot: String; public var serverName: String; public var entryHash: String
    public init(projectRoot: String, serverName: String, entryHash: String) { self.projectRoot = projectRoot; self.serverName = serverName; self.entryHash = entryHash }
}
public struct CensusSummary: Codable, Hashable, Sendable {
    public var cliVersion: String; public var takenAt: Date; public var newInboundSubtypes: [String]
    public init(cliVersion: String, takenAt: Date, newInboundSubtypes: [String]) { self.cliVersion = cliVersion; self.takenAt = takenAt; self.newInboundSubtypes = newInboundSubtypes }
}
