import Foundation
import AfleetCore

public extension ConfigHome {
    /// §6.9: CLAUDE_CONFIG_DIR when set and non-empty (tilde-expanded, standardized), else <HOME>/.claude.
    static func derive(from env: ResolvedEnvironment) -> ConfigHome {
        let home = env.variables["HOME"] ?? NSHomeDirectory()
        if let raw = env.variables["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
            let expanded = raw.hasPrefix("~") ? home + raw.dropFirst() : raw
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            return ConfigHome(root: URL(fileURLWithPath: url.path), source: .environment, projectDirName: env.variables["CLAUDE_CODE_PROJECT_DIR_NAME"])
        }
        return ConfigHome(root: URL(fileURLWithPath: home).appendingPathComponent(".claude"), source: .default, projectDirName: nil)
    }
}
