import Foundation
import AfleetCore
import EditorCore
import SourceControlCore

/// What a `.diff` link resolves to: the pair to show, or the named reason there is no text diff
/// to show (spec Design §5, gate G3).
///
/// The second case is a panel-local state (root spec §10) rather than an error: a binary change, a
/// submodule and a path the base did not touch are all perfectly ordinary answers, and drawing an
/// empty diff editor for any of them would be a lie about the repository.
public enum DiffPairResolution: Sendable, Equatable {
    case pair(EditorCommand)
    case noTextDiff(Reason)

    public enum Reason: Sendable, Equatable {
        /// The changed-file list for this base does not carry the path at all.
        case pathUnchangedByBase
        /// git reported no line counts for it, so there is nothing to diff as text.
        case binaryContent
        /// A gitlink: the entry names a commit in another repository, and neither side is a blob.
        case submodule
    }
}

/// Resolves a `DiffRef` into the two whole texts Monaco's diff editor takes.
///
/// **The changed-file list decides which sides exist**, and that is the step that makes this
/// correct rather than merely working. `added` has no original side, `deleted` has no modified
/// side, a rename or a copy reads its original side at the *old* path, `isBinary` offers no text
/// diff and a gitlink is never blob-read. A resolver without this step has to guess, and both
/// guesses it would make — read each side and treat a failure as empty, or key both sides on the
/// new path — are exactly the added-file and renamed-file defects G3 tests for.
///
/// **Every `git` invocation is C7.3's** (contract W7): `GitCommands.repositoryRoot`,
/// `GitDiff.changes`, `GitDiff.blob` and `GitDiff.workingTreeFile`. The base-to-sides mapping below
/// is read off `GitDiff.arguments(for:)`, so the pair this shows is a pair of the list the panel
/// listed.
public struct DiffPairResolver: Sendable {

    /// The Monaco language id for a repository-relative path.
    ///
    /// A seam, not a map. `MonacoLanguage.id(for:)` is written by another task in this wave; until
    /// the executor wires it in at integration, the default answers `plaintext`, which is what
    /// Monaco would have inferred for an unmapped extension anyway.
    public typealias LanguageForPath = @Sendable (String) -> String

    public static let plaintext: LanguageForPath = { _ in "plaintext" }

    private let runner: any ToolRunning
    private let environment: [String: String]
    private let language: LanguageForPath
    private let timeout: Duration

    public init(runner: any ToolRunning, environment: [String: String],
                language: @escaping LanguageForPath = DiffPairResolver.plaintext,
                timeout: Duration = GitDiff.readTimeout) {
        self.runner = runner
        self.environment = environment
        self.language = language
        self.timeout = timeout
    }

    /// The channel-facing form. X11: a `git` afleet spawns runs with the channel's captured
    /// environment.
    public init(runner: any ToolRunning, environment: ResolvedEnvironment,
                language: @escaping LanguageForPath = DiffPairResolver.plaintext,
                timeout: Duration = GitDiff.readTimeout) {
        self.init(runner: runner, environment: environment.variables, language: language,
                  timeout: timeout)
    }

    /// Resolves `reference` in three steps: the root, the changed-file list, then the two sides.
    ///
    /// Throws only what `SourceControlCore` throws — a `ToolError`, which the session renders in
    /// the panel's own area (§10). Everything this leaf decides is a `DiffPairResolution` case.
    public func resolve(_ reference: DiffRef) async throws -> DiffPairResolution {
        // The link's `repository` is documented as the working-tree root; resolving it again costs
        // one `rev-parse` and makes a link that named a subdirectory harmless, since every path
        // below is repository-relative whatever directory git ran in.
        let root = try await GitCommands.repositoryRoot(cwd: reference.repository,
                                                        environment: environment, runner: runner,
                                                        timeout: timeout)
        let changes = try await GitDiff.changes(root: root, base: reference.base,
                                                environment: environment, runner: runner,
                                                timeout: timeout)
        guard let change = changes.first(where: { $0.path == reference.path }) else {
            return .noTextDiff(.pathUnchangedByBase)
        }
        if change.kind == .gitlink { return .noTextDiff(.submodule) }
        if change.isBinary { return .noTextDiff(.binaryContent) }

        let originalPath = switch change.status {
        case .renamed(let from, _), .copied(let from, _): from
        default: reference.path
        }
        let original = change.status == .added
            ? Data()
            : try await originalSide(reference.base, root: root, path: originalPath)
        let modified = change.status == .deleted
            ? Data()
            : try await modifiedSide(reference.base, root: root, path: reference.path)

        return .pair(.showDiff(path: reference.path,
                               original: text(original), modified: text(modified),
                               language: language(reference.path)))
    }

    /// The side the base diffs *from*.
    ///
    /// `.commitAgainstParent` reads `<hash>^`, the first parent — the side `show --first-parent`
    /// diffs against. It does not exist for a **root commit**, which is why this is never reached
    /// there: step two has already reported every path of a root commit as `added`.
    private func originalSide(_ base: DiffRef.Base, root: URL, path: String) async throws -> Data {
        let revision = switch base {
        case .workingTreeAgainstHEAD: "HEAD"
        case .commit(let hash): hash
        case .commitAgainstParent(let hash): hash + "^"
        }
        return try await GitDiff.blob(root: root, rev: revision, path: path,
                                      environment: environment, runner: runner, timeout: timeout)
    }

    /// The side the base diffs *to*: the working tree for the two bases that end there, and the
    /// commit itself for `.commitAgainstParent`.
    private func modifiedSide(_ base: DiffRef.Base, root: URL, path: String) async throws -> Data {
        switch base {
        case .workingTreeAgainstHEAD, .commit:
            return try GitDiff.workingTreeFile(root: root, path: path)
        case .commitAgainstParent(let hash):
            return try await GitDiff.blob(root: root, rev: hash, path: path,
                                          environment: environment, runner: runner,
                                          timeout: timeout)
        }
    }

    /// Both sides decoded as UTF-8 **with replacement**, which spec Design §5 records as a
    /// deliberate choice: Monaco takes strings, and refusing to show the diff of a file carrying
    /// one invalid byte is worse for the user than showing it with a replacement character. This is
    /// the contents half of tracker 189, whose first half is `SourceControlCore`'s lossy decode of
    /// path bytes.
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}
