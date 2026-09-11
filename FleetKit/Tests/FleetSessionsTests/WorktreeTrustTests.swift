import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Which directory a **linked worktree** keys trust and project consent on (parent §6.11, §6.12).
///
/// The engine resolves the checkout's `gitdir:` and `commondir` and keys on the common repository
/// root (bundle `SPEC/03-settings-and-configuration.md` §15.2). afleet stopping at the checkout
/// meant every `-w` channel's spawn was refused `untrusted` on a repository the user had trusted —
/// and §8.2 promotes *New isolated session*, so that is the ordinary path and not a corner.
///
/// The repository here is made by **`git worktree add`**, not by hand: the layout has four moving
/// parts — the `.git` file, the `gitdir` directory, its `commondir` and its reciprocal `gitdir` —
/// and a hand-made one would be a test of this file's own idea of the layout rather than of git's.
final class WorktreeTrustTests: XCTestCase {

    /// A temporary repository with one linked worktree, or a skip when `git` is unavailable.
    private struct Repository {
        let base: URL
        /// The directory the engine keys trust on: the working copy, or the bare repository.
        let root: URL
        let checkout: URL

        init(bare: Bool = false) throws {
            base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "afleet-worktree-trust-\(UUID().uuidString)")
            let working = base.appending(path: "repository", directoryHint: .isDirectory)
            checkout = base.appending(path: "checkout", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            try Data("invented\n".utf8).write(to: working.appending(path: "README"))
            try Self.git(["init", "--quiet"], in: working)
            try Self.git(["config", "user.email", "invented@example.invalid"], in: working)
            try Self.git(["config", "user.name", "invented"], in: working)
            try Self.git(["add", "README"], in: working)
            try Self.git(["commit", "--quiet", "-m", "invented"], in: working)
            if bare {
                // `--bare` is what makes the common directory `…/repo.git`, whose basename is not
                // `.git` — the branch the engine's resolver takes and this transcription used to
                // refuse.
                root = base.appending(path: "repository.git", directoryHint: .isDirectory)
                try Self.git(["clone", "--bare", "--quiet", working.path(percentEncoded: false),
                              root.path(percentEncoded: false)], in: base)
            } else {
                root = working
            }
            try Self.git(["worktree", "add", "--quiet", checkout.path(percentEncoded: false),
                          "-b", "invented-branch"], in: root)
        }

        /// The same tree, but the worktree is added from a **bare** clone, whose common directory is
        /// `…/repo.git` rather than `…/repo/.git`.
        static func bare() throws -> Repository { try Repository(bare: true) }

        @discardableResult
        static func git(_ arguments: [String], in directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            // Neither the author's identity nor their config reaches this repository (§11).
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitFailure(verb: arguments.first ?? "git", status: process.terminationStatus)
            }
            return String(decoding: data, as: UTF8.self)
        }

        func removeAll() { try? FileManager.default.removeItem(at: base) }
    }

    /// A count and a verb, never git's own output: it can carry a path (§11).
    private struct GitFailure: Error, CustomStringConvertible {
        let verb: String
        let status: Int32
        var description: String { "git \(verb) exited \(status)" }
    }

    private func repository() throws -> Repository {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git is not available, so no real worktree can be made")
        return try Repository()
    }

    // MARK: - The canonical root

    /// The whole claim: a real linked worktree's canonical root is the repository, and the plain
    /// repository is still its own root.
    func testALinkedWorktreesCanonicalRootIsTheRepository() throws {
        let repository = try repository()
        defer { repository.removeAll() }

        let resolved = ProjectRoot.roots(for: repository.checkout)
        XCTAssertTrue(RealPath.string(resolved.trustKey) == RealPath.string(repository.root),
                      "a linked worktree's canonical root is not the repository the engine keys on")
        XCTAssertTrue(resolved.gitRoot != nil, "a worktree resolved to no git root")

        // The floor: the repository itself is unchanged, so the clause above is about the worktree
        // and not about the walk answering the same directory for everything.
        let plain = ProjectRoot.roots(for: repository.root)
        XCTAssertTrue(RealPath.string(plain.trustKey) == RealPath.string(repository.root),
                      "an ordinary checkout stopped being its own root")
    }

    /// A `.git` file that only looks like a worktree link keeps the checkout root.
    ///
    /// Each arm breaks exactly one of the engine's guards, so the fallback is attributable: a
    /// `gitdir:` into nowhere, a `commondir` that is not the parent of the `worktrees` directory,
    /// and a reciprocal pointer that names somebody else.
    func testAMalformedLinkKeepsTheCheckoutRoot() throws {
        let repository = try repository()
        defer { repository.removeAll() }
        let dotGit = repository.checkout.appending(path: ".git")
        let gitDirectory = try XCTUnwrap(WorktreeLayout.gitDirectory(ofWorktreeAt: repository.checkout),
                                         "git worktree add wrote no gitdir pointer")

        // 1. A `gitdir:` naming a directory that does not exist.
        try Data("gitdir: \(repository.base.path(percentEncoded: false))/invented/worktrees/x\n".utf8)
            .write(to: dotGit)
        XCTAssertTrue(RealPath.string(ProjectRoot.roots(for: repository.checkout).trustKey)
                      == RealPath.string(repository.checkout),
                      "a gitdir pointing nowhere still moved the trust key")

        // 2. The real pointer back, with `commondir` broken.
        try Data("gitdir: \(gitDirectory.path(percentEncoded: false))\n".utf8).write(to: dotGit)
        let commondir = gitDirectory.appending(path: "commondir")
        let realCommondir = try Data(contentsOf: commondir)
        try Data("../../..\n".utf8).write(to: commondir)
        XCTAssertTrue(RealPath.string(ProjectRoot.roots(for: repository.checkout).trustKey)
                      == RealPath.string(repository.checkout),
                      "a commondir that is not the worktrees directory's parent still moved the trust key")
        try realCommondir.write(to: commondir)

        // 3. The reciprocal pointer naming somebody else.
        let reciprocal = gitDirectory.appending(path: "gitdir")
        let realReciprocal = try Data(contentsOf: reciprocal)
        try Data("\(repository.base.path(percentEncoded: false))/invented/.git\n".utf8).write(to: reciprocal)
        XCTAssertTrue(RealPath.string(ProjectRoot.roots(for: repository.checkout).trustKey)
                      == RealPath.string(repository.checkout),
                      "a reciprocal pointer naming another checkout still moved the trust key")
        try realReciprocal.write(to: reciprocal)

        // Restored, so the last clause proves the three above failed for their own reasons and not
        // because the repository was broken by the first of them.
        XCTAssertTrue(RealPath.string(ProjectRoot.roots(for: repository.checkout).trustKey)
                      == RealPath.string(repository.root),
                      "the restored link no longer resolves, so the arms above prove nothing")
    }

    /// A worktree of a **bare** repository keys on the common directory **itself**.
    ///
    /// The engine's resolver ends `if basename(commondir) !== ".git" return normalize(commondir)`
    /// (2.1.263 `chunk-gbme4p3n.js`), and a bare repository's common directory is `…/repo.git`. An
    /// earlier transcription required the `.git` basename and refused the whole resolution here,
    /// leaving the checkout — a false `untrusted` on a repository the user trusted.
    func testAWorktreeOfABareRepositoryKeysOnTheCommonDirectoryItself() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git is not available, so no real worktree can be made")
        let repository = try Repository.bare()
        defer { repository.removeAll() }

        let resolved = ProjectRoot.roots(for: repository.checkout)
        XCTAssertTrue(RealPath.string(resolved.trustKey) == RealPath.string(repository.root),
                      "a bare repository's worktree does not key on the common directory")
        XCTAssertFalse(RealPath.string(resolved.trustKey) == RealPath.string(repository.checkout),
                       "a bare repository's worktree kept the checkout as its trust key")
        XCTAssertTrue(RealPath.string(resolved.checkout) == RealPath.string(repository.checkout),
                      "the checkout root moved with the trust key")
    }

    // MARK: - The two roots are two directories

    /// The split itself: a linked worktree's **trust key** is the repository and its **checkout** is
    /// the working tree, and the engine reads different files from each.
    ///
    /// `.mcp.json` and `.claude/settings.json` are read from the checkout, nearest winning (bundle
    /// `SPEC/31-mcp-client.md:361` and `:136`); `hasTrustDialogAccepted` and §6.12's decline target
    /// are the repository's. Collapsing them breaks whichever one loses: keyed on the checkout, a
    /// trusted repository reads as untrusted; keyed on the repository, a user is offered consent for
    /// servers their checkout does not declare and never asked about the ones it does.
    func testTheTrustKeyAndTheCheckoutAreTwoDirectories() throws {
        let repository = try repository()
        defer { repository.removeAll() }
        try Data(#"{"mcpServers":{"invented-checkout-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: repository.checkout.appending(path: ".mcp.json"))
        try Data(#"{"mcpServers":{"invented-repository-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: repository.root.appending(path: ".mcp.json"))

        let resolved = ProjectRoot.roots(for: repository.checkout)
        XCTAssertFalse(RealPath.string(resolved.trustKey) == RealPath.string(resolved.checkout),
                       "a linked worktree's two roots came back as one directory")

        // The checkout's own servers, and not the repository's.
        let consent = ProjectMCPConsent(settings: LocalSettingsStore())
        let fromCheckout = consent.servers(root: resolved.checkout).map(\.name)
        XCTAssertTrue(fromCheckout == ["invented-checkout-server"],
                      "project servers were discovered somewhere other than the checkout")

        // Both roots are real paths with one spelling each, which is what every comparison in the
        // fleet depends on: a trailing slash on one arm makes two projects out of one.
        XCTAssertTrue(resolved.trustKey.path(percentEncoded: false)
                      == RealPath.string(resolved.trustKey),
                      "the trust key is not a real path")
        XCTAssertTrue(resolved.checkout.path(percentEncoded: false)
                      == RealPath.string(resolved.checkout),
                      "the checkout root is not a real path")
    }

    // MARK: - What keys on it

    /// Trust read for the **repository** covers a channel running in its worktree, which is the
    /// defect this resolution exists to close.
    func testTrustOnTheRepositoryCoversAChannelInItsWorktree() throws {
        let repository = try repository()
        defer { repository.removeAll() }
        let home = try ScratchConfigHome()
        defer { home.removeAll() }

        let root = ProjectRoot.roots(for: repository.checkout).trustKey
        XCTAssertFalse(TrustReader.isTrusted(root: root, globalConfig: home.configHome.globalConfig),
                       "an untrusted repository read as trusted")

        try home.trust(root: repository.root)
        XCTAssertTrue(TrustReader.isTrusted(root: root, globalConfig: home.configHome.globalConfig),
                      "trust recorded for the repository does not cover its worktree")
    }

    /// §6.12's **decline target** is the repository's local settings store, not the checkout's.
    ///
    /// The rejection gate the engine runs reads `localSettings`, whose store the engine resolves
    /// from the git root it computed — the repository — so a decline written into a worktree's own
    /// `.claude/settings.local.json` would be read by nobody and the declined server would be
    /// promoted back to approved on the next spawn.
    func testTheDeclineTargetIsTheRepositorysLocalSettingsStore() throws {
        let repository = try repository()
        defer { repository.removeAll() }

        let resolved = ProjectRoot.roots(for: repository.checkout)
        let store = LocalSettingsStore().resolve(gitRoot: resolved.trustKey, cwd: repository.checkout)
        XCTAssertTrue(RealPath.string(store.storeFile.deletingLastPathComponent().deletingLastPathComponent())
                      == RealPath.string(repository.root),
                      "the decline target is not under the repository the engine keys on")
        XCTAssertFalse(RealPath.string(store.storeFile.deletingLastPathComponent().deletingLastPathComponent())
                       == RealPath.string(repository.checkout),
                       "the decline target is the worktree's own store, which the engine never reads")
    }

    /// A worktree of a **bare** repository keeps its store at the **checkout**, because the engine
    /// does.
    ///
    /// The engine's resolver `lstat`s `join(root, ".git")` unguarded, and a bare directory has none
    /// inside it — the may-be-absent licence is `.claude`'s alone. afleet treating an absent entry
    /// as "not foreign" moved the store to the bare directory, so a decline landed in a file the
    /// engine never reads while afleet read it back as authoritative: the declined server loads.
    func testAWorktreeOfABareRepositoryKeepsItsStoreAtTheCheckout() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                          "git is not available, so no real worktree can be made")
        let repository = try Repository.bare()
        defer { repository.removeAll() }

        let resolved = ProjectRoot.roots(for: repository.checkout)
        XCTAssertTrue(RealPath.string(resolved.trustKey) == RealPath.string(repository.root),
                      "the bare repository is not the trust key, so this measures nothing")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repository.root.appending(path: ".git").path(percentEncoded: false)),
                       "the bare repository has a .git inside it, so this measures nothing")

        let store = LocalSettingsStore().resolve(gitRoot: resolved.trustKey, cwd: repository.checkout)
        XCTAssertFalse(store.atGitRoot, "the store moved to a root the engine does not move it to")
        XCTAssertTrue(RealPath.string(store.storeDirectory.deletingLastPathComponent())
                      == RealPath.string(repository.checkout),
                      "the bare repository's worktree writes somewhere the engine never reads")

        // And the rejection gate reads it there: a declined server stays declined.
        let claude = repository.checkout.appending(path: ".claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data(#"{"disabledMcpjsonServers":["invented-server"]}"#.utf8)
            .write(to: claude.appending(path: "settings.local.json"))
        try Data(#"{"mcpServers":{"invented-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: repository.checkout.appending(path: ".mcp.json"))

        let consent = ProjectMCPConsent(settings: LocalSettingsStore())
        let verdicts = consent.evaluate(root: resolved.checkout, gitRoot: resolved.trustKey,
                                        cwd: repository.checkout,
                                        configHome: FileManager.default.temporaryDirectory
                                            .appending(path: "afleet-bare-unwritten"),
                                        settingSources: nil, acceptances: [])
        let rejected = verdicts.filter { if case .rejected = $0.value { return true } else { return false } }
            .keys.map(\.name)
        XCTAssertTrue(rejected == ["invented-server"],
                      "the decline the checkout's own store holds was not read as a rejection")
    }

    /// An ordinary repository is unchanged: its `.git` is there, so the store is still the
    /// repository's — the negative half of the clause above.
    func testAnOrdinaryRepositoryStillKeepsItsStoreAtTheRoot() throws {
        let repository = try repository()
        defer { repository.removeAll() }

        let resolved = ProjectRoot.roots(for: repository.checkout)
        let store = LocalSettingsStore().resolve(gitRoot: resolved.trustKey, cwd: repository.checkout)
        XCTAssertTrue(store.atGitRoot, "an ordinary repository's store stopped being the root's")
    }

    /// §6.12's "no owned process in this project" spans **every checkout of the repository**.
    ///
    /// The write target is the repository's store, so a live child in the main working copy has
    /// already loaded the very server a worktree channel is declining — and an `mcp_toggle` after the
    /// fact arrives too late. The grouping that answers the question keys on the trust key and
    /// compares real-path strings; a `URL ==` read the two checkouts as two projects and let the
    /// write land under a running child.
    func testALiveChannelInTheMainCheckoutRefusesAWorktreeChannelsDecline() async throws {
        let repository = try repository()
        defer { repository.removeAll() }
        let home = try ScratchConfigHome()
        defer { home.removeAll() }
        try home.trust(root: repository.root)
        // The server is the **worktree's** own, because that is where the engine reads `.mcp.json`
        // from. The main working copy declares none, so its channel comes up without a sheet — which
        // is what makes it a live child in the same project and nothing more.
        try Data(#"{"mcpServers":{"invented-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: repository.checkout.appending(path: ".mcp.json"))

        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let storeDirectory = temporary.appending(path: "afleet-worktree-decline-store-\(UUID().uuidString)")
        let diagnostics = temporary.appending(path: "afleet-worktree-decline-diag-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? FileManager.default.removeItem(at: diagnostics)
        }
        let files = ScriptedHolderFiles(home: home)
        let session = try FakeClaudeLaunch.sessionID(of: "plain-two-turn")
        let fleet = Fleet(configHome: home.configHome,
                          environment: FakeClaudeLaunch.environment(fixture: "plain-two-turn"),
                          binary: FakeClaudeLaunch.binary,
                          store: try FileStateStore(baseDirectory: storeDirectory, configHomes: [home.url]),
                          diagnosticsDirectory: diagnostics, clock: TestClock(),
                          factory: { epoch, _ in
                              ScriptedProcessHandle(epoch: epoch, session: session,
                                                    pid: 800_000 + Int32(epoch.rawValue))
                          },
                          runner: ScriptedProcessRunner(rules: ScriptedProcessRunner.defaultRules(files)))
        defer { Task { await fleet.shutdown() } }

        // One channel in the repository's main working copy, with a live child; one in the worktree.
        let main = ChannelKey(configHome: home.url, session: SidebarSession.a)
        let worktree = ChannelKey(configHome: home.url, session: SidebarSession.b)
        await fleet.register(main, cwd: repository.root, recent: true)
        await fleet.register(worktree, cwd: repository.checkout, recent: true)
        _ = try await fleet.perform(.open, on: main)
        let livePID = await fleet.channel(main)?.livePID()
        XCTAssertTrue(livePID != nil, "the main-checkout channel has no live child, so this proves nothing")

        do {
            try await fleet.declineProjectServers(["invented-server"], project: repository.checkout)
            XCTFail("the decline was written while a child of the same repository was running")
        } catch let error as LifecycleError {
            guard case .declineRefused(let reason) = error else {
                return XCTFail("the decline failed for a reason other than a live process")
            }
            XCTAssertTrue(reason == LocalSettingsStore.Refusal.processLive.rawValue,
                          "the decline was refused for something other than a live process")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repository.root.appending(path: ".claude/settings.local.json")
                .path(percentEncoded: false)),
                       "the refused decline wrote the repository's local settings store anyway")
    }
}

/// Two invented session ids, visibly nobody's (§11).
private enum SidebarSession {
    static let a = SessionID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    static let b = SessionID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
}
