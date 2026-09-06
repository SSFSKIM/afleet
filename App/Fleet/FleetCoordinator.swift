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
    private let now: @Sendable () -> Date

    /// What each key was last registered with. A re-registration with an unchanged seed is a call
    /// that changes nothing in `Fleet`, so the warm launch's second snapshot — the fresh build
    /// landing on top of the restored one — does not double every registration. A seed that *did*
    /// change (the user moved the project, the channel aged out of the recency window) is registered
    /// again, which is the point of keeping the value rather than a `Set` of keys.
    private var seeds: [ChannelKey: Seed] = [:]
    private var hasPainted = false

    private struct Seed: Hashable {
        var cwd: URL
        var recent: Bool
    }

    /// Counts only, for the diagnostics line and for Settings (§11).
    private(set) var registeredCount = 0
    private(set) var skippedWithoutCWDCount = 0

    /// The production initialiser: everything from the workspace the launch resolved.
    convenience init(workspace: Workspace, now: @escaping @Sendable () -> Date = { Date() }) {
        let home = workspace.configHome.root
        self.init(configHome: home,
                  registrar: workspace.fleet,
                  index: workspace.index,
                  model: FleetBrowserModel(lifecycle: workspace.fleet,
                                           configHome: home,
                                           grouping: ProjectGrouping(projectOrder: ClaudeProjects.order(configHome: home)),
                                           now: now),
                  now: now)
    }

    /// The injectable form. The registrar is separate from the lifecycle the model holds because
    /// `register` is not a `LifecycleAPI` member and the test that proves a cold launch registers
    /// every listed channel has to record it somewhere a lifecycle double cannot.
    init(configHome: URL,
         registrar: any ChannelRegistering,
         index: any IndexAccess,
         model: FleetBrowserModel,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configHome = configHome
        self.registrar = registrar
        self.index = index
        self.model = model
        self.now = now
        model.startUpdates()
    }

    // MARK: - WorkspaceCoordinating

    func snapshotAvailable(_ snapshot: IndexSnapshot) async {
        let moment = now()
        let listing = ChannelRegistrar.listed(snapshot, configHome: configHome, now: moment)
        await register(listing.rows, at: moment)
        if hasPainted {
            model.apply(snapshot)
        } else {
            hasPainted = true
            model.restore(from: snapshot)
        }
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
        await register(rows, at: moment)
        for id in delta.removed { seeds[ChannelKey(configHome: configHome, session: id)] = nil }
        await model.apply(delta) { [index] id in await index.entry(id) }
    }

    // MARK: - Registration

    private func register(_ rows: [ChannelRow], at moment: Date) async {
        var fresh: [ChannelRow] = []
        for row in rows {
            guard let cwd = row.cwd else {
                skippedWithoutCWDCount += 1
                continue
            }
            let seed = Seed(cwd: cwd, recent: ChannelRegistrar.isRecent(row.mtime, now: moment))
            guard seeds[row.key] != seed else { continue }
            seeds[row.key] = seed
            fresh.append(row)
        }
        let report = await ChannelRegistrar.register(fresh, into: registrar, now: moment)
        registeredCount += report.registered
    }
}
