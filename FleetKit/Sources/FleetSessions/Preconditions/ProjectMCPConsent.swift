import Foundation
import ClaudeWire

/// Which settings source decided a server, or afleet's own store when the user accepted it.
public enum ServerSource: String, Hashable, Sendable {
    case localSettings, projectSettings, userSettings, acceptance
}

/// Rejected wins over approved wins over pending.
public enum ServerVerdict: Hashable, Sendable {
    case rejected(ServerSource)
    case approved(ServerSource)
    case pending
}

/// Every project MCP server's consent state, computed the way the engine computes it.
///
/// The engine's consent function (bundle 2.1.257 `cli.pretty.js`, chunk `1kg58a1a`, pretty lines 94640–94682) reads
/// the *merged effective settings the settings loader returns from disk*: `disabledMcpjsonServers` naming the server
/// is rejected, `enabledMcpjsonServers` naming it or `enableAllProjectMcpServers` is approved, anything else is
/// pending. The per-project arrays in `<configHome>/.claude.json` are **not** read there. They are a legacy location
/// the startup migration (`migrateEnableAllProjectMcpServersToSettings`, pretty lines 503739–503785) copies into
/// local settings and clears, so a host that read them would be reading a file the engine has already emptied —
/// C1's `mcp-decline-files` spike watched the terminal decline a server and leave both arrays empty there.
///
/// Everything this type touches, it reads. The one write in §6.12 is `LocalSettingsStore.decline`.
public struct ProjectMCPConsent: Sendable {
    private let settings: LocalSettingsStore

    public init(settings: LocalSettingsStore = LocalSettingsStore()) { self.settings = settings }

    /// Every server `<root>/.mcp.json` declares, in name order. A shape this build does not recognise is listed and
    /// gated like the rest rather than dropped: an unlisted server is a server nobody was asked about.
    public func servers(root: URL) -> [ProjectMCPServer] {
        guard let data = try? Data(contentsOf: root.appending(path: ".mcp.json")),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = document["mcpServers"] as? [String: Any] else { return [] }
        return entries.keys.sorted().compactMap { name -> ProjectMCPServer? in
            guard let raw = entries[name],
                  // The hash covers the *whole raw entry*, canonicalised, so a change to args, env, headers or url
                  // reopens consent — not only a change to the command.
                  let canonical = try? JSONSerialization.data(withJSONObject: raw,
                                                              options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return ProjectMCPServer(name: name, transport: Self.transport(of: raw),
                                    entryHash: ContentHash.sha256Hex(canonical))
        }
    }

    /// The verdict per declared server. `settingSources` is the launch's: nil is the CLI default, which is all
    /// three, and a source the launch excludes is a file this reader does not consult.
    public func evaluate(root: URL, gitRoot: URL?, cwd: URL, configHome: URL,
                         settingSources: [SettingSource]?,
                         acceptances: [ProjectServerAcceptance]) -> [ProjectMCPServer: ServerVerdict] {
        // Resolved first and unconditionally: §6.12's re-read before a spawn is this call, and it must happen
        // whether or not the project turns out to declare anything.
        let resolution = settings.resolve(gitRoot: gitRoot, cwd: cwd)
        let declared = servers(root: root)
        guard !declared.isEmpty else { return [:] }

        let sources = settingSources ?? [.user, .project, .local]
        var merged: [(ServerSource, [String: Any])] = []
        if sources.contains(.local) {
            merged.append((.localSettings, Self.object(at: resolution.storeFile)))
            if let overlay = resolution.legacyOverlay { merged.append((.localSettings, Self.object(at: overlay))) }
        }
        if sources.contains(.project) {
            merged.append((.projectSettings, Self.object(at: root.appending(path: ".claude/settings.json"))))
        }
        if sources.contains(.user) {
            merged.append((.userSettings, Self.object(at: configHome.appending(path: "settings.json"))))
        }

        let rootPath = RealPath.string(root)
        var out: [ProjectMCPServer: ServerVerdict] = [:]
        for server in declared {
            out[server] = Self.verdict(for: server, merged: merged, acceptances: acceptances, root: rootPath)
        }
        return out
    }

    private static func verdict(for server: ProjectMCPServer, merged: [(ServerSource, [String: Any])],
                                acceptances: [ProjectServerAcceptance], root: String) -> ServerVerdict {
        for (source, object) in merged
        where (object[LocalSettingsStore.disabledKey] as? [String])?.contains(server.name) == true {
            return .rejected(source)
        }
        for (source, object) in merged {
            if (object["enabledMcpjsonServers"] as? [String])?.contains(server.name) == true
                || object["enableAllProjectMcpServers"] as? Bool == true {
                return .approved(source)
            }
        }
        // afleet's own record of the sheet the user answered, per project, per name, per entry hash: a changed entry
        // has a different hash and asks again.
        if acceptances.contains(where: { $0.projectRoot == root && $0.serverName == server.name
                                          && $0.entryHash == server.entryHash }) {
            return .approved(.acceptance)
        }
        return .pending
    }

    /// The three shapes bundle 38223 admits, and one bucket for everything else.
    private static func transport(of raw: Any) -> ProjectMCPServer.Transport {
        guard let entry = raw as? [String: Any] else { return .other(type: "unknown") }
        switch entry["type"] as? String {
        case nil:
            guard let command = entry["command"] as? String else { return .other(type: "unknown") }
            return .stdio(command: command, arguments: entry["args"] as? [String] ?? [])
        case "http": return .http(url: entry["url"] as? String ?? "")
        case "sse": return .sse(url: entry["url"] as? String ?? "")
        case .some(let declared): return .other(type: declared)
        }
    }

    private static func object(at file: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }
}
