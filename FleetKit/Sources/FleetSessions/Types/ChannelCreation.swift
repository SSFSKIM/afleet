import Foundation
import AfleetCore
import ClaudeWire

/// What the app asks for when the user presses *New channel* (parent §8.2, §14 item 3).
///
/// A request value beside `RestartRequest`, and for the same reason: the fields a launch can be
/// *started* with are not the fields a running channel exposes, so the surface names them once and
/// the fleet composes the launch line. It carries no `SessionID` — minting the id is the whole
/// point of the verb this value is passed to, and a caller that chose one would be choosing a
/// channel's identity outside the fleet that has to file it.
///
/// `worktree` is §8.2's *New isolated session*: `-w <name>` makes the CLI create the checkout under
/// `<repo>/.claude/worktrees/<name>` itself, so nothing here runs `git`.
public struct ChannelCreation: Hashable, Sendable {
    /// Where the channel runs. For a worktree creation this is the repository the CLI creates the
    /// checkout inside; the channel's own directory becomes the worktree's once it resumes.
    public var cwd: URL
    public var worktree: Worktree?
    public var model: String?
    public var permissionMode: PermissionMode?
    public var effort: String?
    public var agent: String?
    /// `-n <name>`: the session name, which is also the title the pending row shows before the
    /// engine has an AI title of its own.
    public var name: String?
    /// The Developer setting *Isolated settings for new channels*, read at creation time. On, the
    /// launch carries `settingSources = []` — rendered `--setting-sources ""` — and
    /// `SpawnPreconditions.evaluate` adds `--strict-mcp-config` when the project declares
    /// `.mcp.json` servers (parent §6.12).
    public var isolatedSettings: Bool

    public init(cwd: URL, worktree: Worktree? = nil, model: String? = nil,
                permissionMode: PermissionMode? = nil, effort: String? = nil, agent: String? = nil,
                name: String? = nil, isolatedSettings: Bool = false) {
        self.cwd = cwd
        self.worktree = worktree
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.agent = agent
        self.name = name
        self.isolatedSettings = isolatedSettings
    }

    /// The directory this channel will actually run in once the CLI has made the checkout: §8.2's
    /// `<repo>/.claude/worktrees/<name>`, or `cwd` when no worktree was asked for.
    ///
    /// The engine's, not a guess: `-w <name>` creates the worktree at exactly this path on branch
    /// `worktree-<name>` (spike S10, fixture `session-mirror-relocation`). A surface draws a pending
    /// row here so the row lands under its repository before any transcript exists; the runtime cwd
    /// afterwards is the engine's own report on `system/init`.
    public var expectedCWD: URL {
        guard case .named(let name)? = worktree else { return cwd }
        return cwd.appending(path: ".claude/worktrees/\(name)", directoryHint: .isDirectory)
    }
}
