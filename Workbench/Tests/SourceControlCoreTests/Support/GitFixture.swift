import Foundation
@testable import SourceControlCore

/// A real git repository built inside a `TempTree` with the `git` binary, for tests that parse
/// real `git` output rather than a transcript of it.
///
/// Ledger D14, and a correctness requirement rather than hygiene: a developer's global
/// `~/.gitconfig` can set `init.defaultBranch`, `commit.gpgsign`, `log.date`, `diff.renames`,
/// `core.hooksPath` or a merge driver, any of which changes the bytes a fixture test parses and
/// makes the suite pass or fail by accident of the machine. So every invocation here runs with
/// the global and system configuration disabled, the system *gitattributes* tier disabled too
/// (`GIT_CONFIG_SYSTEM` does not cover it), a fixed `TZ` and `LC_ALL`, `HOME` inside the temporary
/// tree, the terminal prompt off, fixed dates, and an invented identity — never the machine's, per §11 and the
/// dispatch brief.
final class GitFixture {

    /// Invented, and deliberately not resembling any real person. §11: the identifiers in a
    /// fixture are authored, never read off the machine.
    static let authorName = "Wren Alcove"
    static let authorEmail = "wren.alcove@example.invalid"
    /// A fixed instant, so a commit's bytes do not depend on when the suite ran. Each commit adds
    /// its ordinal in seconds so that two commits with the same tree, message and parent still
    /// get distinct hashes — identical inputs would be one git object, not two.
    static let baseTimestamp = 1_614_800_000

    /// Failure of a fixture command. It names the subcommand and the exit code and nothing else:
    /// a thrown error is printed by XCTest, and stderr from a command run in a temporary
    /// directory carries the machine account's hash (§6.3, §11).
    struct Failure: Error, CustomStringConvertible {
        let subcommand: String
        let exitCode: Int32
        var description: String { "git \(subcommand) exited \(exitCode)" }
    }

    /// The repository's working-tree root.
    let root: URL
    /// The tree this repository lives in, so that the R5 wave's signing material can be written
    /// *beside* the repository rather than inside it — a key file in the working tree would show
    /// up as an untracked path in every status assertion.
    private let tree: TempTree
    /// The hermetic environment every invocation in this fixture runs with.
    private(set) var environment: [String: String]
    private let runner = ToolRunner()
    fileprivate var commitCount = 0

    /// Creates and initialises a repository at `tree.root/<name>`, on branch `main`.
    init(_ tree: TempTree, name: String = "repo") async throws {
        self.tree = tree
        root = try tree.directory(name)
        let home = try tree.directory("\(name)-home")
        // `PATH` is the test process's, because the fixture has to find the machine's `git`; every
        // other variable is authored here. The dictionary is exhaustive: `ToolRunner` passes
        // exactly what it is given, so anything not listed is absent from the child.
        environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path(percentEncoded: false),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            // `GIT_CONFIG_SYSTEM` disables the system *config* tier and not the system
            // *gitattributes* tier, which is a separate file: a machine-wide `/etc/gitattributes`
            // marking a pattern `-text` or naming a diff driver changes the bytes a later
            // milestone's parser reads, which is the accident D14 exists to prevent.
            "GIT_ATTR_NOSYSTEM": "1",
            // A fixed zone and the C locale, for the same reason. Dates are pinned per commit
            // below, but git renders them in `TZ`; and git's diagnostics and a few of its
            // porcelain words are localised — this machine's git speaks Korean by default.
            "TZ": "UTC",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": Self.authorName,
            "GIT_AUTHOR_EMAIL": Self.authorEmail,
            "GIT_COMMITTER_NAME": Self.authorName,
            "GIT_COMMITTER_EMAIL": Self.authorEmail,
        ]
        try await run(["init", "-b", "main"])
        try await run(["config", "user.name", Self.authorName])
        try await run(["config", "user.email", Self.authorEmail])
    }

    /// Runs `git` with this fixture's environment, at `directory` (the repository root by
    /// default), and throws unless it exits zero.
    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil,
             extraEnvironment: [String: String] = [:]) async throws -> ToolOutput {
        var environment = self.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        let output = try await runner.run(.git, arguments: arguments,
                                          cwd: directory ?? root, environment: environment,
                                          timeout: .seconds(30))
        guard output.exitCode == 0 else {
            throw Failure(subcommand: arguments.first ?? "", exitCode: output.exitCode)
        }
        return output
    }

    /// Writes `files` (relative path to contents), stages everything, and commits.
    @discardableResult
    func commit(message: String, files: [String: String] = [:]) async throws -> String {
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["add", "-A"])
        try await run(["commit", "--allow-empty", "-m", message],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
        let head = try await run(["rev-parse", "HEAD"])
        return head.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates `name` and switches to it.
    func branch(_ name: String) async throws {
        try await run(["checkout", "-b", name])
    }

    /// Switches to an existing ref.
    func checkout(_ ref: String) async throws {
        try await run(["checkout", ref])
    }

    /// Tags the current `HEAD`.
    func tag(_ name: String) async throws {
        try await run(["tag", name])
    }

    /// Merges `refs` into the current branch with a merge commit, never a fast-forward.
    func merge(_ refs: [String], message: String) async throws {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["merge", "--no-ff", "-m", message] + refs,
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Detaches `HEAD` at `ref`.
    func detach(_ ref: String) async throws {
        try await run(["checkout", "--detach", ref])
    }
}

// MARK: - added by milestone 5 (`git diff`), additively and without touching anything above

extension GitFixture {

    /// Writes raw bytes at `relativePath`, creating every intermediate directory, without
    /// staging or committing.
    ///
    /// `commit(message:files:)` takes `[String: String]` and writes UTF-8, which cannot express
    /// the file milestone 5 needs most: a **binary** one, whose `--numstat` counts git prints as
    /// `-` and from which `FileChange.isBinary` is derived. It is also how an *uncommitted* edit
    /// is made, for the `.workingTreeAgainstHEAD` base.
    func write(_ relativePath: String, bytes: Data) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}

// MARK: - added by the R2 fix wave, additively and without touching anything above

extension GitFixture {

    /// Creates `name` starting at `ref` and switches to it.
    ///
    /// `branch(_:)` branches from wherever `HEAD` is, which cannot build a fixture whose branches
    /// fan out from a commit other than the current tip — the shape the lane-reuse tests need.
    func branch(_ name: String, from ref: String) async throws {
        try await run(["checkout", "-b", name, ref])
    }
}

// MARK: - added by the R3 fix wave, additively and without touching anything above

extension GitFixture {

    /// Merges `ref` into the current branch expecting the merge to **conflict**, resolves every
    /// path in `resolution`, and commits the merge.
    ///
    /// `merge(_:message:)` throws on a non-zero exit, which a conflicting merge always is, so it
    /// cannot build the shape the R3 wave needs: a merge commit whose combined listing carries a
    /// two-letter status. The conflict is asserted here rather than assumed — a fixture whose
    /// merge quietly succeeded would build the *ordinary* shape under a name promising the other
    /// one, and the test above it would then pin nothing.
    func mergeResolvingConflict(_ ref: String, message: String,
                                resolution: [String: String]) async throws {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        let attempt = try await runner.run(.git, arguments: ["merge", "--no-ff", "-m", message, ref],
                                           cwd: root, environment: environment, timeout: .seconds(30))
        guard attempt.exitCode != 0 else {
            throw Failure(subcommand: "merge (expected a conflict)", exitCode: 0)
        }
        for (path, contents) in resolution {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try await run(["add", "-A"])
        try await run(["commit", "-m", message],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Creates a symbolic link at `relativePath` pointing at `destination`, without staging it.
    /// `destination` is stored verbatim, so it need not exist — a dangling link is a valid git
    /// object and one of the two shapes the R3 wave pins.
    func symlink(_ relativePath: String, to destination: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // `removeItem` rather than a `fileExists` guard: `fileExists` follows the link and so
        // answers "no" for a dangling one, which is exactly the case being replaced here.
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false),
                                                   withDestinationPath: destination)
    }
}

// MARK: - added by the R5 fix wave, additively and without touching anything above

extension GitFixture {

    /// Turns on **SSH commit signing** for this repository with an ephemeral key, so that a
    /// fixture can exhibit the one condition `log.showSignature` acts on.
    ///
    /// Returns `false` when the machine has no `ssh-keygen` on the fixture's `PATH`; the caller
    /// skips with a named reason rather than failing, because signing is a property of the host
    /// and not of the code under test.
    ///
    /// Everything it writes lives inside the `TempTree`, **beside** the repository and never in
    /// it: the key would otherwise be an untracked path in every status the fixture reports. The
    /// machine's own `~/.ssh` and git configuration are never read or written — `HOME` already
    /// points inside the tree and the configuration is repository-local, exactly as every other
    /// adverse value here is. The key is generated per fixture, lives for the test, and is deleted
    /// with the tree; it is test material, never committed (§11).
    ///
    /// `gpg.ssh.allowedSignersFile` is set as well, so that the verdict git prints under
    /// `log.showSignature` is the **verified** one (`Good "git" signature for …`) rather than the
    /// unverifiable `No signature`. Both forms contaminate the output identically, but a fixture
    /// that could only produce the failure branch would be pinning the weaker of the two.
    func enableSSHSigning() async throws -> Bool {
        guard let keygen = Self.executableOnPath("ssh-keygen", environment) else { return false }
        let keys = try tree.directory("signing-\(UUID().uuidString)")
        let key = keys.appending(path: "id")
        _ = try await ToolRunner().run(executable: keygen,
                                       arguments: ["-t", "ed25519", "-N", "", "-C", Self.authorEmail,
                                                   "-f", key.path(percentEncoded: false), "-q"],
                                       cwd: keys, environment: environment, timeout: .seconds(30))
        let publicKey = try String(contentsOf: keys.appending(path: "id.pub"), encoding: .utf8)
        let allowed = keys.appending(path: "allowed_signers")
        try "\(Self.authorEmail) \(publicKey)".write(to: allowed, atomically: true, encoding: .utf8)

        try await run(["config", "gpg.format", "ssh"])
        try await run(["config", "user.signingkey",
                       keys.appending(path: "id.pub").path(percentEncoded: false)])
        try await run(["config", "gpg.ssh.allowedSignersFile", allowed.path(percentEncoded: false)])
        try await run(["config", "commit.gpgsign", "true"])
        return true
    }

    /// The first executable named `name` on the fixture environment's `PATH`, or nil.
    ///
    /// `ToolRunner.resolve` only answers for the `Tool` cases this module ships, and `ssh-keygen`
    /// is deliberately not one of them: it is fixture machinery, not something the panel runs.
    private static func executableOnPath(_ name: String, _ environment: [String: String]) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":") where component.hasPrefix("/") {
            let candidate = URL(filePath: String(component)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    /// Attaches a git note to `ref`, so that a fixture can exhibit the condition
    /// `notes.displayRef` acts on.
    func note(_ message: String, on ref: String) async throws {
        try await run(["notes", "add", "-m", message, ref])
    }

    /// Creates a bare repository beside this one, pushes `branch` to it and sets it as the
    /// upstream, so that a fixture can exhibit the condition `status.aheadBehind` acts on: with no
    /// upstream configured `git status` prints no `# branch.ab` header at all, and a tripwire over
    /// that setting reads green for want of the header rather than for want of an effect.
    func publishToUpstream(_ branch: String = "main") async throws {
        let remote = try tree.directory("upstream-\(UUID().uuidString)")
        try await run(["init", "--bare", "-b", branch], in: remote)
        try await run(["remote", "add", "origin", remote.path(percentEncoded: false)])
        try await run(["push", "origin", branch])
        try await run(["branch", "--set-upstream-to=origin/\(branch)", branch])
    }

    /// Renames `from` to `to` **and rewrites its contents**, staging both.
    ///
    /// The distinction that matters: git pairs an *exact* rename cheaply, before any limit
    /// applies, while a rename whose content also changed is paired only by the exhaustive pass
    /// that `diff.renameLimit` and `status.renameLimit` cut off. A fixture whose only rename is
    /// exact therefore cannot exhibit a low limit at all — which is why R4 ruled that setting out.
    func renameEditing(_ from: String, to: String, contents: String) async throws {
        try await run(["mv", from, to])
        try contents.write(to: root.appending(path: to), atomically: true, encoding: .utf8)
        try await run(["add", "-A"])
    }
}

// MARK: - added by the W7 `--decorate=full` amendment, additively and without touching anything above

extension GitFixture {

    /// Creates a bare repository beside this one, adds it as the remote `origin`, and pushes
    /// `local` there under `branch`, so that a genuine `refs/remotes/origin/<branch>` exists.
    ///
    /// `publishToUpstream(_:)` pushes a branch to its own name and sets it as the upstream, which
    /// cannot build the shape tracker 115 is about: a remote-tracking ref whose *shortened* name
    /// collides with a local branch's name. Here the remote branch is named independently of the
    /// local one, so a caller can create `refs/heads/origin/feature` alongside
    /// `refs/remotes/origin/feature` and ask the parser to tell them apart.
    func publishAsRemoteBranch(_ local: String, named branch: String) async throws {
        let remote = try tree.directory("remote-\(UUID().uuidString)")
        try await run(["init", "--bare", "-b", "main"], in: remote)
        try await run(["remote", "add", "origin", remote.path(percentEncoded: false)])
        try await run(["push", "origin", "\(local):refs/heads/\(branch)"])
        try await run(["fetch", "origin"])
    }
}

// MARK: - added by the wave-2 fix wave, additively and without touching anything above

extension GitFixture {

    /// Adds `other` as a **submodule** at `relativePath` and commits the addition.
    ///
    /// A submodule is the one entry in a tree that is neither a file nor a link: git records it as
    /// a *gitlink*, mode `160000`, whose object is a commit in another repository. Nothing else a
    /// fixture can build exercises `FileChange.Kind.gitlink`, and no other shape makes
    /// `diff.ignoreSubmodules` speak.
    ///
    /// `protocol.file.allow=always` is passed on this one command line because git refuses the
    /// `file` transport for submodules by default (CVE-2022-39253). It is scoped to the
    /// invocation, the source is another `TempTree` repository, and nothing here reaches the
    /// network or the machine's configuration.
    func addSubmodule(_ other: GitFixture, at relativePath: String) async throws {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["-c", "protocol.file.allow=always", "submodule", "add", "--quiet",
                       other.root.path(percentEncoded: false), relativePath])
        try await run(["commit", "-m", "add the submodule \(relativePath)"],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Commits inside the submodule checked out at `relativePath`, which leaves the superproject's
    /// working tree carrying exactly one change: the gitlink now names a different commit.
    func commitInsideSubmodule(at relativePath: String, message: String,
                               files: [String: String]) async throws {
        let inner = root.appending(path: relativePath)
        for (path, contents) in files {
            let url = inner.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["add", "-A"], in: inner)
        try await run(["commit", "-m", message], in: inner,
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Creates `relativePath` as a directory, so that a test can point a path at something that is
    /// not a repository.
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
