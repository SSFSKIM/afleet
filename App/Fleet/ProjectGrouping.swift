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
    /// outlives the call so the probes are paid once per distinct directory per launch.
    @MainActor
    func sections(from rows: [ChannelRow], paths: PathMemo) -> [ProjectSection] {
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
/// The cache is deliberately not invalidated. A project root moving under a running app is rare and
/// its consequence is cosmetic — a section drawn under the directory the channel was started in —
/// where re-probing three thousand rows on every state transition is a stall the user feels. A
/// relaunch re-reads everything.
@MainActor
final class PathMemo {
    private var rootOfCWD: [String: String] = [:]
    private var repositoryOfRoot: [String: String] = [:]

    /// How many times the filesystem was actually consulted — a miss, not an entry.
    ///
    /// Counting entries instead would measure how many distinct directories the cache knows about,
    /// which is the same number whether the cache was read or not: a memo that resolved afresh every
    /// time and overwrote the same keys has the same entry count as one that never re-probed. This
    /// counts the probes themselves, which is the thing the cache exists to avoid and the only
    /// number a test can hold it to. A count, per §11 — never a path.
    private(set) var probeCount = 0

    init() {}

    /// The canonical project root of a working directory: up to the first `.git`, else the directory.
    func root(of cwd: URL) -> String {
        let key = cwd.path
        if let known = rootOfCWD[key] { return known }
        probeCount += 1
        let resolved = Self.native(CanonicalPath.string(ProjectRoot.canonical(for: cwd).root))
        rootOfCWD[key] = resolved
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
    func repository(of root: String) -> String {
        if let known = repositoryOfRoot[root] { return known }
        probeCount += 1
        let resolved = Self.native(WorktreeLink.mainRepository(of: root) ?? root)
        repositoryOfRoot[root] = resolved
        return resolved
    }

}

/// A git worktree's link back to the repository that owns it.
///
/// A worktree's `.git` is a *file* holding `gitdir: <repo>/.git/worktrees/<name>`, where an ordinary
/// checkout's is a directory. That one difference is the whole detection: no `git` process is run,
/// nothing is written, and a `.git` that is neither shape simply is not a worktree.
///
/// **The `gitdir` may be relative, and it is relative to the worktree.** `git worktree add` writes a
/// relative path whenever the repository is configured for one, so this is an ordinary checkout
/// rather than an exotic one; resolving it as though it were relative to the process names a
/// directory that depends on where the app was launched from and is usually nowhere. The worktree
/// then groups under a repository that does not exist, apart from the real one.
enum WorktreeLink {
    static func mainRepository(of root: String) -> String? {
        let dotGit = root + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = FileManager.default.contents(atPath: dotGit),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let marker = "gitdir:"
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else { return nil }
        let gitDir = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard let separator = gitDir.range(of: "/.git/worktrees/") else { return nil }
        let repository = String(gitDir[gitDir.startIndex..<separator.lowerBound])
        guard !repository.isEmpty else { return nil }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        return CanonicalPath.string(URL(fileURLWithPath: repository, isDirectory: true, relativeTo: base))
    }
}
