import Foundation

/// A git worktree's link back to the repository that owns it, as the engine reads it.
///
/// A linked worktree's `.git` is a **file** holding `gitdir: <repo>/.git/worktrees/<name>`, where an
/// ordinary checkout's is a directory. That one difference is the whole detection: no `git` process
/// is run and nothing is written.
///
/// Two questions are answered here and they are **not** the same question, which is why there are
/// two members rather than one.
///
/// - *Which repository does this checkout belong to, for the user's benefit?* The sidebar's project
///   grouping asks this, and a tolerant answer is the right one: a section drawn under a path that
///   turns out not to be the repository is cosmetic.
/// - *Which directory does the engine key trust and project consent on?* A wrong answer here is not
///   cosmetic — it banners a trusted project as untrusted and refuses to spawn — so it is answered
///   under exactly the engine's own guards and falls back to the checkout whenever any of them does
///   not hold.
///
/// The parsing is shared so the two cannot drift about what a `gitdir:` line means.
public enum WorktreeLayout {

    /// The `gitdir:` a worktree's `.git` file points at, or nil when `<root>/.git` is not a file.
    ///
    /// **The path may be relative, and it is relative to the worktree.** `git worktree add` writes a
    /// relative `gitdir` whenever the repository is configured for one, so this is an ordinary
    /// checkout rather than an exotic one; resolving it against the process's own directory names a
    /// directory that depends on where the app was launched from and is usually nowhere.
    public static func gitDirectory(ofWorktreeAt root: URL) -> URL? {
        let dotGit = root.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path(percentEncoded: false),
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let pointer = line(prefixed: "gitdir:", in: dotGit) else { return nil }
        return URL(filePath: pointer, directoryHint: .isDirectory, relativeTo: root).standardizedFileURL
    }

    /// The repository root the **engine** keys trust and project consent on for a linked worktree,
    /// or nil — meaning *keep the checkout* — when any guard does not hold.
    ///
    /// Transcribed from the engine's own resolver (bundle `SPEC/03-settings-and-configuration.md`
    /// §15.2 and the paragraph above it; 2.1.263 `chunk-gbme4p3n.js:332851-332888`): resolve the git
    /// root, read its `.git` as a file, follow `gitdir:` and then `commondir`, require the common
    /// directory to be the **exact parent** of the gitdir's `worktrees` directory, and require the
    /// reciprocal `gitdir` pointer inside the gitdir to resolve back to the checkout's own `.git`.
    /// Anything else keeps the checkout root.
    ///
    /// The guards are not defensive padding. Without them a `.git` file that merely *looks* like a
    /// worktree link — a hand-written one, a stale one whose repository has moved, a `gitdir:` into
    /// somebody else's tree — would move the trust key to a directory the engine never reads, and
    /// the channel would be refused as untrusted on a project the user has trusted.
    ///
    /// One guard is this transcription's own and the fallback direction is why it is safe: the
    /// common directory's last component must be `.git`, because the repository root is that
    /// directory's parent and there is no way to name a root without it.
    public static func commonRepositoryRoot(ofWorktreeAt root: URL) -> URL? {
        guard let gitDirectory = gitDirectory(ofWorktreeAt: root) else { return nil }
        let worktrees = gitDirectory.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees" else { return nil }
        guard let commonDirectory = resolved(pointerFile: "commondir", in: gitDirectory,
                                             relativeTo: gitDirectory) else { return nil }
        // The exact parent of the `worktrees` directory, compared as real paths so two spellings of
        // one directory — a linked `TMPDIR`, `/private/var` against `/var` — do not read as two.
        guard RealPath.string(commonDirectory) == RealPath.string(worktrees.deletingLastPathComponent()),
              commonDirectory.lastPathComponent == ".git" else { return nil }
        // The reciprocal pointer, which is what tells a *live* link from a stale or forged one.
        guard let back = resolved(pointerFile: "gitdir", in: gitDirectory, relativeTo: gitDirectory),
              RealPath.string(back) == RealPath.string(root.appending(path: ".git")) else { return nil }
        return URL(filePath: RealPath.string(commonDirectory.deletingLastPathComponent()),
                   directoryHint: .isDirectory)
    }

    /// The tolerant answer, for grouping: the main checkout a `gitdir:` path implies, taken from the
    /// `/.git/worktrees/` segment alone.
    ///
    /// It asks none of the guards above on purpose — a checkout whose repository has moved should
    /// still be drawn under the repository the user knows it by — and it is never used to key a
    /// trust or consent read.
    public static func repositoryByPathShape(ofWorktreeAt root: URL) -> URL? {
        guard let gitDirectory = gitDirectory(ofWorktreeAt: root) else { return nil }
        let path = gitDirectory.path(percentEncoded: false)
        guard let separator = path.range(of: "/.git/worktrees/") else { return nil }
        let repository = String(path[path.startIndex..<separator.lowerBound])
        guard !repository.isEmpty else { return nil }
        // No `directoryHint`, deliberately: the caller turns this into a `ProjectSection.id`, and a
        // trailing slash makes one directory two section ids.
        return URL(filePath: repository)
    }

    // MARK: - Reading the pointer files

    private static func resolved(pointerFile name: String, in directory: URL,
                                 relativeTo base: URL) -> URL? {
        let file = directory.appending(path: name)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pointer.isEmpty else { return nil }
        return URL(filePath: pointer, directoryHint: .isDirectory, relativeTo: base).standardizedFileURL
    }

    private static func line(prefixed marker: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else { return nil }
        let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
