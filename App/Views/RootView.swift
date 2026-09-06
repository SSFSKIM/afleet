import SwiftUI

/// The window's router. One `switch` over `AppModel.route` and nothing else: every screen below is
/// a plain view over a value, and the decision about which one to show was taken by
/// `LaunchSequence` before any of them existed.
///
/// **This file is closed.** Task 5 is the last task permitted to edit it, which is what keeps three
/// later executors — Activity, the conversation column and the panel host — out of one shared file.
/// Each of them fills exactly one of `ActivityView`, `ChannelColumnView` and `PanelColumnView`, and
/// all three already receive everything they can need: the `AppModel` the composition root hangs
/// its models off, the `ShellModel` that says what the window is looking at, and the `Workspace`.
struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var shell: ShellModel

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
                WorkspaceView(model: model, shell: shell, workspace: workspace)
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

/// The three regions of the workspace: the fleet browser, the conversation and the panel host, in
/// one resizable split.
///
/// `NavigationSplitView` rather than an `NSSplitViewController`. §8.1 names `NSSplitView` and the
/// parent's §17.3 makes that advisory; SwiftUI's split reaches every behaviour C5 needs — three
/// resizable columns, per-column width limits, and the sidebar's native vibrancy, which the
/// framework gives the leading column of its own accord rather than through a hand-placed
/// `NSVisualEffectView`. Nothing was dropped to get there, so nothing goes in the Decision Log.
struct WorkspaceView: View {

    @Bindable var model: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        NavigationSplitView {
            Group {
                if let browser = model.browser {
                    SidebarView(browser: browser, shell: shell)
                } else {
                    ProgressView()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } content: {
            Group {
                if shell.focus.isActivity {
                    ActivityView(app: model, shell: shell, workspace: workspace)
                } else {
                    ChannelColumnView(app: model, shell: shell, workspace: workspace)
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            PanelColumnView(app: model, shell: shell, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 320, ideal: 480)
        }
        .navigationTitle("afleet")
        .frame(minWidth: 1000, minHeight: 640)
    }
}
