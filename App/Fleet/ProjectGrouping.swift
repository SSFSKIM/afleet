import Foundation
import AfleetCore
import FleetKit

/// `<configHome>/.claude.json`'s `projects` map, read and never written (X9).
///
/// The engine keys that map by absolute project path and afleet reads it for exactly one thing: the
/// order the user's projects are already in. `TrustReader` reads the same file the same way one
/// level down, and the descriptor is opened with `O_NOFOLLOW` through `ClaudeJSONReader.read` so a
/// symlinked `.claude.json` is refused rather than followed out of the home.
enum ClaudeProjects {

    /// Every project root in the map, in the order its key appears in the file.
    ///
    /// JSON objects carry no order and `JSONSerialization` returns an unordered dictionary, so the
    /// keys are recovered by parsing and then sorted by where each key's own quoted spelling first
    /// occurs in the bytes. A project key is an absolute filesystem path, which does not occur
    /// earlier in the document by accident; where two keys somehow tie, the tie is broken
    /// lexicographically so the order is at least stable across launches.
    static func order(configHome: URL) -> [String] {
        let file = configHome.appending(path: ".claude.json")
        guard let data = ClaudeJSONReader.read(file),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = document["projects"] as? [String: Any]
        else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let offsets: [(key: String, offset: Int)] = projects.keys.map { key in
            let quoted = "\"" + key.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            let offset = text.range(of: quoted).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
            return (key, offset ?? Int.max)
        }
        return offsets.sorted { $0.offset == $1.offset ? $0.key < $1.key : $0.offset < $1.offset }.map(\.key)
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
/// `SidebarGrouping`, already C4's, and are read from the value handed in.
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
    func sections(from rows: [ChannelRow]) -> [ProjectSection] {
        // cwd -> its own root, and root -> the repository that owns it. Both resolutions hit the
        // filesystem, so they are memoised across the rows of one build; a fleet of three thousand
        // channels holds a few dozen distinct directories.
        var rootOfCWD: [String: String] = [:]
        var repositoryOfRoot: [String: String] = [:]
        var buckets: [String: [String: [ChannelRow]]] = [:]   // repository -> root -> rows

        for row in rows {
            guard let cwd = row.cwd else { continue }
            let cwdPath = CanonicalPath.string(cwd)
            let root: String
            if let known = rootOfCWD[cwdPath] {
                root = known
            } else {
                root = CanonicalPath.string(ProjectRoot.canonical(for: cwd).root)
                rootOfCWD[cwdPath] = root
            }
            let repository: String
            if let known = repositoryOfRoot[root] {
                repository = known
            } else {
                repository = WorktreeLink.mainRepository(of: root) ?? root
                repositoryOfRoot[root] = repository
            }
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

/// A git worktree's link back to the repository that owns it.
///
/// A worktree's `.git` is a *file* holding `gitdir: <repo>/.git/worktrees/<name>`, where an ordinary
/// checkout's is a directory. That one difference is the whole detection: no `git` process is run,
/// nothing is written, and a `.git` that is neither shape simply is not a worktree.
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
        return repository.isEmpty ? nil : CanonicalPath.string(URL(fileURLWithPath: repository))
    }
}
