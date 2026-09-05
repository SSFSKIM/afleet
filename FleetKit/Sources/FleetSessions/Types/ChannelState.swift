import Foundation
import AfleetCore
import ClaudeWire

/// A channel is one session under one config home. Two config homes may hold the same session id and they are
/// two channels; nothing in the fleet is keyed by session id alone.
public struct ChannelKey: Hashable, Codable, Sendable {
    public let configHome: URL
    public let session: SessionID
    public init(configHome: URL, session: SessionID) { self.configHome = configHome; self.session = session }
}

/// What afleet *wants* this channel to be. The disagreement between `desired` and `observed` is the parent's
/// rule 1 and is what the contended banner reads.
public enum DesiredOwnership: String, Codable, Sendable { case owned, mirror, none }

/// One observed holder of a session: a registry record, a roster worker, an `agents --json` row, or a merge of them.
public struct Holder: Hashable, Sendable {
    public enum Source: Hashable, Sendable { case registry, roster, agentsJSON }
    public var pid: Int32
    public var sessionID: SessionID
    public var sources: Set<Source>
    public var kind: String
    public var entrypoint: String?
    public var jobShort: String?
    /// The pid equals a live `ClaudeProcess` of ours.
    public var isOwnChild: Bool
    /// Evidence, not branch order: `OriginResolver` classifies a holder by this, so a conversation job's worker —
    /// present in both the registry and the roster — is a job and never a foreign terminal.
    public var isJob: Bool { sources.contains(.roster) || jobShort != nil }
    /// Status, waitingFor and name when the record carries them; nil for every headless holder.
    public var presence: ForeignPresence?

    public init(pid: Int32, sessionID: SessionID, sources: Set<Source>, kind: String,
                entrypoint: String? = nil, jobShort: String? = nil, isOwnChild: Bool = false,
                presence: ForeignPresence? = nil) {
        self.pid = pid; self.sessionID = sessionID; self.sources = sources; self.kind = kind
        self.entrypoint = entrypoint; self.jobShort = jobShort; self.isOwnChild = isOwnChild
        self.presence = presence
    }
}

/// One snapshot of live holders, stamped with the moment it was read. `FleetObserver` publishes a fleet-wide set
/// that `holders(for:)` narrows to a session; a `ChannelState` carries the holders of its own session.
public struct HolderSet: Hashable, Sendable {
    public var holders: [Holder]
    public var observedAt: Date
    public var foreign: [Holder] { holders.filter { !$0.isOwnChild } }
    public init(holders: [Holder], observedAt: Date) { self.holders = holders; self.observedAt = observedAt }
}

public enum Presence: Hashable, Sendable { case idle, busy, waiting(for: String?), unknown }

/// What a foreign holder's own record says about itself.
public struct ForeignPresence: Hashable, Sendable {
    public var status: String
    public var waitingFor: String?
    public var name: String?
    public init(status: String, waitingFor: String? = nil, name: String? = nil) {
        self.status = status; self.waitingFor = waitingFor; self.name = name
    }
}

/// The `terminate_escalated` steps of one epoch, in order: the evidence behind the wedged row.
public struct EscalationTrace: Hashable, Sendable {
    public var steps: [String]
    public var pid: Int32
    public var epoch: ProcessEpoch
    public init(steps: [String], pid: Int32, epoch: ProcessEpoch) { self.steps = steps; self.pid = pid; self.epoch = epoch }
}

/// `ProcessHandle.terminate()`'s result. A nil `exit` is the escalation running out — the wedged row.
public struct TerminationReport: Hashable, Sendable {
    /// nil: the escalation ran out (wedged).
    public var exit: ExitStatus?
    /// ClaudeWire's `terminate_escalated` steps for this epoch, in order, as the diagnostics sink captured them.
    public var steps: [String]
    public init(exit: ExitStatus?, steps: [String]) { self.exit = exit; self.steps = steps }
}

/// One surfaced `InboundRequest`, in ask order; the Activity view's decision rows read these.
public struct PendingDecision: Hashable, Sendable {
    public var id: RequestID
    /// can_use_tool, hook_callback, ... — from the request's payload.
    public var subtype: String
    public var epoch: ProcessEpoch
    /// Stamped by the supervisor when the frame arrived.
    public var askedAt: Date
    public init(id: RequestID, subtype: String, epoch: ProcessEpoch, askedAt: Date) {
        self.id = id; self.subtype = subtype; self.epoch = epoch; self.askedAt = askedAt
    }
}

/// The one item afleet writes into a transcript itself. `ExitStatus` is Hashable on ClaudeWire's side.
public enum SystemItem: Hashable, Sendable {
    case crashed(exit: ExitStatus, reopenOffered: Bool)
    case wedged(EscalationTrace, reopenOffered: Bool)
    /// A fork whose engine never announced its own session id within the supervisor's deadline. Not a crash: afleet
    /// ended the child itself, and the exit is that termination's. It carries `reopenOffered` like the other two
    /// because what the user needs is the same affordance, and a banner could not offer it.
    case forkIdentityTimedOut(exit: ExitStatus, reopenOffered: Bool)
}

/// The channel-level banners of §7.4 and §6.12.
public enum ChannelBanner: Hashable, Sendable {
    case releasedToTerminal                       // "Opened in your terminal; afleet released this session"
    case contended(HolderSet)
    case settingDidNotSurvive(String)             // the setting's name
    // the reason word: unparseable, symlink, notADirectory, foreignUID, insideConfigHome, processLive, writeFailed
    case mcpDeclineRefused(String)
    case managedSettingsPending
    case untrusted
    case heldElsewhere(HolderSet)                 // send refused; Fork offered
}

public enum HeaderNote: Hashable, Sendable { case projectServersOff, capReached(live: Int) }

/// Everything a surface needs about one channel. Published on every transition through `LifecycleAPI.updates`.
public struct ChannelState: Hashable, Sendable {
    public var key: ChannelKey
    /// X2; `.owned(.contended)` is the Contended state.
    public var origin: ChannelOrigin
    public var desired: DesiredOwnership
    public var observed: HolderSet
    public var epoch: ProcessEpoch?
    /// ClaudeWire's: `.known(id)`, or `.awaitingFork(from:provisional:)` until `.sessionIdentityResolved`.
    public var identity: SessionIdentity
    /// Non-nil only in the wedged row.
    public var wedged: EscalationTrace?
    public var systemItem: SystemItem?
    public var presence: Presence
    /// Ask order; emptied on every exit.
    public var pendingDecisions: [PendingDecision]
    public var lastActivity: Date
    /// From the first `system/init`, kept per channel for the header.
    public var apiKeySource: String?
    /// Owned processes live across the fleet, for the cap header.
    public var liveCount: Int
    public var banner: ChannelBanner?
    public var headerNote: HeaderNote?
    /// "Applies when the current work finishes".
    public var pendingChange: RestartRequest?

    public init(key: ChannelKey, origin: ChannelOrigin, desired: DesiredOwnership, observed: HolderSet,
                epoch: ProcessEpoch? = nil, identity: SessionIdentity, wedged: EscalationTrace? = nil,
                systemItem: SystemItem? = nil, presence: Presence = .unknown,
                pendingDecisions: [PendingDecision] = [], lastActivity: Date, apiKeySource: String? = nil,
                liveCount: Int = 0, banner: ChannelBanner? = nil, headerNote: HeaderNote? = nil,
                pendingChange: RestartRequest? = nil) {
        self.key = key; self.origin = origin; self.desired = desired; self.observed = observed
        self.epoch = epoch; self.identity = identity; self.wedged = wedged; self.systemItem = systemItem
        self.presence = presence; self.pendingDecisions = pendingDecisions; self.lastActivity = lastActivity
        self.apiKeySource = apiKeySource; self.liveCount = liveCount; self.banner = banner
        self.headerNote = headerNote; self.pendingChange = pendingChange
    }
}

/// A change the user asked for that a quiescent restart will apply. Each field is a *double* optional where the
/// CLI itself has a default worth naming: the outer nil keeps the current value, the inner nil means the CLI default.
public struct RestartRequest: Hashable, Sendable {
    /// nil: keep the current value.
    public var addDirectories: [URL]?
    /// outer nil: keep the current value; inner nil: the CLI default.
    public var settingSources: [SettingSource]??
    /// nil: keep the current value.
    public var allowBypass: Bool?
    /// nil: keep the current value.
    public var promptSuggestions: Bool?
    /// outer nil: keep the current value; inner nil: the CLI default (no worktree).
    public var worktree: Worktree??
    /// nil: keep the current value.
    public var environment: ChildEnvironmentOptions?

    public init(addDirectories: [URL]? = nil, settingSources: [SettingSource]?? = nil, allowBypass: Bool? = nil,
                promptSuggestions: Bool? = nil, worktree: Worktree?? = nil, environment: ChildEnvironmentOptions? = nil) {
        self.addDirectories = addDirectories; self.settingSources = settingSources; self.allowBypass = allowBypass
        self.promptSuggestions = promptSuggestions; self.worktree = worktree; self.environment = environment
    }
}

/// Actor-owned by the supervisor: every control response and frame that changes a value updates it, and the
/// quiescent restart relaunches from a copy of it.
public struct SessionRuntimeState: Hashable, Sendable {
    public var permissionMode: PermissionMode?
    public var model: String?
    public var effort: String?
    public var outputStyle: String?
    public var cwd: URL
    public var agent: String?
    public var addDirectories: [URL]
    public var environment: ChildEnvironmentOptions
    /// The union of every `apply_flag_settings` payload sent through `perform`.
    public var flagSettings: [String: JSONValue]
    /// `fast_mode_state` from the handshake and every result frame.
    public var fastModeObserved: Bool?

    public init(permissionMode: PermissionMode? = nil, model: String? = nil, effort: String? = nil,
                outputStyle: String? = nil, cwd: URL, agent: String? = nil, addDirectories: [URL] = [],
                environment: ChildEnvironmentOptions = ChildEnvironmentOptions(),
                flagSettings: [String: JSONValue] = [:], fastModeObserved: Bool? = nil) {
        self.permissionMode = permissionMode; self.model = model; self.effort = effort
        self.outputStyle = outputStyle; self.cwd = cwd; self.agent = agent
        self.addDirectories = addDirectories; self.environment = environment
        self.flagSettings = flagSettings; self.fastModeObserved = fastModeObserved
    }
}

/// The copy the quiescent restart takes at the moment it decides to restart.
public typealias RestartSnapshot = SessionRuntimeState
