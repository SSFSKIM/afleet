import Foundation
import AfleetCore
import FleetKit
import PanelHostAPI
import Workbench

/// The app-side seams C7.6's Browser panel is built from: the store it persists through before a
/// launch has one, the inspection policy its web views read, and the two closures its link targets
/// take instead of a reference to the host (spec §7, C7's W5, W6 and the leaf's Q3, Q4 and Q15).
///
/// It is a composition helper and holds no state: everything below is constructed by
/// `AppModel.init` and owned there.
enum BrowserWiring {

    /// The one `BrowserTab` the app registers, with the tab set it owns.
    ///
    /// The panel is handed values rather than the app: X7 gives a tab capabilities and never the
    /// host, and the factory's inspection policy is read once per web view, on the main actor,
    /// inside `makeWebView`.
    @MainActor
    static func makeTab(store: DeferredWorkbenchStore, inspector: WebInspectorSwitch) -> BrowserTab {
        // Q15's two legs. Debug builds are inspectable and never read the setting; a Release build
        // asks the switch, which mirrors what the last launch read out of the store.
        #if DEBUG
        let allowsInspection: BrowserWebViewFactory.InspectionPolicy = { true }
        #else
        let allowsInspection: BrowserWebViewFactory.InspectionPolicy = { inspector.isOn }
        #endif
        let model = BrowserModel(store: BrowserTabStore(store: store),
                                 factory: BrowserWebViewFactory(allowsInspection: allowsInspection))
        return BrowserTab(model: model)
    }

    /// The Browser's `.url` and `.pullRequest` targets, built against the host they are registered
    /// on.
    ///
    /// **The host is captured weakly in both closures.** The registry holds the targets, the host
    /// holds the registry, so a strong capture here would be a cycle from the host back to itself
    /// through its own link router — and a target that outlived the host would be answering for a
    /// window that no longer exists either way.
    ///
    /// **The pull-request resolver reads the channel the click came from** (Q3) — `HostLinkRouter`'s
    /// capture, taken when the action was created and carried with it — rather than a channel cached
    /// when the panel was drawn or the host's selection read when resolution begins. A cached
    /// context is stale in exactly the case that matters, a link arriving before the Browser tab has
    /// ever been rendered; and the live selection is wrong in the other one, because routing
    /// suspends twice before this closure runs and the window can move to another channel in
    /// between — resolving channel A's pull-request number against channel B's repository. The environment `gh` runs under comes with that context — X11's capture, made by
    /// `PanelHostModel.makeContext` out of the workspace's `ResolvedEnvironment` — so the resolver
    /// runs the user's own `gh` through the user's own `PATH` and this file names neither.
    @MainActor
    static func makeLinkTargets(model: BrowserModel, panels: PanelHostModel,
                                runner: any ToolRunning = ToolRunner()) -> [LinkTarget] {
        let resolver = PullRequestURLResolver(runner: runner) { [weak panels] in
            guard let panels, let key = LinkOrigin.channel else { return nil }
            return panels.context(for: key)
        }
        return BrowserLinkTargets.make(model: model,
                                       pullRequests: resolver,
                                       selectBrowserTab: { [weak panels] in panels?.select(.browser) })
    }
}

/// X6's `workbench` store as the Browser sees it, before the app has one.
///
/// The Browser tab is registered in `AppModel.init` — Q4's "once, at tab registration" — and the
/// store a launch reaches only exists at `bindWorkspace`. So the panel is handed this, which is
/// `WorkbenchScopedStore` with its backing store set once a launch has one, and the namespace pin
/// stays in the one type that owns it.
///
/// **Reading nothing before the bind loses nothing.** A panel renders only from a `ChannelContext`,
/// and the call that creates the first context is the same call that binds this — so no read and no
/// write can be asked for while the backing store is absent, and one asked for anyway is answered
/// with an empty document rather than a trap.
///
/// `@unchecked Sendable` is sound because the one mutable field is read and written only inside
/// `lock`, this instance's own `NSLock`.
final class DeferredWorkbenchStore: ScopedStore, @unchecked Sendable {

    private let lock = NSLock()
    private var backing: (any StateStore)?

    /// The launch reached a workspace. Called by `AppModel.bindWorkspace`, which is also what
    /// rebinds the host and the timeline registry to that same workspace.
    func bind(_ store: any StateStore) {
        lock.lock()
        backing = store
        lock.unlock()
    }

    private var scoped: WorkbenchScopedStore? {
        lock.lock()
        defer { lock.unlock() }
        return backing.map { WorkbenchScopedStore(store: $0) }
    }

    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
        guard let scoped else { return nil }
        return try await scoped.read(type, key: key)
    }

    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
        guard let scoped else { return }
        try await scoped.write(value, key: key)
    }

    func remove(key: String) async throws {
        guard let scoped else { return }
        try await scoped.remove(key: key)
    }

    func keys() async throws -> [String] {
        guard let scoped else { return [] }
        return try await scoped.keys()
    }
}

/// Settings' Developer toggle *Web inspector in the Browser panel*, as the thing a web view can ask
/// (Q15), in the shape `RawCaptureSwitch` already takes for *Capture raw frames*.
///
/// The panel's factory reads its policy synchronously, at every `makeWebView`, and a web view being
/// built cannot await the store — so the persisted setting is mirrored here by the launch that read
/// it. That is also why the setting takes effect on the next launch rather than live, which is what
/// the Developer section says of every setting in it except raw capture.
///
/// `@unchecked Sendable` is sound for the same reason it is there: the one mutable field is read
/// and written only inside `lock`.
final class WebInspectorSwitch: @unchecked Sendable {

    private let lock = NSLock()
    private var enabled = false

    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }
}
