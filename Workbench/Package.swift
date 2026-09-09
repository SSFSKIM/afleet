// swift-tools-version: 6.2
import PackageDescription

// Workbench is built by the seven leaves of composite child C7 in parallel worktrees, plus
// C5 for the PanelHostAPI target; see docs/doperpowers/specs/2026-09-05-c7-workbench-panels.md
// contract W1. C7.1 owns this file. Every other leaf adds targets only inside its own marked
// region; the regions stay apart so the branches merge without a conflict. Dependencies are
// AfleetCore and FleetKit only (parent X1; never ClaudeWire) and libghostty-spm at an exact
// tag, bumped only by a leaf with a Revision Note on the C7 spec.
//
// Every row below lists the modules its own sources import: SwiftPM makes a transitive module
// visible whether or not a target asked for it, so an edge left undeclared still compiles and
// W1's table stops describing the package. `TerminalCoreTests/DeclaredEdgeTests` reads this
// manifest through `swift package dump-package` and holds each target to that.

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
        .target(name: "CDarwinWaitStatus"),
        .target(
            name: "TerminalCore",
            dependencies: [
                "CDarwinWaitStatus",
                core,
                ghosttyTerminal,
                ghosttyKit,
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            swiftSettings: v6
        ),
        // `ghosttyTerminal` because the suite asserts on the renderer directly — the adapter's
        // wiring, the flood path, and `NameCollisionTests`, which names
        // `GhosttyTerminal.TerminalSurface` to prove the shipped protocol and the renderer's
        // same-named one are two types. TerminalCore does not re-export it, and a module reached
        // only through another target's edge is an undeclared edge (`DeclaredEdgeTests`).
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore", ghosttyTerminal], swiftSettings: v6),
        .executableTarget(name: "S1Harness", dependencies: ["TerminalCore"], path: "Spikes/S1Harness", swiftSettings: v6),
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
        // The `Samples` directory holds the authored `gh --json` documents C7.3's model tests
        // decode (ledger D9): real field names, invented values, never a recorded account.
        // `.copy` rather than `.process` — the tests read them back as bytes and assert on
        // those bytes, so the build system must not rewrite them.
        // `core` for the member-import-visibility reason C5 recorded for `PanelHostAPITests`:
        // the diff suites name `DiffRef.Base`, and SourceControlCore does not re-export the
        // module that defines it.
        .testTarget(name: "SourceControlCoreTests", dependencies: ["SourceControlCore", core],
                    resources: [.copy("Samples")], swiftSettings: v6),
        // MARK: - end of C7.3

        // MARK: - PanelHostAPI (owner: C5; X7's protocol, declared here so Workbench and the app both import it)
        .target(name: "PanelHostAPI", dependencies: [core, fleet], swiftSettings: v6),
        // `core` and `fleet` are required, not decorative: PanelHostAPI does not re-export them,
        // and under Swift 6's member-import-visibility rules a test that constructs a `ChannelKey`,
        // a `PaneRequest` or a `SeenURL` must import the module that defines it.
        .testTarget(name: "PanelHostAPITests", dependencies: ["PanelHostAPI", core, fleet], swiftSettings: v6),
        // MARK: - end of PanelHostAPI

        // MARK: - C7.4 terminal panel (owner: C7.4)
        // `core` is required, not decorative, and is the same amendment C7.5's, C7.6's and
        // C7.7's rows already took: `TerminalPanelSession` names AfleetCore's own types, and
        // neither `TerminalCore` nor `PanelHostAPI` re-exports the module that defines them.
        // W1's row predates that ruling; every other panel row gained `AfleetCore` at merge and
        // this one reached it through a transitive edge instead (found by the C7 recomposition
        // review, `DeclaredEdgeTests`).
        .target(name: "TerminalPanel", dependencies: [core, "TerminalCore", "LinkRouting", "PanelHostAPI", fleet], swiftSettings: v6),
        // `TerminalCore`, `fleet` and `core` for the member-import-visibility reason C5 recorded
        // for PanelHostAPITests: TerminalPanel re-exports none of them, so a test that names a
        // `TerminalSize`, a `PaneRequest` or the `SessionID` inside `.hatch` must import the
        // module that defines it.
        // `PanelHostAPI` joins them for the same reason: the suites name `PaneRequest` and
        // `ChannelContext`, and reached the module through TerminalPanel's edge until now.
        .testTarget(name: "TerminalPanelTests",
                    dependencies: ["TerminalPanel", "TerminalCore", "PanelHostAPI", fleet, core],
                    swiftSettings: v6),
        // MARK: - end of C7.4

        // MARK: - C7.5 files panel (owner: C7.5)
        // `SourceControlCore` and `core` are required, not decorative. The `.diff` target this leaf
        // registers on `LinkRouter` renders a pair of whole texts, and W7 makes every `git`
        // invocation and every parser C7.3's — `GitDiff.blob` and `GitDiff.workingTreeFile` exist,
        // by C7.3's own account, "because the Monaco bridge takes two texts rather than a patch",
        // which is this use. A second git reader inside this target is what W7 forbids. `core` is
        // the member-import-visibility reason C5 recorded for `PanelHostAPITests` and C7.2 for
        // `LinkRoutingTests`: neither `LinkRouting` nor `PanelHostAPI` re-exports AfleetCore, so a
        // target naming a `WorkspaceLink` or a `DiffRef` must depend on the module defining them.
        // W1's row predates both and is amended at C7.5's gate (composite, 2026-09-09).
        .target(name: "FilesPanel",
                dependencies: [core, "EditorCore", "SourceControlCore", "LinkRouting", "PanelHostAPI", fleet],
                swiftSettings: v6),
        // W1: "every panel target gets one [test target] when a panel leaf lands". The dependencies
        // past `FilesPanel` are the ones the tests name types from directly — `EditorCommand` and
        // `EditorResources` from EditorCore, `LinkRouter` from LinkRouting, `LinkTarget` and
        // `ChannelContext` from PanelHostAPI, `ToolRunner` from SourceControlCore, `WorkspaceLink`
        // from AfleetCore, the store from FleetKit — under that same visibility rule.
        .testTarget(name: "FilesPanelTests",
                    dependencies: ["FilesPanel", "EditorCore", "SourceControlCore", "LinkRouting",
                                   "PanelHostAPI", core, fleet],
                    swiftSettings: v6),
        // MARK: - end of C7.5

        // MARK: - C7.6 browser panel (owner: C7.6)
        // `SourceControlCore` and `core` are required, not decorative. `WorkspaceLink.pullRequest`
        // carries an integer and nothing else, and turning it into a page needs the repository —
        // which only `SourceControlCore` knows. The panel runs `gh pr view <n> --json url` through
        // that module's `ToolRunner` (X11: the user's own binary, resolved through the captured
        // PATH) rather than parsing remotes by hand or standing up a second process runner.
        // W1's table row predates that seam and is amended at this leaf's merge; X1 forbids only
        // ClaudeWire, and the edge is acyclic (SourceControlCore depends on AfleetCore alone).
        // `core` because `LinkTarget`'s handler names `WorkspaceLink`, and BrowserPanel does not
        // re-export the module that defines it.
        .target(name: "BrowserPanel",
                dependencies: ["LinkRouting", "PanelHostAPI", "SourceControlCore", core, fleet],
                swiftSettings: v6),
        // `PanelHostAPI`, `core` and `fleet` for the member-import-visibility reason C5 recorded
        // for PanelHostAPITests: BrowserPanel re-exports none of them, so a test constructing a
        // `WorkspaceLink`, a `LinkTarget` or a `SeenURL` must import the module that defines it.
        .testTarget(name: "BrowserPanelTests",
                    dependencies: ["BrowserPanel", "LinkRouting", "PanelHostAPI", "SourceControlCore", core, fleet],
                    swiftSettings: v6),
        // MARK: - end of C7.6

        // MARK: - C7.7 source control panel (owner: C7.7)
        // `EditorCore` is **gone** from this row and `core` has taken its place. W1 put EditorCore
        // here while C7.7's purpose line still read "commit detail with changed files and Monaco
        // diffs"; the composite amended that line at C7.5's merge — this leaf shows a diff by
        // emitting a `.diff` `WorkspaceLink` the Files tab's target opens, and never imports
        // `FilesPanel`. Under that ruling nothing here constructs a `MonacoEditorView`, sends an
        // `EditorCommand` or names a language id, and a dependency edge with no import site is a
        // claim in the manifest a later reader believes. `core` is required for the
        // member-import-visibility reason C5 recorded for `PanelHostAPITests` and C7.2 for
        // `LinkRoutingTests`: this target names `WorkspaceLink` and `DiffRef`, and neither
        // `LinkRouting` nor `PanelHostAPI` re-exports the module that defines them — the same
        // amendment C7.5's and C7.6's rows already took. Filed as C7.7's `[parent-impact]`
        // (child spec, 2026-09-09) and accepted by the architect; W4 loses its C7.7 half with it.
        .target(name: "SourceControlPanel",
                dependencies: [core, "SourceControlCore", "LinkRouting", "PanelHostAPI", fleet],
                swiftSettings: v6),
        // W1: "every panel target gets one [test target] when a panel leaf lands". The dependencies
        // past `SourceControlPanel` are the ones the tests name types from directly — `ToolRunning`,
        // `GitCommit`, `GraphRow` and `ToolError` from SourceControlCore, `LinkRouter` from
        // LinkRouting, `LinkTarget` and `ChannelContext` from PanelHostAPI, `WorkspaceLink` and
        // `DiffRef` from AfleetCore, `ChannelKey` from FleetKit — under that same visibility rule.
        //
        // The `Samples` directory holds the authored `gh --json` documents this leaf's GitHub tab
        // decodes: real field names, invented values, never a recorded account (§11, and the shape
        // `SourceControlCoreTests/Samples` already takes). `.copy` rather than `.process` — the
        // tests read them back as bytes, so the build system must not rewrite them.
        .testTarget(name: "SourceControlPanelTests",
                    dependencies: ["SourceControlPanel", "SourceControlCore", "LinkRouting",
                                   "PanelHostAPI", core, fleet],
                    resources: [.copy("Samples")], swiftSettings: v6),
        // MARK: - end of C7.7

        // The umbrella: the app imports Workbench and nothing below it.
        .target(name: "Workbench", dependencies: ["TerminalCore", "EditorCore", "LinkRouting", "SourceControlCore", "PanelHostAPI",
                                                  "TerminalPanel", "FilesPanel", "BrowserPanel", "SourceControlPanel", core, fleet], swiftSettings: v6),
    ]
)
