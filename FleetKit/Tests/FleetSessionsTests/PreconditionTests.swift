import XCTest
import Foundation
import Darwin
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// G3. The spawn preconditions, and the one Claude Code-owned file afleet writes.
///
/// Every test here works under a temporary project directory it creates. The scratch config home is a directory of
/// the test's own too: nothing under `~/.claude`, `$CLAUDE_CONFIG_DIR` or `/tmp/afleet-fixtures/config-home` is
/// created, edited or removed by anything in this file (parent X9), and `ScratchConfigHome` refuses to be built
/// under any of the three.
final class PreconditionTests: XCTestCase {
    private var projects: [TemporaryProject] = []
    private var homes: [ScratchConfigHome] = []
    private var rigs: [Rig] = []
    private var stores: [URL] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
        for project in projects { project.remove() }
        projects = []
        for home in homes { home.removeAll() }
        homes = []
        for directory in stores { try? FileManager.default.removeItem(at: directory) }
        stores = []
    }

    // MARK: - Fixtures

    private func newProject(git: Bool = true) throws -> TemporaryProject {
        let project = try TemporaryProject(git: git)
        projects.append(project)
        return project
    }

    private func newHome() throws -> ScratchConfigHome {
        let home = try ScratchConfigHome()
        homes.append(home)
        return home
    }

    private func newStore(home: ScratchConfigHome) throws -> FileStateStore {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-store-\(UUID().uuidString)")
        stores.append(directory)
        return try FileStateStore(baseDirectory: directory, configHomes: [home.url])
    }

    private func newRig() throws -> Rig {
        let rig = try Rig()
        rigs.append(rig)
        return rig
    }

    /// A launch whose only interesting field is the cwd and the setting sources.
    private func launch(cwd: URL, sources: [SettingSource]? = nil) -> LaunchConfiguration {
        LaunchConfiguration(binary: FakeClaudeLaunch.binary, cwd: cwd, session: .new(SessionID()),
                            settingSources: sources)
    }

    private func verdict(_ map: [ProjectMCPServer: ServerVerdict], _ name: String) -> ServerVerdict? {
        map.first { $0.key.name == name }?.value
    }

    private func server(_ map: [ProjectMCPServer: ServerVerdict], _ name: String) -> ProjectMCPServer? {
        map.first { $0.key.name == name }?.key
    }

    /// A directory outside the project a symlink test points into, and which the test then proves untouched.
    private func newOutsideDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        stores.append(url)
        return URL(filePath: TemporaryProject.realpath(url), directoryHint: .isDirectory)
    }

    private func mode(of file: URL) -> mode_t? {
        var st = stat()
        guard lstat(file.path(percentEncoded: false), &st) == 0 else { return nil }
        return st.st_mode & 0o7777
    }

    // MARK: - Trust and the canonical root

    /// The canonical root is the *real* path walked up to the first entry holding `.git`. Real, because `/tmp` is a
    /// symlink to `/private/tmp` on macOS: a root spelled one way and a config home spelled the other are the same
    /// directory, and every containment and trust decision below compares these strings.
    func testCanonicalRootIsTheRealPathWalkedUpToGit() throws {
        let project = try newProject()
        let nested = project.root.appending(path: "a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let walked = ProjectRoot.canonical(for: nested)
        XCTAssertEqual(walked.root.path(percentEncoded: false), TemporaryProject.realpath(project.root))
        XCTAssertEqual(walked.gitRoot?.path(percentEncoded: false), TemporaryProject.realpath(project.root))

        let plain = try newProject(git: false)
        let alone = ProjectRoot.canonical(for: plain.root)
        XCTAssertEqual(alone.root.path(percentEncoded: false), TemporaryProject.realpath(plain.root))
        XCTAssertNil(alone.gitRoot, "no `.git` above it, so the root is the directory itself")

        // The `/tmp` case, which a `standardizedFileURL` would get wrong: it rewrites `/private/var` back to `/var`
        // and undoes exactly the resolution this call exists to do.
        let underTmp = URL(filePath: "/tmp").appending(path: "afleet-c4-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: underTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: underTmp) }
        let resolved = ProjectRoot.canonical(for: underTmp)
        XCTAssertEqual(resolved.root.path(percentEncoded: false), TemporaryProject.realpath(underTmp))
        XCTAssertTrue(resolved.root.path(percentEncoded: false).hasPrefix("/private/tmp/"),
                      "the real path, not the `/tmp` spelling: \(resolved.root.path(percentEncoded: false))")
        XCTAssertEqual(underTmp.resolvingSymlinksInPath().path(percentEncoded: false),
                       underTmp.path(percentEncoded: false),
                       "`resolvingSymlinksInPath` hands the `/tmp` spelling straight back, which is the trap")
    }

    /// Anything but `hasTrustDialogAccepted: true` is untrusted, and an untrusted project renders history only.
    func testUntrustedRootYieldsHistoryOnly() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        let preconditions = SpawnPreconditions()
        let key = ChannelKey(configHome: home.url, session: SessionID())
        let witness = TreeWitness(project.root)

        var (missing, _) = await preconditions.evaluate(key: key, cwd: project.root,
                                                        launch: launch(cwd: project.root), wedged: nil,
                                                        foreignHolders: [], store: store)
        XCTAssertEqual(missing, .untrusted(root: URL(filePath: TemporaryProject.realpath(project.root))))

        try home.setTrust(root: project.root, false)
        (missing, _) = await preconditions.evaluate(key: key, cwd: project.root,
                                                    launch: launch(cwd: project.root), wedged: nil,
                                                    foreignHolders: [], store: store)
        guard case .untrusted = missing else { return XCTFail("an explicit false is untrusted, not \(missing)") }

        try home.trust(root: project.root)
        let (ready, _) = await preconditions.evaluate(key: key, cwd: project.root,
                                                      launch: launch(cwd: project.root), wedged: nil,
                                                      foreignHolders: [], store: store)
        XCTAssertEqual(ready, .ready, "a trusted project with no `.mcp.json` passes to the next check")
        witness.assertUnchanged("the project tree across the trust reads")
    }

    // MARK: - Consent

    /// Consent is the engine's own decision, and the engine reads the *merged effective settings* — the local store,
    /// the project settings file and the user settings file, each only when the launch's sources include it. The
    /// `.claude.json` project entry carries identically-named arrays and is never consulted: the startup migration
    /// copies them into local settings and empties them, so a host reading them sees a file the engine has already
    /// cleared (spec *Preconditions*, bundle 2.1.257 `cli.pretty.js` chunk `1kg58a1a`, pretty lines 94640-94682 and
    /// 503739-503785; C1's spike confirms the write side).
    func testConsentIsComputedFromTheMergedSettingsOnlyReadOnly() async throws {
        let home = try newHome()
        let project = try newProject()
        try home.trust(root: project.root)
        try project.writeMCPJSON([
            "a": ["command": "/usr/bin/true"], "b": ["command": "/usr/bin/true"],
            "c": ["command": "/usr/bin/true"], "d": ["command": "/usr/bin/true"],
            "e": ["command": "/usr/bin/true"],
        ])
        try project.writeLocalSettings(["disabledMcpjsonServers": ["a"]])
        try project.writeProjectSettings(["enabledMcpjsonServers": ["b"]])
        try JSONSerialization.data(withJSONObject: ["enabledMcpjsonServers": ["c"]], options: [.sortedKeys])
            .write(to: home.url.appending(path: "settings.json"))
        try home.setProjectEntry(root: project.root, ["disabledMcpjsonServers": ["d"],
                                                      "enabledMcpjsonServers": ["e"]])

        let homeWitness = TreeWitness(home.url)
        let consent = ProjectMCPConsent()
        let root = ProjectRoot.canonical(for: project.root)

        var verdicts = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root,
                                        configHome: home.url, settingSources: nil, acceptances: [])
        XCTAssertEqual(verdict(verdicts, "a"), .rejected(.localSettings))
        XCTAssertEqual(verdict(verdicts, "b"), .approved(.projectSettings))
        XCTAssertEqual(verdict(verdicts, "c"), .approved(.userSettings))
        XCTAssertEqual(verdict(verdicts, "d"), .pending, "the `.claude.json` entry's disabled array is not read")
        XCTAssertEqual(verdict(verdicts, "e"), .pending, "nor is its enabled array")

        try project.writeProjectSettings(["enabledMcpjsonServers": ["b"], "enableAllProjectMcpServers": true])
        verdicts = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root,
                                    configHome: home.url, settingSources: nil, acceptances: [])
        XCTAssertEqual(verdict(verdicts, "d"), .approved(.projectSettings))
        XCTAssertEqual(verdict(verdicts, "e"), .approved(.projectSettings))

        try project.writeProjectSettings(["enabledMcpjsonServers": ["b"]])
        verdicts = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root,
                                    configHome: home.url, settingSources: [.local, .project], acceptances: [])
        XCTAssertEqual(verdict(verdicts, "c"), .pending, "the user settings source is off for this launch")

        // Rejected wins over approved, whichever source approved it.
        try project.writeLocalSettings(["disabledMcpjsonServers": ["a", "b"]])
        let projectWitness = TreeWitness(project.root)
        verdicts = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root,
                                    configHome: home.url, settingSources: nil, acceptances: [])
        XCTAssertEqual(verdict(verdicts, "b"), .rejected(.localSettings))

        projectWitness.assertUnchanged("the project tree across an evaluation")
        homeWitness.assertUnchanged("the scratch config home across every evaluation")
    }

    /// *Accept* writes nothing into the project: it records `(root, name, hash)` in FleetKit's own store, and the
    /// hash is over the whole raw entry, so a changed command or a changed env reopens the sheet.
    func testAcceptRecordsTheHashAndDoesNotRepeatUntilTheEntryChanges() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        try home.trust(root: project.root)
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])

        let preconditions = SpawnPreconditions()
        let consent = ProjectMCPConsent()
        let root = ProjectRoot.canonical(for: project.root)
        func now(_ acceptances: [ProjectServerAcceptance]) -> [ProjectMCPServer: ServerVerdict] {
            consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root, configHome: home.url,
                             settingSources: nil, acceptances: acceptances)
        }

        let pending = try XCTUnwrap(server(now([]), "d"))
        XCTAssertEqual(verdict(now([]), "d"), .pending)

        let witness = TreeWitness(project.root)
        try await preconditions.accept(pending, root: root.root, store: store)
        witness.assertUnchanged("the project tree across an accept")

        let recorded = try await store.read([ProjectServerAcceptance].self, namespace: .fleetKit,
                                            key: FleetKitKeys.projectServerAcceptances) ?? []
        XCTAssertEqual(recorded, [ProjectServerAcceptance(projectRoot: root.root.path(percentEncoded: false),
                                                          serverName: "d", entryHash: pending.entryHash)])
        XCTAssertEqual(verdict(now(recorded), "d"), .approved(.acceptance))

        try project.writeMCPJSON(["d": ["command": "/usr/bin/false"]])
        XCTAssertEqual(verdict(now(recorded), "d"), .pending, "a changed command reopens consent")

        try project.writeMCPJSON(["d": ["command": "/usr/bin/true", "env": ["K": "v"]]])
        XCTAssertEqual(verdict(now(recorded), "d"), .pending, "and so does a changed env")

        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])
        XCTAssertEqual(verdict(now(recorded), "d"), .approved(.acceptance), "the original entry is still accepted")
    }

    /// The three shapes bundle 38223 admits, plus one it does not: every entry is listed and every entry is gated,
    /// and consent is per *name*, identical across transports.
    func testProjectServersOfEveryTransportAreListedAndConsentIsPerName() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        try home.trust(root: project.root)
        try project.writeMCPJSON([
            "s": ["command": "npx", "args": ["-y", "@example/s"]],
            "h": ["type": "http", "url": "https://example.invalid/mcp"],
            "e": ["type": "sse", "url": "https://example.invalid/sse"],
        ])

        let preconditions = SpawnPreconditions()
        let consent = ProjectMCPConsent()
        let root = ProjectRoot.canonical(for: project.root)
        func now(_ acceptances: [ProjectServerAcceptance]) -> [ProjectMCPServer: ServerVerdict] {
            consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root, configHome: home.url,
                             settingSources: nil, acceptances: acceptances)
        }

        let verdicts = now([])
        XCTAssertEqual(verdicts.count, 3)
        XCTAssertEqual(Set(verdicts.values.map { $0 == .pending }), [true], "all three are pending")
        XCTAssertEqual(server(verdicts, "s")?.transport, .stdio(command: "npx", arguments: ["-y", "@example/s"]))
        XCTAssertEqual(server(verdicts, "h")?.transport, .http(url: "https://example.invalid/mcp"))
        XCTAssertEqual(server(verdicts, "e")?.transport, .sse(url: "https://example.invalid/sse"))

        let http = try XCTUnwrap(server(verdicts, "h"))
        try await preconditions.accept(http, root: root.root, store: store)
        var recorded = try await store.read([ProjectServerAcceptance].self, namespace: .fleetKit,
                                            key: FleetKitKeys.projectServerAcceptances) ?? []
        XCTAssertEqual(verdict(now(recorded), "h"), .approved(.acceptance))

        try project.writeMCPJSON([
            "s": ["command": "npx", "args": ["-y", "@example/s"]],
            "h": ["type": "http", "url": "https://example.invalid/other"],
            "e": ["type": "sse", "url": "https://example.invalid/sse"],
        ])
        XCTAssertEqual(verdict(now(recorded), "h"), .pending, "the hash covers the url as well")

        _ = try preconditions.decline(names: ["e"], cwd: project.root, configHome: home.url, processIsLive: false)
        let disabled = try project.localSettingsObject()["disabledMcpjsonServers"] as? [String]
        XCTAssertEqual(disabled, ["e"], "the consent file holds names, the same array for every transport")
        recorded = try await store.read([ProjectServerAcceptance].self, namespace: .fleetKit,
                                        key: FleetKitKeys.projectServerAcceptances) ?? []
        XCTAssertEqual(verdict(now(recorded), "e"), .rejected(.localSettings))

        try project.writeMCPJSON(["w": ["type": "websocket", "url": "wss://example.invalid/ws"]])
        let odd = now([])
        XCTAssertEqual(server(odd, "w")?.transport, .other(type: "websocket"))
        XCTAssertEqual(verdict(odd, "w"), .pending, "an unknown transport is listed and gated like the rest")
    }

    // MARK: - The one §6.12 write

    /// The file and the key C1's spike recorded the terminal's own dialog writing, and every other byte of the file
    /// left exactly as it was: the CLI keeps entries this build does not recognise, so the writer splices the one
    /// array's text rather than re-serialising the document.
    func testDeclineWritesThroughTheCLIsOwnPolicy() throws {
        let home = try newHome()
        let project = try newProject()
        let raw = "{\n  \"zeta\": 1,\n  \"alpha\": {\"x\": [1,2]},\n  \"disabledMcpjsonServers\": [\"old\"]\n}\n"
        try project.writeLocalSettingsRaw(raw)
        let beforeListing = try XCTUnwrap(TreeDigest.listing(of: project.root.appending(path: ".claude")))

        let store = LocalSettingsStore()
        _ = try store.decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)

        let after = try project.localSettingsRaw()
        XCTAssertEqual(try project.localSettingsObject()["disabledMcpjsonServers"] as? [String], ["old", "d"])
        XCTAssertTrue(after.contains("\"zeta\": 1"), "the raw text of every other key is untouched: \(after)")
        XCTAssertTrue(after.contains("\"alpha\": {\"x\": [1,2]}"), "including its whitespace: \(after)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.stagingDirectory.path(percentEncoded: false)),
                       "the staging directory is gone")
        XCTAssertEqual(TreeDigest.listing(of: project.root.appending(path: ".claude")), beforeListing)

        // A missing file is created, 0o644, with the single key.
        let fresh = try newProject()
        _ = try store.decline(names: ["d"], gitRoot: fresh.root, cwd: fresh.root, configHome: home.url)
        XCTAssertEqual(try fresh.localSettingsObject()["disabledMcpjsonServers"] as? [String], ["d"])
        XCTAssertEqual(try fresh.localSettingsObject().count, 1)
        XCTAssertEqual(mode(of: fresh.localSettingsFile), 0o644)
        XCTAssertEqual(TreeDigest.listing(of: fresh.root.appending(path: ".claude")), ["settings.local.json"])
    }

    /// The staging file is created 0o600 and `fchmod`ed to the target's mode before the rename, so the rename cannot
    /// widen or narrow a file the user set deliberately.
    func testDeclinePreservesTheModeAcrossTheRename() throws {
        let home = try newHome()
        for wanted in [mode_t(0o640), mode_t(0o600)] {
            let project = try newProject()
            try project.writeLocalSettingsRaw("{\"disabledMcpjsonServers\": []}", mode: Int(wanted))
            let staging = LockedBox<mode_t?>(nil)
            let hooks = LocalSettingsStore.Hooks(afterStagingCreated: { fd in
                var st = stat()
                staging.value = fstat(fd, &st) == 0 ? st.st_mode & 0o7777 : nil
            })
            let store = LocalSettingsStore(hooks: hooks)
            _ = try store.decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)
            XCTAssertEqual(staging.value, 0o600, "the staging file is created private")
            XCTAssertEqual(mode(of: project.localSettingsFile), wanted, "and ends at the target's own mode")
        }
    }

    /// `.claude` is a symlink out of the project: the `openat` with `O_NOFOLLOW` fails with `ELOOP` and the writer
    /// refuses. The proof it refused *before writing* is the target's own listing and bytes, unchanged.
    func testDeclineRefusesASymlinkedDotClaude() async throws {
        let home = try newHome()
        let project = try newProject()
        let outside = try newOutsideDirectory()
        try Data("{}".utf8).write(to: outside.appending(path: "settings.local.json"))
        try FileManager.default.createSymbolicLink(at: project.root.appending(path: ".claude"),
                                                   withDestinationURL: outside)
        let witness = TreeWitness(outside)

        let store = LocalSettingsStore()
        XCTAssertThrowsError(try store.decline(names: ["d"], gitRoot: project.root, cwd: project.root,
                                               configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witness.assertUnchanged("the symlink target")
        XCTAssertEqual(TreeDigest.listing(of: outside), ["settings.local.json"])

        // The channel half: the refusal banners and the spawn is still blocked on consent.
        let rig = try newRig()
        rig.useScriptedHandle()
        try rig.home.trust(root: project.root)
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])
        let supervisor = rig.supervisor(session: SessionID(), cwdOverride: project.root,
                                        preconditions: SpawnPreconditions())
        await XCTAssertThrowsErrorAsync(try await supervisor.declineProjectServers(["d"], projectHasLiveProcess: false)) { error in
            XCTAssertEqual(error as? LifecycleError, .declineRefused(reason: "symlink"))
        }
        let banner = await supervisor.state.banner
        XCTAssertEqual(banner, .mcpDeclineRefused("symlink"))

        await XCTAssertThrowsErrorAsync(try await supervisor.spawn(reason: .open)) { error in
            guard case .precondition(.consentNeeded(let servers))? = error as? LifecycleError else {
                return XCTFail("not a consent refusal: \(error)")
            }
            XCTAssertEqual(servers.map(\.name), ["d"])
        }
        XCTAssertEqual(rig.spawnCount, 0, "nothing was spawned")
        let after = await supervisor.state.banner
        XCTAssertEqual(after, .mcpDeclineRefused("symlink"), "the refusal banner survives the blocked spawn")
        witness.assertUnchanged("the symlink target after the blocked spawn")
    }

    /// The staging directory is a symlink out of the project: the writer never `mkdir`s or opens it by path, so the
    /// `openat` with `O_NOFOLLOW` refuses and nothing is created in the target.
    func testDeclineRefusesASymlinkedStagingDirectory() throws {
        let home = try newHome()
        let project = try newProject()
        let outside = try newOutsideDirectory()
        try FileManager.default.createDirectory(at: project.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.stagingDirectory, withDestinationURL: outside)
        let witness = TreeWitness(outside)

        let store = LocalSettingsStore()
        XCTAssertThrowsError(try store.decline(names: ["d"], gitRoot: project.root, cwd: project.root,
                                               configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witness.assertUnchanged("the staging symlink's target")
        XCTAssertEqual(TreeDigest.listing(of: outside), [], "no staging file was created in it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.localSettingsFile
            .path(percentEncoded: false)), "and no target file was written either")
    }

    /// The target file itself is a symlink out of the project: the read is `openat` with `O_NOFOLLOW`, so it fails
    /// rather than reading through the link, and the rename that would have replaced the link never runs.
    func testDeclineRefusesASymlinkedTargetFile() throws {
        let home = try newHome()
        let project = try newProject()
        let outside = try newOutsideDirectory()
        let target = outside.appending(path: "real-settings.json")
        try Data("{\"disabledMcpjsonServers\": [\"keep\"]}".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640],
                                              ofItemAtPath: target.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: project.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.localSettingsFile, withDestinationURL: target)
        let witness = TreeWitness(outside)

        let store = LocalSettingsStore()
        XCTAssertThrowsError(try store.decline(names: ["d"], gitRoot: project.root, cwd: project.root,
                                               configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witness.assertUnchanged("the linked file")
        XCTAssertEqual(try Data(contentsOf: target), Data("{\"disabledMcpjsonServers\": [\"keep\"]}".utf8))
        XCTAssertEqual(mode(of: target), 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.stagingDirectory.path(percentEncoded: false)),
                       "no staging file remains")
    }

    /// A component swapped for a symlink *after* `resolve` returned. The writer re-derives no path from the
    /// resolution: everything after the root's descriptor is `openat` with `O_NOFOLLOW`, so the swap is an `ELOOP`
    /// and never a followed link.
    func testDeclineRefusesAComponentSwappedAfterResolution() throws {
        let home = try newHome()

        // (a) `.claude` swapped between `resolve` and the first `openat`.
        let first = try newProject()
        let outsideA = try newOutsideDirectory()
        try FileManager.default.createDirectory(at: first.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        let witnessA = TreeWitness(outsideA)
        let claudePath = first.root.appending(path: ".claude")
        let hooksA = LocalSettingsStore.Hooks(afterResolve: { _ in
            try? FileManager.default.removeItem(at: claudePath)
            try? FileManager.default.createSymbolicLink(at: claudePath, withDestinationURL: outsideA)
        })
        XCTAssertThrowsError(try LocalSettingsStore(hooks: hooksA)
            .decline(names: ["d"], gitRoot: first.root, cwd: first.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witnessA.assertUnchanged("the swapped-in target of `.claude`")

        // (b) `.cc-writes` swapped between the `mkdirat` and the staging `openat`.
        let second = try newProject()
        let outsideB = try newOutsideDirectory()
        let witnessB = TreeWitness(outsideB)
        let stagingPath = second.stagingDirectory
        let hooksB = LocalSettingsStore.Hooks(afterStagingDirectory: {
            try? FileManager.default.removeItem(at: stagingPath)
            try? FileManager.default.createSymbolicLink(at: stagingPath, withDestinationURL: outsideB)
        })
        XCTAssertThrowsError(try LocalSettingsStore(hooks: hooksB)
            .decline(names: ["d"], gitRoot: second.root, cwd: second.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witnessB.assertUnchanged("the swapped-in target of `.cc-writes`")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.localSettingsFile
            .path(percentEncoded: false)), "nothing was written")
    }

    /// An *ancestor* swapped after `resolve`. `O_NOFOLLOW` covers only the last component, so the open succeeds and
    /// lands somewhere else entirely — inside the scratch config home. The descriptor's `F_GETPATH` is what catches
    /// it, and the containment check runs on that result rather than on any string computed before the open.
    func testDeclineRefusesAnAncestorSwappedAfterResolve() throws {
        let home = try newHome()
        let project = try newProject()
        // The decoy the swapped ancestor points at: a `proj` of the same name, inside the config home.
        let decoy = home.url.appending(path: "decoy")
        try FileManager.default.createDirectory(at: decoy.appending(path: "proj"), withIntermediateDirectories: true)
        let homeWitness = TreeWitness(home.url)

        let work = project.work
        let moved = project.base.appending(path: "work-moved")
        let hooks = LocalSettingsStore.Hooks(afterResolve: { _ in
            // Renamed aside rather than deleted: the project has to still exist, or the refusal could be nothing
            // more than the tree having gone away.
            try? FileManager.default.moveItem(at: work, to: moved)
            try? FileManager.default.createSymbolicLink(at: work, withDestinationURL: decoy)
        })
        XCTAssertThrowsError(try LocalSettingsStore(hooks: hooks)
            .decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        homeWitness.assertUnchanged("the scratch config home")
        XCTAssertEqual(TreeDigest.listing(of: decoy.appending(path: "proj")), [],
                       "nothing exists under the swapped path")
    }

    /// The same swap, once the root's descriptor is open and verified. Everything after it is relative to that
    /// descriptor, so the write lands in the directory the writer resolved and not in the one the name now reaches.
    func testDeclineWritesToTheOriginalDirectoryWhenAnAncestorIsSwappedAfterOpen() throws {
        let home = try newHome()
        let project = try newProject()
        let decoy = home.url.appending(path: "decoy")
        try FileManager.default.createDirectory(at: decoy.appending(path: "proj"), withIntermediateDirectories: true)
        let homeWitness = TreeWitness(home.url)
        let originalRoot = URL(filePath: TemporaryProject.realpath(project.root), directoryHint: .isDirectory)

        let work = project.work
        let moved = project.base.appending(path: "work-moved")
        let hooks = LocalSettingsStore.Hooks(afterOpen: { _ in
            try? FileManager.default.moveItem(at: work, to: moved)
            try? FileManager.default.createSymbolicLink(at: work, withDestinationURL: decoy)
        })
        _ = try LocalSettingsStore(hooks: hooks)
            .decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)

        // The name `<base>/work/proj` now reaches the decoy; the descriptor still reaches the directory that was
        // there when it was opened, which is where the file has to be.
        XCTAssertEqual(TemporaryProject.realpath(originalRoot),
                       TemporaryProject.realpath(decoy.appending(path: "proj")),
                       "the name really was swapped out from under the writer")
        let landed = moved.appending(path: "proj/.claude/settings.local.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: landed)) as? [String: Any]
        XCTAssertEqual(object?["disabledMcpjsonServers"] as? [String], ["d"],
                       "the write followed the descriptor, not the name")
        homeWitness.assertUnchanged("the scratch config home")
        XCTAssertEqual(TreeDigest.listing(of: decoy.appending(path: "proj")), [])
    }

    /// Two ways the write could reach inside the config home through a link, both refused as `symlink` before any
    /// `mkdirat`: the staging directory linked into it, and `.claude` itself linked into it.
    func testDeclineRefusesAStagingDirectoryInsideTheConfigHome() throws {
        let home = try newHome()

        let first = try newProject()
        let inside = home.url.appending(path: "sneak")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: first.stagingDirectory, withDestinationURL: inside)
        var witness = TreeWitness(home.url)
        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: first.root, cwd: first.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink)
        }
        witness.assertUnchanged("the scratch config home behind a linked staging directory")

        let second = try newProject()
        let insideClaude = home.url.appending(path: "sneak-claude")
        try FileManager.default.createDirectory(at: insideClaude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: second.root.appending(path: ".claude"),
                                                   withDestinationURL: insideClaude)
        witness = TreeWitness(home.url)
        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: second.root, cwd: second.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .symlink,
                           "the `openat` fails with ELOOP before any `F_GETPATH` runs on it")
        }
        witness.assertUnchanged("the scratch config home behind a linked `.claude`")
    }

    /// The first of the two arrangements that put the store inside the config home: the **project** is inside the
    /// config home, so the project root's own descriptor already lies under it. The other arrangement — a config
    /// home at `<root>/.claude`, which is the one parent §6.12 names — is
    /// `testDeclineRefusesAConfigHomeInsideTheProject`, and the root check here does not catch it.
    func testDeclineRefusesAStoreInsideTheConfigHome() throws {
        let home = try newHome()
        let root = home.url.appending(path: "inside-project")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        let witness = TreeWitness(home.url)

        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: root, cwd: root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .insideConfigHome)
        }
        witness.assertUnchanged("the scratch config home")
    }

    /// The second arrangement, and the one parent §6.12 names in as many words: `CLAUDE_CONFIG_DIR` places the
    /// config home *inside the project*, at the very directory the store resolves to. The project root is nowhere
    /// near the config home, so a check on the root alone passes and the write goes straight into a Claude Code
    /// config home — the one thing §7.8 and X9 forbid without exception. The store directory's own descriptor is
    /// what catches it, and the staging directory's descriptor catches the same trick one level down.
    func testDeclineRefusesAConfigHomeInsideTheProject() throws {
        // (a) the config home *is* `<root>/.claude`, the store directory itself.
        let a = try newProject()
        let configHome = a.root.appending(path: ".claude")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        try Data("{\"projects\": {}}".utf8).write(to: configHome.appending(path: ".claude.json"))
        var witness = TreeWitness(configHome)

        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: a.root, cwd: a.root, configHome: configHome)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .insideConfigHome)
        }
        witness.assertUnchanged("the config home at the project's `.claude`")
        XCTAssertEqual(TreeDigest.listing(of: configHome), [".claude.json"],
                       "no settings.local.json was written into the config home")

        // (b) one level down: the config home is the staging directory, so `.claude` passes and `.cc-writes` is
        // where the write would land.
        let b = try newProject()
        let staging = b.stagingDirectory
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        witness = TreeWitness(staging)

        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: b.root, cwd: b.root, configHome: staging)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .insideConfigHome)
        }
        witness.assertUnchanged("the config home at the project's staging directory")
        XCTAssertEqual(TreeDigest.listing(of: staging), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.localSettingsFile.path(percentEncoded: false)),
                       "and the refusal came before the target was written")
    }

    /// The same arrangement, with the config home spelled through the data volume's firmlink.
    ///
    /// `realpath(3)` keeps a `/System/Volumes/Data` prefix — the firmlink is not a symlink and there is nothing for
    /// it to resolve — while `fcntl(F_GETPATH)` answers the same directory without it. The writer compares the
    /// descriptor's `F_GETPATH` against the config home, so a home spelled with the prefix never contains anything
    /// and the child's one absolute rule stops holding for it. Both sides are canonicalised through the same
    /// normaliser instead.
    ///
    /// Deliberate break: take the config home through `RealPath.string` again -> the containment check passes and
    /// `settings.local.json` is written into a Claude Code config home.
    func testDeclineRefusesAConfigHomeSpelledThroughTheDataVolumeFirmlink() throws {
        let firmlink = "/System/Volumes/Data"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: firmlink, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("no \(firmlink) on this machine: the two spellings cannot differ")
        }
        let project = try newProject()
        let configHome = project.root.appending(path: ".claude")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        try Data("{\"projects\": {}}".utf8).write(to: configHome.appending(path: ".claude.json"))

        let aliased = URL(filePath: firmlink + TemporaryProject.realpath(configHome), directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: aliased.path(percentEncoded: false)) else {
            throw XCTSkip("the data volume does not reach \(aliased.path(percentEncoded: false))")
        }
        XCTAssertNotEqual(TemporaryProject.realpath(aliased), TemporaryProject.realpath(configHome),
                          "the two spellings are the same directory and realpath keeps them apart")

        let witness = TreeWitness(configHome)
        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: aliased)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .insideConfigHome)
        }
        witness.assertUnchanged("the config home spelled through the firmlink")
        XCTAssertEqual(TreeDigest.listing(of: configHome), [".claude.json"],
                       "no settings.local.json was written into the config home")
    }

    /// A `.claude` that is a plain file is `notADirectory`, and a `.claude` that is a symlink is `symlink` — and on
    /// Darwin the errno cannot tell the two apart. `openat` with `O_DIRECTORY|O_NOFOLLOW` answers `ENOTDIR` for
    /// both (`ELOOP` appears only without `O_DIRECTORY`), so the writer asks the entry through the descriptor it
    /// already holds. This test is one half of that discrimination; `testDeclineRefusesASymlinkedDotClaude` is the
    /// other, and a mapping that answers either word unconditionally fails one of them.
    func testDeclineRefusesAPlainFileWhereTheStoreDirectoryShouldBe() throws {
        let home = try newHome()
        let project = try newProject()
        try Data("not a directory".utf8).write(to: project.root.appending(path: ".claude"))
        let witness = TreeWitness(project.root)

        XCTAssertThrowsError(try LocalSettingsStore()
            .decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .notADirectory)
        }
        witness.assertUnchanged("the project whose `.claude` is a plain file")
    }

    /// An existing `disabledMcpjsonServers` of another shape is refused rather than worked around: splicing cannot
    /// find a bracketed value, and inserting the key would leave the document carrying it twice.
    func testDeclineRefusesANonArrayDisabledList() throws {
        let home = try newHome()
        for value in ["null", "\"a\"", "{\"x\": 1}", "[1, 2]"] {
            let project = try newProject()
            try project.writeLocalSettingsRaw("{\"disabledMcpjsonServers\": \(value)}")
            let witness = TreeWitness(project.root)
            XCTAssertThrowsError(try LocalSettingsStore()
                .decline(names: ["d"], gitRoot: project.root, cwd: project.root, configHome: home.url)) { error in
                XCTAssertEqual(error as? LocalSettingsStore.Refusal, .unparseable, "for \(value)")
            }
            witness.assertUnchanged("the project whose disabled list is \(value)")
        }
    }

    /// A foreign uid anywhere on the path is a refusal, and so is a file whose JSON does not parse.
    func testDeclineRefusesAForeignUIDAndUnparseableJSON() throws {
        let home = try newHome()
        let mine = geteuid()
        let stranger = mine &+ 1

        // (a) `<root>/.git`, checked by path before anything is created.
        let a = try newProject()
        let witnessA = TreeWitness(a.root)
        let storeA = LocalSettingsStore(ownerUID: { subject in
            if case .path(let url) = subject, url.lastPathComponent == ".git" { return stranger }
            return LocalSettingsStore.statOwner(subject)
        })
        XCTAssertThrowsError(try storeA.decline(names: ["d"], gitRoot: a.root, cwd: a.root,
                                                configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .foreignUID)
        }
        witnessA.assertUnchanged("the project with a foreign `.git`")

        // (b) the `.claude` descriptor's own `fstat`.
        let b = try newProject()
        try FileManager.default.createDirectory(at: b.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        let witnessB = TreeWitness(b.root)
        let seenB = LockedBox<Int>(0)
        let storeB = LocalSettingsStore(ownerUID: { subject in
            if case .descriptor = subject {
                seenB.value += 1
                // The root's descriptor is the first; the `.claude` one is the second.
                if seenB.value == 2 { return stranger }
            }
            return LocalSettingsStore.statOwner(subject)
        })
        XCTAssertThrowsError(try storeB.decline(names: ["d"], gitRoot: b.root, cwd: b.root,
                                                configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .foreignUID)
        }
        witnessB.assertUnchanged("the project with a foreign `.claude`")

        // (c) the staging directory's descriptor, the third. `.claude` is made by the test, because the writer
        // legitimately creates it before it ever reaches the staging directory and the witness is about what was
        // *written*, not about an empty directory on the way there.
        let c = try newProject()
        try FileManager.default.createDirectory(at: c.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)
        let witnessC = TreeWitness(c.root)
        let seenC = LockedBox<Int>(0)
        let storeC = LocalSettingsStore(ownerUID: { subject in
            if case .descriptor = subject {
                seenC.value += 1
                if seenC.value == 3 { return stranger }
            }
            return LocalSettingsStore.statOwner(subject)
        })
        XCTAssertThrowsError(try storeC.decline(names: ["d"], gitRoot: c.root, cwd: c.root,
                                                configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .foreignUID)
        }
        witnessC.assertUnchanged("the project with a foreign staging directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.localSettingsFile.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.stagingDirectory.path(percentEncoded: false)))

        // (d) unparseable JSON: the file is left exactly as it was.
        let d = try newProject()
        try d.writeLocalSettingsRaw("{")
        let witnessD = TreeWitness(d.root)
        XCTAssertThrowsError(try LocalSettingsStore().decline(names: ["d"], gitRoot: d.root, cwd: d.root,
                                                              configHome: home.url)) { error in
            XCTAssertEqual(error as? LocalSettingsStore.Refusal, .unparseable)
        }
        witnessD.assertUnchanged("the project with unparseable settings")
        XCTAssertEqual(try d.localSettingsRaw(), "{")
    }

    /// The write runs only while no owned process for the project is live, and the store is re-read through the same
    /// resolver before any spawn is allowed.
    func testDeclineRunsOnlyWhileNoOwnedProcessIsLiveAndReReadsBeforeSpawn() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        try home.trust(root: project.root)
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])

        let resolves = LockedBox<Int>(0)
        let hooks = LocalSettingsStore.Hooks(afterResolve: { _ in resolves.value += 1 })
        let preconditions = SpawnPreconditions(settings: LocalSettingsStore(hooks: hooks))

        XCTAssertThrowsError(try preconditions.decline(names: ["d"], cwd: project.root, configHome: home.url,
                                                       processIsLive: true)) { error in
            XCTAssertEqual(error as? LifecycleError, .declineRefused(reason: "processLive"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.localSettingsFile
            .path(percentEncoded: false)), "a live process means nothing is written at all")

        resolves.value = 0
        _ = try preconditions.decline(names: ["d"], cwd: project.root, configHome: home.url, processIsLive: false)
        XCTAssertEqual(resolves.value, 1, "the write resolved the store once")

        let key = ChannelKey(configHome: home.url, session: SessionID())
        let (result, _) = await preconditions.evaluate(key: key, cwd: project.root,
                                                       launch: launch(cwd: project.root), wedged: nil,
                                                       foreignHolders: [], store: store)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(resolves.value, 2, "and the spawn re-read it through the same resolver")
    }

    // MARK: - Isolated sources and managed settings

    /// A launch whose setting sources exclude `local` would promote a declined server back to approved, so afleet
    /// adds `--strict-mcp-config` — which drops every `.mcp.json` server — and the header says so.
    func testIsolatedSourcesWithDeclaredServersAddStrictMCPConfig() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let project = try newProject()
        try rig.home.trust(root: project.root)
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])

        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting),
                                        template: launch(cwd: project.root, sources: []),
                                        cwdOverride: project.root, preconditions: SpawnPreconditions())
        try await supervisor.spawn(reason: .open)
        XCTAssertEqual(rig.launches.last?.strictMCPConfig, true)
        var note = await supervisor.state.headerNote
        XCTAssertEqual(note, .projectServersOff)

        try FileManager.default.removeItem(at: project.root.appending(path: ".mcp.json"))
        let bare = try newProject()
        try rig.home.trust(root: bare.root)
        let second = rig.supervisor(session: SessionID(), origin: .owned(.connecting),
                                    template: launch(cwd: bare.root, sources: []),
                                    cwdOverride: bare.root, preconditions: SpawnPreconditions())
        try await second.spawn(reason: .open)
        XCTAssertEqual(rig.launches.last?.strictMCPConfig, false, "no `.mcp.json`, nothing to isolate")
        note = await second.state.headerNote
        XCTAssertNil(note)
    }

    /// A managed-settings payload pending approval blocks every spawn, and an unparseable pair fails closed.
    func testManagedSettingsPendingBlocksTheSpawn() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let project = try newProject()
        try rig.home.trust(root: project.root)
        let payload = Data("{\"managed\": true}".utf8)
        try payload.write(to: rig.home.url.appending(path: "remote-settings.json"))

        XCTAssertTrue(ManagedSettingsReader.isPending(configHome: rig.home.url))
        let supervisor = rig.supervisor(session: SessionID(), origin: .archived,
                                        template: launch(cwd: project.root), cwdOverride: project.root,
                                        preconditions: SpawnPreconditions())
        await XCTAssertThrowsErrorAsync(try await supervisor.spawn(reason: .open)) { error in
            XCTAssertEqual(error as? LifecycleError, .precondition(.managedSettingsPending))
        }
        XCTAssertEqual(rig.spawnCount, 0)
        let banner = await supervisor.state.banner
        XCTAssertEqual(banner, .managedSettingsPending)

        try Data("{\"approvedHash\": \"\(ContentHash.sha256Hex(payload))\"}".utf8)
            .write(to: rig.home.url.appending(path: "remote-settings-consent.json"))
        XCTAssertFalse(ManagedSettingsReader.isPending(configHome: rig.home.url), "the recorded hash matches")

        try Data("{".utf8).write(to: rig.home.url.appending(path: "remote-settings-consent.json"))
        XCTAssertTrue(ManagedSettingsReader.isPending(configHome: rig.home.url), "an unparseable pair fails closed")
    }

    /// The order the spec fixes: wedged, contended, managed settings, untrusted, consent. A project failing every
    /// check at once reports the first, and clearing each in turn reports the next.
    func testPreconditionOrderIsWedgedContendedManagedUntrustedConsent() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        try project.writeMCPJSON(["d": ["command": "/usr/bin/true"]])
        try Data("{\"managed\": true}".utf8).write(to: home.url.appending(path: "remote-settings.json"))

        let trace = EscalationTrace(steps: ["sigterm", "sigkill"], pid: 4242, epoch: ProcessEpoch(rawValue: 1))
        let holder = Holder(pid: 4243, sessionID: SessionID(), sources: [.registry], kind: "interactive")
        let key = ChannelKey(configHome: home.url, session: SessionID())
        let preconditions = SpawnPreconditions()

        func step(wedged: EscalationTrace?, holders: [Holder]) async -> SpawnPrecondition {
            await preconditions.evaluate(key: key, cwd: project.root, launch: launch(cwd: project.root),
                                         wedged: wedged, foreignHolders: holders, store: store).0
        }

        let first = await step(wedged: trace, holders: [holder])
        XCTAssertEqual(first, .wedged(trace))
        guard case .contended(let set) = await step(wedged: nil, holders: [holder]) else {
            return XCTFail("contended comes after wedged")
        }
        XCTAssertEqual(set.holders, [holder])
        let third = await step(wedged: nil, holders: [])
        XCTAssertEqual(third, .managedSettingsPending)

        try Data("{\"approvedHash\": \"\(ContentHash.sha256Hex(Data("{\"managed\": true}".utf8)))\"}".utf8)
            .write(to: home.url.appending(path: "remote-settings-consent.json"))
        guard case .untrusted = await step(wedged: nil, holders: []) else {
            return XCTFail("untrusted comes after managed settings")
        }

        try home.trust(root: project.root)
        guard case .consentNeeded(let servers) = await step(wedged: nil, holders: []) else {
            return XCTFail("consent comes last")
        }
        XCTAssertEqual(servers.map(\.name), ["d"])
    }

    /// The whole-package property: nothing in `FleetSessions` other than `LocalSettingsStore.decline` writes under a
    /// project directory. Every precondition path runs here inside one witness; the same witness is installed in the
    /// rig, so every lifecycle row test asserts it too at teardown.
    func testNothingElseInThePackageWritesUnderAProject() async throws {
        let home = try newHome()
        let project = try newProject()
        let store = try newStore(home: home)
        try project.writeMCPJSON(["s": ["command": "/usr/bin/true"],
                                  "h": ["type": "http", "url": "https://example.invalid/mcp"]])
        try project.writeProjectSettings(["enabledMcpjsonServers": ["s"]])
        let witness = TreeWitness(project.root)

        let preconditions = SpawnPreconditions()
        let consent = ProjectMCPConsent()
        let root = ProjectRoot.canonical(for: project.root)
        let key = ChannelKey(configHome: home.url, session: SessionID())

        _ = ProjectRoot.canonical(for: project.root.appending(path: "nowhere"))
        _ = TrustReader.isTrusted(root: root.root, configHome: home.url)
        _ = ManagedSettingsReader.isPending(configHome: home.url)
        _ = LocalSettingsStore().resolve(gitRoot: root.gitRoot, cwd: project.root)
        _ = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root, configHome: home.url,
                             settingSources: nil, acceptances: [])
        _ = await preconditions.evaluate(key: key, cwd: project.root, launch: launch(cwd: project.root),
                                         wedged: nil, foreignHolders: [], store: store)
        try home.trust(root: project.root)
        let verdicts = consent.evaluate(root: root.root, gitRoot: root.gitRoot, cwd: project.root,
                                        configHome: home.url, settingSources: nil, acceptances: [])
        for pending in verdicts.keys { try await preconditions.accept(pending, root: root.root, store: store) }
        _ = await preconditions.evaluate(key: key, cwd: project.root, launch: launch(cwd: project.root),
                                         wedged: nil, foreignHolders: [], store: store)

        witness.assertUnchanged("the project tree across every precondition path but the decline")
    }

    // MARK: - The two carried items

    /// A fork whose child crashes before its identity arrives gives its cap slot back. The reservation a fork holds
    /// is confirmed nowhere but `resolveForkIdentity`, so an exit that does not clear it leaves it in the counter's
    /// `reserved` map for the life of the process — one of six slots, permanently, per crash. The assertion is
    /// occupancy, not state: the state is right either way.
    func testAForkThatCrashesBeforeItsIdentityGivesItsSlotBack() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let occupiedBefore = await rig.fleet.occupancy

        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let forkHandle = try XCTUnwrap(rig.scriptedHandles.last)
        let occupiedWithFork = await rig.fleet.occupancy
        XCTAssertEqual(occupiedWithFork, occupiedBefore + 1, "the fork holds a provisional reservation")

        let published = await fork.publishedCount
        forkHandle.push(.exited(.code(1, stderrTail: ""), forkHandle.epoch))
        try await rig.waitForPublish(fork, above: published)

        let occupiedAfter = await rig.fleet.occupancy
        XCTAssertEqual(occupiedAfter, occupiedBefore,
                       "the crashed fork's reservation went back to the counter")
        let state = await fork.state
        XCTAssertEqual(state.origin, .owned(.connecting), "and the crash took the respawn row as usual")
    }

    /// The expiry is no longer silent: it is recorded, and the channel carries an item the user can see.
    func testTheForkIdentityDeadlineIsRecordedAndSurfaced() async throws {
        let rig = try newRig()
        rig.useScriptedHandle()
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let provisional = try await supervisor.fork(at: nil)
        let fork = try XCTUnwrap(rig.supervisor(for: provisional))
        let forkHandle = try XCTUnwrap(rig.scriptedHandles.last)

        try await rig.waitForSleeper(due: .seconds(30))
        await rig.clock.advance(by: .seconds(30))
        try await rig.waitFor("the identity deadline to fire") { forkHandle.terminateCount == 1 }

        try await rig.waitFor("the expiry to be recorded") {
            rig.diagnostics.forkIdentityDeadlines.contains { $0 == provisional.session.description }
        }
        try await rig.waitFor("an item the user can see") {
            let item = await fork.state.systemItem
            return item != nil
        }
    }

    // MARK: - Async throwing assertion

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                              file: StaticString = #filePath, line: UInt = #line,
                                              _ inspect: (any Error) -> Void = { _ in }) async {
        do {
            _ = try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            inspect(error)
        }
    }
}
