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

    /// `configHome` is the launch's own home record, and the trust read needs the record rather than
    /// `key.configHome`'s bare root: the global config document sits inside the home only when
    /// `CLAUDE_CONFIG_DIR` named it, and beside it otherwise (`ConfigHome.globalConfig`).
    public func evaluate(key: ChannelKey, cwd: URL, launch: LaunchConfiguration, configHome: ConfigHome,
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
        // **Trust on the trust key, project servers on the checkout.** A linked worktree's two roots
        // are two directories: the repository is what `hasTrustDialogAccepted` is keyed on, and the
        // checkout is what the engine reads `.mcp.json` from (see `ProjectRoots`). The local
        // settings store — where a decline lands and where the rejection gate reads — is the trust
        // key's, because that is the write target §6.12 names.
        let project = ProjectRoot.roots(for: cwd)
        guard TrustReader.isTrusted(root: project.trustKey, globalConfig: configHome.globalConfig) else {
            return (.untrusted(root: project.trustKey), launch)
        }

        let sources = launch.settingSources ?? [.user, .project, .local]
        if !sources.contains(.local), !consent.servers(root: project.checkout).isEmpty {
            launch.strictMCPConfig = true
            return (.ready, launch)
        }

        let acceptances = (try? await store?.read([ProjectServerAcceptance].self, namespace: .fleetKit,
                                                  key: FleetKitKeys.projectServerAcceptances)) ?? nil
        let verdicts = consent.evaluate(root: project.checkout, gitRoot: project.trustKey, cwd: cwd,
                                        configHome: key.configHome, settingSources: launch.settingSources,
                                        acceptances: acceptances ?? [])
        let pending = verdicts.filter { $0.value == .pending }.keys.sorted { $0.name < $1.name }
        // The evaluated directory, not the canonical root: it is the one the decline's own resolver
        // takes, and it is what a caller must answer against for the write to land where this read
        // looked.
        guard pending.isEmpty else { return (.consentNeeded(project: cwd, servers: pending), launch) }
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
        // The trust key: §6.12's write target is the repository's `.claude/settings.local.json`, the
        // same file the rejection gate reads, and a worktree's decline that landed in the checkout
        // would be read by nobody.
        let project = ProjectRoot.roots(for: cwd)
        do {
            return try settings.decline(names: names, gitRoot: project.trustKey, cwd: cwd,
                                        configHome: configHome)
        } catch let refusal as LocalSettingsStore.Refusal {
            throw LifecycleError.declineRefused(reason: refusal.rawValue)
        }
    }
}
