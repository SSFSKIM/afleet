import Foundation
import Darwin

/// Real paths, and only real paths.
///
/// `URL.standardizedFileURL` rewrites `/private/var` back to `/var` and undoes symlink resolution, so two spellings
/// of one directory compare unequal and a containment check written against it passes where it should refuse. Every
/// path this module compares — a trust key, a config-home containment, a descriptor's `F_GETPATH` — goes through
/// `realpath(3)` here instead.
enum RealPath {
    /// `realpath(3)`, or the path as given when the entry does not exist. Never a trailing slash.
    static func string(_ url: URL) -> String {
        let given = trimmed(url.path(percentEncoded: false))
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard given.withCString({ Darwin.realpath($0, &buffer) }) != nil else { return given }
        return trimmed(Self.string(fromCString: buffer))
    }

    /// A NUL-terminated C buffer as a Swift string. `String(cString:)` over an array is deprecated, and the whole
    /// PATH_MAX buffer decoded whole would carry its padding.
    static func string(fromCString buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func url(_ url: URL) -> URL { URL(filePath: string(url)) }

    /// `path` equals `root` or lies under it. Both sides must already be real paths.
    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func trimmed(_ path: String) -> String {
        var out = path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// The canonical root of a channel: the real path of its directory walked up to the first entry containing `.git`
/// (a file or a directory — a worktree's `.git` is a file), else the real path itself (parent §6.12, spec
/// *Preconditions*).
public enum ProjectRoot {
    /// The root every trust and consent decision is keyed on, and the git root when there is one. They are the same
    /// directory whenever a `.git` was found; `gitRoot` is nil exactly when the walk found none.
    public static func canonical(for cwd: URL) -> (root: URL, gitRoot: URL?) {
        let resolved = RealPath.string(cwd)
        var probe = resolved
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: probe + "/.git") {
                let root = URL(filePath: probe)
                return (root, root)
            }
            guard let slash = probe.lastIndex(of: "/"), slash != probe.startIndex else { break }
            probe = String(probe[probe.startIndex..<slash])
        }
        return (URL(filePath: resolved), nil)
    }
}

/// Read-only. afleet never writes trust: the only in-protocol trust write is `set_cwd`'s `needs_trust` handshake,
/// and the app re-reads this value after a terminal pane exits (parent §6.11, §6.12).
public enum TrustReader {
    /// `projects[<root>].hasTrustDialogAccepted == true` in the engine's global config document. Anything else —
    /// a missing file, a missing entry, an explicit `false`, a non-boolean — is untrusted.
    ///
    /// The document is passed in rather than derived from the config home, because it is not always inside one:
    /// the engine resolves it as `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")`
    /// (2.1.263 `cli.pretty.js:298330`) while the home is `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")`
    /// (`:298581`). With the variable unset — every ordinary installation — the document is the home's sibling
    /// `~/.claude.json`, and `<home>/.claude.json` names a file the engine never reads. `ConfigHome.globalConfig`
    /// applies that rule; this reader only opens what it is given.
    public static func isTrusted(root: URL, globalConfig: URL) -> Bool {
        guard let data = try? Data(contentsOf: globalConfig),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = document["projects"] as? [String: Any],
              let entry = projects[RealPath.string(root)] as? [String: Any] else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool == true
    }
}
