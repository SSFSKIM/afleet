import Foundation

public struct ConfigHome: Hashable, Codable, Sendable {
    public var root: URL
    public var source: Source
    public var projectDirName: String?
    public enum Source: String, Codable, Sendable { case environment, `default` }
    public init(root: URL, source: Source, projectDirName: String? = nil) {
        self.root = root; self.source = source; self.projectDirName = projectDirName
    }

    /// Where the engine's global config document actually is, which is **not** always inside the home.
    ///
    /// The engine resolves the document as `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")`
    /// (2.1.263 `cli.pretty.js:298330`, `Ot(e)`), while the config home is
    /// `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")` (`:298581`, `:828780` the same shape). The two
    /// expressions coincide only when the variable is set. With it unset — the ordinary installation —
    /// the home is `~/.claude` and the document is its *sibling* `~/.claude.json`; `<home>/.claude.json`
    /// names a file the engine never reads.
    ///
    /// `source` already records which derivation produced `root`, so this needs nothing from the
    /// environment a second time.
    public var globalConfig: URL {
        switch source {
        case .environment: root.appending(path: ".claude.json")
        case .default: root.deletingLastPathComponent().appending(path: ".claude.json")
        }
    }
}
