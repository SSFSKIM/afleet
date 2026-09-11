import Foundation
import AfleetCore
import FleetKit

/// The engine's global config document's `projects` map, read and never written (X9).
///
/// The engine keys that map by absolute project path and afleet reads it for exactly one thing: the
/// order the user's projects are already in. `TrustReader` reads the same file the same way one
/// level down, and the descriptor is opened with `O_NOFOLLOW` through `ClaudeJSONReader.read` so a
/// symlinked `.claude.json` is refused rather than followed out of the home.
enum ClaudeProjects {

    /// Every project root in the map, in the order its key appears in the file.
    ///
    /// A single left-to-right pass over the **bytes**, not the characters. The first version of
    /// this parsed the document, then located each key by `String.range(of:)` and
    /// `String.distance(from:to:)` over the whole text — both grapheme-level, both restarted per
    /// key, so the work was O(projects x file length) with Unicode segmentation on the inner loop.
    /// Against a config home of 514 KB holding 306 projects that measured 2.08 seconds, on the main
    /// actor, inside the launch: 42 percent of the five-second first-paint budget spent deciding
    /// what order to draw section headers in. The scan below is O(file length) once.
    ///
    /// It is also **correct where the search was only usually correct**. Matching a quoted key
    /// anywhere in the document meant a project path that happened to appear earlier as some other
    /// field's *value* sorted to that earlier position. This reads keys only from inside the
    /// top-level `projects` object, so a value cannot be mistaken for a key.
    /// `globalConfig` is the document's resolved location and **not** a config-home root, because
    /// the two are different directories whenever `CLAUDE_CONFIG_DIR` is unset — see
    /// `ConfigHome.globalConfig`. Appending `.claude.json` to the root here is what made this read
    /// find nothing at all on an ordinary installation, so the resolved URL is what crosses the
    /// boundary and the caller does the resolving once.
    static func order(globalConfig: URL) -> [String] {
        guard let data = ClaudeJSONReader.read(globalConfig) else { return [] }
        return projectKeys(in: data)
    }

    /// The keys of the top-level `projects` object, in document order.
    ///
    /// Deliberately not a full JSON parser: it tracks container depth and string boundaries, which
    /// is all that is needed to tell a key of one particular object from every other string in the
    /// file. A malformed document yields whatever it read before the malformation, which for a
    /// display order is the right failure — the sidebar falls back to activity order and nothing
    /// refuses to launch.
    static func projectKeys(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

        var keys: [String] = []
        var depth = 0
        /// The depth at which this object's keys sit, once `projects` has been entered.
        var projectKeyDepth: Int?
        /// Set between reading the `projects` key and consuming the `{` that opens its object.
        var awaitingProjectsObject = false
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case openBrace, openBracket:
                depth += 1
                if awaitingProjectsObject {
                    // An array here would mean `"projects": [...]`, which is not a shape this file
                    // has; either way the keys we want are not in it.
                    if byte == openBrace { projectKeyDepth = depth }
                    awaitingProjectsObject = false
                }
                index += 1
            case closeBrace, closeBracket:
                // The projects object closing: every key it had has been read.
                if let wanted = projectKeyDepth, depth == wanted { return keys }
                depth -= 1
                index += 1
            case quote:
                var scan = index + 1
                while scan < bytes.count {
                    if bytes[scan] == backslash { scan += 2; continue }
                    if bytes[scan] == quote { break }
                    scan += 1
                }
                guard scan < bytes.count else { return keys }
                let raw = bytes[(index + 1)..<scan]
                var after = scan + 1
                while after < bytes.count, isWhitespace(bytes[after]) { after += 1 }
                let isKey = after < bytes.count && bytes[after] == colon
                if isKey {
                    if depth == projectKeyDepth {
                        if let key = string(from: raw) { keys.append(key) }
                    } else if projectKeyDepth == nil, depth == 1, raw.elementsEqual("projects".utf8) {
                        awaitingProjectsObject = true
                    }
                }
                index = scan + 1
            default:
                index += 1
            }
        }
        return keys
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// A JSON string body as a Swift string. The overwhelmingly common case — an absolute path with
    /// nothing to escape — decodes straight from UTF-8; anything carrying a backslash goes back
    /// through `JSONSerialization` rather than growing a second, subtly different unescaper here.
    private static func string(from raw: ArraySlice<UInt8>) -> String? {
        if !raw.contains(UInt8(ascii: "\\")) { return String(decoding: raw, as: UTF8.self) }
        var quoted = Data([UInt8(ascii: "\"")])
        quoted.append(contentsOf: raw)
        quoted.append(UInt8(ascii: "\""))
        return (try? JSONSerialization.jsonObject(with: quoted, options: [.fragmentsAllowed])) as? String
    }
}

/// Turning rows into the sidebar's project sections (spec §4).
///
/// A section is a **repository root**, not a working directory: several checkouts of one repository
/// are one section with a group per worktree, because that is how the user thinks about them and
/// because two worktrees of one repository sorted apart alphabetically is the thing this grouping
/// exists to prevent.
///
/// Neither pinning nor collapse is modelled here. Both are `FleetKitKeys.grouping`'s
/// `SidebarGrouping`, already C4's, and are read from the value handed in — which the composition
/// root loads from the store, so a user's pin and a user's section order survive a relaunch.
struct ProjectGrouping: Sendable {
    /// `.claude.json`'s project order, longest-standing first.
    var projectOrder: [String]
    /// C4's `SidebarGrouping`: the user's explicit section order, their pinned sessions and the
    /// sections they collapsed.
    var grouping: SidebarGrouping

    init(projectOrder: [String] = [], grouping: SidebarGrouping = SidebarGrouping()) {
        self.projectOrder = projectOrder
        self.grouping = grouping
    }

    /// Sections, ordered: pinned first, then the user's own `sectionOrder`, then `.claude.json`'s
    /// order, then most recently active first.
    ///
    /// `paths` is the filesystem memo and is **required**, not a convenience. Grouping a row means a
    /// `realpath` plus an upward walk of `fileExists` per path component, and then a read of the
    /// candidate's `.git`. Memoising that only inside one call meant the whole set of probes was
    /// repeated from scratch on every rebuild — and a rebuild happens on every `ChannelState`, every
    /// delta, every failed action and every dismissed banner, all on the main actor. The cache
    /// outlives the call so the probes are paid once per distinct directory per launch — except for
    /// a directory that does not exist, which costs one `stat` per rebuild and is re-derived once if
    /// it appears; see `PathMemo`.
    @MainActor
    func sections(from rows: [ChannelRow], paths: PathMemo) -> [ProjectSection] {
        // One generation per rebuild: the memo asks the filesystem about a still-missing directory
        // once per generation rather than once per row that names it.
        paths.beginGeneration()
        var buckets: [String: [String: [ChannelRow]]] = [:]   // repository -> root -> rows

        for row in rows {
            guard let cwd = row.cwd else { continue }
            let root = paths.root(of: cwd)
            let repository = paths.repository(of: root)
            buckets[repository, default: [:]][root, default: []].append(row)
        }

        let pinned = Set(grouping.pinned)
        var sections = buckets.map { repository, byRoot -> ProjectSection in
            let sorted = byRoot.mapValues { $0.sorted { $0.mtime > $1.mtime } }
            let rootURL = URL(fileURLWithPath: repository, isDirectory: true)
            var own = sorted[repository] ?? []
            var worktrees: [WorktreeGroup] = []
            // One checkout is not a sub-grouping: spec §4 sub-groups only when a repository root
            // holds several.
            if sorted.count == 1 {
                own = sorted.values.first ?? []
            } else {
                for (root, rows) in sorted where root != repository {
                    worktrees.append(WorktreeGroup(id: root,
                                                   root: URL(fileURLWithPath: root, isDirectory: true),
                                                   title: (root as NSString).lastPathComponent,
                                                   rows: rows))
                }
                worktrees.sort { $0.title < $1.title }
            }
            let all = own + worktrees.flatMap(\.rows)
            return ProjectSection(id: repository,
                                  root: rootURL,
                                  title: (repository as NSString).lastPathComponent,
                                  isPinned: all.contains { pinned.contains($0.id) },
                                  rows: own,
                                  worktrees: worktrees)
        }

        let explicit = index(of: grouping.sectionOrder)
        let declared = index(of: projectOrder)
        let newest = Dictionary(uniqueKeysWithValues: sections.map {
            ($0.id, $0.allRows.map(\.mtime).max() ?? .distantPast)
        })
        sections.sort { left, right in
            if left.isPinned != right.isPinned { return left.isPinned }
            let leftExplicit = explicit[left.id] ?? Int.max
            let rightExplicit = explicit[right.id] ?? Int.max
            if leftExplicit != rightExplicit { return leftExplicit < rightExplicit }
            let leftDeclared = declared[left.id] ?? Int.max
            let rightDeclared = declared[right.id] ?? Int.max
            if leftDeclared != rightDeclared { return leftDeclared < rightDeclared }
            let leftNewest = newest[left.id] ?? .distantPast
            let rightNewest = newest[right.id] ?? .distantPast
            if leftNewest != rightNewest { return leftNewest > rightNewest }
            return left.id < right.id
        }
        return sections
    }

    private func index(of order: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (position, key) in order.enumerated() where map[key] == nil { map[key] = position }
        return map
    }
}

/// The filesystem answers grouping needs, remembered for the life of the model that owns it.
///
/// Two questions, each of which costs syscalls: which directory is a working directory's project
/// root, and which repository owns that root. Both answers are properties of the filesystem rather
/// than of the fleet, so they are the same on every rebuild and are cached across all of them.
///
/// A settled answer is deliberately never invalidated. A project root moving under a running app is
/// rare and its consequence is cosmetic — a section drawn under the directory the channel was
/// started in — where re-probing three thousand rows on every state transition is a stall the user
/// feels. A relaunch re-reads everything.
///
/// **An answer about a directory that does not exist is a different thing and is held separately.**
/// It is not a property of the filesystem yet: the case that produces it is §8.2's worktree
/// creation, which names `<repo>/.claude/worktrees/<name>` before the CLI has made the checkout, and
/// the fallback answer for that path is the repository itself — so settling it would group the
/// checkout's channel into the repository's own rows for the life of the process, once the checkout
/// finally exists. Such an answer therefore goes in `provisional`, and each rebuild pays **one
/// `stat`** to ask whether the directory has appeared: on a real config home 452 of 3,244 rows point
/// at a directory that is gone, and re-deriving all of them per rebuild — a `realpath` plus an
/// upward walk of seven-odd components each — would put four thousand syscalls on the main actor
/// per `ChannelState`, which is the stall this type was introduced to remove.
@MainActor
final class PathMemo {
    private var rootOfCWD: [String: String] = [:]
    private var repositoryOfRoot: [String: String] = [:]
    /// Answers about directories that did not exist when they were derived, keyed the same way.
    /// Re-derived on the first rebuild that finds the directory there, and settled then.
    private var provisionalRoot: [String: String] = [:]
    private var provisionalRepository: [String: String] = [:]
    /// Which (question, path) pairs this rebuild has already asked the filesystem about, so each is
    /// asked once per rebuild rather than once per row.
    ///
    /// A rebuild groups two rows of one missing project — the ordinary case, since a project the
    /// user worked in has several channels — and `root(of:)` is asked once per row. Without this the
    /// stat is paid per row, and `repository(of:)` pays a second one for the same directory: four
    /// stats for one absent project with two channels.
    ///
    /// **Keyed by the question and not by the path alone.** A missing directory with no `.git` above
    /// it is its own root, so `root(of:)` and `repository(of:)` are asked about the *same* path: the
    /// first is handed `cwd.path` and the second the canonical root, and `URL.path` strips a
    /// directory URL's trailing slash, so those are one identical string. A set keyed on paths alone
    /// therefore made the second question skip its own stat and hand back a provisional answer that
    /// a checkout appearing would never refresh. Cleared by `beginGeneration()`, which
    /// `sections(from:paths:)` calls.
    private var askedThisGeneration: Set<Question> = []

    /// Which of the two answers a memo entry is about, with the path it is about.
    private struct Question: Hashable {
        enum Kind: Hashable { case root, repository }
        var kind: Kind
        var path: String
    }

    /// How many times the filesystem was actually consulted — a miss, not an entry.
    ///
    /// Counting entries instead would measure how many distinct directories the cache knows about,
    /// which is the same number whether the cache was read or not: a memo that resolved afresh every
    /// time and overwrote the same keys has the same entry count as one that never re-probed. This
    /// counts the probes themselves, which is the thing the cache exists to avoid and the only
    /// number a test can hold it to. A count, per §11 — never a path.
    ///
    /// It does **not** count the one `fileExists` a missing directory costs per rebuild: that stat
    /// is the gate that keeps the derivation from being re-run, not the derivation.
    private(set) var probeCount = 0

    /// How many times the filesystem was asked *whether a path exists* — the gate that keeps a
    /// missing directory from being re-derived.
    ///
    /// Counted separately from `probeCount` and counted at all for one reason: it is a syscall on
    /// the main actor inside a rebuild, so it is a cost, and a cost no test can see is a cost that
    /// grows. `probeCount` stays what it was — the derivation the cache exists to avoid — because
    /// folding the two would make the existing cost test unable to tell them apart.
    private(set) var existenceCheckCount = 0

    init() {}

    /// Starts a new rebuild's generation, forgetting which paths this memo has already asked about.
    ///
    /// Called by `ProjectGrouping.sections(from:paths:)` and by nothing else: the generation is a
    /// rebuild, and a caller that grouped twice under one generation would be told a directory is
    /// still missing after it appeared.
    func beginGeneration() { askedThisGeneration.removeAll(keepingCapacity: true) }

    /// Whether `path` is on disk, asked at most once per (question, path) per rebuild.
    ///
    /// The first generation that meets a path costs one stat per question — there is no provisional
    /// answer yet, so the caller is going to derive anyway and a gate would buy nothing — and every
    /// later generation costs one per question until the directory appears.
    private func exists(_ path: String, _ kind: Question.Kind, provisional: Bool) -> Bool {
        guard provisional else { return checkedExists(path) }
        let asked = Question(kind: kind, path: path)
        guard !askedThisGeneration.contains(asked) else { return false }
        askedThisGeneration.insert(asked)
        return checkedExists(path)
    }

    private func checkedExists(_ path: String) -> Bool {
        existenceCheckCount += 1
        return FileManager.default.fileExists(atPath: path)
    }

    /// The canonical project root of a working directory: up to the first `.git`, else the directory.
    ///
    /// A directory that does not exist yet is answered **provisionally**: the answer is returned so
    /// the row is placed, and the next rebuild re-derives it if the directory has appeared. See the
    /// note on the type for why that case is worth one `stat` a rebuild and why settling it is not.
    func root(of cwd: URL) -> String {
        let key = cwd.path
        if let known = rootOfCWD[key] { return known }
        // The gate is not counted as a probe — `probeCount` measures the derivation the cache exists
        // to avoid — but it *is* counted, under `existenceCheckCount`: see that property.
        let exists = exists(key, .root, provisional: provisionalRoot[key] != nil)
        if !exists, let provisional = provisionalRoot[key] { return provisional }
        probeCount += 1
        // **The checkout and not the trust key.** §8.2 sub-groups a repository that holds several
        // checkouts, and that grouping is keyed on the directory a channel actually runs in; the
        // trust key is the repository, so keying on it collapses every worktree into its repository
        // body and the sub-grouping disappears. `WorktreeLink` below is what finds the repository
        // for the section, from this root.
        let resolved = Self.native(CanonicalPath.string(ProjectRoot.roots(for: cwd).checkout))
        if exists {
            rootOfCWD[key] = resolved
            provisionalRoot[key] = nil
        } else {
            provisionalRoot[key] = resolved
        }
        return resolved
    }

    /// A path string that is really a Swift string, not a lazily bridged `NSPathStore2`.
    ///
    /// **Found by sampling the running app, not by reasoning.** `CanonicalPath.string` ends in
    /// `(out as NSString).appendingPathComponent(_:)`, so the path it returns is an `NSString`
    /// bridged back — and every `Hashable` operation on such a string runs
    /// `_StringGutsSlice._normalizedHash`, which walks it through `-[NSPathStore2 characterAtIndex:]`
    /// one Objective-C message per character with NFC normalisation on top. These strings become
    /// `ProjectSection.id` and `WorktreeGroup.id`, which SwiftUI hashes into its `ForEach` identity
    /// dictionary on every list diff. Against a real config home of 306 projects that pinned the
    /// main thread at 100 percent inside `OutlineListCoordinator.diffRows`, with
    /// `Dictionary.lookup` and `characterAtIndex:` at the top of the profile and the window
    /// unresponsive. Copying the bytes once per distinct directory per launch — this memo's whole
    /// purpose — makes every later hash a native one.
    private static func native(_ path: String) -> String {
        String(decoding: Array(path.utf8), as: UTF8.self)
    }

    /// The repository a root belongs to: itself, or the main checkout when the root is a worktree.
    ///
    /// Provisional for a root that does not exist, for `root(of:)`'s reason: a worktree's `.git` is
    /// the file that identifies it, and a checkout the CLI has not made yet has none.
    func repository(of root: String) -> String {
        if let known = repositoryOfRoot[root] { return known }
        let exists = exists(root, .repository, provisional: provisionalRepository[root] != nil)
        if !exists, let provisional = provisionalRepository[root] { return provisional }
        probeCount += 1
        let resolved = Self.native(WorktreeLink.mainRepository(of: root) ?? root)
        if exists {
            repositoryOfRoot[root] = resolved
            provisionalRepository[root] = nil
        } else {
            provisionalRepository[root] = resolved
        }
        return resolved
    }

}

/// A git worktree's link back to the repository that owns it, for **grouping**.
///
/// The parsing is `WorktreeLayout`'s, in FleetSessions, so the sidebar and the trust reader cannot
/// drift about what a `gitdir:` line means or about resolving a relative one against the worktree.
/// What is different here is the *question*: grouping wants the repository a user knows a checkout
/// by, so it takes the tolerant answer and asks none of the engine's trust guards. A checkout whose
/// repository has moved still draws under the repository it was made from; keying a trust read that
/// way would be a defect, which is why `ProjectRoot.canonical` takes the guarded answer instead.
enum WorktreeLink {
    static func mainRepository(of root: String) -> String? {
        WorktreeLayout.repositoryByPathShape(ofWorktreeAt: URL(filePath: root, directoryHint: .isDirectory))
            .map { CanonicalPath.string($0) }
    }
}
