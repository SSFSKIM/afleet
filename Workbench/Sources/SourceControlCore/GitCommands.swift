import Foundation

/// The `git` invocations that answer questions about a repository rather than about its content.
///
/// Today that is one question, and it is the one every other reader in this module depends on:
/// *where is the repository root*. Ledger D13 fixed the answer when the module was planned — the
/// channel's cwd is any directory the user opened, commonly a subdirectory, and every command here
/// runs at the root so that `--all`, `status` and the repository-relative paths git prints all mean
/// what the panel shows — but the resolver itself was never written, so every reader trusted the
/// `root` it was handed. That is a wrong answer rather than a failure: run from `repo/subdir`,
/// `git diff` still prints paths relative to the *true* root, so `GitDiff.workingTreeFile` resolved
/// `repo/subdir` + `sub/n.txt` and read a file that does not exist.
public enum GitCommands {

    /// A `rev-parse` is a read of `.git` and nothing else, so it is bounded by disk; the same 30 s
    /// budget the other readers take, for the same reason (D4).
    public static let readTimeout: Duration = .seconds(30)

    /// The working-tree root of the repository containing `cwd`.
    ///
    /// `--show-toplevel` prints the *physical* path — symbolic links in the ancestry are already
    /// resolved by git — which is what makes it usable as the anchor
    /// `GitDiff.workingTreeFile` compares a resolved path against.
    ///
    /// **`--show-superproject-working-tree` considered and rejected.** Asked from inside a
    /// submodule's working tree, it names the *superproject* instead. That is the wrong answer for
    /// this module: the panel shows the repository the channel's directory belongs to, and a
    /// directory inside a submodule belongs to the submodule — its own branch, its own history,
    /// its own `git status`. Climbing to the superproject would silently show the user a different
    /// repository than the one they opened, and the superproject's view of the submodule is a
    /// single gitlink entry (`FileChange.Kind.gitlink`), which is what a panel pointed at the
    /// superproject already sees.
    ///
    /// A directory that is in no repository at all — and a **bare** repository, which has no
    /// working tree and prints nothing on exit 0 — is `.notARepository`: the panel's empty state,
    /// not an error to report (§10, D13).
    public static func repositoryRoot(cwd: URL, environment: [String: String],
                                      runner: any ToolRunning,
                                      timeout: Duration = readTimeout) async throws -> URL {
        let output = try await runner.run(.git, arguments: ["rev-parse", "--show-toplevel"],
                                          cwd: cwd, environment: environment, timeout: timeout)
        try output.requireCompleted(tool: .git, timeout: timeout)
        // Exactly one trailing line feed, because exactly one is framing. `rev-parse` prints the
        // path and terminates the line; every other byte it printed belongs to the pathname, and a
        // directory name may end in a space or a tab — legal on every filesystem this runs on.
        // Trimming the whole whitespace set took those with it and resolved the repository to a
        // directory that does not exist, which every reader then read a working tree out of.
        var path = output.stdoutText
        if path.hasSuffix("\n") { path.removeLast() }
        guard output.exitCode == 0, !path.isEmpty else { throw ToolError.notARepository }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
