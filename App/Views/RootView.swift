import SwiftUI

/// The window's router. One `switch` over `AppModel.route` and nothing else: every screen below is
/// a plain view over a value, and the decision about which one to show was taken by
/// `LaunchSequence` before any of them existed.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.route {
            case .launching:
                LaunchingView()
            case .setup(let state):
                SetupView(state: state) { await model.launch() }
            case .upgrade(let installed, let baseline):
                UpgradeView(installed: installed, baseline: baseline) { await model.launch() }
            case .workspace(let workspace):
                WorkspaceView(workspace: workspace)
            }
        }
        .task {
            guard model.route.isLaunching else { return }
            await model.launch()
        }
    }
}

private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Resolving your shell environment…")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 460, minHeight: 300)
    }
}

/// The three regions of the workspace, empty. Task 5 fills the sidebar with the fleet browser and
/// Activity, Task 6 the conversation, Task 7 the panel host; the split itself is here so the shape
/// of the window is decided once.
struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        NavigationSplitView {
            EmptyRegion(name: "Fleet")
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } content: {
            EmptyRegion(name: "Conversation")
                .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            EmptyRegion(name: "Panel")
                .navigationSplitViewColumnWidth(min: 320, ideal: 480)
        }
        .navigationTitle("afleet")
        .frame(minWidth: 1000, minHeight: 640)
    }
}

private struct EmptyRegion: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
