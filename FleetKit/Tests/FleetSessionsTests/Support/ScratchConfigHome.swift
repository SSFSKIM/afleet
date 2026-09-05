import Foundation
import AfleetCore

/// A config home the test owns outright, laid out like the real one: `sessions/`, `jobs/`, `daemon/roster.json`,
/// `projects/` and `.claude.json`.
///
/// Nothing in FleetSessions or its tests may write under a Claude Code config home — `~/.claude`,
/// `$CLAUDE_CONFIG_DIR`, or the live suite's `/tmp/afleet-fixtures/config-home` (parent X9). This type is how a
/// test gets a home-shaped directory anyway, and it refuses to be built anywhere near the three protected roots.
final class ScratchConfigHome {
    let url: URL

    var configHome: ConfigHome { ConfigHome(root: url, source: .environment) }

    init() throws {
        let candidate = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "afleet-c4-home-\(UUID().uuidString)")
        Self.refuseProtectedRoots(candidate)
        url = candidate

        let fm = FileManager.default
        try fm.createDirectory(at: url.appending(path: "sessions"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: url.appending(path: "jobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appending(path: "daemon"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appending(path: "projects"), withIntermediateDirectories: true)
        try write(["proto": 1, "supervisorPid": Int(ProcessInfo.processInfo.processIdentifier),
                   "updatedAt": 0, "workers": [String: Any]()],
                  to: url.appending(path: "daemon/roster.json"))
        try write(["projects": [String: Any]()], to: url.appending(path: ".claude.json"))
    }

    /// Marks a project root trusted, the way the trust dialog does — in *this* directory, which is a home the test
    /// created and not one the never-write rule protects.
    func trust(root: URL) throws {
        let file = url.appending(path: ".claude.json")
        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var projects = document["projects"] as? [String: Any] ?? [:]
        let key = root.resolvingSymlinksInPath().path(percentEncoded: false)
        var entry = projects[key] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[key] = entry
        document["projects"] = projects
        try write(document, to: file)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
    }

    /// The three roots no test may touch. A candidate equal to one of them, or under one of them, is a bug in the
    /// test, not a condition to recover from.
    private static func refuseProtectedRoots(_ candidate: URL) {
        var protected = [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
                         URL(filePath: "/tmp/afleet-fixtures/config-home")]
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            protected.append(URL(filePath: override))
        }
        let path = candidate.resolvingSymlinksInPath().path(percentEncoded: false)
        for root in protected {
            let rootPath = root.resolvingSymlinksInPath().path(percentEncoded: false)
            precondition(path != rootPath && !path.hasPrefix(rootPath + "/"),
                         "a scratch config home may not be created under a Claude Code config home")
        }
    }
}
