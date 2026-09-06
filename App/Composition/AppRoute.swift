import Foundation
import ClaudeWire

/// The four screens the window can show, and the one value each carries.
///
/// Deliberately not `Equatable`: `.workspace` carries live references — an actor, a store, a
/// watcher — and none of them has an identity a value comparison could mean. Tests discriminate
/// through the accessors below, which is also how a view switches without unwrapping twice.
enum AppRoute {
    case launching
    case setup(SetupState)
    case upgrade(installed: SemanticVersion, baseline: SemanticVersion)
    case workspace(Workspace)
}

extension AppRoute {
    var setupState: SetupState? {
        if case .setup(let state) = self { return state }
        return nil
    }

    var upgradeVersions: (installed: SemanticVersion, baseline: SemanticVersion)? {
        if case .upgrade(let installed, let baseline) = self { return (installed, baseline) }
        return nil
    }

    var workspace: Workspace? {
        if case .workspace(let workspace) = self { return workspace }
        return nil
    }

    var isLaunching: Bool {
        if case .launching = self { return true }
        return false
    }
}

/// Which of afleet's two write roots collided with the config home. Named rather than pathed so
/// the screen and the log can both say which one without printing either (parent §11).
enum WriteRoot: String, Hashable, Sendable {
    /// `~/Library/Application Support/afleet`, where the state store's documents live.
    case store
    /// `~/Library/Logs/afleet`, where the three diagnostics sinks live.
    case diagnostics
}

/// Why the app cannot reach a workspace, and what the setup screen tells the user to do about it.
enum SetupState: Hashable, Sendable {
    /// No `claude` on the resolved PATH, at `~/.local/bin/claude`, or at the Developer override.
    case engineMissing
    /// The version probe ran and its output was not a version. Carries the output verbatim so the
    /// screen can show what the binary actually said.
    case engineUnreadable(output: String)
    /// `<configHome>/.claude.json` does not report `hasCompletedOnboarding: true`.
    case notSignedIn(configHome: URL)
    /// X9: one of afleet's own write roots is the config home or lies beneath it. Nothing was
    /// constructed — no store, no diagnostics, no `Fleet`.
    case writeRootInsideConfigHome(root: WriteRoot, configHome: URL)
    /// `FileStateStore.init` threw. Carries the error's own shape, which is already path-free.
    case storeUnavailable(reason: String)
}
