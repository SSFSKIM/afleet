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
    /// The hermetic environment every invocation in this fixture runs with.
    private(set) var environment: [String: String]
    private let runner = ToolRunner()
    private var commitCount = 0

    /// Creates and initialises a repository at `tree.root/<name>`, on branch `main`.
    init(_ tree: TempTree, name: String = "repo") async throws {
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
