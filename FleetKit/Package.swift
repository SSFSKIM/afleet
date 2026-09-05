// swift-tools-version: 6.2
import PackageDescription

// FleetKit is built by two children of the roadmap in parallel worktrees: C3 (the timeline
// data half) and C4 (sessions, lifecycle and the fleet); parent spec §17 C3, C4 and X1.
// C4 owns this manifest. C3 adds targets only inside its marked region below; C4 edits
// everything else. The regions stay apart so the two branches merge without a conflict.

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let core: Target.Dependency = .product(name: "AfleetCore", package: "AfleetCore")
let wire: Target.Dependency = .product(name: "ClaudeWire", package: "ClaudeWire")

let package = Package(
    name: "FleetKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FleetKit", targets: ["FleetKit"])],
    dependencies: [.package(path: "../AfleetCore"), .package(path: "../ClaudeWire")],
    targets: [
        // MARK: - C3 timeline group (owner: C3). Add C3 targets between these marks only.
        .target(name: "FleetTimeline", dependencies: [core, wire], swiftSettings: v6),
        .testTarget(name: "FleetTimelineTests", dependencies: ["FleetTimeline"], swiftSettings: v6),
        // MARK: - end of C3 group

        // MARK: - C4 sessions group (owner: C4).
        .target(name: "FleetSessions", dependencies: ["FleetTimeline", core, wire], swiftSettings: v6),
        .testTarget(name: "FleetSessionsTests", dependencies: ["FleetSessions"], swiftSettings: v6),
        // MARK: - end of C4 group

        // The umbrella: Workbench and the app import FleetKit and nothing below it.
        .target(name: "FleetKit", dependencies: ["FleetTimeline", "FleetSessions", core], swiftSettings: v6),
    ]
)
