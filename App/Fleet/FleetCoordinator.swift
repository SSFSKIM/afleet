import Foundation
import AfleetCore
import FleetKit

/// The composition root's registrar (spec §2 step 9, §3), and Task 3's `NoopWorkspaceCoordinator`
/// replaced by something that does the work.
///
/// Registration is **eager over every listed entry**, which is what spike S-C5-2 measured and
/// promoted. Every entry the `ListingPolicy` lists and whose transcript names a working directory
/// becomes a `Fleet.register(_:cwd:recent:)`, and it happens **before** the model exposes those
/// sessions as rows: `Fleet.events(of:)` returns nil for a key the fleet was never told about, so a
/// row painted ahead of its registration is a row whose live half can never arrive.
///
/// Nothing here reads `state(of:)`. C4 seeds a new supervisor's holders in a detached task, so the
/// answer does not exist yet at the moment `register` returns; the model's `updates` loop is the
/// only feed for the live half, and it is started here.
@MainActor
final class FleetCoordinator: WorkspaceCoordinating {

    let model: FleetBrowserModel

    private let registrar: any ChannelRegistering
    private let index: any IndexAccess
    private let configHome: URL
    /// Where `.claude.json` really is. Carried separately from `configHome` because the two are
    /// different directories on an ordinary installation (`ConfigHome.globalConfig`).
    private let globalConfig: URL
    private let now: @Sendable () -> Date

    /// What each key was last registered with. A re-registration with an unchanged seed is a call
    /// that changes nothing in `Fleet`, so the warm launch's second snapshot — the fresh build
    /// landing on top of the restored one — does not double every registration. A seed that *did*
    /// change (the user moved the project, the channel aged out of the recency window) is registered
    /// again, which is the point of keeping the value rather than a `Set` of keys.
    private var seeds: [ChannelKey: Seed] = [:]

    private struct Seed: Hashable {
        var cwd: URL
        var recent: Bool
    }

    /// The store the persisted `SidebarGrouping` comes from, and the task that loads it. Nil in the
    /// tests that do not care about grouping.
    private let store: (any StateStore)?
    private var groupingLoad: Task<Void, Never>?

    /// Counts only, for the diagnostics line and for Settings (§11).
    private(set) var registeredCount = 0
    /// The listed channels this launch declined to register because their transcript named no
    /// working directory. A **set**, not a running total: a warm launch hands the coordinator the
    /// restored snapshot and then the fresh build, and a `+=` counted the same rows twice and
    /// reported a number the model's own `listedWithoutCWD` disagreed with.
    private var withoutCWD: Set<ChannelKey> = []
    var skippedWithoutCWDCount: Int { withoutCWD.count }

    /// Contract X7's host, so a channel that leaves the index releases the panel sessions it held
    /// (spec §7). Optional because most of this type's tests are about registration and hold no
    /// host; nil means there is nothing to tell, not a wire left off.
    ///
    /// **The forwarding lives here rather than inside the host** because this is the seam the
    /// composition root actually drives. A host that released a removed channel only when a test
    /// called it directly would accumulate a session per removed channel in the running app, each
    /// potentially holding a PTY, and every unit test over the host alone would still be green.
    private let panels: PanelHostModel?

    /// The production initialiser: everything from the workspace the launch resolved.
    convenience init(workspace: Workspace, panels: PanelHostModel? = nil,
                     now: @escaping @Sendable () -> Date = { Date() }) {
        let home = workspace.configHome.root
        self.init(configHome: home,
                  globalConfig: workspace.configHome.globalConfig,
                  registrar: workspace.fleet,
                  index: workspace.index,
                  model: FleetBrowserModel(lifecycle: workspace.fleet, configHome: home, now: now),
                  store: workspace.store,
                  panels: panels,
                  now: now)
    }

    /// The injectable form. The registrar is separate from the lifecycle the model holds because
    /// `register` is not a `LifecycleAPI` member and the test that proves a cold launch registers
    /// every listed channel has to record it somewhere a lifecycle double cannot.
    init(configHome: URL,
         globalConfig: URL? = nil,
         registrar: any ChannelRegistering,
         index: any IndexAccess,
         model: FleetBrowserModel,
         store: (any StateStore)? = nil,
         panels: PanelHostModel? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configHome = configHome
        self.panels = panels
        // The default is the `CLAUDE_CONFIG_DIR` layout, which is what every scratch home in the
        // tests builds. Production never takes it: the convenience initialiser above passes the
        // resolved location.
        self.globalConfig = globalConfig ?? configHome.appending(path: ".claude.json")
        self.registrar = registrar
        self.index = index
        self.model = model
        self.store = store
        self.now = now
        model.startUpdates()
        groupingLoad = Task { [weak self] in await self?.loadGrouping() }
    }

    /// The sidebar's ordering inputs, both read off the main actor and applied when they land.
    ///
    /// Neither is on the launch's critical path. `.claude.json` is a file read and the store is an
    /// actor hop, and the sidebar is correct without either — it falls back to most-recent-activity
    /// order — so making the window wait for them buys nothing. The first version did do this
    /// synchronously inside the initialiser, which put a whole-file scan on the main actor inside
    /// `LaunchSequence.run()`.
    private func loadGrouping() async {
        let document = globalConfig
        let order = await Task.detached(priority: .userInitiated) {
            ClaudeProjects.order(globalConfig: document)
        }.value
        var stored = SidebarGrouping()
        if let store, let persisted = try? await store.read(SidebarGrouping.self,
                                                            namespace: .fleetKit,
                                                            key: FleetKitKeys.grouping) {
            stored = persisted
        }
        guard !Task.isCancelled else { return }
        model.updateGrouping(ProjectGrouping(projectOrder: order, grouping: stored))
    }

    /// Ends the model's `updates` loop and abandons the grouping read.
    func stop() {
        groupingLoad?.cancel()
        groupingLoad = nil
        model.stopUpdates()
    }

    // MARK: - WorkspaceCoordinating

    func snapshotAvailable(_ snapshot: IndexSnapshot, origin: SnapshotOrigin) async {
        let moment = now()
        let listing = ChannelRegistrar.listed(snapshot, configHome: configHome, now: moment)
        await register(listing.rows, at: moment, replacingSkips: true)
        // The listing is handed on rather than recomputed: the model would otherwise run the same
        // join a second time over every entry in the snapshot.
        model.paint(snapshot, listing: listing, origin: origin)
    }

    func indexChanged(_ delta: IndexDelta) async {
        let moment = now()
        var rows: [ChannelRow] = []
        for id in delta.added + delta.updated {
            guard let entry = await index.entry(id) else { continue }
            let decision = ChannelRegistrar.decide(entry)
            guard let mode = decision.listedMode else { continue }
            rows.append(ChannelRegistrar.row(for: entry, configHome: configHome, mode: mode,
                                             rule: decision.rule, now: moment))
        }
        await register(rows, at: moment, replacingSkips: false)
        for id in delta.removed {
            let key = ChannelKey(configHome: configHome, session: id)
            seeds[key] = nil
            withoutCWD.remove(key)
            // The channel left the index, so whatever panel state it held goes now rather than
            // waiting for sixteen further channels of LRU pressure (spec §7).
            panels?.releaseChannel(key)
        }
        await model.apply(delta) { [index] id in await index.entry(id) }
    }

    // MARK: - Registration

    /// `replacingSkips` is true for a snapshot, which is the whole picture, and false for a delta,
    /// which is a patch on it.
    private func register(_ rows: [ChannelRow], at moment: Date, replacingSkips: Bool) async {
        var fresh: [ChannelRow] = []
        if replacingSkips { withoutCWD = [] }
        for row in rows {
            guard let cwd = row.cwd else {
                withoutCWD.insert(row.key)
                continue
            }
            withoutCWD.remove(row.key)
            let seed = Seed(cwd: cwd, recent: ChannelRegistrar.isRecent(row.mtime, now: moment))
            guard seeds[row.key] != seed else { continue }
            seeds[row.key] = seed
            fresh.append(row)
        }
        let report = await ChannelRegistrar.register(fresh, into: registrar, now: moment)
        registeredCount += report.registered
    }
}
