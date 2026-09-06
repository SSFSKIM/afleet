import Foundation
import AfleetCore
import ClaudeWire

/// What the lifecycle asks before it spawns, in the spec's order: wedged, contended, managed settings pending,
/// untrusted, consent needed. The first failure is the answer; only `.ready` spawns.
///
/// `evaluate` also decides one thing about the launch. When the launch's setting sources exclude `local`, the
/// rejection gate the engine runs would not read the store a decline was written into, so a declined server would be
/// promoted back to approved — afleet adds `--strict-mcp-config`, which loads no `.mcp.json` server at all, and the
/// header says so (parent §6.12). With no project server loading there is nothing left to consent to, which is why
/// that branch returns `.ready` rather than a sheet.
public struct SpawnPreconditions: Sendable {
    private let settings: LocalSettingsStore
    private let consent: ProjectMCPConsent

    public init(settings: LocalSettingsStore = LocalSettingsStore()) {
        self.settings = settings
        self.consent = ProjectMCPConsent(settings: settings)
    }

    public func evaluate(key: ChannelKey, cwd: URL, launch: LaunchConfiguration,
                         wedged: EscalationTrace?, foreignHolders: [Holder],
                         store: (any StateStore)?) async -> (SpawnPrecondition, LaunchConfiguration) {
        var launch = launch
        if let wedged { return (.wedged(wedged), launch) }
        if !foreignHolders.isEmpty {
            return (.contended(HolderSet(holders: foreignHolders, observedAt: Date())), launch)
        }
        if ManagedSettingsReader.isPending(configHome: key.configHome) {
            return (.managedSettingsPending, launch)
        }
        let project = ProjectRoot.canonical(for: cwd)
        guard TrustReader.isTrusted(root: project.root, configHome: key.configHome) else {
            return (.untrusted(root: project.root), launch)
        }

        let sources = launch.settingSources ?? [.user, .project, .local]
        if !sources.contains(.local), !consent.servers(root: project.root).isEmpty {
            launch.strictMCPConfig = true
            return (.ready, launch)
        }

        let acceptances = (try? await store?.read([ProjectServerAcceptance].self, namespace: .fleetKit,
                                                  key: FleetKitKeys.projectServerAcceptances)) ?? nil
        let verdicts = consent.evaluate(root: project.root, gitRoot: project.gitRoot, cwd: cwd,
                                        configHome: key.configHome, settingSources: launch.settingSources,
                                        acceptances: acceptances ?? [])
        let pending = verdicts.filter { $0.value == .pending }.keys.sorted { $0.name < $1.name }
        guard pending.isEmpty else { return (.consentNeeded(pending), launch) }
        return (.ready, launch)
    }

    /// *Accept* writes nothing into the project. The headless path approves a pending server for the session anyway,
    /// so all that is needed is a record that the sheet was answered — per project, per name, per entry hash.
    public func accept(_ server: ProjectMCPServer, root: URL, store: any StateStore) async throws {
        let key = FleetKitKeys.projectServerAcceptances
        var recorded = try await store.read([ProjectServerAcceptance].self, namespace: .fleetKit, key: key) ?? []
        let entry = ProjectServerAcceptance(projectRoot: RealPath.string(root), serverName: server.name,
                                            entryHash: server.entryHash)
        recorded.removeAll { $0.projectRoot == entry.projectRoot && $0.serverName == entry.serverName }
        recorded.append(entry)
        try await store.write(recorded, namespace: .fleetKit, key: key)
    }

    /// *Decline*: the one §6.12 write. It runs only while no owned process for the project is live — the child would
    /// have loaded the server already, and a `mcp_toggle` after the fact arrives too late — and the store is re-read
    /// through the same resolver, by `evaluate`, before any spawn is allowed.
    @discardableResult
    public func decline(names: [String], cwd: URL, configHome: URL,
                        processIsLive: Bool) throws -> LocalSettingsStore.Resolution {
        guard !processIsLive else {
            throw LifecycleError.declineRefused(reason: LocalSettingsStore.Refusal.processLive.rawValue)
        }
        let project = ProjectRoot.canonical(for: cwd)
        do {
            return try settings.decline(names: names, gitRoot: project.gitRoot, cwd: cwd, configHome: configHome)
        } catch let refusal as LocalSettingsStore.Refusal {
            throw LifecycleError.declineRefused(reason: refusal.rawValue)
        }
    }
}
