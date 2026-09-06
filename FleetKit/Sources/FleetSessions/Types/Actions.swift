import Foundation
import AfleetCore
import ClaudeWire

/// What the lifecycle must be satisfied of before it spawns. `.ready` is the only value that lets a spawn through.
public enum SpawnPrecondition: Hashable, Sendable {
    case ready
    case untrusted(root: URL)
    /// Name, transport summary and hash of every project server the user has not decided about.
    case consentNeeded([ProjectMCPServer])
    case managedSettingsPending
    case contended(HolderSet)
    case wedged(EscalationTrace)
}

/// One server entry of a project's `.mcp.json`, parsed far enough to describe and to gate.
public struct ProjectMCPServer: Hashable, Sendable {
    public var name: String
    /// Parsed from the raw entry: no `type` and a `command` is stdio; `type` http/sse carries a url; anything else
    /// is `.other`, still listed and still consent-gated.
    public var transport: Transport
    /// SHA-256 (`ContentHash.sha256Hex`) over the canonical JSON of the *whole* raw entry, so any field change
    /// reopens consent.
    public var entryHash: String
    public init(name: String, transport: Transport, entryHash: String) {
        self.name = name; self.transport = transport; self.entryHash = entryHash
    }
}

extension ProjectMCPServer {
    public enum Transport: Hashable, Sendable {
        case stdio(command: String, arguments: [String])   // no `type`, a `command`
        case http(url: String)                             // type: "http"
        case sse(url: String)                              // type: "sse"
        case other(type: String)                           // anything else: still listed, still consent-gated
    }
}

/// One roster job, reconciled with `agents --json` when read; an exec job has no session.
public struct JobEntry: Hashable, Sendable {
    public var short: JobShort
    public var state: String
    public var kind: String
    /// nil for an exec job.
    public var sessionID: SessionID?
    public var cwd: URL?
    public var name: String?
    public init(short: JobShort, state: String, kind: String, sessionID: SessionID?, cwd: URL?, name: String?) {
        self.short = short; self.state = state; self.kind = kind
        self.sessionID = sessionID; self.cwd = cwd; self.name = name
    }
}

/// `LifecycleAPI.performJob(_:_:)`: `claude stop|respawn|rm <short>` through the runner, no PTY.
public enum JobVerb: Hashable, Sendable { case stop, respawn, remove }

/// Sendable only, never Hashable: `InboundAnswer` is not Hashable.
public enum LifecycleAction: Sendable {
    case open
    case send(UserInput)
    case reap
    case adopt
    case sendToBackground
    /// nil = a plain fork; `ForkPoint` is ClaudeWire's `{entryUUID, dropsTurn?}`.
    case fork(at: ForkPoint?)
    case quiescentRestart(RestartRequest)
    case stopEverything
    case backgroundAll
    case logout
    case reopen
    /// The one path a decision is answered through; `LifecycleError.decisionGone` when the id is gone.
    case answer(RequestID, InboundAnswer)
}

/// The lifecycle operations a channel runs one at a time. The supervisor holds at most one in flight and refuses a
/// second entrant with `LifecycleError.busy`; nothing waits on the marker, so nothing can deadlock on it. An X5
/// addition: C5 and C6 see `busy` where they previously saw two entrants both proceed.
public enum LifecycleOperation: String, Hashable, Sendable {
    case spawn, handOff, restart, reopen, adopt, evict, reap
}

public enum LifecycleError: Error, Hashable, Sendable {
    case heldElsewhere(HolderSet)
    case capReached(live: Int)
    case precondition(SpawnPrecondition)
    case wedged(EscalationTrace)
    case handoffTimedOut(HolderSet)
    case declineRefused(reason: String)
    case notOwned
    case verbFailed(verb: String, exitCode: Int32)
    /// The verb outlasted its budget and the runner had to signal the child. Distinct from `verbFailed` because
    /// the two ask for different answers: a non-zero exit is the CLI refusing the request, while this is afleet
    /// giving up on a child that never returned — and the third merge-evidence run could not tell them apart,
    /// because a killed child's `-1` reads exactly like any other failure. `childState` is what the kernel said
    /// about that child at the instant its budget expired, which is what says whether it had hung, had exited
    /// unreaped, or had been collected by something else.
    case verbTimedOut(verb: String, afterMs: Int, childState: String)
    /// An answer for an id that is unknown, cancelled, already answered or from an older epoch.
    case decisionGone(RequestID)
    /// The write behind an answer failed; the id is consumed (`ClaudeProcess.answer` removes `pendingInbound[id]`
    /// before it writes) and is not restored.
    case answerFailed(RequestID, reason: String)
    /// The spawn barrier while a `LogoutPlan` runs.
    case logoutInProgress
    /// The action needs a quiescent channel and this one is not: *Reap* with a decision on screen, a turn in
    /// flight or a background shell still working. The blocker is the one the verdict named, so a surface can say
    /// what is holding the channel rather than "not now".
    case notEligible(DormantEligibility.Blocker)
    /// Another lifecycle operation on this channel is already in flight. The two documented exceptions never raise
    /// it: a send while a spawn is in flight queues, and a restart asked for while one runs merges into the
    /// pending change.
    case busy(LifecycleOperation)
}
