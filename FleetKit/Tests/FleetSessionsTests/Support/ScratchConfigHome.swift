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
    let source: ConfigHome.Source

    var configHome: ConfigHome { ConfigHome(root: url, source: source) }

    /// `source` chooses the *layout*, which is not cosmetic: an `.environment` home holds its global
    /// config document inside itself and a `.default` home's document is the sibling
    /// `<parent>/.claude.json` (`ConfigHome.globalConfig`), and the two are different files. It also
    /// decides whether a child launched against this home is told `CLAUDE_CONFIG_DIR` at all
    /// (§6.1), which is what a test needs control of when the child is `Tools/fake-claude`: the
    /// replayer refuses to write into a home that variable names, so a test that wants a real
    /// transcript materialised has to be a default-home test.
    init(source: ConfigHome.Source = .environment) throws {
        self.source = source
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "afleet-c4-home-\(UUID().uuidString)")
        let candidate = source == .default ? base.appending(path: ".claude") : base
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
        try write(["projects": [String: Any]()], to: configHome.globalConfig)
    }

    /// Marks a project root trusted, the way the trust dialog does — in *this* directory, which is a home the test
    /// created and not one the never-write rule protects.
    func trust(root: URL) throws { try setTrust(root: root, true) }

    /// The same write with the answer the dialog recorded, so a test can produce the *declined* entry as well as
    /// the accepted one.
    func setTrust(root: URL, _ accepted: Bool) throws {
        try mutateProjectEntry(root: root) { $0["hasTrustDialogAccepted"] = accepted }
    }

    /// The legacy per-project consent arrays live here. The engine migrates them into local settings at startup and
    /// its consent decision never reads them; a test writes them to prove afleet does not read them either.
    func setProjectEntry(root: URL, _ fields: [String: Any]) throws {
        try mutateProjectEntry(root: root) { entry in for (k, v) in fields { entry[k] = v } }
    }

    private func mutateProjectEntry(root: URL, _ body: (inout [String: Any]) -> Void) throws {
        let file = configHome.globalConfig
        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var projects = document["projects"] as? [String: Any] ?? [:]
        // `realpath`, not `resolvingSymlinksInPath`: the latter rewrites `/private/var` back to `/var`, which is
        // the spelling the reader will never produce, so the entry would be written under a key nothing looks up.
        let key = TemporaryProject.realpath(root)
        var entry = projects[key] as? [String: Any] ?? [:]
        body(&entry)
        projects[key] = entry
        document["projects"] = projects
        try write(document, to: file)
    }

    func removeAll() {
        // The base and not the leaf: a `.default` home's global config document is the leaf's
        // sibling, so removing `url` alone would leave the document behind.
        try? FileManager.default.removeItem(at: source == .default ? url.deletingLastPathComponent() : url)
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
