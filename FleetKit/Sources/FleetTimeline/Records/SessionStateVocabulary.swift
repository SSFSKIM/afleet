/// The engine's own record-kind table, transcribed from 2.1.258 `cli.pretty.js` lines 428922 (`dts`: fold policy) and
/// 429460 (`vbr`: dedup policy). Thirty-eight kinds in all: the five conversation kinds (`Vr` at line 250499) and the
/// thirty-three state kinds below. `dts` folds `progress` as "boundary-cleared", not "transcript" — `conversationKinds` is
/// the reducer's partition, not a `dts` fold class. `vbr` gives "dedup-transcript" to exactly the five conversation kinds
/// and to no state kind (the state kinds are "always", bar three routed "route-by-agent"): the engine never
/// content-deduplicates a state record, which is why `RecordKey` carries an occurrence ordinal. A kind outside this set
/// decodes as `.unknown` and fails the vocabulary assertion, because a new kind is drift this child exists to notice.
public enum SessionStateVocabulary {
    public enum Fold: String, Sendable { case lastWins = "last-wins", accumulate, boundaryCleared = "boundary-cleared", transcript }
    public static let conversationKinds: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
    public static let kinds: [String: Fold] = [
        "file-history-snapshot": .boundaryCleared, "file-history-delta": .boundaryCleared, "last-prompt": .boundaryCleared,
        "continued-in": .boundaryCleared, "marble-origami-commit": .boundaryCleared, "marble-origami-snapshot": .boundaryCleared,
        "marble-origami-reset": .boundaryCleared,
        "content-replacement": .accumulate, "fork-context-ref": .accumulate, "frame-link": .accumulate, "artifact-comment-monitor": .accumulate,
        "summary": .lastWins, "custom-title": .lastWins, "ended-by-model": .lastWins, "ai-title": .lastWins, "tag": .lastWins,
        "relocated": .lastWins, "agent-name": .lastWins, "agent-color": .lastWins, "agent-setting": .lastWins, "pr-link": .lastWins,
        "artifact-autoreact-ledger": .lastWins, "bridge-session": .lastWins, "history-suppression": .lastWins,
        "attribution-snapshot": .lastWins, "mode": .lastWins, "permission-mode": .lastWins, "isolation-latch": .lastWins,
        "atis-latch": .lastWins, "worktree-state": .lastWins, "cost-state": .lastWins, "queue-operation": .lastWins,
        "observer-ref": .lastWins,
    ]
    /// `agent_metadata` is the mirror's name for the sidecar and is neither conversation nor session state; it is routed on its own.
    public static let mirrorOnlyKinds: Set<String> = ["agent_metadata"]
    public static func isKnown(_ kind: String) -> Bool { conversationKinds.contains(kind) || kinds[kind] != nil || mirrorOnlyKinds.contains(kind) }
}
