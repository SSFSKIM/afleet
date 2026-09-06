import Foundation
import ClaudeWire
import FleetKit

/// Spec §2's launch, with every external call behind an injectable seam.
///
/// The order is the spec's and is not negotiable: environment, config home, **the write-root
/// overlap check**, store, binary, version, index, fleet, registration, watcher. The binary probe
/// runs under the resolved environment because `claude` is commonly a launcher script with
/// `#!/usr/bin/env node` and would fail under the GUI's own PATH — `VersionGate.check`'s doc
/// comment records that mistake having been made twice.
///
/// Step 11 of §2, consuming `LifecycleAPI.updates` into the sidebar, is deliberately not here: it
/// is the sidebar model's loop and belongs with the model that owns it (Task 5), which reaches the
/// fleet through `Workspace`.
///
/// Every seam is a stored closure rather than a protocol because the assertions the tests need are
/// about calls that must *not* happen. "No `Fleet` was ever constructed" is only assertable if
/// constructing one is something a recording closure can decline to do.
struct LaunchSequence: Sendable {

    // MARK: - The two write roots

    /// `~/Library/Application Support/afleet`, the state store's.
    var storeRoot: URL
    /// `~/Library/Logs/afleet`, the three diagnostics sinks'.
    var diagnosticsRoot: URL

    // MARK: - Seams

    var resolveEnvironment: @Sendable () async -> ResolvedEnvironment
    var locateBinary: @Sendable (ResolvedEnvironment, URL?) -> URL?
    var checkVersion: @Sendable (URL, ResolvedEnvironment) async -> VersionVerdict
    var makeStore: @Sendable (URL, [URL]) throws -> any StateStore
    var makeDiagnostics: @Sendable (URL) -> DiagnosticsComposer
    var makeIndex: @Sendable (ConfigHome, any StateStore, DiagnosticsComposer) -> any IndexAccess
    var fleetFactory: @Sendable (ConfigHome, ResolvedEnvironment, URL, any StateStore, URL) -> any AppFleet
    var makeWatcher: @Sendable (ConfigHome) -> any TranscriptWatching
    /// The global config document's `hasCompletedOnboarding`. It takes the whole `ConfigHome` and
    /// not its root, because where that document lives depends on how the root was derived.
    var readClaudeJSON: @Sendable (ConfigHome) -> Bool
    var makeCoordinator: @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating

    init(storeRoot: URL = LaunchSequence.defaultStoreRoot,
         diagnosticsRoot: URL = LaunchSequence.defaultDiagnosticsRoot,
         resolveEnvironment: @escaping @Sendable () async -> ResolvedEnvironment = LaunchSequence.resolveLoginShellEnvironment,
         locateBinary: @escaping @Sendable (ResolvedEnvironment, URL?) -> URL? = { BinaryLocator.locate(in: $0, override: $1) },
         checkVersion: @escaping @Sendable (URL, ResolvedEnvironment) async -> VersionVerdict = { await VersionGate().check(binary: $0, environment: $1) },
         makeStore: @escaping @Sendable (URL, [URL]) throws -> any StateStore = { try FileStateStore(baseDirectory: $0, configHomes: $1) },
         makeDiagnostics: @escaping @Sendable (URL) -> DiagnosticsComposer = { DiagnosticsComposer(directory: $0) },
         makeIndex: @escaping @Sendable (ConfigHome, any StateStore, DiagnosticsComposer) -> any IndexAccess = LaunchSequence.makeTranscriptIndex,
         fleetFactory: @escaping @Sendable (ConfigHome, ResolvedEnvironment, URL, any StateStore, URL) -> any AppFleet = LaunchSequence.makeFleet,
         makeWatcher: @escaping @Sendable (ConfigHome) -> any TranscriptWatching = { TranscriptWatcher(configHome: $0.root) },
         readClaudeJSON: @escaping @Sendable (ConfigHome) -> Bool = { ClaudeJSONReader.hasCompletedOnboarding(in: $0) },
         makeCoordinator: @escaping @MainActor @Sendable (Workspace) -> any WorkspaceCoordinating = { _ in NoopWorkspaceCoordinator() }) {
        self.storeRoot = storeRoot
        self.diagnosticsRoot = diagnosticsRoot
        self.resolveEnvironment = resolveEnvironment
        self.locateBinary = locateBinary
        self.checkVersion = checkVersion
        self.makeStore = makeStore
        self.makeDiagnostics = makeDiagnostics
        self.makeIndex = makeIndex
        self.fleetFactory = fleetFactory
        self.makeWatcher = makeWatcher
        self.readClaudeJSON = readClaudeJSON
        self.makeCoordinator = makeCoordinator
    }

    // MARK: - Production seams

    static let defaultStoreRoot: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "afleet", directoryHint: .isDirectory)

    static let defaultDiagnosticsRoot: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/afleet", directoryHint: .isDirectory)

    /// §6.9, X11: the login shell, captured once per launch and handed to everything below.
    static let resolveLoginShellEnvironment: @Sendable () async -> ResolvedEnvironment = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return await EnvironmentResolver().resolve(shell: shell)
    }

    static let makeTranscriptIndex: @Sendable (ConfigHome, any StateStore, DiagnosticsComposer) -> any IndexAccess = { home, store, diagnostics in
        TranscriptIndex(configHome: home,
                        storage: StoreIndexStorage(store: store),
                        diagnostics: diagnostics.timeline)
    }

    static let makeFleet: @Sendable (ConfigHome, ResolvedEnvironment, URL, any StateStore, URL) -> any AppFleet = { home, environment, binary, store, diagnosticsRoot in
        Fleet(configHome: home, environment: environment, binary: binary, store: store,
              diagnosticsDirectory: diagnosticsRoot)
    }

    // MARK: - The launch

    func run() async -> AppRoute {
        // 1. The login shell's environment, once.
        let environment = await resolveEnvironment()

        // 2. CLAUDE_CONFIG_DIR when set, else <HOME>/.claude.
        let configHome = ConfigHome.derive(from: environment)

        // 3. The write-root overlap check, ahead of everything that writes. `FileStateStore`'s
        //    `configHomes:` guard covers the store alone, and `Fleet` builds its two diagnostics
        //    sinks itself, eagerly and unguarded, so a home that contains either root has to be
        //    refused here or not at all (X9).
        if let collision = Self.overlappingWriteRoot(configHome: configHome.root,
                                                     storeRoot: storeRoot,
                                                     diagnosticsRoot: diagnosticsRoot) {
            return .setup(.writeRootInsideConfigHome(root: collision, configHome: configHome.root))
        }

        // 4. The store. Its `configHomes:` argument is the X9 guard and is never an empty array.
        let store: any StateStore
        do {
            store = try makeStore(storeRoot, [configHome.root])
        } catch {
            return .setup(.storeUnavailable(reason: Self.shape(of: error)))
        }
        let settings = await AfleetSettingsStore.read(from: store)

        // 5. The engine binary, with the Developer override ahead of the captured PATH.
        guard let binary = locateBinary(environment, settings.developer.overrideURL) else {
            return .setup(.engineMissing)
        }

        // 6. The version gate, probed under the resolved environment.
        let installed: SemanticVersion
        switch await checkVersion(binary, environment) {
        case .accepted(let version):
            installed = version
        case .tooOld(let found, let baseline):
            return .upgrade(installed: found, baseline: baseline)
        case .unparseable(let output):
            return .setup(.engineUnreadable(output: output))
        }

        // The sign-in gate. A home whose `.claude.json` does not report a completed onboarding has
        // no account behind it, and every spawn below would fail at the handshake.
        guard readClaudeJSON(configHome) else {
            return .setup(.notSignedIn(configHome: configHome.root))
        }

        let diagnostics = makeDiagnostics(diagnosticsRoot)

        // 7. C3's index over this home, persisting through the store.
        let index = makeIndex(configHome, store, diagnostics)

        // 8. The fleet.
        let fleet = fleetFactory(configHome, environment, binary, store, diagnosticsRoot)
        await fleet.start()

        // 10. The watcher, unless the Developer toggle left it stopped (item 56). Its single
        //     `changes` stream is fanned out at once: the index is one consumer and Task 7's
        //     `StreamIngestion.fileChanged(_:)` is the other, and a second `for await` on one
        //     `AsyncStream` splits the batches rather than duplicating them.
        var watcher: (any TranscriptWatching)?
        var changes: TranscriptChangeFeed?
        if !settings.developer.transcriptWatcherStopped {
            let candidate = makeWatcher(configHome)
            // An unwatchable `projects/` is not a reason to refuse the workspace: the list is
            // simply not live until the next launch.
            if (try? candidate.start()) != nil {
                watcher = candidate
                changes = TranscriptChangeFeed(source: candidate.changes)
            }
        }

        let workspace = Workspace(configHome: configHome, environment: environment, binary: binary,
                                  installed: installed, store: store, index: index, fleet: fleet,
                                  watcher: watcher, changes: changes, diagnostics: diagnostics)

        // 9. Registration, through the coordinator seam, at all three points.
        let coordinator = await makeCoordinator(workspace)

        if let restored = try? await index.loadPersisted() {
            await coordinator.snapshotAvailable(restored, origin: .restored)
        }

        // Detached, because C3 measured that a build awaited from a main-actor-bound caller runs
        // at about a third of the machine's width. The cold case runs through here too: with no
        // persisted snapshot the coordinator hears about the fleet's channels for the first time
        // when this lands, which is what keeps a first-ever launch from finishing with zero
        // registered supervisors.
        Task.detached(priority: .userInitiated) {
            guard let built = try? await index.build() else { return }
            await coordinator.snapshotAvailable(built, origin: .built)
            try? await index.persist()
        }

        if let changes {
            // `changes.changes` is the feed's primary subscription and was created by its
            // initialiser, so it has been collecting since before the feed read anything. Starting
            // the pump is the last thing the launch does, which is what lets every batch the
            // watcher produced during startup reach the index.
            let subscription = changes.changes
            // `.userInitiated`, not `.utility`. This pump is the only thing keeping the sidebar in
            // step with the filesystem, so its latency is a latency the user sees; the utility lane
            // is for work nobody is waiting on, and somebody is always waiting on this. Do not
            // lower it for tidiness — a starved pump does not report a slow sidebar, it reports
            // nothing at all, which is why the stall notice below exists as well.
            let appDiagnostics = diagnostics.app
            Task.detached(priority: .userInitiated) {
                for await batch in subscription {
                    // A report, never a gate: computed after the batch is in hand, written from a
                    // queue of its own, and nothing here waits on it or fails because of it.
                    if let notice = TranscriptChangePump.notice(for: batch) {
                        appDiagnostics.record(notice)
                    }
                    let delta = await index.update(changed: batch.paths)
                    await coordinator.indexChanged(delta)
                }
            }
            await changes.start()
        }

        return .workspace(workspace)
    }

    // MARK: - The overlap check

    /// The write root that is the config home or lies beneath it, or nil when neither does.
    ///
    /// Every path is canonicalised first, because `CLAUDE_CONFIG_DIR` is an arbitrary string and
    /// `~/Library/Logs`, `/Users/x/../x/Library/Logs` and a symlink to either all name one
    /// directory. The store root is checked first only so the report is stable; a home that
    /// contains both is a collision either way.
    static func overlappingWriteRoot(configHome: URL, storeRoot: URL, diagnosticsRoot: URL) -> WriteRoot? {
        let home = CanonicalPath.string(configHome)
        for (root, path) in [(WriteRoot.store, storeRoot), (WriteRoot.diagnostics, diagnosticsRoot)] {
            let candidate = CanonicalPath.string(path)
            if candidate == home || candidate.hasPrefix(home + "/") { return root }
        }
        return nil
    }

    /// An error's kind and nothing else. `StoreError` is already path-free by construction; anything
    /// else is reported by its type name rather than by its description, which on a Foundation error
    /// carries the path it failed on.
    static func shape(of error: any Error) -> String {
        if let store = error as? StoreError { return String(describing: store) }
        return String(describing: type(of: error))
    }
}

/// `realpath(3)` over as much of a path as exists, with the components that do not yet exist put
/// back on the end. The two write roots are usually absent on a first launch, so resolving only an
/// existing path would leave the check comparing an unresolved string against a resolved one.
enum CanonicalPath {
    static func string(_ url: URL) -> String {
        var trailing: [String] = []
        var probe = url.standardizedFileURL.path
        while true {
            if let resolved = realpath(probe, nil) {
                var out = String(cString: resolved)
                free(resolved)
                for component in trailing.reversed() {
                    out = (out as NSString).appendingPathComponent(component)
                }
                return out
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { return url.standardizedFileURL.path }
            trailing.append((probe as NSString).lastPathComponent)
            probe = parent
        }
    }
}

extension ConfigHome {
    /// Where `.claude.json` actually is, which is **not** always inside the config home.
    ///
    /// The engine resolves it as `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")` —
    /// 2.1.263 `cli.pretty.js:298330`, `Ot(e) { return { globalConfig: Xe(e || Mt(), ".claude.json"), … } }`
    /// with `Mt` bound to `os.homedir`. The config home is `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")`
    /// — a *different* expression — so the two coincide only when the variable is set. With it
    /// unset, which is the ordinary installation, the config home is `~/.claude` and the document
    /// is its sibling `~/.claude.json`, and `<configHome>/.claude.json` names a file that has
    /// never existed.
    ///
    /// `ConfigHome.source` already records which of the two derivations produced the root, so this
    /// needs nothing from the environment a second time.
    var globalConfig: URL {
        switch source {
        case .environment: root.appending(path: ".claude.json")
        case .default: root.deletingLastPathComponent().appending(path: ".claude.json")
        }
    }
}

/// The engine's global config document, read and never written (X9).
///
/// The reading approach is `TrustReader`'s — the same file, opened for reading and taken apart with
/// `JSONSerialization` rather than through a second `Codable` model of a document afleet does not
/// own. The one difference is the descriptor: this opens with `O_NOFOLLOW`, so a `.claude.json`
/// that is a symlink is refused rather than followed out of the home.
enum ClaudeJSONReader {
    /// True only for an explicit `hasCompletedOnboarding: true`. A missing file, a missing key, an
    /// explicit `false` and a non-boolean are all "not signed in".
    static func hasCompletedOnboarding(in configHome: ConfigHome) -> Bool {
        guard let data = read(configHome.globalConfig),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return document["hasCompletedOnboarding"] as? Bool == true
    }

    /// Internal rather than private since Task 4: `ClaudeProjects` reads the same file for the
    /// sidebar's section order and must open it the same guarded way — read-only, `O_NOFOLLOW`, so
    /// a `.claude.json` that is a symlink is refused rather than followed out of the home (X9).
    static func read(_ url: URL) -> Data? {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }
}
