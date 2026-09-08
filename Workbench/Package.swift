// swift-tools-version: 6.2
import PackageDescription

// Workbench is built by the seven leaves of composite child C7 in parallel worktrees, plus
// C5 for the PanelHostAPI target; see docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md
// contract W1. C7.1 owns this file. Every other leaf adds targets only inside its own marked
// region; the regions stay apart so the branches merge without a conflict. Dependencies are
// AfleetCore and FleetKit only (parent X1; never ClaudeWire) and libghostty-spm at an exact
// tag, bumped only by a leaf with a Revision Note on the C7 spec.

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let core: Target.Dependency = .product(name: "AfleetCore", package: "AfleetCore")
let fleet: Target.Dependency = .product(name: "FleetKit", package: "FleetKit")
let ghosttyTerminal: Target.Dependency = .product(name: "GhosttyTerminal", package: "libghostty-spm")
let ghosttyKit: Target.Dependency = .product(name: "GhosttyKit", package: "libghostty-spm")

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Workbench", targets: ["Workbench"])],
    dependencies: [
        .package(path: "../AfleetCore"),
        .package(path: "../FleetKit"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.5.20260903"),
    ],
    targets: [
        // MARK: - C7.1 terminal core (owner: C7.1; also owns this file)
        .target(name: "TerminalCore", dependencies: [core, ghosttyTerminal, ghosttyKit], swiftSettings: v6),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"], swiftSettings: v6),
        // MARK: - end of C7.1

        // MARK: - C7.2 editor core and link routing (owner: C7.2)
        // Two resource directories, both `.copy` and never `.process`: a web bundle's directory
        // layout *is* its URL space, and `.process` reserves the right to rewrite it.
        // `Resources/monaco` is generated — Tools/build-monaco.sh replaces it whole — and
        // `Resources/bootstrap` is hand-written, which is why they are not one directory.
        .target(name: "EditorCore", dependencies: [core],
                resources: [.copy("Resources/monaco"), .copy("Resources/bootstrap")],
                swiftSettings: v6),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore", core], swiftSettings: v6),
        // `PanelHostAPI` is required, not decorative: C7.2's registry is built over X7's own
        // `LinkTarget`, its `(WorkspaceLink, LinkDestination)` handler and `PanelTabID`-keyed
        // withdrawal, and a registry over those types cannot avoid the target that defines them.
        // W1's table row predates that seam and is amended at C7.2's merge; X1 forbids only
        // ClaudeWire, and this edge is acyclic (PanelHostAPI depends on AfleetCore and FleetKit).
        .target(name: "LinkRouting", dependencies: [core, "PanelHostAPI"], swiftSettings: v6),
        // `core` and `PanelHostAPI` for the member-import-visibility reason C5 recorded for
        // PanelHostAPITests: LinkRouting does not re-export them, so a test constructing a
        // `WorkspaceLink` or a `LinkTarget` must import the module that defines it.
        .testTarget(name: "LinkRoutingTests", dependencies: ["LinkRouting", "PanelHostAPI", core], swiftSettings: v6),
        // The S3 spike (spec Design §8). An executable and not a test: it opens a real NSWindow
        // and measures frame times, neither of which a `swift test` process can do honestly. It
        // is in no product and not in the `Workbench` umbrella, so nothing the app links reaches
        // it; `swift run --package-path Workbench S3Harness` is its only entry point.
        // `measure-cold-load.sh` is excluded because the target treats its whole directory as
        // sources; it is the shell instrument for G2's cold-load clause, which needs a
        // distribution rather than the single sample one harness run produces.
        .executableTarget(name: "S3Harness", dependencies: ["EditorCore"], path: "Spikes/S3Harness",
                          exclude: ["measure-cold-load.sh"], swiftSettings: v6),
        // MARK: - end of C7.2

        // MARK: - C7.3 source control core (owner: C7.3)
        .target(name: "SourceControlCore", dependencies: [core], swiftSettings: v6),
        .testTarget(name: "SourceControlCoreTests", dependencies: ["SourceControlCore"], swiftSettings: v6),
        // MARK: - end of C7.3

        // MARK: - PanelHostAPI (owner: C5; X7's protocol, declared here so Workbench and the app both import it)
        .target(name: "PanelHostAPI", dependencies: [core, fleet], swiftSettings: v6),
        // `core` and `fleet` are required, not decorative: PanelHostAPI does not re-export them,
        // and under Swift 6's member-import-visibility rules a test that constructs a `ChannelKey`,
        // a `PaneRequest` or a `SeenURL` must import the module that defines it.
        .testTarget(name: "PanelHostAPITests", dependencies: ["PanelHostAPI", core, fleet], swiftSettings: v6),
        // MARK: - end of PanelHostAPI

        // MARK: - C7.4 terminal panel (owner: C7.4)
        .target(name: "TerminalPanel", dependencies: ["TerminalCore", "LinkRouting", "PanelHostAPI", fleet], swiftSettings: v6),
        // MARK: - end of C7.4

        // MARK: - C7.5 files panel (owner: C7.5)
        .target(name: "FilesPanel", dependencies: ["EditorCore", "LinkRouting", "PanelHostAPI", fleet], swiftSettings: v6),
        // MARK: - end of C7.5

        // MARK: - C7.6 browser panel (owner: C7.6)
        .target(name: "BrowserPanel", dependencies: ["LinkRouting", "PanelHostAPI", fleet], swiftSettings: v6),
        // MARK: - end of C7.6

        // MARK: - C7.7 source control panel (owner: C7.7)
        .target(name: "SourceControlPanel", dependencies: ["SourceControlCore", "EditorCore", "LinkRouting", "PanelHostAPI", fleet], swiftSettings: v6),
        // MARK: - end of C7.7

        // The umbrella: the app imports Workbench and nothing below it.
        .target(name: "Workbench", dependencies: ["TerminalCore", "EditorCore", "LinkRouting", "SourceControlCore", "PanelHostAPI",
                                                  "TerminalPanel", "FilesPanel", "BrowserPanel", "SourceControlPanel", core, fleet], swiftSettings: v6),
    ]
)
