import Foundation
import ClaudeWire

/// One logical session as the index knows it, from a single head-and-tail read of one main transcript.
///
/// The engine's picker drop rules are **not** applied: `entrypoint`, `sessionKind`, `isSidechain`, `teamName` and
/// `continuedIn` are carried and none of them hides an entry. afleet's own sessions are `entrypoint: sdk-cli`, which
/// the terminal's picker hides and afleet must show; the sidebar policy is C4's (spec Contracts X5, X6).
public struct IndexEntry: Hashable, Sendable, Codable {
    public let sessionID: SessionID
    /// The main transcript this entry was read from. Two files can carry one id; this is the survivor with the later `mtime`.
    public var path: URL
    public var slug: String
    /// The last `relocated` record's `relocatedCwd` when there is one, else the first line that carries a `cwd`.
    public var cwd: String?
    public var title: String
    public var titleSource: TitleSource
    public var firstPrompt: String?
    public var lastPrompt: String?
    /// `lastPrompt ?? summary ?? firstPrompt ?? ""`, truncated to 200 characters.
    public var preview: String
    public var gitBranch: String?
    public var tag: String?
    public var agentName: String?
    public var mtime: Date
    public var size: Int64
    public var createdAt: Date?
    public var entrypoint: String?
    public var sessionKind: String?
    public var isSidechain: Bool
    public var teamName: String?
    /// The last `continued-in` line's `continuedInSessionId` — the destination. That line's own `sessionId` is this
    /// file's id and is never read for this field (2.1.258 line 246351).
    public var continuedIn: SessionID?
    public var clearedToEmpty: Bool
    public var hasSubagents: Bool
    /// nil until a full read has counted it: the picker itself shows bytes, and a count would cost the parse the budget forbids.
    public var turnCount: Int?

    public init(sessionID: SessionID, path: URL, slug: String, cwd: String? = nil, title: String,
                titleSource: TitleSource, firstPrompt: String? = nil, lastPrompt: String? = nil, preview: String,
                gitBranch: String? = nil, tag: String? = nil, agentName: String? = nil, mtime: Date, size: Int64,
                createdAt: Date? = nil, entrypoint: String? = nil, sessionKind: String? = nil, isSidechain: Bool = false,
                teamName: String? = nil, continuedIn: SessionID? = nil, clearedToEmpty: Bool = false,
                hasSubagents: Bool = false, turnCount: Int? = nil) {
        self.sessionID = sessionID; self.path = path; self.slug = slug; self.cwd = cwd
        self.title = title; self.titleSource = titleSource
        self.firstPrompt = firstPrompt; self.lastPrompt = lastPrompt; self.preview = preview
        self.gitBranch = gitBranch; self.tag = tag; self.agentName = agentName
        self.mtime = mtime; self.size = size; self.createdAt = createdAt
        self.entrypoint = entrypoint; self.sessionKind = sessionKind; self.isSidechain = isSidechain
        self.teamName = teamName; self.continuedIn = continuedIn; self.clearedToEmpty = clearedToEmpty
        self.hasSubagents = hasSubagents; self.turnCount = turnCount
    }
}

/// The whole index at one instant. Keyed by session id: two files can carry one id and only one entry survives.
public struct IndexSnapshot: Sendable, Codable, Hashable {
    public var configHome: URL
    public var builtAt: Date
    public var entries: [SessionID: IndexEntry]
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1

    public init(configHome: URL, builtAt: Date, entries: [SessionID: IndexEntry], schemaVersion: Int = IndexSnapshot.currentSchemaVersion) {
        self.configHome = configHome; self.builtAt = builtAt; self.entries = entries; self.schemaVersion = schemaVersion
    }
}

/// What one `update(changed:)` did. A session is never both `removed` and `added` in one update.
public struct IndexDelta: Hashable, Sendable, Codable {
    public var added: [SessionID]
    public var updated: [SessionID]
    public var removed: [SessionID]
    public var durationMs: Int

    public init(added: [SessionID] = [], updated: [SessionID] = [], removed: [SessionID] = [], durationMs: Int = 0) {
        self.added = added; self.updated = updated; self.removed = removed; self.durationMs = durationMs
    }
}
