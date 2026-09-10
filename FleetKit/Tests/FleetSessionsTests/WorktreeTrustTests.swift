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
        let root: URL
        let checkout: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "afleet-worktree-trust-\(UUID().uuidString)")
            root = base.appending(path: "repository", directoryHint: .isDirectory)
            checkout = base.appending(path: "checkout", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("invented\n".utf8).write(to: root.appending(path: "README"))
            try Self.git(["init", "--quiet"], in: root)
            try Self.git(["config", "user.email", "invented@example.invalid"], in: root)
            try Self.git(["config", "user.name", "invented"], in: root)
            try Self.git(["add", "README"], in: root)
            try Self.git(["commit", "--quiet", "-m", "invented"], in: root)
            try Self.git(["worktree", "add", "--quiet", checkout.path(percentEncoded: false),
                          "-b", "invented-branch"], in: root)
        }

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

        let resolved = ProjectRoot.canonical(for: repository.checkout)
        XCTAssertTrue(RealPath.string(resolved.root) == RealPath.string(repository.root),
                      "a linked worktree's canonical root is not the repository the engine keys on")
        XCTAssertTrue(resolved.gitRoot != nil, "a worktree resolved to no git root")

        // The floor: the repository itself is unchanged, so the clause above is about the worktree
        // and not about the walk answering the same directory for everything.
        let plain = ProjectRoot.canonical(for: repository.root)
        XCTAssertTrue(RealPath.string(plain.root) == RealPath.string(repository.root),
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
        XCTAssertTrue(RealPath.string(ProjectRoot.canonical(for: repository.checkout).root)
                      == RealPath.string(repository.checkout),
                      "a gitdir pointing nowhere still moved the trust key")

        // 2. The real pointer back, with `commondir` broken.
        try Data("gitdir: \(gitDirectory.path(percentEncoded: false))\n".utf8).write(to: dotGit)
        let commondir = gitDirectory.appending(path: "commondir")
        let realCommondir = try Data(contentsOf: commondir)
        try Data("../../..\n".utf8).write(to: commondir)
        XCTAssertTrue(RealPath.string(ProjectRoot.canonical(for: repository.checkout).root)
                      == RealPath.string(repository.checkout),
                      "a commondir that is not the worktrees directory's parent still moved the trust key")
        try realCommondir.write(to: commondir)

        // 3. The reciprocal pointer naming somebody else.
        let reciprocal = gitDirectory.appending(path: "gitdir")
        let realReciprocal = try Data(contentsOf: reciprocal)
        try Data("\(repository.base.path(percentEncoded: false))/invented/.git\n".utf8).write(to: reciprocal)
        XCTAssertTrue(RealPath.string(ProjectRoot.canonical(for: repository.checkout).root)
                      == RealPath.string(repository.checkout),
                      "a reciprocal pointer naming another checkout still moved the trust key")
        try realReciprocal.write(to: reciprocal)

        // Restored, so the last clause proves the three above failed for their own reasons and not
        // because the repository was broken by the first of them.
        XCTAssertTrue(RealPath.string(ProjectRoot.canonical(for: repository.checkout).root)
                      == RealPath.string(repository.root),
                      "the restored link no longer resolves, so the arms above prove nothing")
    }

    // MARK: - What keys on it

    /// Trust read for the **repository** covers a channel running in its worktree, which is the
    /// defect this resolution exists to close.
    func testTrustOnTheRepositoryCoversAChannelInItsWorktree() throws {
        let repository = try repository()
        defer { repository.removeAll() }
        let home = try ScratchConfigHome()
        defer { home.removeAll() }

        let root = ProjectRoot.canonical(for: repository.checkout).root
        XCTAssertFalse(TrustReader.isTrusted(root: root, globalConfig: home.configHome.globalConfig),
                       "an untrusted repository read as trusted")

        try home.trust(root: repository.root)
        XCTAssertTrue(TrustReader.isTrusted(root: root, globalConfig: home.configHome.globalConfig),
                      "trust recorded for the repository does not cover its worktree")
    }

    /// Project consent keys on the same root, so the `.mcp.json` a `-w` channel is asked about is
    /// the repository's — the same file the engine's own rejection gate reads.
    func testProjectConsentKeysOnTheRepositoryRoot() throws {
        let repository = try repository()
        defer { repository.removeAll() }
        try Data(#"{"mcpServers":{"invented-server":{"command":"/usr/bin/true"}}}"#.utf8)
            .write(to: repository.root.appending(path: ".mcp.json"))

        let root = ProjectRoot.canonical(for: repository.checkout).root
        let servers = ProjectMCPConsent(settings: LocalSettingsStore()).servers(root: root)
        XCTAssertEqual(servers.count, 1, "the repository's project servers were read as \(servers.count)")
    }
}
