import Foundation
import Observation
import AfleetCore
import SourceControlCore

/// The Files panel's directory listing: what a directory holds, in what order, and which of its
/// entries git ignores (spec Design §3).
///
/// **Lazy, and refreshed rather than watched.** A directory is enumerated the first time it is
/// asked for and never again until `refresh` says so. Root spec §9.1 asks for a watcher over *open
/// files*; a recursive watch over a working tree is a different instrument with a different failure
/// mode — an FSEvents stream over a `node_modules` — so the tab re-enumerates on expansion, on the
/// panel's *Refresh*, and after a save that created a file.
///
/// **Symbolic links are listed and never followed into.** A link to an ancestor is a cycle and the
/// tree has no other defence, so a link is marked on the node, sorts as a leaf, and expanding it
/// enumerates nothing.
///
/// **Nothing here throws.** Every git failure — no repository, no `git` on the resolved `PATH`, a
/// listing git would not classify — becomes `gitignore == .unavailable` and a complete listing,
/// which is the panel-local state root spec §10 asks for rather than an error crossing into the
/// conversation.
@MainActor
@Observable
public final class FileTree {

    /// One entry of a directory listing.
    ///
    /// `isDirectory` is false for a symbolic link *to* a directory, deliberately: it is the
    /// property the view asks before offering an expander, and this tree does not follow links.
    public struct Node: Identifiable, Hashable, Sendable {
        public let url: URL
        public let name: String
        public let isDirectory: Bool
        public let isSymbolicLink: Bool
        /// True only when a classification actually ran and named this entry. When the toggle is
        /// unavailable nothing is ignored, which is what makes "shows everything" fall out of the
        /// ordinary path rather than out of a special case.
        public let isIgnored: Bool

        public var id: URL { url }
    }

    /// Whether the gitignore toggle has an answer to give.
    ///
    /// `.unavailable` is the panel-local state a directory in no repository, or a machine with no
    /// `git` on the channel's resolved `PATH`, resolves to: the preference is kept, the listing is
    /// complete, and the view draws the toggle as unavailable (§10).
    public enum GitignoreAvailability: Equatable, Sendable {
        case unknown
        case available
        case unavailable
    }

    /// The tree's anchor — the channel's directory.
    public let root: URL

    /// Dotfiles are hidden until this is set. A pure view property: the enumeration keeps them.
    public var showsHiddenFiles = false

    /// A case-insensitive substring over the names of the **loaded** nodes.
    ///
    /// Not a search: §9's *Deferred* names "search across the Files tree" as out of scope, and a
    /// filter that walked the tree would be that feature with no budget for it. Setting it never
    /// enumerates anything.
    public var filter = ""

    /// Whether entries git ignores are hidden. Changed through `setHidesIgnoredFiles(_:)`, because
    /// turning it on is what pays for the classification.
    public private(set) var hidesIgnoredFiles: Bool

    /// Whether the classification has an answer for this tree.
    public private(set) var gitignore: GitignoreAvailability = .unknown

    private let environment: [String: String]
    private let runner: any ToolRunning
    private let timeout: Duration
    private var loaded: [URL: [Node]] = [:]

    public init(root: URL, environment: [String: String], runner: any ToolRunning,
                hidesIgnoredFiles: Bool = true, timeout: Duration = GitCommands.readTimeout) {
        self.root = root
        self.environment = environment
        self.runner = runner
        self.hidesIgnoredFiles = hidesIgnoredFiles
        self.timeout = timeout
    }

    /// The channel-facing form. X11: every `git` afleet spawns runs with the channel's captured
    /// environment, never this process's.
    public convenience init(root: URL, environment: ResolvedEnvironment, runner: any ToolRunning,
                            hidesIgnoredFiles: Bool = true,
                            timeout: Duration = GitCommands.readTimeout) {
        self.init(root: root, environment: environment.variables, runner: runner,
                  hidesIgnoredFiles: hidesIgnoredFiles, timeout: timeout)
    }

    // MARK: - listing

    /// `directory`'s visible entries, enumerating it once if it has not been enumerated yet.
    ///
    /// A symbolic link and anything that is not a directory answer with nothing and are not
    /// recorded, so a link to an ancestor cannot become a cycle.
    public func children(of directory: URL) async -> [Node] {
        if loaded[directory] == nil {
            guard isEnumerable(directory) else { return [] }
            loaded[directory] = await enumerate(directory)
        }
        return visible(loaded[directory] ?? [])
    }

    /// Everything loaded for `directory`, unfiltered and unhidden — the classification itself,
    /// which is what a view draws an "ignored" row from and what a test asserts over.
    public func entries(of directory: URL) -> [Node] { loaded[directory] ?? [] }

    public func isLoaded(_ directory: URL) -> Bool { loaded[directory] != nil }

    /// Discards `directory`'s listing and enumerates it again, if it was loaded at all.
    public func refresh(_ directory: URL) async {
        guard loaded[directory] != nil, isEnumerable(directory) else { return }
        loaded[directory] = await enumerate(directory)
    }

    /// Re-enumerates every loaded directory. The panel's *Refresh*.
    public func refreshAll() async {
        for directory in loaded.keys { await refresh(directory) }
    }

    /// Sets the gitignore toggle, re-enumerating what is loaded when it is turned on.
    ///
    /// Asynchronous, and not a plain property, because the classification is a `git` invocation per
    /// loaded directory: a listing loaded while the toggle was off carries no answer, and a toggle
    /// that flipped a boolean would hide nothing until the user happened to refresh.
    public func setHidesIgnoredFiles(_ hidden: Bool) async {
        guard hidden != hidesIgnoredFiles else { return }
        hidesIgnoredFiles = hidden
        if hidden { await refreshAll() }
    }

    // MARK: - enumeration

    /// True when `directory` is a directory this tree may descend into — which a symbolic link
    /// never is, whatever it points at.
    private func isEnumerable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// One directory, sorted and classified.
    ///
    /// Directories first and then by localized name, because that is the order a person reads a
    /// tree in; `localizedStandardCompare` rather than a raw `<`, so that case and embedded numbers
    /// order the way the Finder orders them.
    private func enumerate(_ directory: URL) async -> [Node] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])) ?? []
        var entries = contents.map { url -> (url: URL, isDirectory: Bool, isLink: Bool) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink == true
            return (url, values?.isDirectory == true && !isLink, isLink)
        }
        entries.sort { one, other in
            if one.isDirectory != other.isDirectory { return one.isDirectory }
            return one.url.lastPathComponent
                .localizedStandardCompare(other.url.lastPathComponent) == .orderedAscending
        }
        let names = entries.map(\.url.lastPathComponent)
        let ignored = hidesIgnoredFiles ? await classify(names, in: directory) : nil
        if hidesIgnoredFiles { gitignore = ignored == nil ? .unavailable : .available }
        return entries.enumerated().map { index, entry in
            Node(url: entry.url, name: names[index], isDirectory: entry.isDirectory,
                 isSymbolicLink: entry.isLink, isIgnored: ignored?[index] ?? false)
        }
    }

    /// The hidden-files toggle and the filter, in that order. Neither loads anything.
    private func visible(_ nodes: [Node]) -> [Node] {
        nodes.filter { node in
            if !showsHiddenFiles, node.name.hasPrefix(".") { return false }
            if hidesIgnoredFiles, node.isIgnored { return false }
            if !filter.isEmpty,
               node.name.range(of: filter, options: .caseInsensitive) == nil { return false }
            return true
        }
    }

    // MARK: - the gitignore batch

    /// Which of `names` git ignores, in the order given, or nil when the question cannot be asked.
    ///
    /// **One invocation per directory, not one per row.** A listing is one process; a per-file
    /// `check-ignore` would be one process per row of a tree the user is scrolling.
    ///
    /// **`--verbose --non-matching`, and the answer is read by position.** Spec Design §3 spells
    /// this batch `--stdin -z`, which cannot be run here: `ToolRunner` opens every child's stdin on
    /// `/dev/null` (there is no stdin on `ToolRunning.run`), so `--stdin` would read EOF and report
    /// nothing ignored, and measured on `git` 2.55.0 `-z` is refused outright without `--stdin`.
    /// Without `-z` git C-quotes any path carrying a newline, a quote or a backslash — the quoting
    /// D7 refused to reimplement. `--non-matching` closes that gap instead: git prints exactly one
    /// record per input path, in input order, so the *position* of a record answers the question
    /// and the pathname it echoes is never decoded. A record that did not match any pattern begins
    /// `::\t`. The deviation is reported to the executor rather than resolved by adding a `git`
    /// invocation to another leaf's module (W7).
    ///
    /// **Exit 1 is a normal answer**, not a failure: it is what git says when nothing matched. Only
    /// 0 and 1 are answers; anything else — 128 for a directory in no repository — is
    /// `.unavailable`, and so is a `PATH` holding no `git` at all.
    ///
    /// Each name is passed as `./<name>` after `--`, because a name beginning with `:` is otherwise
    /// read as *pathspec magic* rather than as a file.
    private func classify(_ names: [String], in directory: URL) async -> [Bool]? {
        guard !names.isEmpty else { return [] }
        var answers: [Bool] = []
        for batch in Self.batches(of: names) {
            let arguments = ["check-ignore", "--verbose", "--non-matching", "--no-index", "--"]
                + batch.map { "./" + $0 }
            guard let output = try? await runner.run(.git, arguments: arguments, cwd: directory,
                                                     environment: environment, timeout: timeout),
                  (try? output.requireCompleted(tool: .git, timeout: timeout)) != nil,
                  output.exitCode == 0 || output.exitCode == 1
            else { return nil }
            var records = output.stdoutText.split(separator: "\n", omittingEmptySubsequences: false)
            if records.last?.isEmpty == true { records.removeLast() }
            // A record per input path is the contract this reading rests on. When git printed a
            // different number the positions no longer name the paths that were asked about, and
            // hiding the wrong rows is worse than not hiding any.
            guard records.count == batch.count else { return nil }
            answers += records.map { !$0.hasPrefix("::\t") }
        }
        return answers
    }

    /// The names split into command lines whose arguments stay far below `ARG_MAX`.
    ///
    /// A directory with tens of thousands of long names is the one shape that would otherwise fail
    /// at spawn, which reads as "the toggle is unavailable" for a repository that is perfectly
    /// readable. In every ordinary listing this yields exactly one batch.
    private static let argumentBudget = 128 * 1024

    private static func batches(of names: [String]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var used = 0
        for name in names {
            let cost = name.utf8.count + 3
            if !current.isEmpty, used + cost > argumentBudget {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(name)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
